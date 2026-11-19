# 00-bootstrap: everything that has to exist before CI can deploy anything,
# applied once by hand with the operator's own credentials.
#
#   project + billing link   the container for all spend; delete it = $0
#   APIs                     enabled here so 10-cluster never needs serviceusage.admin
#   state bucket             holds this layer's state and 10-cluster's
#   node service account     what GKE nodes run as (minimal, not the Compute default)
#   quota requests           GPUs and vCPUs; a new project can launch neither
#   budget                   email backstop
#   github.tf                Workload Identity Federation + the deploy SA CI uses

resource "google_project" "this" {
  name            = var.project_name
  project_id      = var.project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = var.labels

  # 10-cluster builds its own VPC; the default network's permissive firewall
  # rules are just attack surface.
  auto_create_network = false

  # Deleting the project deletes everything in it, state bucket included.
  # `make nuke` is the deliberate path; a stray `terraform destroy` is not.
  deletion_policy = "PREVENT"
}

locals {
  apis = [
    "cloudbilling.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.apis)

  project = google_project.this.project_id
  service = each.value

  # Turning an API off on destroy can cascade into deleting its resources.
  # The project is the unit of teardown, not individual APIs.
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "tfstate" {
  project  = google_project.this.project_id
  name     = "${var.project_id}-tfstate"
  location = var.region
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # GCS backend locks natively with a lock object; no extra table to run.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  # Losing state mid-apply orphans a live cluster that must be cleaned up by hand.
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

# ---------------------------------------------------------------------------
# Node service account. Created here, not in 10-cluster, so the CI deploy SA
# only needs to *use* it, never to create service accounts or grant IAM roles
# (either of which would let CI escalate to owner).
# ---------------------------------------------------------------------------

resource "google_service_account" "gke_nodes" {
  project      = google_project.this.project_id
  account_id   = "gke-nodes"
  display_name = "GKE nodes (${var.project_id})"
  description  = "Runs GKE node VMs. Logging/monitoring only; no access to project data."

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "gke_nodes" {
  project = google_project.this.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}
