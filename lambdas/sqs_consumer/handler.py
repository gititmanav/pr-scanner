import json
import os

import boto3

ecs = boto3.client("ecs")

CLUSTER           = os.environ["ECS_CLUSTER"]
TASK_DEFINITION   = os.environ["TASK_DEFINITION_ARN"]
SUBNET_ID         = os.environ["SUBNET_ID"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
CONTAINER_NAME    = os.environ.get("CONTAINER_NAME", "scanner")
S3_BUCKET         = os.environ["S3_BUCKET"]
DYNAMODB_TABLE    = os.environ["DYNAMODB_TABLE"]


def handler(event, context):
    """Triggered by SQS. For each scan-job message, launch a Fargate scanner task,
    passing the job fields through as container environment overrides.

    The override container name MUST match the container name in the scanner task
    definition, or ECS silently ignores the overrides and the task runs with no
    REPO_URL/JOB_ID. TIMESTAMP is the dispatch timestamp (the DynamoDB SK component)
    and is passed through verbatim so the scanner updates the original PENDING row.
    """
    for record in event.get("Records", []):
        msg = json.loads(record["body"])

        repo_owner = msg["repo_owner"]
        repo_name  = msg["repo_name"]
        repo_url   = f"https://github.com/{repo_owner}/{repo_name}.git"

        env = [
            {"name": "JOB_ID",         "value": str(msg["job_id"])},
            {"name": "REPO_OWNER",     "value": repo_owner},
            {"name": "REPO_NAME",      "value": repo_name},
            {"name": "PR_NUMBER",      "value": str(msg["pr_number"])},
            {"name": "COMMIT_SHA",     "value": str(msg.get("commit_sha", "HEAD"))},
            {"name": "BRANCH",         "value": str(msg.get("branch", ""))},
            {"name": "TIMESTAMP",      "value": str(msg["timestamp"])},
            {"name": "REPO_URL",       "value": repo_url},
            {"name": "S3_BUCKET",      "value": S3_BUCKET},
            {"name": "DYNAMODB_TABLE", "value": DYNAMODB_TABLE},
        ]

        resp = ecs.run_task(
            cluster=CLUSTER,
            taskDefinition=TASK_DEFINITION,
            launchType="FARGATE",
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets":        [SUBNET_ID],
                    "securityGroups": [SECURITY_GROUP_ID],
                    "assignPublicIp": "ENABLED",  # public subnet for the milestone (no NAT)
                }
            },
            overrides={
                "containerOverrides": [
                    {"name": CONTAINER_NAME, "environment": env}
                ]
            },
        )

        # run_task returns HTTP 200 even on failure — the error is in `failures`.
        # Raise so the message is retried and eventually lands in the DLQ instead of
        # being silently deleted.
        failures = resp.get("failures", [])
        if failures:
            print(f"run_task FAILED for job_id={msg['job_id']}: {failures}")
            raise Exception(f"ECS run_task failed: {failures}")

        task_arn = resp["tasks"][0]["taskArn"]
        print(f"Launched scan task {task_arn} for job_id={msg['job_id']}")

    return {"statusCode": 200}
