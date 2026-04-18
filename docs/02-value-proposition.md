# 02 — Value Proposition (aws-devsecops-pipeline-module)

## GitHub Actions + CodePipeline: Complementary Roles

This module uses **both** GitHub Actions and CodePipeline. They serve different purposes and are not interchangeable.

| Concern | GitHub Actions | CodePipeline (this module) |
|---------|---------------|---------------------------|
| When it runs | On push and pull_request — pre-merge | On push to main — post-merge |
| What it blocks | PR merge | Nothing downstream (audit gate) |
| Account boundary | Runs outside AWS | Runs inside AWS account boundary |
| Audit trail | GitHub UI only | Native CloudTrail |
| AWS credential management | OIDC token exchange required | IAM role attached natively to CodeBuild |
| Purpose | Developer feedback + PR gate | AWS-native enforcement + audit trail |

**GitHub Actions** runs first — it blocks bad PRs before they merge. **CodePipeline** runs second — it enforces the same checks on main with full AWS auditability and handles the optional container build/scan stage.

Neither replaces the other. Removing GitHub Actions means bad code can reach main before being caught. Removing CodePipeline means scans have no AWS audit trail and no container scanning capability.

---

## Why Not Manual Pipeline Setup?

Every team that builds pipelines manually makes slightly different choices: different stage names, different scan tools, different severity thresholds, different approval mechanics. When something goes wrong, there is no single reference to audit. When a new project starts, the process begins again from scratch.

This module eliminates that inconsistency. The security gates are wired in by default — they cannot be forgotten because they are the module. A consuming project gets the same pipeline as every other project that uses the module, with the same severity thresholds and the same stage structure.

---

## What This Module Adds Over Manual Setup

| Capability | Manual Setup | This Module |
|-----------|-------------|------------|
| Security scanning | Forgotten, inconsistent | Enforced on every push to `main` |
| Multi-language support | Per-project decision | Single `language` variable selects correct scanner image |
| Scanner image management | Build on every run or manage separately | Pre-built images on GitHub Container Registry (ghcr.io) — zero setup for consumers |
| IaC scanning | Typically skipped | checkov runs on every push to main |
| Container CVE scanning | Often skipped | trivy blocks CRITICAL CVEs before ECR push (`enable_container_scan = true`) |
| Reusability | Copy-paste | `module "pipeline"` call with ≤ 8 inputs |
| Versioning | None | Git tags — pin to `?ref=v1.0.0` |

---

## Tooling Decisions

### Secret Detection: gitleaks

| Alternative | Why Not |
|-------------|---------|
| `detect-secrets` (Yelp) | Lower recall on AWS credential patterns — gitleaks specifically tuned for API keys, JWT tokens, and cloud credentials |
| `git-secrets` (AWS) | AWS-specific only — misses non-AWS secrets; abandoned project |
| Manual review | Not scalable — humans miss patterns in large diffs |
| **gitleaks** | Active project, high recall across credential types, pre-commit integration, blocks at scan stage |

**When detect-secrets is better:** Repositories that need to whitelist known false positives via a `.secrets.baseline` file with team sign-off. For a portfolio/portfolio-demo pipeline, gitleaks recall is more important.

---

### Python SAST: bandit + Semgrep

| Alternative | Why Not |
|-------------|---------|
| bandit alone | Misses cross-file patterns, no rules for non-Python frameworks |
| Semgrep alone | Strong but does not have the Flask/Django-native depth of bandit |
| PyLint security plugin | Limited security rules, primarily a style linter |
| **bandit + Semgrep** | Layered coverage: bandit handles Python-native patterns (subprocess, eval, crypto misuse); Semgrep handles cross-language patterns and framework rules |

**When Semgrep alone is better:** Non-Python projects where bandit is irrelevant. Java/C#/Node scanner images use Semgrep only.

---

### IaC Scanning: checkov

| Alternative | Why Not |
|-------------|---------|
| tfsec | Fewer AWS-specific rules; merged into Trivy as of 2023 |
| Trivy (IaC mode) | Viable — but Trivy is already used for container scanning; using one tool for both reduces specialization |
| Terrascan | Narrower rule set for AWS; less active community |
| **checkov** | Widest AWS Terraform rule coverage, active rule updates, pre-commit integration via `checkov` hook |

**When tfsec is better:** Teams already invested in the Aqua Security toolchain (Trivy, tfsec/Trivy IaC) who want a single vendor.

---

### Container Scanning: trivy

| Alternative | Why Not |
|-------------|---------|
| ECR native scanning (Basic) | Scans only on push — too late in the pipeline; misses the blocking opportunity |
| ECR enhanced scanning (Inspector) | $0.09/image — not free tier |
| Snyk | Paid tier required for CI/CD integration |
| **trivy** | Free, open source, high recall, runs in CodeBuild before ECR push, blocks on CRITICAL unfixed CVEs |

Trivy runs inside CodeBuild before the image reaches ECR — this is the blocking gate. Whether to enable ECR Basic scan-on-push as an additional audit layer is the consuming project's decision, not this module's responsibility.

---

### Multi-Language SAST: Semgrep (Community)

| Alternative | Why Not |
|-------------|---------|
| SpotBugs + FindSecBugs (Java) | Requires compilation (JDK in image, separate compile stage) — adds ~3 min and significant complexity |
| Security Code Scan (C#) | Requires dotnet build (SDK in image, separate compile stage) |
| eslint-plugin-security (Node) | Pattern-based like Semgrep — no meaningful advantage over Semgrep's JS ruleset |
| **Semgrep community** | Source-only, no compilation, unified tool across all 4 languages, active rule registry |

**Acknowledged gap:** Semgrep community performs pattern-based analysis only. It does not trace user input flowing through method calls to a dangerous sink (taint analysis). This gap is meaningful for Java and C# in production environments. The gap is documented in the module README — production users of Java/C# should add SpotBugs + FindSecBugs or Security Code Scan to the pipeline.

---

### Scanner Image Registry: GitHub Container Registry (ghcr.io)

| Alternative | Rate Limits | Auth to Pull (public) | Account Dependency | Why Not |
|-------------|-------------|----------------------|-------------------|---------|
| ECR Public Gallery | None | No | AWS account — images lost on account closure | Tied to the AWS account being used for learning; not portable |
| Docker Hub | 100–200 pulls/6h (free tier) | No | Docker Hub account | Rate limits are a real risk for CodeBuild — multiple simultaneous pipeline runs could get throttled |
| Quay.io | None | No | Red Hat account | Less familiar; no meaningful advantage over ghcr.io |
| **GitHub Container Registry (ghcr.io)** | None | No (public images) | GitHub account | — |

**Decision:** ghcr.io — images live at `ghcr.io/mvhungrydev/`, tied to GitHub which is already the source of truth for all code. Survives any AWS account closure. No pull rate limits. Public images require no credentials for CodeBuild to pull — simpler IAM (no `ecr-public:GetAuthorizationToken` needed). Push via a GitHub Personal Access Token (PAT) with `write:packages` scope.

**When ECR Public is better:** Teams that want all artifacts inside AWS and have a stable, long-lived AWS account (e.g., enterprise production). For a portfolio project where the AWS account may be closed and reopened, ghcr.io is the more durable choice.

---

### CI/CD Platform: CodePipeline + CodeBuild

**Decision:** AWS CodePipeline + CodeBuild — AWS-managed, no server to maintain, native IAM, native CloudTrail, Manual Approval built in.

| Alternative | Why Not |
|-------------|---------|
| Jenkins | Self-hosted — requires EC2 instance (not free tier), OS patching, plugin management |
| CircleCI | Third-party SaaS — secrets and logs leave AWS account boundary |
| GitLab CI | Requires GitLab (not GitHub) or self-hosted GitLab runner |

**When Jenkins is better:** Large teams with existing Jenkins infrastructure and plugin ecosystems. For a new AWS-native project with no existing CI/CD investment, CodePipeline is the path of least resistance.
