import { execSync } from 'child_process';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { DynamoDBClient, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { scanCode } from './scanner.js';
import fs from 'fs';
import path from 'path';


// Read environment variables (passed by Fargate task)
const REPO_URL       = process.env.REPO_URL;
const COMMIT_SHA     = process.env.COMMIT_SHA || 'HEAD';
const JOB_ID         = process.env.JOB_ID;
const PR_NUMBER      = process.env.PR_NUMBER;
const REPO_OWNER     = process.env.REPO_OWNER;
const REPO_NAME      = process.env.REPO_NAME;
const S3_BUCKET      = process.env.S3_BUCKET;
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE || 'pr-scanner-jobs';
const REGION         = process.env.AWS_DEFAULT_REGION || 'us-east-1';

const s3 = new S3Client({ region: REGION });
const dynamodb = new DynamoDBClient({ region: REGION });

const CLONE_DIR = '/tmp/repo';

function findJSFiles(dir) {
  const files = [];
  const items = fs.readdirSync(dir);
  for (const item of items) {
    if (item === 'node_modules' || item === '.git') continue;
    const fullPath = path.join(dir, item);
    const stat = fs.statSync(fullPath);
    if (stat.isDirectory()) {
      files.push(...findJSFiles(fullPath));
    } else if (item.endsWith('.js')) {
      files.push(fullPath);
    }
  }
  return files;
}

async function main() {
  const startedAt = Math.floor(Date.now() / 1000);
  console.log(`[PR Scanner] Starting scan for job ${JOB_ID}`);
  console.log(`[PR Scanner] Repo: ${REPO_URL}, Commit: ${COMMIT_SHA}`);

  try {
    // 1. Clone the repo
    console.log('[PR Scanner] Cloning repository...');
    execSync(`git clone ${REPO_URL} ${CLONE_DIR}`, { stdio: 'inherit' });
    if (COMMIT_SHA !== 'HEAD') {
      execSync(`cd ${CLONE_DIR} && git checkout ${COMMIT_SHA}`, { stdio: 'inherit' });
    }

    // 2. Find all JS files and scan them
    console.log('[PR Scanner] Scanning files...');
    const jsFiles = findJSFiles(CLONE_DIR);
    console.log(`[PR Scanner] Found ${jsFiles.length} JS files to scan`);

    const allVulnerabilities = [];
    const severityCount = { HIGH: 0, MEDIUM: 0, LOW: 0 };

    for (const filePath of jsFiles) {
      const code = fs.readFileSync(filePath, 'utf-8');
      const relativePath = path.relative(CLONE_DIR, filePath);
      const result = scanCode(code, relativePath);

      if (Array.isArray(result) && result.length > 0) {
        for (const vuln of result) {
          vuln.file = relativePath;
          allVulnerabilities.push(vuln);
          if (severityCount[vuln.severity] !== undefined) {
            severityCount[vuln.severity]++;
          }
        }
      }
    }

    const report = {
      job_id: JOB_ID,
      repo: `${REPO_OWNER}/${REPO_NAME}`,
      pr_number: PR_NUMBER,
      commit_sha: COMMIT_SHA,
      scanned_at: new Date().toISOString(),
      total_files_scanned: jsFiles.length,
      total_vulnerabilities: allVulnerabilities.length,
      severity_breakdown: severityCount,
      vulnerabilities: allVulnerabilities
    };

    console.log(`[PR Scanner] Scan complete: ${allVulnerabilities.length} vulnerabilities found`);
    console.log(`[PR Scanner] Severity: HIGH=${severityCount.HIGH}, MEDIUM=${severityCount.MEDIUM}, LOW=${severityCount.LOW}`);

    // 3. Upload report to S3
    const s3Key = `reports/${JOB_ID}.json`;
    console.log(`[PR Scanner] Uploading report to s3://${S3_BUCKET}/${s3Key}`);
    await s3.send(new PutObjectCommand({
      Bucket: S3_BUCKET,
      Key: s3Key,
      Body: JSON.stringify(report, null, 2),
      ContentType: 'application/json'
    }));

    // 4. Update DynamoDB
    const finishedAt = Math.floor(Date.now() / 1000);
    console.log('[PR Scanner] Updating DynamoDB...');
    await dynamodb.send(new UpdateItemCommand({
      TableName: DYNAMODB_TABLE,
      Key: {
        PK: { S: `REPO#${REPO_OWNER}/${REPO_NAME}` },
        SK: { S: `SCAN#${new Date(startedAt * 1000).toISOString()}#${PR_NUMBER}` }
      },
      UpdateExpression: 'SET #s = :s, findings_count = :fc, severity_breakdown = :sb, s3_report_key = :s3, started_at = :sa, finished_at = :fa',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: {
        ':s':  { S: 'COMPLETED' },
        ':fc': { N: String(allVulnerabilities.length) },
        ':sb': { S: JSON.stringify(severityCount) },
        ':s3': { S: s3Key },
        ':sa': { N: String(startedAt) },
        ':fa': { N: String(finishedAt) }
      }
    }));

    console.log(`[PR Scanner] Job ${JOB_ID} completed successfully`);
    process.exit(0);

  } catch (error) {
    console.error(`[PR Scanner] Error: ${error.message}`);
    try {
      await dynamodb.send(new UpdateItemCommand({
        TableName: DYNAMODB_TABLE,
        Key: {
          PK: { S: `REPO#${REPO_OWNER}/${REPO_NAME}` },
          SK: { S: `SCAN#${new Date(startedAt * 1000).toISOString()}#${PR_NUMBER}` }
        },
        UpdateExpression: 'SET #s = :s',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: { ':s': { S: 'FAILED' } }
      }));
    } catch (e) {
      console.error(`[PR Scanner] Failed to update DynamoDB: ${e.message}`);
    }
    process.exit(1);
  }
}

main();
