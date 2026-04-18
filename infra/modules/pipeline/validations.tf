# Input validations that span multiple variables.
# Terraform variable blocks cannot reference other variables,
# so cross-variable rules live here as resource preconditions.

resource "terraform_data" "validate_container_scan_inputs" {
  lifecycle {
    precondition {
      condition     = !var.enable_container_scan || var.ecr_repo_name != ""
      error_message = "ecr_repo_name must be set when enable_container_scan = true."
    }

    precondition {
      condition     = !var.enable_container_scan || var.dockerfile_path != ""
      error_message = "dockerfile_path must be set when enable_container_scan = true."
    }
  }
}
