output "project_id" {
  description = "The project everything lives in."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "Project number (used in Workload Identity principal names)."
  value       = google_project.this.number
}

output "region" {
  description = "Region for the cluster and quota."
  value       = var.region
}

output "state_bucket" {
  description = "GCS bucket holding remote state for every layer."
  value       = google_storage_bucket.tfstate.name
}

output "gke_node_service_account" {
  description = "Service account GKE nodes run as; passed to 10-cluster."
  value       = google_service_account.gke_nodes.email
}

output "quota_console_url" {
  description = "Where to watch the quota requests get approved."
  value       = "https://console.cloud.google.com/iam-admin/quotas?project=${google_project.this.project_id}"
}

output "workload_identity_provider" {
  description = "GCP_WORKLOAD_IDENTITY_PROVIDER for GitHub Actions. Null until github_repo is set."
  value       = try(google_iam_workload_identity_pool_provider.github[0].name, null)
}

output "deploy_service_account" {
  description = "GCP_DEPLOY_SERVICE_ACCOUNT for GitHub Actions. Null until github_repo is set."
  value       = try(google_service_account.deploy[0].email, null)
}
