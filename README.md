# aws-devsecops-pipeline-module

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.10-purple)
![AWS CodePipeline](https://img.shields.io/badge/AWS-CodePipeline-orange)
![License](https://img.shields.io/badge/License-MIT-green)

A reusable Terraform module that provisions an AWS-native security scanning pipeline. Drop it into any project to get automated secret scanning, SAST, and IaC scanning on every push — with optional container vulnerability scanning. Supports Python, Java, C#, and Node.js via a single `language` input variable. Does not own deployment — stops at producing a verified artifact.

---

## What This Repo Delivers

**Two artifacts:**

1. **4 scanner Docker images** — hosted on ECR Public Gallery, pulled by CodeBuild at runtime with no authentication required
2. **Terraform module** (`infra/modules/pipeline/`) — provisions CodePipeline, CodeBuild projects, S3 artifact bucket, SNS approval topic, and IAM roles in the consuming project's AWS account

This repo contains no application code. The Flask demo app that consumes this module lives in a separate repository (`sample-python-app`).

---

## Pipeline Stages

**Base mode** (`enable_container_scan = false`, default):
```
GitHub (source only)
      │ CodeStar Connection
      ▼
CodePipeline
  ├── Stage 1: Source         ← pull from GitHub → S3
  └── Stage 2: Security Scan  ← gitleaks + bandit/Semgrep + checkov   [BLOCKS]
```

**With container scanning** (`enable_container_scan = true`):
```
CodePipeline
  ├── Stage 1: Source         ← pull from GitHub → S3
  ├── Stage 2: Security Scan  ← gitleaks + bandit/Semgrep + checkov   [BLOCKS]
  └── Stage 3: Build & Scan   ← docker build + trivy + ECR push       [BLOCKS]
```

The consuming project's deployment pipeline takes over from ECR after Stage 3. All stages run inside AWS. Every execution is logged in CloudTrail. No credentials leave the AWS account boundary.

---

## Security Scanning Tools

| Stage | Tool | Scope | Blocks On |
|-------|------|-------|-----------|
| Security Scan | gitleaks | All files | Any detected credential |
| Security Scan | bandit | Python source only | HIGH+ findings |
| Security Scan | Semgrep | All source files | HIGH+ findings |
| Security Scan | checkov | `infra/**/*.tf` | CRITICAL/HIGH misconfigs |
| Build & Scan | trivy | Built container image | CRITICAL unfixed CVEs |

### SAST Gap — Read Before Using in Production

This pipeline uses **Semgrep community** for multi-language SAST. Semgrep performs **pattern-based analysis** — it identifies dangerous function calls and obvious misuse. It does **not** perform **taint analysis** — it cannot trace user input through multiple method calls to a dangerous sink.

| Language | Gap | Production Recommendation |
|----------|-----|--------------------------|
| Python | Small — bandit covers Flask/stdlib patterns | bandit + Semgrep (already included) |
| Node | Negligible — comparable to eslint-plugin-security | Semgrep is sufficient |
| Java | Meaningful — multi-hop injection paths missed | Add SpotBugs + Find Security Bugs |
| C# | Meaningful — cross-method taint analysis missing | Add Security Code Scan |

---

## Scanner Images (ECR Public Gallery)

Pre-built images, publicly pullable — no authentication required for CodeBuild to pull.

| `language` value | Image URI |
|-----------------|-----------|
| `python` | `ghcr.io/mvhungrydev/security-scanner-python:latest` |
| `java` | `ghcr.io/mvhungrydev/security-scanner-java:latest` |
| `dotnet` | `ghcr.io/mvhungrydev/security-scanner-dotnet:latest` |
| `node` | `ghcr.io/mvhungrydev/security-scanner-node:latest` |

Each image includes: checkov, gitleaks, Semgrep, pre-commit. The Python image also includes bandit.

### First-Time Bootstrap (One-Time Manual Step)

Scanner images must be built and pushed to GitHub Container Registry before any consuming project can run a pipeline. Run from this repo's root:

```bash
# 1. Create a GitHub PAT with write:packages scope
#    GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic)
#    Scopes: write:packages

# 2. Authenticate
export GITHUB_PAT=<your-token>
echo $GITHUB_PAT | docker login ghcr.io --username mvhungrydev --password-stdin

# 3. Build and push all 4 images
docker build -t security-scanner-python scanner-images/python/
docker tag security-scanner-python ghcr.io/mvhungrydev/security-scanner-python:latest
docker push ghcr.io/mvhungrydev/security-scanner-python:latest

docker build -t security-scanner-java scanner-images/java/
docker tag security-scanner-java ghcr.io/mvhungrydev/security-scanner-java:latest
docker push ghcr.io/mvhungrydev/security-scanner-java:latest

docker build -t security-scanner-dotnet scanner-images/dotnet/
docker tag security-scanner-dotnet ghcr.io/mvhungrydev/security-scanner-dotnet:latest
docker push ghcr.io/mvhungrydev/security-scanner-dotnet:latest

docker build -t security-scanner-node scanner-images/node/
docker tag security-scanner-node ghcr.io/mvhungrydev/security-scanner-node:latest
docker push ghcr.io/mvhungrydev/security-scanner-node:latest

# 4. Set each package to Public visibility
#    GitHub → Packages → [package name] → Package settings → Change visibility → Public
```

To update a scanner image, bump the version in the Dockerfile, rebuild, and push with the same tag.

---

## Consuming This Module

### Step 1 — CodeStar Connection (One-Time Per AWS Account)

CodePipeline connects to GitHub via AWS CodeStar Connections. The OAuth step cannot be automated — it requires a one-time click in the console.

1. AWS Console → **CodePipeline** → **Settings** → **Connections**
2. **Create connection** → provider: **GitHub** → name: `github-connection`
3. **Connect to GitHub** → authorize AWS Connector for GitHub → **Connect**
4. Wait for status: **Available**
5. Copy the Connection ARN → add to `terraform.tfvars` as `codestar_connection_arn`

One connection per AWS account can serve all pipelines.

### Step 2 — Call the Module

Pin to a git tag. Never use `HEAD` — a tag guarantees the module version is immutable.

**Security scan only (default):**
```hcl
# your-project/infra/envs/dev/main.tf
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"   # python | java | dotnet | node
  app_name                = "my-app"
  github_repo             = "mvhungrydev/my-app"
  branch                  = "main"
  codestar_connection_arn = var.codestar_connection_arn
}
```

**With container scanning (adds Build + Trivy + ECR Push stage):**
```hcl
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"   # python | java | dotnet | node
  app_name                = "my-app"
  github_repo             = "mvhungrydev/my-app"
  branch                  = "main"
  codestar_connection_arn = var.codestar_connection_arn
  enable_container_scan   = true
  ecr_repo_name           = module.ecr.repository_name
}
```

### Step 3 — Done

No SNS subscription, no approval email, no Terraform state configuration needed. The pipeline is self-contained — consuming projects handle their own deployment after the pipeline produces a verified artifact.

---

## Using with Java, C#, or Node.js

Changing `language` is the only Terraform change needed. Two additional steps are required in your consuming project:

### 1. Update `.pre-commit-config.yaml`

Copy `.pre-commit-config.yaml` from this repo to your project root, then **remove the bandit hook** — bandit is Python-only and will error on Java/C#/Node source files:

```yaml
# REMOVE this entire block for non-Python projects
- repo: https://github.com/PyCQA/bandit
  rev: 1.7.9
  hooks:
    - id: bandit
      args: ["-c", "pyproject.toml"]
      files: ^sample-app/
```

The remaining hooks (gitleaks, Semgrep, checkov, terraform_fmt) work for all languages.

### 2. Know the SAST gap for Java and C#

This module uses **Semgrep community** for SAST — pattern-based analysis only. For Java and C#, Semgrep cannot trace user input through multiple method calls to a dangerous sink (taint analysis). This is a meaningful gap for production workloads.

| Language | Gap | Recommended addition |
|----------|-----|----------------------|
| Java | Multi-hop injection paths missed | SpotBugs + [Find Security Bugs](https://find-sec-bugs.github.io/) |
| C# | Cross-method taint analysis missing | [Security Code Scan](https://security-code-scan.github.io/) |
| Node.js | Negligible — comparable rule coverage | None required |

Adding these tools requires a dedicated compile-and-scan stage (they need bytecode/compiled output). This is a documented v1 limitation — not a blocker for getting started, but address it before using this pipeline for production Java or C# workloads.

---

## Module Input Variables

| Variable | Type | Default | Required | Description |
|----------|------|---------|----------|-------------|
| `language` | string | — | Yes | Scanner image selector: `python`, `java`, `dotnet`, `node` |
| `app_name` | string | — | Yes | Used in all resource names and tags |
| `github_repo` | string | — | Yes | GitHub repo in `owner/repo` format |
| `branch` | string | `"main"` | No | Pipeline trigger branch |
| `codestar_connection_arn` | string | — | Yes | ARN of the Available CodeStar Connection to GitHub |
| `enable_container_scan` | bool | `false` | No | Adds Build + Trivy + ECR Push stage when `true` |
| `ecr_repo_name` | string | `""` | No | Required when `enable_container_scan = true` |
| `aws_region` | string | `"us-east-1"` | No | AWS region for all resources |
| `environment` | string | `"dev"` | No | Environment tag applied to all module resources |

## Module Outputs

| Output | Description |
|--------|-------------|
| `pipeline_name` | CodePipeline name — for console navigation |
| `artifact_bucket_name` | S3 artifact bucket name |
| `artifact_bucket_arn` | S3 artifact bucket ARN |

---

## Module Versioning

This module uses semantic versioning via git tags.

```
v1.0.0  — initial release
v1.0.1  — buildspec bugfix, no variable changes
v1.1.0  — new optional variable added (backward compatible)
v2.0.0  — breaking change: variable renamed or removed
```

To release a new version:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Consuming projects update their `source` ref and run:

```bash
terraform init -upgrade
terraform plan
```

---

## Local Developer Setup

Copy `.pre-commit-config.yaml` from this repo to your consuming project's root, then run the setup script.

### macOS / Linux

```bash
./scripts/setup-dev.sh
```

### Windows (PowerShell)

```powershell
.\scripts\setup-dev.ps1
```

Both scripts install `pre-commit` and register hooks in `.git/hooks/`. Hooks then run automatically on every `git commit`.

### Why Local gitleaks Matters

For all hooks except gitleaks, local setup is a convenience (faster feedback). For **gitleaks specifically**, it prevents a worse outcome:

- **Without local gitleaks:** A commit with a secret reaches GitHub before the pipeline blocks it. The secret is in git history and must be scrubbed — a painful, often incomplete process.
- **With local gitleaks:** The commit is rejected before it leaves your machine. The secret never touches GitHub.

---

## Free Tier Usage (Per Consuming Project)

| Service | Free Tier | Usage |
|---------|-----------|-------|
| CodePipeline | 1 free active pipeline/month | 1 pipeline per project |
| CodeBuild | 100 min/month (`general1.small`) | ~8 min/run with S3 caching |
| S3 | 5 GB storage, 20k GET, 2k PUT | Artifacts + cache + state |
| SNS | 1M publishes/month | 1 email per pipeline run |
| CloudWatch Logs | 5 GB ingestion/month | Build logs, 30-day retention |

With S3 caching: approximately **12 full pipeline runs per month** within the free tier. Over-budget runs cost ~$0.04–$0.07 each (`$0.005/min × ~8 min`).

---

## Repo Structure

```
aws-devsecops-pipeline-module/
├── infra/
│   └── modules/
│       └── pipeline/          ← reusable Terraform module
│           ├── main.tf        ← CodePipeline, CodeBuild, S3, SNS, CloudWatch
│           ├── variables.tf
│           ├── outputs.tf
│           ├── iam.tf         ← 3 CodeBuild IAM roles + 1 CodePipeline role
│           ├── scanner_images.tf  ← locals: language → ECR Public image map
│           └── buildspecs/    ← YAML templates per stage
│               ├── scan.yml
│               ├── build.yml
│               ├── plan.yml
│               └── apply.yml
├── scanner-images/            ← Dockerfiles for ECR Public
│   ├── python/Dockerfile
│   ├── java/Dockerfile
│   ├── dotnet/Dockerfile
│   └── node/Dockerfile
├── scripts/
│   ├── setup-dev.sh           ← macOS/Linux pre-commit setup
│   └── setup-dev.ps1          ← Windows pre-commit setup
├── docs/                      ← design documentation (Mike Velasco Special)
├── .pre-commit-config.yaml    ← template — copy to consuming project root
├── .gitignore
└── README.md
```
