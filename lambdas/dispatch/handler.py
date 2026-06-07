import json
import os
import hmac
import hashlib
import logging
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
sqs_client = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")

WEBHOOK_SECRET_NAME = os.environ.get("WEBHOOK_SECRET_NAME", "cs6620/github-webhook-secret")
QUEUE_URL = os.environ["SCAN_JOBS_QUEUE_URL"]
TABLE_NAME = os.environ["SCAN_JOBS_TABLE"]

table = dynamodb.Table(TABLE_NAME)

_cached_secret = None


def get_webhook_secret():
    global _cached_secret
    if _cached_secret is None:
        resp = secrets_client.get_secret_value(SecretId=WEBHOOK_SECRET_NAME)
        _cached_secret = resp["SecretString"]
    return _cached_secret


def verify_signature(body: str, signature_header: str) -> bool:
    if not signature_header:
        logger.warning("Missing signature header")
        return False
    secret = get_webhook_secret().encode("utf-8")
    expected = "sha256=" + hmac.new(secret, body.encode("utf-8"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)


def get_header(event, name):
    headers = event.get("headers") or {}
    name_lower = name.lower()
    for k, v in headers.items():
        if k.lower() == name_lower:
            return v
    return None


def handler(event, context):
    body = event.get("body", "") or ""
    signature = get_header(event, "X-Hub-Signature-256")

    if not verify_signature(body, signature):
        logger.warning("Signature verification FAILED — rejecting request")
        return {
            "statusCode": 401,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "invalid signature"}),
        }

    logger.info("Signature verified OK")

    # Parse the webhook payload
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        logger.error("Body is not valid JSON")
        return {"statusCode": 400, "body": json.dumps({"error": "invalid JSON"})}

    # Extract PR details (GitHub pull_request webhook shape)
    repo = payload.get("repository", {})
    repo_full = repo.get("full_name", "")  # e.g. "owner/repo"
    repo_owner = repo.get("owner", {}).get("login") or (repo_full.split("/")[0] if "/" in repo_full else "unknown")
    repo_name = repo.get("name", "unknown")

    pr = payload.get("pull_request", {})
    pr_number = payload.get("number") or pr.get("number", 0)
    commit_sha = pr.get("head", {}).get("sha", "unknown")
    branch = pr.get("head", {}).get("ref", "unknown")

    job_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # ---- Write PENDING record to DynamoDB (data contract) ----
    pk = f"REPO#{repo_owner}/{repo_name}"
    sk = f"SCAN#{timestamp}#{pr_number}"

    table.put_item(Item={
        "PK": pk,
        "SK": sk,
        "job_id": job_id,
        "status": "PENDING",
        "pr_number": pr_number,
        "commit_sha": commit_sha,
        "branch": branch,
        "retry_count": 0,
    })
    logger.info("Wrote PENDING record: PK=%s SK=%s job_id=%s", pk, sk, job_id)

    # ---- Send message to SQS (data contract shape) ----
    message = {
        "job_id": job_id,
        "repo_owner": repo_owner,
        "repo_name": repo_name,
        "pr_number": pr_number,
        "commit_sha": commit_sha,
        "branch": branch,
        "timestamp": timestamp,
    }
    sqs_client.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(message))
    logger.info("Sent SQS message for job_id=%s", job_id)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": "scan queued", "job_id": job_id}),
    }
