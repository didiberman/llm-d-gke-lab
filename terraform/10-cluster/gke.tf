# GKE Standard, zonal control plane, nodes in up to three zones.
#
# Zonal on purpose: GKE's free tier credits the $0.10/hr management fee of one
# zonal (or Autopilot) cluster per billing account, so the control plane is
# effectively $0. A regional control plane would be billed. Node pools can
# still span other zones (a "multi-zonal" cluster), which is what matters for
# finding Spot GPU capacity.
#
# Why Standard, not Autopilot: Autopilot bills per pod request with a GPU
# premium and hides the node, and this lab is about watching nodes appear and
# disappear.
#
# Karpenter's job on EKS is done here by GKE itself:
#   cluster_autoscaling (node auto-provisioning) below  = the Karpenter controller
#   ComputeClass (in gitops/, managed by Argo CD)       = the NodePool + EC2NodeClass
# The resource_limits are the hard cost ceiling, the analogue of the NodePool
# vCPU limit: no tier, autoscaler or bug can exceed them.

resource "google_container_cluster" "this" {
  name     = var.name
  location = var.zone

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.this.id

  # The default pool is replaced by the system pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  # The destroy workflow must be able to delete the cluster.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Public endpoint: driven from CI and a laptop on a changing IP, no bastion.
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.api_allowed_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "allowed-${cidr_blocks.key}"
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Gateway API CRDs are installed by platform.tf at the version llm-d v1.0.0
  # tests (v1.6.2). A GKE-managed channel would own the same CRDs and fight it.
  gateway_api_config {
    channel = "CHANNEL_DISABLED"
  }

  # Node auto-provisioning: lets ComputeClasses create GPU node pools on demand
  # and delete them when empty.
  cluster_autoscaling {
    enabled = true

    # Reclaims an idle GPU node in minutes instead of ~10; the EKS
    # equivalent of consolidationPolicy WhenEmptyOrUnderutilized.
    autoscaling_profile = "OPTIMIZE_UTILIZATION"

    auto_provisioning_locations = var.node_zones

    auto_provisioning_defaults {
      service_account = local.node_service_account
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

      management {
        auto_repair  = true
        auto_upgrade = true
      }
    }

    # Cluster-wide ceilings, system pool included.
    dynamic "resource_limits" {
      for_each = merge(
        { cpu = var.max_vcpus, memory = var.max_memory_gb },
        var.max_gpus,
      )
      content {
        resource_type = resource_limits.key
        minimum       = 0
        maximum       = resource_limits.value
      }
    }
  }

  # Cost visibility per namespace/label in the billing export; free.
  cost_management_config {
    enabled = true
  }

  # System logs only. Workload logs and Managed Prometheus bill per GB; the
  # in-cluster Prometheus (platform.tf) is what feeds KEDA.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  resource_labels = var.labels
}

# Somewhere for Argo CD, KEDA, Prometheus, the router and Open WebUI to run
# that is not a GPU. Without it the first GPU node would also have to host the
# platform, and scaling GPUs to zero would take the platform with it.
resource "google_container_node_pool" "system" {
  name     = "system"
  cluster  = google_container_cluster.this.id
  location = var.zone

  # Single zone: the control plane's. Spot reclaims reschedule pods onto the
  # replacement, which is worth watching rather than avoiding.
  node_locations = [var.zone]

  autoscaling {
    min_node_count = 1
    max_node_count = var.system_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.system_machine_type
    spot            = true
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = local.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "${local.label_prefix}/role" = "system"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    resource_labels = var.labels
  }

  lifecycle {
    # The autoscaler owns the count.
    ignore_changes = [initial_node_count]
  }
}
