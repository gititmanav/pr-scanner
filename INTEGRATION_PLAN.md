# PR Scanner — End-to-End Integration Plan & Handoff

> **Purpose:** Take the three independently-built slices (A: Ingress, B: Scanner, C: Results)
> and wire them into a working end-to-end pipeline on a **single AWS account**.
>
> **Ordering:** Vaishnavi (Slice A) is on a deadline and hands off mid-project. Her tasks are
> sequenced **first** and built to be self-contained, so completing them unblocks Manav and Sai.
> The handoff sections are written in full detail so the team can finish without her.

---

## 1. What we're building (the relay)

```
GitHub PR opened
   │  HTTPS webhook (HMAC-signed)
   ▼
[A] Dispatch Lambda (Function URL)        modules/ingress + lambdas/dispatch
   │  verify HMAC → write PENDING to DynamoDB → send SQS message
   ▼
   SQS scan-jobs queue (+ DLQ)
   │
   ▼
[NEW] SQS→Fargate Consumer Lambda         modules/consumer + lambdas/sqs_consumer
   │  ecs.run_task, passing job fields as container env overrides
   ▼
[B] Fargate scanner task                  modules/scanner + scanner/scan-wrapper.js
   │  clone repo → SAST scan → write report to S3 → update DynamoDB COMPLETED
   ▼
   EventBridge "ECS Task STOPPED"
   ▼
[C] Post-Scan Lambda                       modules/results + lambdas/post_scan
      read DynamoDB + S3 → format Markdown → POST comment to GitHub PR
```

---

## 2. Why it doesn't work yet (root causes)

| # | Problem | Effect |
|---|---------|--------|
| 1 | **No SQS→Fargate consumer exists** | The queue is never drained; the scanner never runs. This is the only *net-new* component. |
| 2 | **Three tables / two buckets** | ingress writes `pr-scanner-scan-jobs`; scanner & post-scan use `pr-scanner-jobs`; the reports bucket is declared in two modules (name collision on apply). The PENDING write and the COMPLETED update land in different tables. |
| 3 | **Scanner rebuilds the sort key from its own clock** | `scan-wrapper.js` computes `SK` with `new Date()`, which never equals the dispatch timestamp, so `UpdateItem` creates a *duplicate* row instead of flipping PENDING→COMPLETED. |
| 4 | **Report JSON shape mismatch** | Scanner writes flat `total_vulnerabilities` / `severity_breakdown`; post-scan reads nested `summary.totalVulnerabilities` → `KeyError`. |
| 5 | **post-scan reads fields that aren't stored** | It reads `record['repo_owner']` / `record['repo_name']`, but the contract only stores those inside `PK = REPO#owner/repo`. |
| 6 | **post-scan can't tell which job finished** | The ECS "task stopped" event carries no `jobId`; post-scan falls back to a hardcoded `'test-job-001'`. |

The fix for #1 (the consumer) is also the carrier that resolves #3 and #6, because the consumer is where the job's data is handed from the queue into the container.

---

## 3. Data contracts (authoritative — do not deviate)

**SQS message** (dispatch → consumer):
```json
{ "job_id": "uuid", "repo_owner": "acme", "repo_name": "web-app",
  "pr_number": 42, "commit_sha": "abc123", "branch": "feature/x",
  "timestamp": "2026-06-12T14:30:00Z" }
```

**DynamoDB item:**
| Field | Value | Written by |
|-------|-------|-----------|
| `PK` | `REPO#<owner>/<repo>` | dispatch |
| `SK` | `SCAN#<timestamp>#<pr_number>` | dispatch |
| `job_id`, `pr_number`, `commit_sha`, `branch` | from webhook | dispatch |
| `status` | `PENDING` → `COMPLETED` / `FAILED` | dispatch creates, scanner updates |
| `findings_count`, `severity_breakdown`, `s3_report_key`, `started_at`, `finished_at` | scan results | scanner |

> **The join key is `SK`, and its `<timestamp>` MUST be the dispatch timestamp** (the one in the
> SQS message), not the scanner's own clock. The consumer passes it through as `TIMESTAMP`.

**S3 report:** bucket `pr-scanner-reports-<account-id>`, key `reports/<job_id>.json`. Internal shape
(produced by `scan-wrapper.js`, consumed by post-scan):
```json
{ "job_id": "...", "total_vulnerabilities": 5,
  "severity_breakdown": { "HIGH": 2, "MEDIUM": 2, "LOW": 1 },
  "vulnerabilities": [ { "severity": "HIGH", "id": "...", "file": "...", "line": 1, "message": "..." } ] }
```

---

# PART 1 — Vaishnavi's tasks (do these first)

Each task is self-contained. After all four, your half is deployable and verified, and the team
has a working consumer to build the rest on.

## V1 — Decouple ingress from its own DynamoDB table

The canonical table lives in the `results` module. Ingress should *reference* it, not create a second one.

**Edit `modules/ingress/main.tf`** — delete the entire `aws_dynamodb_table "scan_jobs"` resource block
(the `attribute` blocks and the `global_secondary_index` go with it).

**Edit the dispatch Lambda env** in the same file so it uses the passed-in name:
```hcl
environment {
  variables = {
    SCAN_JOBS_QUEUE_URL = aws_sqs_queue.scan_jobs.id
    SCAN_JOBS_TABLE      = var.dynamodb_table_name   # was: aws_dynamodb_table.scan_jobs.name
    WEBHOOK_SECRET_NAME  = "cs6620/github-webhook-secret"
  }
}
```

**Edit `modules/ingress/variables.tf`** — add:
```hcl
variable "dynamodb_table_name" {
  description = "Name of the shared DynamoDB scan-jobs table (created in results module)"
  type        = string
}
```

**Edit `modules/ingress/outputs.tf`** — delete the `scan_jobs_table_name` and `scan_jobs_table_arn`
outputs (the table no longer lives here).

> **Why:** Contract #2. One table, written by dispatch (PENDING) and updated by the scanner
> (COMPLETED). Two tables = the update never finds the original row.

## V2 — Wire the root so all modules share one table + one bucket

**Edit root `main.tf`:**

1. In `module "scanner"`, **remove** `account_id = "771014276560"` and add the shared names:
```hcl
module "scanner" {
  source            = "./modules/scanner"
  region            = var.region
  project           = var.project
  lab_role_arn      = data.aws_iam_role.lab.arn
  subnet_id         = module.networking.public_subnet_id
  security_group_id = module.networking.scanner_security_group_id
  reports_bucket    = module.results.s3_bucket_name
  dynamodb_table    = module.results.dynamodb_table_name
}
```

2. In `module "ingress"`, pass the table name:
```hcl
module "ingress" {
  source              = "./modules/ingress"
  project             = var.project
  region              = var.region
  lab_role_arn        = data.aws_iam_role.lab.arn
  dynamodb_table_name = module.results.dynamodb_table_name
}
```

> **Why:** The hardcoded account ID built the scanner's bucket name from *someone else's* account,
> so reports went to a different bucket than post-scan reads. Sourcing both names from `results`
> (which derives them from `aws_caller_identity`) makes the whole stack account-agnostic — moving
> to another teammate's account later requires **zero code changes**, only re-creating the two secrets.
>
> **Note for Manav:** the scanner module still *creates* its own bucket. Your wiring passes the
> correct name in; he must delete the duplicate `aws_s3_bucket` resource (see Handoff M1) before
> `terraform apply` will be collision-free.

## V3 — Build the SQS→Fargate consumer (the missing middle)

This is the only net-new component. It belongs to you because it's the direct continuation of your
SQS message — and building it now means the team isn't blocked on the hardest piece.

### V3a — Lambda code: create `lambdas/sqs_consumer/handler.py`
```python
import json
import os
import boto3

ecs = boto3.client("ecs")

CLUSTER            = os.environ["ECS_CLUSTER"]
TASK_DEFINITION    = os.environ["TASK_DEFINITION_ARN"]
SUBNET_ID          = os.environ["SUBNET_ID"]
SECURITY_GROUP_ID  = os.environ["SECURITY_GROUP_ID"]
CONTAINER_NAME     = os.environ.get("CONTAINER_NAME", "scanner")
S3_BUCKET          = os.environ["S3_BUCKET"]
DYNAMODB_TABLE     = os.environ["DYNAMODB_TABLE"]


def handler(event, context):
    """Triggered by SQS. For each scan-job message, launch a Fargate scanner task,
    passing the job fields through as container environment overrides."""
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
            {"name": "TIMESTAMP",      "value": str(msg["timestamp"])},   # <-- dispatch time = SK timestamp
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
                    "assignPublicIp": "ENABLED",   # public subnet for the milestone
                }
            },
            overrides={
                "containerOverrides": [
                    {"name": CONTAINER_NAME, "environment": env}
                ]
            },
        )

        failures = resp.get("failures", [])
        if failures:
            print(f"run_task FAILED for job_id={msg['job_id']}: {failures}")
            raise Exception(f"ECS run_task failed: {failures}")

        task_arn = resp["tasks"][0]["taskArn"]
        print(f"Launched scan task {task_arn} for job_id={msg['job_id']}")

    return {"statusCode": 200}
```

### V3b — Terraform: create `modules/consumer/`

`modules/consumer/variables.tf`:
```hcl
variable "project"             { type = string }
variable "lab_role_arn"        { type = string }
variable "queue_arn"           { type = string }
variable "ecs_cluster_arn"     { type = string }
variable "task_definition_arn" { type = string }
variable "subnet_id"           { type = string }
variable "security_group_id"   { type = string }
variable "container_name"      { type = string  default = "scanner" }
variable "s3_bucket"           { type = string }
variable "dynamodb_table"      { type = string }
```

`modules/consumer/main.tf`:
```hcl
data "archive_file" "consumer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambdas/sqs_consumer"
  output_path = "${path.module}/consumer.zip"
}

resource "aws_lambda_function" "consumer" {
  function_name    = "${var.project}-consumer"
  role             = var.lab_role_arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.consumer_zip.output_path
  source_code_hash = data.archive_file.consumer_zip.output_base64sha256

  environment {
    variables = {
      ECS_CLUSTER         = var.ecs_cluster_arn
      TASK_DEFINITION_ARN = var.task_definition_arn
      SUBNET_ID           = var.subnet_id
      SECURITY_GROUP_ID   = var.security_group_id
      CONTAINER_NAME      = var.container_name
      S3_BUCKET           = var.s3_bucket
      DYNAMODB_TABLE      = var.dynamodb_table
    }
  }
}

# SQS triggers the consumer
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = var.queue_arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 1
  enabled          = true
}
```

`modules/consumer/outputs.tf`:
```hcl
output "consumer_function_name" {
  value = aws_lambda_function.consumer.function_name
}
```

### V3c — Wire it in root `main.tf`
```hcl
# ============================================
# SQS -> Fargate Consumer (connects Slice A queue to Slice B scanner)
# ============================================
module "consumer" {
  source              = "./modules/consumer"
  project             = var.project
  lab_role_arn        = data.aws_iam_role.lab.arn
  queue_arn           = module.ingress.scan_jobs_queue_arn
  ecs_cluster_arn     = module.scanner.ecs_cluster_arn
  task_definition_arn = module.scanner.task_definition_arn
  subnet_id           = module.networking.public_subnet_id
  security_group_id   = module.networking.scanner_security_group_id
  container_name      = "scanner"
  s3_bucket           = module.results.s3_bucket_name
  dynamodb_table      = module.results.dynamodb_table_name
}
```

> **Why:** Guide §11 step 2 — "add a consumer that polls SQS and launches tasks." Passing the
> message fields as **container env overrides** does double duty: `TIMESTAMP` lets the scanner
> rebuild the exact `SK` (fixes #3), and `JOB_ID` shows up in the ECS "task stopped" event so
> post-scan knows which job finished (fixes #6). The container name `scanner` matches the name in
> `modules/scanner/main.tf` → `container_definitions`. LabRole already grants `ecs:RunTask` and
> `iam:PassRole`, so no IAM changes are needed (Learner Lab forbids creating roles anyway).

## V4 — Account prerequisites (manual, not Terraform)

Per Guide §3.2, secrets are never in Terraform. On the bring-up account:

```bash
# 1. GitHub Personal Access Token (repo scope) -> Secrets Manager
aws secretsmanager create-secret \
  --name cs6620/github-token \
  --secret-string 'ghp_xxxxxxxxxxxxxxxxxxxx' \
  --region us-east-1

# 2. Random webhook secret -> Secrets Manager
aws secretsmanager create-secret \
  --name cs6620/github-webhook-secret \
  --secret-string "$(openssl rand -hex 20)" \
  --region us-east-1
# (note the value — you'll paste it into the GitHub webhook config)
```

Then, **after** `terraform apply` (so the Function URL exists):
```bash
terraform output dispatch_function_url
```
On the test GitHub repo → Settings → Webhooks → Add webhook:
- **Payload URL:** the `dispatch_function_url`
- **Content type:** `application/json`
- **Secret:** the webhook-secret value from above
- **Events:** "Let me select" → Pull requests only

> **If the team later switches accounts:** the only redo is these two `create-secret` commands and
> the webhook URL (re-run `terraform output`). No `.tf` changes — that's the payoff of V2.

## V5 — Verify your half before handoff

```bash
terraform init && terraform apply       # whole stack comes up
terraform output dispatch_function_url

# Send a signed test webhook (replace URL and SECRET):
BODY='{"number":1,"pull_request":{"head":{"sha":"testsha","ref":"main"}},"repository":{"full_name":"you/test","name":"test","owner":{"login":"you"}}}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')"
curl -s -X POST "$DISPATCH_URL" -H "X-Hub-Signature-256: $SIG" \
  -H "Content-Type: application/json" -d "$BODY"
```
Confirm, and note in the handoff what you saw:
- [ ] `200 {"message":"scan queued","job_id":"..."}`
- [ ] CloudWatch (`pr-scanner-dispatch`): "Signature verified OK", "Wrote PENDING record"
- [ ] DynamoDB `pr-scanner-jobs`: a PENDING item with that `job_id`
- [ ] SQS: message consumed; CloudWatch (`pr-scanner-consumer`): "Launched scan task ..."
- [ ] ECS console: a Fargate task started (it may fail until Manav pushes the image — that's expected)

---

# PART 2 — HANDOFF to Manav (Slice B)

## M1 — Remove the duplicate S3 bucket
Root now passes the shared bucket name into the scanner. **Edit `modules/scanner/main.tf`:** delete
the `aws_s3_bucket "reports"` resource (and any `data "aws_caller_identity"` only used for its name).
The scanner reads `var.reports_bucket` — keep that variable. This clears the apply-time name collision.

## M2 — Fix the sort key in the scanner
**Edit `scanner/scan-wrapper.js`.** Read the dispatch timestamp from env and use it for the SK in
**both** the success update and the failure update:
```js
const TIMESTAMP = process.env.TIMESTAMP;   // ISO8601 dispatch time, from the SQS message
// ...
Key: {
  PK: { S: `REPO#${REPO_OWNER}/${REPO_NAME}` },
  SK: { S: `SCAN#${TIMESTAMP}#${PR_NUMBER}` }   // was: SCAN#${new Date(startedAt*1000).toISOString()}#...
}
```
Apply the same change to the `catch` block's `UpdateItemCommand`. Keep `started_at`/`finished_at` as
epoch numbers — only the **SK** must use `TIMESTAMP`.

> **Why:** This makes the scanner's `UpdateItem` target the exact row dispatch created, so the item
> transitions PENDING→COMPLETED instead of a second COMPLETED row appearing with a mismatched key.

## M3 — Build and push the scanner image to ECR
Nothing pushes the image yet; Fargate pulls `:latest` and will fail without it.
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO="$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/pr-scanner-scanner"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REPO"
docker build -t pr-scanner-scanner ./scanner
docker tag pr-scanner-scanner:latest "$REPO:latest"
docker push "$REPO:latest"
```

## M4 — Sanity-check the consumer's network params
Confirm the subnet (`module.networking.public_subnet_id`) is the public one with an internet
gateway route, and the security group allows outbound 443 (git clone + AWS APIs). The consumer
uses `assignPublicIp=ENABLED` because the milestone uses a public subnet.

---

# PART 3 — HANDOFF to Sai (Slice C)

## S1 — Confirm `results` owns the shared table + bucket
`modules/results/main.tf` already creates `pr-scanner-jobs` (+ `status-index` GSI) and the reports
bucket — keep both as the **single** owners. Verify the outputs `dynamodb_table_name` and
`s3_bucket_name` exist (root wires them into ingress, scanner, and consumer). No new resources needed.

## S2 — Fix the report reader
**Edit `lambdas/post_scan/handler.py`** → `format_pr_comment` to match the scanner's actual output:
```python
def format_pr_comment(record, report):
    total = report.get('total_vulnerabilities', 0)
    sev   = report.get('severity_breakdown', {})
    high  = sev.get('HIGH', 0)
    med   = sev.get('MEDIUM', 0)
    low   = sev.get('LOW', 0)
    # ... rest unchanged; iterate report.get('vulnerabilities', [])
```

## S3 — Parse owner/repo from the PK
The item has no `repo_owner` / `repo_name` attributes — they live in the PK. In `lambda_handler`:
```python
# PK looks like "REPO#owner/repo"
owner_repo = record['PK'].split('#', 1)[1]      # "owner/repo"
repo_owner, repo_name = owner_repo.split('/', 1)
# then use repo_owner, repo_name in post_github_comment(...)
```

## S4 — Correlate the job from the EventBridge event
**Replace** the hardcoded `'test-job-001'` fallback. Pull `JOB_ID` from the container overrides
that the consumer set (present in the ECS Task State Change event):
```python
def get_job_id_from_event(event):
    detail = event.get("detail", {})
    for c in detail.get("overrides", {}).get("containerOverrides", []):
        for env in c.get("environment", []):
            if env.get("name") == "JOB_ID":
                return env.get("value")
    return event.get("job_id")   # manual-invoke fallback only

def lambda_handler(event, context):
    job_id = get_job_id_from_event(event)
    # ...
```

## S5 — Tighten the EventBridge rule
**Edit `modules/results/main.tf`** → the `aws_cloudwatch_event_rule.fargate_stopped` event pattern so
it only fires for the scanner cluster (avoid reacting to unrelated ECS tasks):
```hcl
detail = {
  lastStatus = ["STOPPED"]
  clusterArn = [module.scanner... ]   # pass the scanner cluster ARN in as a variable
}
```
(Add a `scanner_cluster_arn` variable to the results module and wire `module.scanner.ecs_cluster_arn`
in root.)

---

# PART 4 — End-to-end test (whole team)

**Dependency order:** V1→V2→V3 (Vaishnavi) → M1/M2/M3 (Manav) ∥ S1–S5 (Sai) → joint test.

```bash
terraform apply        # full stack, on the chosen account
```
1. Create secrets (V4) and the GitHub webhook if not already done.
2. Open a PR on the test repo containing a planted vuln, e.g. `const password = "admin123";`.
3. Watch it flow (target < 2 min):

| Stage | Where to look | Expected |
|-------|---------------|----------|
| Webhook received | `pr-scanner-dispatch` logs | "Signature verified OK", PENDING written |
| Queued | SQS `NumberOfMessagesSent` | 1 |
| Consumer launched task | `pr-scanner-consumer` logs | "Launched scan task ..." |
| Scan ran | ECS console + scanner logs | RUNNING→STOPPED, exit 0, findings printed |
| Report saved | S3 `reports/<job_id>.json` | file present |
| Record updated | DynamoDB item | `status=COMPLETED`, `findings_count`, `s3_report_key` |
| Event fired | EventBridge `TriggeredRules` | > 0 |
| Comment posted | `pr-scanner-post-scan` logs + the PR | comment with severity table |

**Debugging checklist (Guide §11):**
- Fargate not launching → check consumer logs + LabRole `ecs:RunTask`/`iam:PassRole`.
- Fargate exit 137 → OOM, raise task memory.
- EventBridge `TriggeredRules` = 0 → pattern mismatch (check `clusterArn`).
- Comment 401 → bad `cs6620/github-token`; 404 → wrong repo/PR path.

---

# PART 5 — Cost discipline (Guide §2)

- **`terraform destroy` at the end of every session.** Fargate + any NAT bill while idle.
- Region is **us-east-1** only. Budget is **$100 total** across the team.
- State is local (`terraform.tfstate` in the working dir) — back it up before destroying if you want
  to inspect outputs later.

---

# Quick checklist

**Vaishnavi (now):**
- [ ] V1 — remove ingress table, add `dynamodb_table_name` var
- [ ] V2 — root wiring: drop hardcoded account ID, pass shared table+bucket
- [ ] V3 — consumer Lambda + `modules/consumer` + root wiring
- [ ] V4 — create secrets + webhook (document the steps)
- [ ] V5 — apply, signed-curl test, record what passed

**Manav (handoff):**
- [ ] M1 — delete duplicate S3 bucket from scanner module
- [ ] M2 — SK from `TIMESTAMP` in `scan-wrapper.js` (both updates)
- [ ] M3 — build + push image to ECR
- [ ] M4 — verify consumer network params

**Sai (handoff):**
- [ ] S1 — confirm results owns the single table + bucket
- [ ] S2 — read flat report fields
- [ ] S3 — parse owner/repo from PK
- [ ] S4 — pull JOB_ID from event overrides
- [ ] S5 — scope EventBridge rule to scanner cluster

**Together:**
- [ ] End-to-end test: real PR → comment in < 2 min
- [ ] `terraform destroy` after the session
