output "pipeline_name" {
  value       = aws_codepipeline.this.name
  description = "CodePipeline name — for console navigation and manual retries"
}

output "artifact_bucket_name" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "S3 artifact bucket name — used by CodePipeline and CodeBuild cache"
}

output "artifact_bucket_arn" {
  value       = aws_s3_bucket.artifacts.arn
  description = "S3 artifact bucket ARN — for attaching additional IAM policies if needed"
}
