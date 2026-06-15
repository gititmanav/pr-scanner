# PR Scanner — End-to-End Integration Plan & Handoff

> **Single source of truth** for Phase 2 integration. Reconciles the team's *Phase 2 Complete Guide*
> (shared-account decisions, task split) with the integration-time bugs/blockers found while reading
> the merged `main` branch.
>
> **Shared AWS account:** `771014276560` (Manav's Learner Lab). Everyone works in this one account.
>
> **Ordering:** Vaishnavi (Slice A) is on a deadline and hands off mid-project. Her tasks are
> sequenced **first** and built to be self-contained, so finishing them unblocks Manav and Sai.
> The handoff sections are written in full so the team can finish without her.

---

## 0. What changed vs. the Phase 2 guide (read this first)

The Phase 2 guide and this plan agree on the backbone. These are the points where this plan adds
detail or corrects something that will break the unified `terraform apply`:

| Topic | Decision / correction |
|---|---|
| **Account** | Manav's `771014276560`. The hardcoded `account_id = "771014276560"` in `main.tf` is **correct** — keep it. |
| **S3 bucket owner** | **Manav** (`pr-scanner-reports-771014276560`, already deployed with real scan data). `results` must **not** create a second bucket — it references Manav's. |
| **DynamoDB table owner** | **Sai** (`pr-scanner-jobs`). `ingress` must **not** create a second table — it references Sai's. |
| **Apply-blocker** | Today both `scanner` **and** `results` declare the reports bucket, and both `ingress` **and** `results` declare a jobs table. In one account these **collide** and `apply` fails. Fixing this is step zero. |
| **Cycle risk** | If `scanner` references `results`'s table output *and* `results` references `scanner`'s bucket output, Terraform hits a **dependency cycle**. Avoid it with root `locals` holding the deterministic names (below). |
| **owner/repo/job_id in post-scan** | Read from the EventBridge event's `detail.overrides.containerOverrides[].environment` (the consumer sets them), **not** by parsing the DynamoDB PK. |
| **Latent bug #1 (SK)** | Scanner builds `SK` from its own clock → won't match the PENDING row. Fix by passing the dispatch `TIMESTAMP` through. *(Guide §9 hints; no fix given.)* |
| **Latent bug #2 (report shape)** | post-scan reads `report['summary']['totalVulnerabilities']`; scanner writes flat `total_vulnerabilities`. Guaranteed `KeyError`. *(Not mentioned in the guide.)* |

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
[NEW] SQS→Fargate Consumer Lambda         modules/consumer + lambdas/sqs_consumer   (Vaishnavi)
   │  ecs.run_task, passing job fields as container env overrides
   ▼
[B] Fargate scanner task                  modules/scanner + scanner/scan-wrapper.js
   │  clone repo → SAST scan → write report to S3 → update DynamoDB COMPLETED
   ▼
   EventBridge "ECS Task STOPPED" (scoped to pr-scanner-cluster)
   ▼
[C] Post-Scan Lambda                       modules/results + lambdas/post_scan
      read DynamoDB + S3 → format Markdown → POST comment to GitHub PR
```

**The three connections to build** (Phase 2 guide §3.1):
1. **SQS → Fargate** — new consumer Lambda (Vaishnavi). *Does not exist yet.*
2. **EventBridge → Post-Scan** — scope the rule to Manav's cluster ARN (Sai).
3. **GitHub webhook → Dispatch** — configure on the test repo (Vaishnavi).

---

## 2. Why it doesn't work yet (root causes)

| # | Problem | Effect |
|---|---------|--------|
| 1 | **No SQS→Fargate consumer exists** | The queue is never drained; the scanner never runs. The only *net-new* component. |
| 2 | **Duplicate bucket + duplicate table across modules** | On Manav's account the names collide → `terraform apply` fails before anything deploys. |
| 3 | **Scanner rebuilds the sort key from its own clock** | `scan-wrapper.js` computes `SK` with `new Date()`, which never equals the dispatch timestamp → `UpdateItem` creates a *duplicate* row instead of flipping PENDING→COMPLETED. Worked in M1 only because there was no PENDING row to match. |
| 4 | **Report JSON shape mismatch** | Scanner writes flat `total_vulnerabilities`; post-scan reads nested `summary.totalVulnerabilities` → `KeyError`. |
| 5 | **post-scan can't identify the job / repo** | The hardcoded `'test-job-001'` fallback; `repo_owner`/`repo_name` aren't stored as attributes. Fix: read them from the ECS event's container overrides. |

The consumer (fix #1) is also the carrier that resolves #3 and #5, because it hands the job's data
from the queue into the container as env overrides.

---

## 3. Data contracts (authoritative — do not deviate)

**SQS message** (dispatch → consumer):
```json
{ "job_id": "uuid", "repo_owner": "acme", "repo_name": "web-app",
  "pr_number": 42, "commit_sha": "abc123", "branch": "feature/x",
  "timestamp": "2026-06-12T14:30:00Z" }
```

**DynamoDB item** (table `pr-scanner-jobs`, owned by Sai):
| Field | Value | Written by |
|-------|-------|-----------|
| `PK` | `REPO#<owner>/<repo>` | dispatch |
| `SK` | `SCAN#<timestamp>#<pr_number>` | dispatch |
| `job_id`, `pr_number`, `commit_sha`, `branch` | from webhook | dispatch |
| `status` | `PENDING` → `COMPLETED` / `FAILED` | dispatch creates, scanner updates |
| `findings_count`, `severity_breakdown`, `s3_report_key`, `started_at`, `finished_at` | scan results | scanner |

> **The join key is `SK`, and its `<timestamp>` MUST be the dispatch timestamp** (the one in the SQS
> message), not the scanner's clock. The consumer passes it through as `TIMESTAMP`.

**S3 report:** bucket `pr-scanner-reports-771014276560` (owned by Manav), key `reports/<job_id>.json`.
Internal shape (produced by `scan-wrapper.js`, consumed by post-scan):
```json
{ "job_id": "...", "total_vulnerabilities": 5,
  "severity_breakdown": { "HIGH": 2, "MEDIUM": 2, "LOW": 1 },
  "vulnerabilities": [ { "severity": "HIGH", "id": "...", "file": "...", "line": 1, "message": "..." } ] }
```

**Container env var names** (consumer → scanner — case-sensitive, must match `scan-wrapper.js`):
`JOB_ID, REPO_OWNER, REPO_NAME, PR_NUMBER, COMMIT_SHA, BRANCH, TIMESTAMP, REPO_URL, S3_BUCKET, DYNAMODB_TABLE`

---

## 4. Shared account workflow (everyone, every session)

1. Manav starts his Learner Lab → **AWS Details → Show** → copy credentials.
2. Manav shares them via private DM (never Git, never a public channel).
3. Each person pastes into `~/.aws/credentials` and verifies:
   ```bash
   aws sts get-caller-identity     # must show Account: 771014276560
   ```
4. On `ExpiredToken`, Manav re-shares fresh creds (his lab must be running).
5. **`terraform destroy` at the end of every session** — Fargate, NAT, idle resources burn the $100 budget.

## ⛔ TEAM BLOCKER — decide before anyone runs `terraform apply`

**Who owns Terraform state, and who runs `apply` / `destroy`?**

Right now the root config uses **local state** (`terraform.tfstate` on each person's laptop). With all
three of us pointing at the **same** account (`771014276560`), running `apply` from separate laptops
will collide:
- One person's `apply` doesn't see resources another person created → **"resource already exists"** errors,
  or Terraform tries to re-create/destroy things it doesn't know about (**drift**).
- A `terraform destroy` from any laptop wipes **everyone's** resources — including the reports S3 bucket
  (`force_destroy = true`, so all scan reports are deleted with it) and the DynamoDB table.
- Two people applying at the same time can leave the account in a half-built state with no lock to stop them.

**Pick ONE of these before integration starts:**

| Option | What it means | Best when |
|--------|---------------|-----------|
| **A. Single applier (simplest)** | One person (recommend **Manav**, the account owner) is the *only* one who runs `apply`/`destroy`. Others edit `.tf`, commit, and ask him to apply. State stays on his machine. | We want to start today with zero setup. |
| **B. Shared remote state** | Add an `s3` backend + a DynamoDB lock table. Everyone runs `terraform init` against it, state is shared and locked so two applies can't clash. | We expect lots of back-and-forth applies during integration. |

**Recommendation:** start with **Option A** (single applier = Manav) to unblock immediately, and move to
**Option B** if we find ourselves waiting on each other. Either way: **nobody runs `terraform destroy`
without posting in the team channel first** — it deletes the shared bucket and all reports.

> **Decision (fill in):** Owner of `apply`/`destroy` = __________ · State = local (A) / remote (B) = ______

---

# PART 1 — Vaishnavi's tasks (do these first)

## V1 — Decouple ingress from its own DynamoDB table
The canonical table is Sai's `pr-scanner-jobs`. Ingress references it.

**`modules/ingress/main.tf`** — delete the entire `aws_dynamodb_table "scan_jobs"` resource.
Point the dispatch Lambda env at the passed-in name:
```hcl
environment {
  variables = {
    SCAN_JOBS_QUEUE_URL = aws_sqs_queue.scan_jobs.id
    SCAN_JOBS_TABLE      = var.dynamodb_table_name   # was: aws_dynamodb_table.scan_jobs.name
    WEBHOOK_SECRET_NAME  = "cs6620/github-webhook-secret"
  }
}
```
**`modules/ingress/variables.tf`** — add:
```hcl
variable "dynamodb_table_name" {
  description = "Name of the shared DynamoDB jobs table (created in results module)"
  type        = string
}
```
**`modules/ingress/outputs.tf`** — delete the `scan_jobs_table_name` / `scan_jobs_table_arn` outputs.

## V2 — Root wiring + break the collisions and the cycle
Keep Manav's account ID and bucket. Use root `locals` for the deterministic shared names so no module
references another module's output (this is what prevents the `scanner ↔ results` dependency cycle).

**`main.tf`** — add locals and wire the names in:
```hcl
locals {
  account_id     = "771014276560"                         # Manav's shared Learner Lab account
  reports_bucket = "pr-scanner-reports-${local.account_id}"  # created in scanner module (Manav)
  jobs_table     = "${var.project}-jobs"                  # created in results module (Sai)
}

module "ingress" {
  source              = "./modules/ingress"
  project             = var.project
  region              = var.region
  lab_role_arn        = data.aws_iam_role.lab.arn
  dynamodb_table_name = local.jobs_table
}

module "scanner" {
  source            = "./modules/scanner"
  region            = var.region
  project           = var.project
  lab_role_arn      = data.aws_iam_role.lab.arn
  subnet_id         = module.networking.public_subnet_id
  security_group_id = module.networking.scanner_security_group_id
  account_id        = local.account_id      # keep — builds the bucket name
  dynamodb_table    = local.jobs_table
}

module "results" {
  source         = "./modules/results"
  project        = var.project
  region         = var.region
  lab_role_arn   = data.aws_iam_role.lab.arn
  alert_email    = var.alert_email
  reports_bucket = local.reports_bucket      # reference Manav's bucket, do NOT create one
}
```

> **Why locals, not module outputs:** the names are deterministic, so passing them as plain strings
> creates no dependency edge between `scanner` and `results`. The resources still get created in
> their owning modules; LabRole's broad permissions mean apply order doesn't matter for correctness.

## V3 — Build the SQS→Fargate consumer (the missing middle)
The only net-new component. Yours, per Phase 2 guide §3.1/§4.1.

### V3a — `lambdas/sqs_consumer/handler.py`
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
            raise Exception(f"ECS run_task failed: {failures}")   # let it retry / hit the DLQ

        print(f"Launched scan task {resp['tasks'][0]['taskArn']} for job_id={msg['job_id']}")

    return {"statusCode": 200}
```

### V3b — `modules/consumer/`

`variables.tf`:
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

`main.tf`:
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

resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = var.queue_arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 1
  enabled          = true
}
```

`outputs.tf`:
```hcl
output "consumer_function_name" { value = aws_lambda_function.consumer.function_name }
```

### V3c — wire it in root `main.tf`
```hcl
module "consumer" {
  source              = "./modules/consumer"
  project             = var.project
  lab_role_arn        = data.aws_iam_role.lab.arn
  queue_arn           = module.ingress.scan_jobs_queue_arn
  ecs_cluster_arn     = module.scanner.ecs_cluster_arn
  task_definition_arn = module.scanner.task_definition_arn
  subnet_id           = module.networking.public_subnet_id
  security_group_id   = module.networking.scanner_security_group_id
  container_name      = "scanner"            # matches container name in modules/scanner task def
  s3_bucket           = local.reports_bucket
  dynamodb_table      = local.jobs_table
}
```

> **Why:** passing the message fields as container overrides does triple duty: `TIMESTAMP` fixes the
> SK bug (#3), `JOB_ID`/`REPO_OWNER`/`REPO_NAME`/`PR_NUMBER` let post-scan identify the job from the
> ECS event (#5), and `REPO_URL` tells the scanner what to clone. LabRole already grants `ecs:RunTask`,
> `iam:PassRole`, and `sqs:ReceiveMessage/DeleteMessage` (Learner Lab forbids creating roles anyway).

## V4 — Secrets + webhook (in Manav's account)
```bash
aws secretsmanager create-secret --name cs6620/github-token \
  --secret-string 'ghp_xxxxxxxx' --region us-east-1
aws secretsmanager create-secret --name cs6620/github-webhook-secret \
  --secret-string "$(openssl rand -hex 20)" --region us-east-1
```
The GitHub token needs **`repo` scope with write access to the test repo** (so post-scan can comment).
After `terraform apply`, get the webhook target and configure it on the test repo
(`gititmanav/pr-scanner-test-target` or the shared test repo):
```bash
terraform output dispatch_function_url
```
Webhook → Payload URL = that URL, Content type = `application/json`, Secret = the webhook-secret value,
Events = **Pull requests** (opened, synchronize).

## V5 — Verify your half before handoff
```bash
terraform init && terraform apply
terraform output dispatch_function_url

BODY='{"number":1,"pull_request":{"head":{"sha":"testsha","ref":"main"}},"repository":{"full_name":"you/test","name":"test","owner":{"login":"you"}}}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')"
curl -s -X POST "$DISPATCH_URL" -H "X-Hub-Signature-256: $SIG" \
  -H "Content-Type: application/json" -d "$BODY"
```
Confirm and record what passed:
- [ ] `200 {"message":"scan queued","job_id":"..."}`
- [ ] `pr-scanner-dispatch` logs: "Signature verified OK", "Wrote PENDING record"
- [ ] DynamoDB `pr-scanner-jobs`: PENDING item with that `job_id`
- [ ] SQS message consumed; `pr-scanner-consumer` logs: "Launched scan task ..."
- [ ] ECS console: a Fargate task started (may fail until Manav pushes the image — expected)

---

# PART 2 — HANDOFF to Manav (Slice B)

## M1 — Keep the bucket; confirm `results` no longer creates one
You **own** `pr-scanner-reports-771014276560` — keep your `aws_s3_bucket "reports"` in
`modules/scanner/main.tf` exactly as is (it's already deployed with data). Confirm Sai deleted the
duplicate bucket from `results` (Handoff S1) so there's no collision.

## M2 — Fix the sort key in the scanner
**`scanner/scan-wrapper.js`** — read the dispatch timestamp from env and use it for the SK in
**both** the success and failure `UpdateItemCommand`:
```js
const TIMESTAMP = process.env.TIMESTAMP;   // ISO8601 dispatch time, from the SQS message
// ...
Key: {
  PK: { S: `REPO#${REPO_OWNER}/${REPO_NAME}` },
  SK: { S: `SCAN#${TIMESTAMP}#${PR_NUMBER}` }   // was: SCAN#${new Date(startedAt*1000).toISOString()}#...
}
```
Keep `started_at`/`finished_at` as epoch numbers — only the **SK** must use `TIMESTAMP`. Without this,
your `UpdateItem` creates a second row instead of flipping the PENDING one to COMPLETED.

## M3 — Rebuild and push the image (linux/amd64)
```bash
ACCOUNT=771014276560
REPO="$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/pr-scanner-scanner"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REPO"
docker build --platform linux/amd64 -t pr-scanner-scanner ./scanner
docker tag pr-scanner-scanner:latest "$REPO:latest"
docker push "$REPO:latest"
```

## M4 — Export outputs + sanity-check networking
Confirm `modules/scanner/outputs.tf` exports `ecs_cluster_arn`, `ecs_cluster_name`,
`task_definition_arn`, `reports_bucket`, `ecr_repository_url`, and that networking exports
`public_subnet_id` + `scanner_security_group_id`. Verify the public subnet has an IGW route and the
SG allows outbound 443 (git clone + AWS APIs). The consumer uses `assignPublicIp=ENABLED`.

## M5 — Verify
Confirm a Fargate task launches and exits 0 when triggered **by the consumer** (not a manual run-task),
writes the report to S3, and flips the DynamoDB record to COMPLETED.

---

# PART 3 — HANDOFF to Sai (Slice C)

## S1 — Own the table; stop creating a second bucket
- Keep `aws_dynamodb_table` (`pr-scanner-jobs`) + `status-index` GSI in `modules/results/main.tf`.
- **Delete** the `aws_s3_bucket "reports"` from `modules/results/main.tf` (Manav owns it).
- Add a `reports_bucket` variable; point post-scan's `S3_BUCKET` env at `var.reports_bucket`
  (root passes `local.reports_bucket`).

## S2 — Fix the report reader
**`lambdas/post_scan/handler.py`** → `format_pr_comment`, match the scanner's actual output:
```python
total = report.get('total_vulnerabilities', 0)
sev   = report.get('severity_breakdown', {})
high, med, low = sev.get('HIGH', 0), sev.get('MEDIUM', 0), sev.get('LOW', 0)
# iterate report.get('vulnerabilities', [])
```

## S3 — Get job + repo identity from the EventBridge event
**`lambdas/post_scan/handler.py`** — replace the hardcoded `'test-job-001'`. The consumer set these
as container overrides, so they ride along in the ECS "task stopped" event:
```python
def _overrides_env(event):
    detail = event.get("detail", {})
    out = {}
    for c in detail.get("overrides", {}).get("containerOverrides", []):
        for kv in c.get("environment", []):
            out[kv.get("name")] = kv.get("value")
    return out

def lambda_handler(event, context):
    ov         = _overrides_env(event)
    job_id     = ov.get("JOB_ID")     or event.get("job_id")
    repo_owner = ov.get("REPO_OWNER")
    repo_name  = ov.get("REPO_NAME")
    pr_number  = int(ov.get("PR_NUMBER", 0))
    # look up the record by job_id, read S3 report, post comment to repo_owner/repo_name#pr_number
```

## S4 — Scope the EventBridge rule to Manav's cluster
**`modules/results/main.tf`** — the rule's most common failure is matching nothing. Pattern:
```hcl
event_pattern = jsonencode({
  source      = ["aws.ecs"]
  detail-type = ["ECS Task State Change"]
  detail = {
    clusterArn = [var.scanner_cluster_arn]   # pass module.scanner.ecs_cluster_arn from root
    lastStatus = ["STOPPED"]
  }
})
```
Add a `scanner_cluster_arn` variable and wire `module.scanner.ecs_cluster_arn` in root. If
`TriggeredRules` is 0, the ARN is wrong — copy the exact value from `terraform output`.

## S5 — Token write access
Confirm the `cs6620/github-token` secret has `repo` scope **with write access** to the test repo, or
comments fail with 404/403.

---

# PART 4 — End-to-End Testing (whole team)

**Dependency order:** V1→V2→V3 (Vaishnavi) → M1–M5 (Manav) ∥ S1–S5 (Sai) → joint test.

## 4.1 Happy path (the one test that proves "done")
1. `terraform apply` from root (whole stack on `771014276560`).
2. Open a PR on the test repo with a planted vuln (e.g. `const password = "admin123";`).
3. Trace it (target **< 2 min**):

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

## 4.2 Failure path
- Invalid signature → dispatch returns **401**, no SQS message.
- Point the scanner at a nonexistent repo → Fargate fails, DynamoDB `status=FAILED`, SNS alarm fires.
- Consumer fails repeatedly → message lands in the **DLQ**.

## 4.3 Concurrency
- Open 3 PRs at once → 3 Fargate tasks run concurrently → 3 correct comments, no cross-contamination,
  3 separate `COMPLETED` records.

## 4.4 Debugging checklist (check in order)
- Webhook reaching dispatch? → Function URL / Lambda invocation count.
- Dispatch payload correct? → `pr-scanner-dispatch` logs.
- SQS message sent? → `NumberOfMessagesSent`.
- Consumer triggered? → `pr-scanner-consumer` invocation count + logs.
- Fargate launching? → ECS tasks tab; LabRole `ecs:RunTask`/`iam:PassRole`.
- Fargate succeeding? → container logs. Exit 0=ok, 137=OOM (raise memory), 1=script error.
- EventBridge firing? → `TriggeredRules`. 0 = clusterArn mismatch.
- Post-scan running? → invocation count + logs.
- Comment posting? → GitHub API response. 401=bad token, 404=wrong repo/PR path, 422=malformed body.

---

# PART 5 — Key metrics (from the proposal)

| Metric | Target | How to measure |
|--------|--------|----------------|
| Dispatch latency | ≤ 5 s (PR event → RunTask) | dispatch log timestamp vs consumer RunTask timestamp |
| End-to-end turnaround | < 2 min (PR event → comment) | webhook time vs GitHub comment `created_at` (or DynamoDB `started_at`/`finished_at`) |
| Scan success rate | ≥ 95% | GSI on `status`: COMPLETED / total |
| Concurrent scans | ≥ 3 without queuing | open 3 PRs, all complete |
| Findings completeness | 100% with severity/file/line | every comment has all fields |

---

# PART 6 — Polish & hardening (after the happy path works)

- **Security:** move Fargate to a private subnet + NAT (or VPC endpoints); restrict the SG egress to
  GitHub + AWS endpoints (currently all egress); consider a GitHub App for short-lived tokens.
- **PR comment:** clean Markdown table — `# | Severity | File | Line | Issue | Recommendation`.
- **Merge blocking (bonus):** use the GitHub Checks API — fail the check on HIGH findings to block merge.
- **Multi-repo:** the webhook payload carries owner/repo, so the pipeline is repo-agnostic — test 2–3 repos.
- **Dashboard (optional):** S3-hosted page querying DynamoDB; pre-signed links to S3 reports.

---

# PART 7 — Common integration pitfalls

- **EventBridge not matching** (most common) — pattern must match the exact cluster ARN; `TriggeredRules=0` ⇒ wrong ARN.
- **Consumer permissions** — needs `ecs:RunTask`, `iam:PassRole`, `sqs:ReceiveMessage/DeleteMessage` (LabRole covers; verify in logs).
- **Env var name mismatch** — consumer's override names must exactly match `scan-wrapper.js` (case-sensitive).
- **DynamoDB key mismatch** — PK/SK written by dispatch must equal what the scanner updates (the SK-timestamp fix, M2).
- **Credential expiry** — re-paste fresh creds from Manav's running lab.
- **Token scope** — `repo` write access, or comments 404.
- **Fargate networking** — needs outbound internet to clone; public subnet + `assignPublicIp` for the milestone.
- **Costs** — `terraform destroy` after every session.

---

# Quick checklist

**Vaishnavi (now):**
- [ ] V1 — remove ingress table, add `dynamodb_table_name` var
- [ ] V2 — root `locals` + wiring (keep account ID/bucket; break collisions & cycle)
- [ ] V3 — consumer Lambda + `modules/consumer` + root wiring
- [ ] V4 — secrets + webhook in Manav's account
- [ ] V5 — apply, signed-curl test, record what passed

**Manav (handoff):**
- [ ] M1 — keep the bucket; confirm results' duplicate is gone
- [ ] M2 — SK from `TIMESTAMP` in `scan-wrapper.js` (both updates)
- [ ] M3 — rebuild + push image (`--platform linux/amd64`)
- [ ] M4 — export outputs; verify networking
- [ ] M5 — verify Fargate runs when triggered by the consumer

**Sai (handoff):**
- [ ] S1 — own the table; delete duplicate bucket; reference `var.reports_bucket`
- [ ] S2 — read flat report fields
- [ ] S3 — pull JOB_ID/REPO_OWNER/REPO_NAME from event overrides
- [ ] S4 — scope EventBridge rule to Manav's cluster ARN
- [ ] S5 — token write access

**Together:**
- [ ] Happy path: real PR → comment in < 2 min
- [ ] Failure path + concurrency (3 PRs)
- [ ] `terraform destroy` after the session
