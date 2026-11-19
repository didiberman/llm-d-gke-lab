# Quota increase requests as code. Cloud Quotas records the preference and
# Google grants (or reviews) it asynchronously: the apply succeeds as soon as
# the request is filed, not when it is approved. Watch the result with
# `make quota-status` or in the console's Quotas page.
#
# GPU quota on GCP is layered; a Spot G4 node must clear every layer:
#   GPUS-ALL-REGIONS-per-project            0 by default
#   GPUS-PER-GPU-FAMILY-per-project-region  0 by default for NVIDIA_RTX_PRO_6000;
#                                           NVIDIA_L4 is often 1 (the small tier)
#   CPUS-ALL-REGIONS-per-project            32 by default; one g4-standard-48 is 48
#
# Spot VMs draw on the normal (non-PREEMPTIBLE) limits while the PREEMPTIBLE
# quota is unset, which it is on a new project.

locals {
  quota_requests = var.request_quota ? {
    gpus-all-regions = {
      quota_id   = "GPUS-ALL-REGIONS-per-project"
      dimensions = {}
      value      = var.gpu_quota
    }
    gpus-rtx-pro-6000 = {
      quota_id   = "GPUS-PER-GPU-FAMILY-per-project-region"
      dimensions = { region = var.region, gpu_family = "NVIDIA_RTX_PRO_6000" }
      value      = var.gpu_quota
    }
    gpus-l4 = {
      quota_id   = "GPUS-PER-GPU-FAMILY-per-project-region"
      dimensions = { region = var.region, gpu_family = "NVIDIA_L4" }
      value      = var.l4_quota
    }
    cpus-all-regions = {
      quota_id   = "CPUS-ALL-REGIONS-per-project"
      dimensions = {}
      value      = var.cpu_quota_global
    }
  } : {}
}

resource "google_cloud_quotas_quota_preference" "this" {
  provider = google.in_project
  for_each = local.quota_requests

  parent        = "projects/${google_project.this.project_id}"
  name          = each.key
  service       = "compute.googleapis.com"
  quota_id      = each.value.quota_id
  dimensions    = each.value.dimensions
  justification = var.quota_justification
  contact_email = var.quota_contact_email

  quota_config {
    preferred_value = each.value.value
  }

  # Google may grant less than asked, or adjust it later; that is not drift
  # to fight on every plan.
  lifecycle {
    ignore_changes = [quota_config[0].preferred_value]
  }

  depends_on = [google_project_service.this]
}
