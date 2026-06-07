import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    Stage 1: log the incoming event and return 200.
    GitHub will POST webhook payloads here via the Lambda Function URL.
    """
    logger.info("Received event: %s", json.dumps(event))

    # The HTTP body arrives as a string in event["body"]
    body = event.get("body", "")
    logger.info("Request body: %s", body)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": "received"}),
    }
