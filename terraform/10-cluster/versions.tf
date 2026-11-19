terraform {
  required_version = "~> 1.13"

  # Bucket created by 00-bootstrap (<project_id>-tfstate), passed at init:
  #   terraform init -backend-config="bucket=<project_id>-tfstate"
  # (CI and `make cluster-plan` do this.) The prefix keeps each layer's state
  # separate.
  backend "gcs" {
    prefix = "10-cluster"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Kubernetes auth uses the caller's own Google access token (CI: the deploy
# SA via Workload Identity Federation; locally: gcloud ADC). No kubeconfig,
# no gke-gcloud-auth-plugin, nothing long-lived in state.
data "google_client_config" "this" {}

locals {
  k8s_host = "https://${google_container_cluster.this.endpoint}"
  k8s_ca   = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)

  label_prefix         = var.name
  node_service_account = coalesce(var.node_service_account, "gke-nodes@${var.project_id}.iam.gserviceaccount.com")
}

provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca
  token                  = data.google_client_config.this.access_token
}

# helm provider v3 takes `kubernetes` as an attribute, not a block.
provider "helm" {
  kubernetes = {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca
    token                  = data.google_client_config.this.access_token
  }
}
