import json
import boto3
import urllib.request
import urllib.error
import os

dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
s3 = boto3.client('s3', region_name='us-east-1')
secretsmanager = boto3.client('secretsmanager', region_name='us-east-1')

TABLE_NAME = os.environ['DYNAMODB_TABLE']
S3_BUCKET   = os.environ['S3_BUCKET']
SECRET_NAME = os.environ.get('GITHUB_TOKEN_SECRET', 'cs6620/github-token')


def get_github_token():
    response = secretsmanager.get_secret_value(SecretId=SECRET_NAME)
    return response['SecretString']


def get_dynamodb_record(job_id):
    table = dynamodb.Table(TABLE_NAME)
    response = table.scan(
        FilterExpression='job_id = :jid',
        ExpressionAttributeValues={':jid': job_id}
    )
    items = response.get('Items', [])
    return items[0] if items else None


def get_s3_report(s3_key):
    response = s3.get_object(Bucket=S3_BUCKET, Key=s3_key)
    return json.loads(response['Body'].read().decode('utf-8'))


def format_pr_comment(record, report):
    total = report['summary']['totalVulnerabilities']
    high  = report['summary']['high']
    med   = report['summary']['medium']
    low   = report['summary']['low']

    lines = [
        "## 🔍 PR Security Scan Results",
        f"**Total vulnerabilities found: {total}** — 🔴 High: {high} | 🟡 Medium: {med} | 🟢 Low: {low}",
        "",
        "| Severity | Rule | File | Line | Message |",
        "|----------|------|------|------|---------|",
    ]

    for v in report.get('vulnerabilities', []):
        severity = v.get('severity', 'UNKNOWN')
        emoji = '🔴' if severity == 'HIGH' else ('🟡' if severity == 'MEDIUM' else '🟢')
        lines.append(
            f"| {emoji} {severity} | {v.get('id','')} | `{v.get('file','')}` | {v.get('line','')} | {v.get('message','')} |"
        )

    lines += [
        "",
        f"*Scanned commit: `{record.get('commit_sha', 'unknown')}`*",
        f"*Scan duration: {record.get('started_at','?')} → {record.get('finished_at','?')}*"
    ]

    return '\n'.join(lines)


def post_github_comment(token, repo_owner, repo_name, pr_number, comment):
    url = f"https://api.github.com/repos/{repo_owner}/{repo_name}/issues/{pr_number}/comments"
    payload = json.dumps({'body': comment}).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            'Authorization': f'token {token}',
            'Content-Type': 'application/json',
            'User-Agent': 'pr-scanner-lambda'
        },
        method='POST'
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode('utf-8'))


def lambda_handler(event, context):
    print(f"Event received: {json.dumps(event)}")

    # Extract job_id from EventBridge event
    detail = event.get('detail', {})
    job_id = detail.get('jobId') or event.get('job_id', 'test-job-001')

    print(f"Processing job_id: {job_id}")

    # Get DynamoDB record
    record = get_dynamodb_record(job_id)
    if not record:
        raise Exception(f"No DynamoDB record found for job_id: {job_id}")

    # Get S3 report
    s3_key = record['s3_report_key']
    report = get_s3_report(s3_key)

    # Format comment
    comment = format_pr_comment(record, report)

    # Get GitHub token and post comment
    token = get_github_token()
    result = post_github_comment(
        token,
        record['repo_owner'],
        record['repo_name'],
        int(record['pr_number']),
        comment
    )

    print(f"Comment posted: {result.get('html_url')}")
    return {
        'statusCode': 200,
        'body': json.dumps({'comment_url': result.get('html_url')})
    }