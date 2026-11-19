terraform {
  required_version = "~> 1.13"

  # Remote state lives in the bucket this layer creates (backend.tf). On a
  # brand-new project that bucket does not exist yet: move backend.tf aside,
  # apply with local state, restore it, then `terraform init -migrate-state`
  # and confirm the migration succeeded before deleting the local file.

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

# Creates the project and links billing. Runs on the operator's own gcloud
# application-default credentials; nothing in this layer runs from CI.
provider "google" {
  region = var.region
}

# Cloud Quotas and Billing Budgets bill API usage to a "quota project". With
# user credentials that has to be set explicitly, and it should be the project
# the request is about, which only exists once google_project.this does.
provider "google" {
  alias = "in_project"

  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
