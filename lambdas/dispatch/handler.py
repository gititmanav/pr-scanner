import json
import os
import hmac
import hashlib
import logging

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")

WEBHOOK_SECRET_NAME = os.environ.get("WEBHOOK_SECRET_NAME", "cs6620/github-webhook-secret")

# Cache the secret across warm invocations so we don't hit Secrets Manager every time
_cached_secret = None


def get_webhook_secret():
    global _cached_secret
    if _cached_secret is None:
        resp = secrets_client.get_secret_value(SecretId=WEBHOOK_SECRET_NAME)
        _cached_secret = resp["SecretString"]
    return _cached_secret


def verify_signature(body: str, signature_header: str) -> bool:
    """
    GitHub sends header X-Hub-Signature-256: sha256=<hexdigest>
    We recompute HMAC-SHA256 over the raw body using the shared secret
    and compare in constant time.
    """
    if not signature_header:
        logger.warning("Missing signature header")
        return False

    secret = get_webhook_secret().encode("utf-8")
    expected = "sha256=" + hmac.new(secret, body.encode("utf-8"), hashlib.sha256).hexdigest()

    # constant-time compare to prevent timing attacks
    return hmac.compare_digest(expected, signature_header)


def get_header(event, name):
    """Headers can arrive with varied casing; normalize lookup."""
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
    logger.info("Request body: %s", body)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": "signature valid"}),
    }
