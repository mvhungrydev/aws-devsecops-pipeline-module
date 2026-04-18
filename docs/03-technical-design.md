# 03 — Technical Design (aws-devsecops-pipeline-module)

## What This Repo Delivers

Two artifacts:

1. **Scanner images** — 4 Docker images hosted on GitHub Container Registry (ghcr.io). Each image contains the security scanning tools for a specific language. CodeBuild pulls these images at the start of the Security Scan stage.

2. **Terraform module** — `infra/modules/pipeline/` provisions a CodePipeline with security scanning stages. Consuming projects reference this module via a versioned GitHub source. The module does not own deployment — it stops at producing a verified artifact.

---

## Architecture: What the Module Creates

```
  Developer
       │
       │ git push / pull request
       ▼
  GitHub
       │
       ├──► GitHub Actions (security-scan.yml)          [PRE-MERGE GATE]
       │         pre-commit run --all-files
       │         Blocks PR merge on any finding
       │
       │ merge to main
       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Consuming Project AWS Account                       │
│                                                                             │
│  GitHub (consuming repo)                                                    │
│       │                                                                     │
│       │ push to main                                                        │
│       ▼                                                                     │
│  CodeStar Connection ──────────────────────────────► CodePipeline           │
│  (one-time manual setup,                                    │               │
│   ARN passed as input var)                                  │               │
│                                                             │               │
│  ┌──────────────────────────────────────────────────────────▼─────────┐    │
│  │  Stage 1: Source                                                    │    │
│  │  CodePipeline pulls source artifact → stores in S3 artifact bucket │    │
│  └──────────────────────────────────────────────────────────┬─────────┘    │
│                                                             │               │
│  ┌──────────────────────────────────────────────────────────▼─────────┐    │
│  │  Stage 2: Security Scan                          BLOCKS            │    │
│  │  CodeBuild pulls ghcr.io scanner image (language-specific)        │    │
│  │  Restores S3 cache (pre-commit envs, pip packages)                 │    │
│  │  pre-commit run --all-files:                                       │    │
│  │    gitleaks → bandit (Python only) → Semgrep → checkov             │    │
│  │  Exit non-zero on any finding → pipeline FAILED                   │    │
│  └──────────────────────────────────────────────────────────┬─────────┘    │
│                                                             │ pass          │
│  ┌──────────────────────────────────────────────────────────▼─────────┐    │
│  │  Stage 3: Build & Scan Image (enable_container_scan = true only)   │    │
│  │  BLOCKS                                                             │    │
│  │  CodeBuild (AWS standard image, privileged mode)                   │    │
│  │  docker build → trivy image scan → docker push to ECR (private)   │    │
│  │  Blocks on CRITICAL unfixed CVEs — image NOT pushed if blocked    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Supporting resources provisioned by module:                                │
│    S3 bucket ── pipeline artifacts + CodeBuild cache                        │
│    CloudWatch Log Groups ── one per CodeBuild project, 30-day retention     │
│    IAM roles ── one per CodeBuild project (least-privilege)                 │
│                                                                             │
│  External dependency (not provisioned by module):                           │
│    GitHub Container Registry ── scanner images (public, no auth required)  │
│    CodeStar Connection ARN ── passed as input variable                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow (Numbered Steps)

**Full flow (GitHub Actions + CodePipeline):**

1. Developer pushes to a feature branch or opens a PR
2. **GitHub Actions fires:** runs `pre-commit run --all-files` — gitleaks, bandit (Python), Semgrep, checkov, terraform fmt. Any failure blocks the PR merge. Developer fixes and pushes again.
3. PR passes all checks → developer merges to `main`
4. CodeStar Connection webhook notifies CodePipeline

**Base mode (`enable_container_scan = false`):**

1. Developer pushes code to the configured `branch` on GitHub
2. CodeStar Connection webhook notifies CodePipeline
3. CodePipeline pulls the source artifact from GitHub and stores it in the S3 artifact bucket
4. **Stage 2:** CodeBuild starts using the language-specific ghcr.io scanner image. Restores S3 cache. Runs `pre-commit run --all-files`. Any hook failure exits non-zero → stage FAILED → pipeline stops
5. All hooks pass → pipeline execution complete. Consuming project's deployment pipeline takes over from here.

**Container scan mode (`enable_container_scan = true`):**

Steps 1–4 are identical. Then:

5. **Stage 3:** CodeBuild starts with AWS standard image (privileged mode). Restores Docker layer cache. Runs `docker build`. Runs `trivy image --severity CRITICAL --ignore-unfixed --exit-code 1`. If trivy exits 1 → stage FAILED → image NOT pushed to ECR. If trivy passes → `docker push` to private ECR tagged with short commit SHA.
6. Pipeline execution complete. Consuming project deploys from ECR.

---

## Scanner Image Design

### Language → Image Mapping

| `language` input | ghcr.io Image URI | SAST Tools Included |
|------------------|------------------|---------------------|
| `python` | `ghcr.io/mvhungrydev/security-scanner-python:latest` | Semgrep + bandit |
| `java` | `ghcr.io/mvhungrydev/security-scanner-java:latest` | Semgrep |
| `dotnet` | `ghcr.io/mvhungrydev/security-scanner-dotnet:latest` | Semgrep |
| `node` | `ghcr.io/mvhungrydev/security-scanner-node:latest` | Semgrep |

All 4 images include: **checkov**, **gitleaks**, **pre-commit framework**.

The mapping is stored in `infra/modules/pipeline/scanner_images.tf` as a Terraform `locals` block. The CodeBuild scan project references `local.scanner_images[var.language]` for its build environment image.

### Python Scanner Dockerfile (annotated)

```dockerfile
FROM python:3.12-slim

# git is required by pre-commit for hook installation and by gitleaks for history scan
RUN apt-get update && apt-get install -y \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# gitleaks: installed as a binary (not via pip) — pinned to known-good version
RUN curl -sSfL \
    https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz \
    | tar -xz -C /usr/local/bin gitleaks

# All Python security tools pinned to exact versions for reproducible scans
# bandit: Python-specific SAST (Flask, subprocess, crypto misuse patterns)
# semgrep: Multi-language pattern-based SAST
# checkov: Terraform IaC misconfiguration scanner
# pre-commit: Hook framework — runs all tools via .pre-commit-config.yaml
RUN pip install --no-cache-dir \
    bandit==1.7.9 \
    semgrep==1.70.0 \
    checkov==3.2.0 \
    pre-commit==3.7.0

# Fail the image build if any tool is broken — catches installation errors early
RUN gitleaks version && bandit --version && semgrep --version && checkov --version
```

### Java/dotnet/node Dockerfile (delta from Python)

Identical to Python image except `bandit` is omitted:

```dockerfile
RUN pip install --no-cache-dir \
    semgrep==1.70.0 \
    checkov==3.2.0 \
    pre-commit==3.7.0
```

bandit is Python-only tooling — including it in the Java/dotnet/node images would add install time with zero benefit.

### ghcr.io Bootstrap (First-Time Only)

Scanner images must be built and pushed before the first pipeline run. This is a one-time manual step. Full step-by-step in `README.md`. Summary:

1. Create a GitHub PAT with `write:packages` scope (GitHub → Settings → Developer settings → Personal access tokens)
2. `echo $GITHUB_PAT | docker login ghcr.io --username mvhungrydev --password-stdin`
3. `docker build -t security-scanner-python scanner-images/python/`
4. `docker tag security-scanner-python ghcr.io/mvhungrydev/security-scanner-python:latest`
5. `docker push ghcr.io/mvhungrydev/security-scanner-python:latest`
6. Set each pushed package to **Public** visibility (GitHub → Packages → Package settings → Change visibility)
7. Repeat for java, dotnet, node

Public ghcr.io images require no credentials for CodeBuild to pull — no IAM permissions needed beyond what CodeBuild already has.

---

## Pre-Commit Hook Architecture

`.pre-commit-config.yaml` lives in this repo as a **template**. Consuming projects copy it to their repo root. CodeBuild (Stage 2) runs `pre-commit run --all-files` inside the scanner image — this is the mandatory enforcement point. Local installation is optional.

```
.pre-commit-config.yaml (in this repo — template)
       │
       └── copied to consuming project root
                │
                ├── CodeBuild Stage 2 (mandatory — no bypass)
                │   pre-commit run --all-files
                │
                └── Developer local (optional)
                    macOS: scripts/setup-dev.sh
                    Windows: scripts/setup-dev.ps1
```

### Hooks Configured

| Hook | Tool | Scope | Blocks On |
|------|------|-------|-----------|
| Secret detection | gitleaks | All files | Any detected credential |
| Python SAST | bandit | `sample-app/**/*.py` | HIGH+ findings |
| Multi-language SAST | Semgrep | All source files | HIGH+ findings |
| IaC scan | checkov | `infra/**/*.tf` | CRITICAL/HIGH misconfigs |
| Terraform format | terraform fmt | `infra/**/*.tf` | Unformatted files |

### Why the bandit hook scopes to `sample-app/`

bandit runs on Python source files only. The `sample-app/` path is hard-coded in the `.pre-commit-config.yaml` template because the template is designed for the `sample-python-app` consumer. Projects with a different app directory must update this path.

### Why Local gitleaks Matters Beyond CI Enforcement

For all hooks except gitleaks, local installation speeds up feedback. For gitleaks specifically, it provides a security advantage: a secret blocked locally never enters GitHub history. A secret blocked by the pipeline has already been committed and pushed — it exists in the git log and requires history rewriting. Local gitleaks prevents that.

---

## SAST Gap Documentation

Semgrep community performs **pattern-based analysis** — dangerous function calls and obvious misuse. It does NOT perform **taint analysis** — it cannot trace user input through multiple method calls to a dangerous sink.

| Language | Gap Severity | Native Taint Tool | Why Not Included |
|----------|-------------|-------------------|-----------------|
| Python | Low | N/A | bandit covers most Python-native patterns |
| Node | Negligible | eslint-plugin-security | Comparable rule coverage |
| Java | Meaningful | SpotBugs + FindSecBugs | Requires bytecode compilation — adds JDK, compile stage |
| C# | Meaningful | Security Code Scan | Requires dotnet build — adds SDK, compile stage |

**Production recommendation for Java/C#:** Add SpotBugs + FindSecBugs (Java) or Security Code Scan (C#) as a dedicated compile-and-scan stage. This is a documented limitation of the v1 module, not a design error.

---

## IAM Role Design

### Role 1 — Security Scan (`${app_name}-codebuild-scan-role`)

```json
{
  "Statement": [
    // ghcr.io is a public registry — no IAM permissions needed to pull scanner images

    // Read source artifact from S3; write/read cache
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::${artifact_bucket}/*"
    },
    { "Effect": "Allow", "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::${artifact_bucket}" },

    // CloudWatch Logs — write build logs
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/codebuild/${app_name}-*"
    }
  ]
}
```

### Role 2 — Build & Push (`${app_name}-codebuild-build-role`) — `enable_container_scan = true` only

All permissions from Role 1, plus:

```json
{
  "Statement": [
    // Authenticate to private ECR (push app image)
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },

    // Push image layers and manifest to private ECR repo only
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:${region}:${account_id}:repository/${ecr_repo_name}"
    }
  ]
}
```

### Role 3 — CodePipeline (`${app_name}-codepipeline-role`)

```json
{
  "Statement": [
    // Start and manage CodeBuild projects
    { "Effect": "Allow", "Action": ["codebuild:StartBuild", "codebuild:BatchGetBuilds"], "Resource": "*" },

    // Read/write artifacts in S3
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion", "s3:GetBucketVersioning"],
      "Resource": [
        "arn:aws:s3:::${artifact_bucket}",
        "arn:aws:s3:::${artifact_bucket}/*"
      ]
    },

    // Use CodeStar Connection to pull from GitHub
    { "Effect": "Allow", "Action": "codestar-connections:UseConnection", "Resource": "${codestar_connection_arn}" }
  ]
}
```

---

## CodeBuild Caching Strategy

S3 caching is the primary mechanism for staying within 100 free CodeBuild minutes/month.

| Stage | Cached Paths | Estimated Savings |
|-------|-------------|------------------|
| Security Scan | `~/.cache/pre-commit/**/*`, `~/.cache/pip/**/*` | ~60s on repeat runs |
| Build & Image (optional) | `~/.docker/**/*` (Docker layer cache) | ~90s on repeat runs |

Cache is stored in `${artifact_bucket}/codebuild-cache/${app_name}/` — isolated per app name so multiple pipelines sharing the same artifact bucket do not collide.

### Free Tier Math

| Scenario | Minutes per Run | Runs/Month (100 min budget) |
|----------|----------------|----------------------------|
| Scan only, no caching | ~4 min | ~25 |
| Scan only, S3 caching | ~2 min | ~50 |
| Scan + container, no caching | ~10 min | ~10 |
| Scan + container, S3 caching | ~6 min | ~16 |
