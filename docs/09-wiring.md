# 09 — Module Wiring Reference

How every file in `infra/modules/pipeline/` connects to every other file.

---

## File Map

```
infra/modules/pipeline/
├── variables.tf       ← all module inputs (caller-facing)
├── scanner_images.tf  ← local map: language → ghcr.io image URL
├── validations.tf     ← cross-variable preconditions (enable_container_scan guards)
├── iam.tf             ← 3 IAM roles: codebuild_scan, codebuild_build[count], codepipeline
├── main.tf            ← S3, CloudWatch log groups, 2 CodeBuild projects, CodePipeline
└── outputs.tf         ← pipeline_name, artifact_bucket_name, artifact_bucket_arn
```

---

## Variable Flow

```
variables.tf
│
├── var.language ──────────────────────────────────────────────────────────────►  scanner_images.tf
│                                                                                  local.scanner_images[var.language]
│                                                                                  └──► main.tf  aws_codebuild_project.scan  environment.image
│
├── var.app_name ──────────────────────────────────────────────────────────────►  All resource names + tags (iam.tf, main.tf)
│
├── var.github_repo ───────────────────────────────────────────────────────────►  main.tf  aws_codepipeline  Source stage FullRepositoryId
│
├── var.branch ────────────────────────────────────────────────────────────────►  main.tf  aws_codepipeline  Source stage BranchName
│
├── var.codestar_connection_arn ───────────────────────────────────────────────►  main.tf  aws_codepipeline  Source stage ConnectionArn
│                                                                                  iam.tf   codepipeline policy  codestar-connections:UseConnection Resource
│
├── var.aws_region ────────────────────────────────────────────────────────────►  iam.tf   log group ARN scopes
│                                                                                  main.tf  codebuild_build env var ECR_REPO + AWS_REGION
│                                                                                  main.tf  local.ecr_repo_url construction
│
├── var.environment ───────────────────────────────────────────────────────────►  All resource tags (iam.tf, main.tf)
│
├── var.enable_container_scan ─────────────────────────────────────────────────►  validations.tf  precondition guards
│                                                                                  iam.tf           codebuild_build role + policy  count
│                                                                                  main.tf          codebuild_project.build  count
│                                                                                  main.tf          cloudwatch_log_group.build  count
│                                                                                  main.tf          aws_codepipeline  dynamic stage "BuildAndScanImage"
│                                                                                  main.tf          local.ecr_repo_url  ternary guard
│
├── var.ecr_repo_name ─────────────────────────────────────────────────────────►  validations.tf  precondition: must not be "" when enable_container_scan = true
│                                                                                  iam.tf           codebuild_build policy  ECR push Resource ARN
│                                                                                  main.tf          local.ecr_repo_url construction
│
└── var.dockerfile_path ───────────────────────────────────────────────────────►  validations.tf  precondition: must not be "" when enable_container_scan = true
                                                                                   main.tf          codebuild_build env var DOCKERFILE_PATH
```

---

## IAM → Resource Bindings

| IAM resource | Bound to | How |
|---|---|---|
| `aws_iam_role.codebuild_scan` | `aws_codebuild_project.scan` | `service_role = aws_iam_role.codebuild_scan.arn` |
| `aws_iam_role_policy.codebuild_scan` | `aws_iam_role.codebuild_scan` | `role = aws_iam_role.codebuild_scan.id` |
| `aws_iam_role.codebuild_build[0]` | `aws_codebuild_project.build[0]` | `service_role = aws_iam_role.codebuild_build[0].arn` |
| `aws_iam_role_policy.codebuild_build[0]` | `aws_iam_role.codebuild_build[0]` | `role = aws_iam_role.codebuild_build[0].id` |
| `aws_iam_role.codepipeline` | `aws_codepipeline.this` | `role_arn = aws_iam_role.codepipeline.arn` |
| `aws_iam_role_policy.codepipeline` | `aws_iam_role.codepipeline` | `role = aws_iam_role.codepipeline.id` |

---

## S3 Bucket References

`aws_s3_bucket.artifacts` is referenced in five places:

| File | Resource | Field | Purpose |
|---|---|---|---|
| `main.tf` | `aws_codepipeline.this` | `artifact_store.location` | Pipeline reads/writes all stage artifacts here |
| `main.tf` | `aws_codebuild_project.scan` | `cache.location` | pre-commit + pip cache prefix `…/scan` |
| `main.tf` | `aws_codebuild_project.build[0]` | `cache.location` | Docker layer cache prefix `…/build` |
| `iam.tf` | `codebuild_scan` policy | `Resource` | Grants `s3:GetObject`, `s3:PutObject` on `arn/…/*` |
| `iam.tf` | `codebuild_build[0]` policy | `Resource` | Same grants for build role |
| `iam.tf` | `codepipeline` policy | `Resource` | Grants `s3:GetObject`, `s3:PutObject`, `s3:GetBucketVersioning` on bucket + `/*` |

---

## CloudWatch Log Group → CodeBuild Bindings

| Log group | CodeBuild project | Condition |
|---|---|---|
| `aws_cloudwatch_log_group.scan` | `aws_codebuild_project.scan` | always |
| `aws_cloudwatch_log_group.build[0]` | `aws_codebuild_project.build[0]` | `enable_container_scan = true` only |

Both log groups are pre-created with `retention_in_days = 30`. CodeBuild references them via `logs_config.cloudwatch_logs.group_name`.

---

## CodePipeline Stage → CodeBuild Bindings

| Stage | CodeBuild project | `input_artifacts` | `output_artifacts` | Condition |
|---|---|---|---|---|
| `Source` | n/a (CodeStarSourceConnection) | — | `SourceArtifact` | always |
| `SecurityScan` | `aws_codebuild_project.scan` | `SourceArtifact` | — | always |
| `BuildAndScanImage` | `aws_codebuild_project.build[0]` | `SourceArtifact` | `BuildArtifact` | `enable_container_scan = true` |

---

## `count` and `dynamic` — What Gets Skipped

When `enable_container_scan = false` (the default), Terraform creates nothing for:

- `aws_iam_role.codebuild_build`
- `aws_iam_role_policy.codebuild_build`
- `aws_codebuild_project.build`
- `aws_cloudwatch_log_group.build`
- Stage 3 of `aws_codepipeline.this` (omitted via `dynamic "stage"`)
- `local.ecr_repo_url` evaluates to `""` and is never used

---

## Outputs

| Output | Source expression |
|---|---|
| `pipeline_name` | `aws_codepipeline.this.name` |
| `artifact_bucket_name` | `aws_s3_bucket.artifacts.bucket` |
| `artifact_bucket_arn` | `aws_s3_bucket.artifacts.arn` |

Consuming projects surface these via `module.pipeline.<output_name>`.