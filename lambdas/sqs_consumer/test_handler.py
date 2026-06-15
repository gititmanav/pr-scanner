"""Local unit tests for the SQS consumer — no AWS account or credentials needed.

boto3 and the environment are stubbed before import, so this runs with just:
    python3 lambdas/sqs_consumer/test_handler.py
It verifies the things that fail *silently* in production: the override container
name, the env var names/formats, TIMESTAMP passthrough, and the failures-raises path.
"""
import importlib
import json
import os
import sys
import types
import unittest


class FakeECS:
    def __init__(self, response):
        self._response = response
        self.calls = []

    def run_task(self, **kwargs):
        self.calls.append(kwargs)
        return self._response


def load_handler(fake_ecs):
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = lambda name, *a, **k: fake_ecs
    sys.modules["boto3"] = fake_boto3

    os.environ.update({
        "ECS_CLUSTER": "pr-scanner-cluster",
        "TASK_DEFINITION_ARN": "arn:aws:ecs:us-east-1:771014276560:task-definition/pr-scanner-scanner:1",
        "SUBNET_ID": "subnet-123",
        "SECURITY_GROUP_ID": "sg-456",
        "CONTAINER_NAME": "scanner",
        "S3_BUCKET": "pr-scanner-reports-771014276560",
        "DYNAMODB_TABLE": "pr-scanner-jobs",
    })

    sys.modules.pop("handler", None)
    sys.path.insert(0, os.path.dirname(__file__))
    return importlib.import_module("handler")


def sqs_event(body):
    return {"Records": [{"body": json.dumps(body)}]}


MESSAGE = {
    "job_id": "550e8400-e29b-41d4-a716-446655440000",
    "repo_owner": "acme",
    "repo_name": "web-app",
    "pr_number": 42,
    "commit_sha": "abc123",
    "branch": "feature/login",
    "timestamp": "2026-06-12T14:30:00Z",
}


class ConsumerTest(unittest.TestCase):
    def test_launches_task_with_correct_overrides(self):
        fake = FakeECS({"tasks": [{"taskArn": "arn:task/1"}], "failures": []})
        handler = load_handler(fake)

        handler.handler(sqs_event(MESSAGE), None)

        self.assertEqual(len(fake.calls), 1)
        call = fake.calls[0]
        self.assertEqual(call["cluster"], "pr-scanner-cluster")
        self.assertEqual(call["launchType"], "FARGATE")
        self.assertEqual(
            call["networkConfiguration"]["awsvpcConfiguration"]["assignPublicIp"], "ENABLED"
        )

        override = call["overrides"]["containerOverrides"][0]
        # MUST match the container name in the scanner task def, or ECS ignores the overrides
        self.assertEqual(override["name"], "scanner")

        env = {e["name"]: e["value"] for e in override["environment"]}
        self.assertEqual(env["JOB_ID"], MESSAGE["job_id"])
        self.assertEqual(env["TIMESTAMP"], "2026-06-12T14:30:00Z")  # verbatim — drives the DynamoDB SK
        self.assertEqual(env["PR_NUMBER"], "42")                    # stringified (env vars are strings)
        self.assertEqual(env["REPO_URL"], "https://github.com/acme/web-app.git")
        self.assertEqual(env["S3_BUCKET"], "pr-scanner-reports-771014276560")
        self.assertEqual(env["DYNAMODB_TABLE"], "pr-scanner-jobs")

    def test_raises_when_run_task_reports_failure(self):
        # run_task returns HTTP 200 with a `failures` array — must NOT be treated as success
        fake = FakeECS({"tasks": [], "failures": [{"reason": "RESOURCE:MEMORY"}]})
        handler = load_handler(fake)

        with self.assertRaises(Exception):
            handler.handler(sqs_event(MESSAGE), None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
