# Checkov Security Findings — Pipeline Module

**Scan date:** 2026-04-25  
**Tool:** Checkov (Terraform static analysis)  
**Target:** `infra/modules/pipeline/`  
**Result:** 34 passed · 9 failed · 1 skipped

---

## Summary Table

| Check ID | Resource | Finding | Decision |
|---|---|---|---|
| CKV_AWS_145 | `aws_s3_bucket.artifacts` | S3 not encrypted with KMS CMK | Skip — cost |
| CKV_AWS_18 | `aws_s3_bucket.artifacts` | S3 access logging not enabled | Skip — cost |
| CKV_AWS_144 | `aws_s3_bucket.artifacts` | S3 cross-region replication not enabled | Skip — cost |
| CKV2_AWS_62 | `aws_s3_bucket.artifacts` | S3 event notifications not enabled | Skip — not applicable |
| CKV_AWS_300 | `aws_s3_bucket_lifecycle_configuration.artifacts` | Lifecycle rule missing abort-failed-uploads | Fix |
| CKV_AWS_158 | `aws_cloudwatch_log_group.scan` | CloudWatch log group not encrypted with KMS | Skip — cost |
| CKV_AWS_338 | `aws_cloudwatch_log_group.scan` | Log group retention < 1 year | Skip — intentional |
| CKV_AWS_147 | `aws_codebuild_project.scan` | CodeBuild not encrypted with KMS CMK | Skip — cost |
| CKV_AWS_219 | `aws_codepipeline.this` | CodePipeline artifact store not using KMS CMK | Skip — cost |

---

## Finding Details

---

### CKV_AWS_300 — S3 Lifecycle: Missing Abort Failed Uploads Rule

**Decision: FIX**

**What Checkov checks:**  
The lifecycle configuration must include an `abort_incomplete_multipart_upload` rule with a `days_after_initiation` value. Without it, failed or abandoned multipart uploads accumulate in S3 indefinitely and incur storage charges.

**How to fix:**  
Add an `abort_incomplete_multipart_upload` block to the existing lifecycle rule in `main.tf`:

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # Abort incomplete multipart uploads after 1 day to prevent
    # abandoned uploads from silently accumulating storage charges.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
```

**Why it matters:**  
CodePipeline and CodeBuild write artifacts via multipart upload. If a pipeline run is interrupted mid-upload, the incomplete parts are not automatically cleaned up. At scale this creates unbounded storage costs with no corresponding usable artifact.

---

### CKV_AWS_145 — S3 Encryption: Not Using KMS CMK

**Decision: SKIP**

**What Checkov checks:**  
S3 bucket default encryption must use a customer-managed KMS key (CMK) rather than SSE-S3 (AES256).

**Current config:**  
The bucket uses SSE-S3 (`sse_algorithm = "AES256"`), which encrypts all objects at rest using AWS-managed keys.

**Why we are skipping:**  
KMS CMKs cost **$1/key/month** plus **$0.03 per 10,000 API calls**. Every S3 GET and PUT against an encrypted bucket generates a KMS API call. For a CI/CD artifact bucket that handles frequent pipeline runs, this adds up quickly with zero free tier coverage. SSE-S3 provides encryption at rest — data is protected. The threat model for this project (internal CI/CD pipeline, bucket is fully private with public access blocked) does not justify the additional cost of envelope encryption with a CMK.

**When to revisit:**  
If this pipeline handles regulated data (PCI, HIPAA) or the consuming project has a compliance requirement for CMK-managed encryption, add a `kms_key_id` variable and switch the `sse_algorithm` to `aws:kms`.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_145: SSE-S3 is sufficient for this use case; KMS CMK costs $1/key/month with no free tier
```

---

### CKV_AWS_18 — S3 Access Logging Not Enabled

**Decision: SKIP**

**What Checkov checks:**  
S3 buckets should have server access logging enabled, writing request logs to a separate target bucket.

**Why we are skipping:**  
Access logging requires a second S3 bucket dedicated to log storage, plus ongoing storage costs for the log objects themselves. For this free-tier pipeline project the artifact bucket is already private (no public access), and all access is exclusively via CodePipeline and CodeBuild IAM roles. CloudTrail data events can be enabled at the account level if full S3 API audit logging is needed. Creating a dedicated logging bucket adds infrastructure scope that is out of bounds for a free-tier module.

**When to revisit:**  
If a compliance framework (SOC 2, PCI) requires full S3 access audit logs, add a `logging_bucket` variable and an `aws_s3_bucket_logging` resource.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_18: Access logging requires a second bucket; covered by CloudTrail at account level if needed
```

---

### CKV_AWS_144 — S3 Cross-Region Replication Not Enabled

**Decision: SKIP**

**What Checkov checks:**  
S3 buckets should replicate objects to a bucket in another AWS region for disaster recovery.

**Why we are skipping:**  
Cross-region replication requires a destination bucket in a second region and incurs replication data transfer charges. This bucket holds **transient CI/CD artifacts** — source zip files and build outputs that are regenerated on every pipeline run. Losing these artifacts does not cause data loss; the next pipeline run regenerates them from source. CRR is appropriate for primary data stores, not ephemeral artifact buckets.

**When to revisit:**  
Never for this use case. If the pipeline is extended to store release artifacts that must survive a region outage, create a separate long-term artifact bucket with CRR enabled.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_144: Artifacts are ephemeral and regenerated on each run; CRR adds cost with no recovery value
```

---

### CKV2_AWS_62 — S3 Event Notifications Not Enabled

**Decision: SKIP**

**What Checkov checks:**  
S3 buckets should have event notifications configured to alert on object-level events.

**Why we are skipping:**  
This bucket is the CodePipeline artifact store. CodePipeline already monitors the bucket using its own internal polling and event mechanism via CodeStar connections — it does not rely on S3 event notifications to trigger. Adding an SNS or SQS notification on every `s3:PutObject` would fire on every artifact write (including CodeBuild cache writes) and has no consumer in this architecture. This check is not applicable to pipeline artifact buckets.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV2_AWS_62: Pipeline artifact bucket; CodePipeline manages triggers — S3 event notifications have no consumer here
```

---

### CKV_AWS_158 — CloudWatch Log Group Not Encrypted with KMS

**Decision: SKIP**

**What Checkov checks:**  
CloudWatch log groups should be encrypted using a KMS CMK via the `kms_key_id` argument.

**Why we are skipping:**  
CloudWatch log group KMS encryption costs **$1/key/month** plus KMS API calls for every log event ingested. CodeBuild generates a high volume of log events per build (tool output, stdout from scanners). CloudWatch already encrypts log data at rest using AWS-managed keys. The build logs in this pipeline contain scan tool output — not secrets, credentials, or PII. The AWS-managed encryption is appropriate.

**When to revisit:**  
If logs contain sensitive output (e.g., bandit findings that expose internal paths in a regulated environment), add a `kms_key_arn` variable and pass it to `kms_key_id`.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_158: CloudWatch default encryption is sufficient; KMS CMK costs $1/key/month with no free tier
```

---

### CKV_AWS_338 — CloudWatch Log Group Retention < 1 Year

**Decision: SKIP — intentional design choice**

**What Checkov checks:**  
CloudWatch log group retention must be set to at least 365 days.

**Current config:**  
Retention is set to **30 days**.

**Why we are skipping:**  
This is an intentional free-tier decision. CloudWatch charges **$0.03/GB/month** for log storage beyond the free tier (5GB). Security scanner output (gitleaks, bandit, semgrep, checkov) can be verbose — a busy pipeline accumulates gigabytes of logs quickly. 30 days covers the window needed to investigate recent pipeline failures and is standard practice for CI/CD build logs.

If audit retention of scan results is required, the correct approach is to export findings to S3 (which has a much lower storage cost) rather than retaining raw CloudWatch logs.

**When to revisit:**  
If a compliance requirement mandates 1-year retention of security scan evidence, increase retention to 365 and budget for log storage costs, or add a CloudWatch → S3 export.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_338: 30-day retention is intentional — build logs are verbose and CloudWatch storage is $0.03/GB/month
```

---

### CKV_AWS_147 — CodeBuild Project Not Encrypted with KMS CMK

**Decision: SKIP**

**What Checkov checks:**  
CodeBuild projects should specify a KMS key ARN for encrypting build artifacts at rest.

**Why we are skipping:**  
CodeBuild artifacts are written to the S3 artifact bucket, which is already encrypted with SSE-S3. The KMS key on the CodeBuild project is an additional envelope encryption layer applied to the build output before it lands in S3. For pipeline scan results (exit codes and log output), this is redundant with the S3-level encryption already in place. Adding a CMK adds $1/key/month with no practical security improvement for this threat model.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_147: Artifacts encrypted at rest via S3 SSE-S3; additional CMK adds $1/key/month with no added value
```

---

### CKV_AWS_219 — CodePipeline Artifact Store Not Using KMS CMK

**Decision: SKIP**

**What Checkov checks:**  
The CodePipeline `artifact_store` block should specify an `encryption_key` block with a KMS CMK ARN.

**Why we are skipping:**  
Same rationale as CKV_AWS_147. The artifact store is the S3 bucket already encrypted with SSE-S3. CodePipeline will use the bucket's default encryption for all artifacts it writes. Specifying a CMK at the pipeline level would require provisioning and managing a KMS key ($1/key/month) for what amounts to transient build artifacts. SSE-S3 encryption is sufficient.

**Checkov skip annotation:**
```hcl
# checkov:skip=CKV_AWS_219: Artifact bucket uses SSE-S3 encryption; KMS CMK adds $1/key/month with no added value for transient artifacts
```

---

## Applying the Skip Annotations

All skip annotations should be added as inline comments on the resource block, directly above the argument or at the resource level. Example pattern:

```hcl
resource "aws_s3_bucket" "artifacts" {
  # checkov:skip=CKV_AWS_145: SSE-S3 is sufficient; KMS CMK costs $1/key/month with no free tier
  # checkov:skip=CKV_AWS_18: Access logging requires a second bucket; covered by CloudTrail at account level if needed
  # checkov:skip=CKV_AWS_144: Artifacts are ephemeral and regenerated on each run; CRR adds cost with no recovery value
  # checkov:skip=CKV2_AWS_62: Pipeline artifact bucket; CodePipeline manages triggers — S3 event notifications have no consumer
  bucket        = "${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  ...
}
```

---

## Action Items

| Priority | Action | File |
|---|---|---|
| 1 | Add `abort_incomplete_multipart_upload` block to lifecycle rule | `main.tf` |
| 2 | Add checkov skip annotations to `aws_s3_bucket.artifacts` | `main.tf` |
| 3 | Add checkov skip annotation to `aws_cloudwatch_log_group.scan` (×2) | `main.tf` |
| 4 | Add checkov skip annotation to `aws_codebuild_project.scan` | `main.tf` |
| 5 | Add checkov skip annotation to `aws_codepipeline.this` | `main.tf` |
