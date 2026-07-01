# PR Scanner

**Automated SAST Pipeline for GitHub Pull Requests**

Built for CS 6620 — Fundamentals of Cloud Computing, Northeastern University (Professor Aanchan Mohan, Summer 2026)

> "Shift left" — catch vulnerabilities at the PR stage, not in production.

PR Scanner automatically scans every GitHub pull request for security vulnerabilities and posts the findings directly as a PR comment — in about 60 seconds — so developers can fix issues before merging instead of discovering them later.

---

## Table of Contents

- [Why PR Scanner](#why-pr-scanner)
- [Architecture](#architecture)
- [How a Scan Works](#how-a-scan-works)
- [Tech Stack](#tech-stack)
- [Data Contracts](#data-contracts)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Monitoring & Alerts](#monitoring--alerts)
- [Performance & Cost](#performance--cost)
- [Learner Lab Constraints](#learner-lab-constraints)
- [Known Issues & Fixes](#known-issues--fixes)
- [Lessons Learned](#lessons-learned)
- [Team](#team)

---

## Why PR Scanner

| Without PR Scanner | With PR Scanner |
|---|---|
| Vulnerabilities slip into production undetected | Every PR is scanned automatically on open |
| Manual code reviews miss security patterns | Findings posted as a PR comment in ~60 seconds |
| No consistent SAST across repositories | Severity-ranked vulnerability table, inline |
| Developers discover issues too late in the cycle | Developers fix issues before merge |

The scanner is a Static Application Security Testing (SAST) tool — it reads code without running it, pattern-matching against known bad practices. It detects 10 vulnerability types: hardcoded secrets, SQL injection, NoSQL injection, XSS, path traversal, eval/exec usage, hardcoded IPs, weak randomness, sensitive data in logs, and weak crypto.

## Architecture

An event-driven, fully serverless pipeline on AWS:

```
GitHub PR opened
      │  webhook
      ▼
API Gateway (HTTP API)  ──POST /webhook──▶  Dispatch Lambda
                                              │  HMAC verify (Secrets Manager)
                                              │  write PENDING record (DynamoDB)
                                              ▼
                                        SQS (scan-jobs + DLQ)
                                              │
                                              ▼
                                        Consumer Lambda
                                              │  launches task, passes env vars
                                              ▼
                                        ECS Fargate task
                                              │  clone repo → run SAST scan
                                              ▼
                                        S3 (report JSON) + DynamoDB (status: COMPLETED)
                                              │
                                        EventBridge (task STOPPED rule)
                                              ▼
                                        Post-Scan Lambda
                                              │  read results, format Markdown table
                                              ▼
                                        GitHub PR comment posted
```

The system is split into three independently owned slices:

| Slice | Owner | Responsibility |
|---|---|---|
| **A — Ingress & Dispatch** | Vaishnavi Jariwala | Webhook intake, HMAC verification, job enqueueing |
| **B — Scanner Core & Networking** | Manav Kaneria | VPC/networking, ECS Fargate scanner container |
| **C — Results & Observability** | Sai Vardhan Pathuri | Post-scan processing, GitHub comment posting, logging, alerting |

### Slice A — Ingress & Dispatch

- **Ingress Module (`modules/ingress/`):** Creates the SQS queues and Dispatch Lambda.
  - **SQS + DLQ:** `scan-jobs` queue with a 5-minute visibility timeout; the dead-letter queue (`scan-jobs-dlq`) captures messages after 3 failed retries.
  - **Dispatch Lambda (Python 3.12):** Exposed via Lambda Function URL (public HTTPS). Verifies the GitHub webhook signature (HMAC-SHA256) via Secrets Manager, writes a `PENDING` record to DynamoDB (`PK=REPO#…`, `SK=SCAN#<timestamp>#<pr>`), and enqueues a job to SQS.
  - **DynamoDB:** The canonical jobs table lives in the results module (`pr-scanner-jobs`); Dispatch references it by name.

- **Consumer Module (`modules/consumer/`):** Drains the SQS queue and launches ECS tasks.
  - **Consumer Lambda (Python 3.12):** Triggered by SQS messages (batch_size = 1). Parses the message and launches an ECS Fargate task, passing repo URL, commit SHA, job ID, and PR number as environment variables.

### Slice B — Scanner Core & Networking

- **Networking Module (`modules/networking/`):** VPC infrastructure for Fargate.
  - **VPC:** `10.0.0.0/16` CIDR with DNS support.
  - **Public Subnet:** `10.0.1.0/24` in `us-east-1a` with `map_public_ip_on_launch` enabled.
  - **Internet Gateway:** Attached to VPC for outbound internet access.
  - **Route Table:** Routes `0.0.0.0/0` to the IGW, associated with the public subnet.
  - **Security Group:** Allows all outbound traffic (for cloning repos and pushing to S3).

- **Scanner Module (`modules/scanner/`):** ECS and storage infrastructure.
  - **ECR Repository:** `pr-scanner-scanner` for Docker images.
  - **ECS Cluster:** `pr-scanner-cluster` running Fargate tasks.
  - **Task Definition:** 512 CPU / 1024 MiB, `linux/amd64` platform, `awsvpc` network mode.
  - **CloudWatch Log Group:** `/ecs/pr-scanner-scanner` with 7-day retention.
  - **S3 Bucket:** `pr-scanner-reports-<account_id>` for storing scan result JSON.

- **Scanner Container (Node.js):** `scan-wrapper.js` orchestrates `git clone` → `scanCode()` → upload. `scanCode()` is the course-provided SAST engine (regex-based detection) and returns a flat array of `{ severity, rule, file, line, message }` objects.
- **Output:** report JSON written to the `pr-scanner-reports` S3 bucket; DynamoDB record updated to `status: COMPLETED` with `vuln_count` and `s3_key`.

### Slice C — Results & Observability

- **Results Module (`modules/results/`):** Post-scan processing and monitoring.
  - **DynamoDB Jobs Table:** `pr-scanner-jobs` with PK/SK design and a `status-index` GSI for querying by status.
  - **Post-Scan Lambda (Python 3.12):** Reads the DynamoDB record, fetches the JSON report from S3, formats a Markdown vulnerability table, and posts it as a PR comment via the GitHub API using a stored token.
  - **EventBridge Rule:** Matches ECS task state changes to `STOPPED` for `pr-scanner-cluster`, triggering the Post-Scan Lambda.
  - **CloudWatch:** Dedicated log groups per Lambda and per ECS task, with full traceability via a shared `job_id` across every stage. Includes a CloudWatch dashboard with widgets for invocations, errors, and duration.
  - **SNS:** Alerts the team by email on scan failures or DLQ messages (`pr-scanner-alerts` topic).
  - **CloudWatch Alarm:** `pr-scanner-post-scan-errors` watches the `Errors` metric on the Post-Scan Lambda and fires on any error within a 60-second window.

## How a Scan Works

1. A developer opens or updates a pull request on GitHub.
2. GitHub fires a webhook to the API Gateway endpoint.
3. The Dispatch Lambda verifies the signature, records a `PENDING` scan, and queues the job.
4. The Consumer Lambda picks up the job and starts an ECS Fargate task.
5. The Fargate task clones the repo at the PR's commit and runs the SAST scanner.
6. Results are written to S3 and DynamoDB.
7. When the task stops, EventBridge triggers the Post-Scan Lambda, which posts a formatted vulnerability table as a comment on the PR.

End-to-end latency: **~60 seconds**.

## Tech Stack

- **Compute:** AWS Lambda (Python 3.12), AWS ECS Fargate (Node.js scanner container)
- **Messaging:** Amazon SQS (+ DLQ), Amazon EventBridge
- **Storage:** Amazon S3, Amazon DynamoDB
- **Networking:** Amazon API Gateway (HTTP API), VPC with public subnet + Internet Gateway
- **Security:** AWS Secrets Manager (GitHub token + webhook HMAC secret)
- **Observability:** Amazon CloudWatch (logs, metrics, alarms), Amazon SNS
- **Infrastructure as Code:** Terraform
- **Container registry:** Amazon ECR

## Data Contracts

**SQS message (Dispatch → Consumer)**
```json
{
  "job_id": "0c495bc3-...",
  "repo_url": "github.com/user/repo",
  "commit_sha": "2c87b07...",
  "pr_number": 1,
  "repo_full_name": "user/repo",
  "timestamp": "2026-06-16T00:28:20Z"
}
```

**DynamoDB record**
```
PK: REPO#<owner>/<repo>
SK: SCAN#<timestamp>#<pr_number>
job_id, status: PENDING -> COMPLETED
vuln_count, s3_key
```

**S3 report (JSON)**
```json
{
  "job_id": "0c495bc3-...",
  "repo": "user/repo",
  "commit": "2c87b07...",
  "vulnerabilities": [
    {
      "severity": "HIGH",
      "rule": "hardcoded-secret",
      "file": "vulnerable.js",
      "line": 3,
      "message": "Potential ...",
      "snippet": "const api..."
    }
  ],
  "summary": { "total": 10, "high": 6, "medium": 4 }
}
```

**GitHub PR comment (Markdown)**
```
## PR Scanner Results

| Severity | Rule | File | Line | Message |
|---|---|---|---|---|
| HIGH | hardcoded-secret | vulnerable.js | 3 | ... |
| MEDIUM | eval-usage | vulnerable.js | 8 | ... |

10 findings total
```

## Repository Layout

```
pr-scanner/
 ├── modules/
 │   ├── ingress/                 # Slice A: SQS queues, DLQ, Dispatch Lambda + Function URL
 │   │   ├── main.tf
 │   │   ├── variables.tf
 │   │   └── outputs.tf
 │   ├── consumer/                # Slice A→B: SQS consumer Lambda, ECS RunTask
 │   │   ├── main.tf
 │   │   ├── variables.tf
 │   │   └── outputs.tf
 │   ├── scanner/                 # Slice B: ECR, ECS cluster, task definition, S3 bucket
 │   │   ├── main.tf
 │   │   ├── variables.tf
 │   │   └── outputs.tf
 │   ├── networking/              # Slice B: VPC, subnet, IGW, route tables, security group
 │   │   ├── main.tf
 │   │   ├── variables.tf
 │   │   └── outputs.tf
 │   └── results/                 # Slice C: DynamoDB, Post-Scan Lambda, EventBridge, SNS, CloudWatch
 │       ├── main.tf
 │       ├── variables.tf
 │       └── outputs.tf
 ├── lambdas/
 │   ├── dispatch/                # Python: HMAC verify, SQS enqueue, DynamoDB PENDING write
 │   │   └── handler.py
 │   ├── sqs_consumer/            # Python: Parse SQS message, launch ECS Fargate task
 │   │   └── handler.py
 │   └── post_scan/               # Python: Read S3/DynamoDB, format Markdown, post GitHub comment
 │       └── handler.py
 ├── scanner/
 │   ├── scan-wrapper.js          # Node.js: git clone → scanCode() → S3 upload
 │   ├── scanner.js               # Course-provided SAST engine (regex-based detection)
 │   ├── server.js                # Local test server
 │   ├── Dockerfile
 │   └── package.json
 ├── main.tf                      # Root module: providers, backend, module calls
 ├── variables.tf                 # Input variables (project name, region, account ID, emails)
 ├── outputs.tf                   # Stack outputs (webhook URL, cluster ARN, bucket name)
 ├── terraform.tfvars             # Variable values (account_id, region, alert_email)
 ├── terraform.tfstate            # State file (do not commit in production)
 ├── terraform.tfstate.backup     # Backup state
 ├── .terraform.lock.hcl          # Provider version lock
 ├── .gitignore
 └── README.md
```

## Prerequisites

- AWS Academy Learner Lab account (or standard AWS account with equivalent IAM permissions)
- Terraform
- Node.js (for building the scanner container)
- Docker, with the ability to build `linux/amd64` images
- A GitHub repository with permission to configure webhooks and post PR comments
- A GitHub personal access token with `repo` scope (stored in Secrets Manager)

## Deployment

> The exact commands depend on how the Terraform root module is organized — confirm against `terraform/` before running in a new environment.

1. **Configure secrets** in AWS Secrets Manager: GitHub webhook secret and GitHub API token.
2. **Build and push the scanner image** to ECR — always target `linux/amd64`, even from Apple Silicon:
   ```bash
   docker build --platform linux/amd64 -t pr-scanner-scanner:latest .
   docker tag pr-scanner-scanner:latest <ecr-repo-uri>:latest
   docker push <ecr-repo-uri>:latest
   ```
3. **Deploy infrastructure** with Terraform (one applier at a time to avoid state conflicts):
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
4. **Configure the GitHub webhook** on the target repo to point at the API Gateway `POST /webhook` URL, using the same secret stored in Secrets Manager.
5. **Tear down when done:**
   ```bash
   terraform destroy
   ```

## Configuration

Key environment variables / parameters passed between components:

| Name | Set by | Used by |
|---|---|---|
| `repo_url`, `commit_sha`, `pr_number`, `job_id` | Consumer Lambda | ECS Fargate task |
| `TIMESTAMP` | Dispatch Lambda | Scanner (ensures a consistent DynamoDB sort key) |
| GitHub webhook secret | Secrets Manager | Dispatch Lambda (HMAC verification) |
| GitHub API token | Secrets Manager | Post-Scan Lambda (comment posting) |

## Monitoring & Alerts

- CloudWatch log groups exist per Lambda and per ECS task, all correlated by `job_id`.
- A CloudWatch alarm (`pr-scanner-post-scan-errors`) watches the `Errors` metric on the Post-Scan Lambda and fires on any error within a 60-second window.
- Alarm state changes publish to the `pr-scanner-alerts` SNS topic, which emails subscribed team members.

## Performance & Cost

**Timing breakdown (end-to-end ~60s):**

| Stage | Component | Duration |
|---|---|---|
| Webhook receive | API Gateway + Lambda cold start | < 1 sec |
| Dispatch processing | HMAC verify + DDB write + SQS send | ~0.8 sec |
| Task launch | SQS + Consumer Lambda + ECS RunTask | ~2 sec |
| Container pull (cold) | ECR image download | ~27 sec |
| SAST scan | Clone repo + scan + S3 upload | ~1 sec |
| Post-scan | EventBridge + Lambda + GitHub API | ~2 sec |

**Cost per scan: ~$0.005** (dominated by ECS Fargate runtime). At 100 scans/day, estimated monthly cost is ~$15 — well within a $100 Learner Lab budget.

## Learner Lab Constraints

This project was built against AWS Academy Learner Lab, which imposes some non-standard restrictions worth knowing if you deploy it elsewhere:

- **LabRole only** — no custom IAM roles/policies; every service uses the pre-provisioned `LabRole` ARN.
- **Session expiry** — credentials expire roughly every 4 hours and must be refreshed via the Learner Lab console (Secrets Manager values persist across refreshes).
- **Single region** — restricted to `us-east-1`.
- **Single-applier Terraform model** — only one person runs `apply`/`destroy` at a time to avoid state conflicts.
- **$100 budget cap** — the serverless-first design keeps cost under $0.01/scan; run `terraform destroy` at the end of every session (an idle NAT Gateway alone costs ~$1/day).
- **Undocumented restrictions** — e.g., Lambda Function URLs are silently blocked; discovered only through trial and error.

## Known Issues & Fixes

| Problem | Fix |
|---|---|
| Lambda Function URL returned 403 despite correct IAM | Switched the webhook endpoint to API Gateway (HTTP API) |
| Docker images built on Apple Silicon (arm64) failed silently on Fargate | Always build with `--platform linux/amd64` before pushing to ECR |
| Assumed `scanCode()` returned `{ vulnerabilities: [...] }`; actual output is a flat array | Tested locally first; adjusted `scan-wrapper.js` to handle the array directly |
| Scanner generating its own timestamp caused DynamoDB key mismatches | Dispatch Lambda passes a `TIMESTAMP` env var; the scanner uses it for a consistent sort key |

## Lessons Learned

1. Test locally before deploying — especially Docker images and scanner output shapes.
2. Learner Lab has undocumented restrictions — always keep a fallback architecture ready.
3. Platform targeting matters — arm64 images on amd64 Fargate fail silently.
4. A serverless-first design keeps costs near zero while still behaving production-like.
5. A single-applier Terraform model prevents state corruption in shared accounts.
6. End-to-end traceability via a shared `job_id` makes debugging straightforward.

## Team

| Team Member | Slice | Role |
|---|---|---|
| Vaishnavi Jariwala | Slice A | Ingress & Dispatch |
| Manav Kaneria | Slice B | Scanner Core & Networking |
| Sai Vardhan Pathuri | Slice C | Results & Observability |

**Course:** CS 6620 — Fundamentals of Cloud Computing, Northeastern University
**Instructor:** Professor Aanchan Mohan · Summer 2026 · Group 11
