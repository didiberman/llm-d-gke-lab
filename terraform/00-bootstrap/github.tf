# GitHub Actions -> GCP without stored keys: Workload Identity Federation.
#
# GitHub's OIDC token is exchanged for a short-lived token of the deploy
# service account. The provider's attribute_condition is the real boundary:
# only workflows in var.github_repo running on refs/heads/main get through, so
# a pull request from a branch can neither deploy nor read state.
#
# The deploy SA gets what 10-cluster needs and nothing that grants IAM:
#   container.admin          create/upgrade/delete the cluster, kubectl as admin
#   compute.networkAdmin     VPC, subnet, router
#   compute.securityAdmin    firewall rules
#   iam.serviceAccountUser   on the node SA only: attach it to node pools
#   storage.objectAdmin      on the state bucket only
#   compute.viewer           read-only: the destroy workflow's "nothing left
#                            billing" report lists VMs, disks and addresses

locals {
  github_enabled = var.github_repo != null
}

resource "google_iam_workload_identity_pool" "github" {
  count = local.github_enabled ? 1 : 0

  project                   = google_project.this.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = local.github_enabled ? 1 : 0

  project                            = google_project.this.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == '${var.github_repo}' && assertion.ref == 'refs/heads/main'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deploy" {
  count = local.github_enabled ? 1 : 0

  project      = google_project.this.project_id
  account_id   = "github-deploy"
  display_name = "GitHub Actions deploy"
  description  = "Impersonated by GitHub Actions on main of ${var.github_repo} to apply 10-cluster."

  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "deploy_wif" {
  count = local.github_enabled ? 1 : 0

  service_account_id = google_service_account.deploy[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repo}"
}

resource "google_project_iam_member" "deploy" {
  for_each = local.github_enabled ? toset([
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/compute.viewer",
    "roles/serviceusage.serviceUsageConsumer",
  ]) : toset([])

  project = google_project.this.project_id
  role    = each.value
  member  = google_service_account.deploy[0].member
}

resource "google_service_account_iam_member" "deploy_uses_node_sa" {
  count = local.github_enabled ? 1 : 0

  service_account_id = google_service_account.gke_nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deploy[0].member
}

resource "google_storage_bucket_iam_member" "deploy_state" {
  count = local.github_enabled ? 1 : 0

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.deploy[0].member
}
