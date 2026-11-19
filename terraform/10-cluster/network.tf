# Network, built around the same decision as the EKS version: NO NAT.
#
# Cloud NAT bills per VM-hour plus $0.045/GB processed. Every cold start pulls
# a ~10 GB vLLM image and tens of GB of weights from Hugging Face, so the data
# charge alone can rival the GPU bill. Nodes therefore get external IPs and
# egress directly; ingress is free.
#
# The trade: nodes are internet-addressable, so the firewall is the only thing
# between the kubelet and the world. GKE creates only the rules it needs
# (control plane -> nodes, node <-> node); nothing else is open inbound.
# Fine for a disposable lab; production would use private nodes + NAT.

resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name          = var.name
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = var.node_cidr

  # VPC-native cluster: pods and services come from secondary ranges, so pod
  # IPs are routable in the VPC with no overlay.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }

  # Lets nodes without external IPs (none today) reach Google APIs; free.
  private_ip_google_access = true
}
