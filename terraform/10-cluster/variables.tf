# ---------------------------------------------------------------------------
# Project and placement. project_id and node_service_account come from the
# 00-bootstrap outputs.
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project created by 00-bootstrap."
  type        = string
  default     = "gke-llm-lab-01"

  nullable = false
}

variable "name" {
  description = "Name of the cluster, network and subnet. Also the prefix of the Kubernetes node labels (<name>/role=system), which gitops/bootstrap and gitops/values hardcode as llm-d-gke-lab: change them together."
  type        = string
  default     = "llm-d-gke-lab"

  nullable = false
}

variable "region" {
  description = "Region of the subnet. Must contain var.zone and var.node_zones."
  type        = string
  default     = "us-central1"

  nullable = false
}

variable "zone" {
  description = "Zone of the (zonal, free-tier) control plane and the system pool. Must also offer the GPU types in use."
  type        = string
  default     = "us-central1-b"

  nullable = false
}

variable "node_zones" {
  description = "Zones auto-provisioned (GPU) node pools may use. Three zones triples the chance of finding Spot capacity. us-central1 b/c/f all offer RTX PRO 6000 (G4); L4 (G2) is in a/b/c, so the overlap is b and c."
  type        = list(string)
  default     = ["us-central1-b", "us-central1-c", "us-central1-f"]

  validation {
    condition     = length(var.node_zones) >= 1
    error_message = "At least one zone is required."
  }

  nullable = false
}

variable "node_service_account" {
  description = "Service account GKE nodes run as (00-bootstrap output gke_node_service_account). Null = the gke-nodes account 00-bootstrap creates in var.project_id."
  type        = string
  default     = null
}

variable "labels" {
  description = "GCP labels on the cluster and its node VMs, so billing reports can group spend."
  type        = map(string)

  default = {
    project    = "gke-llm-lab"
    managed-by = "terraform"
  }

  nullable = false
}

variable "node_cidr" {
  description = "Primary range of the subnet (node IPs)."
  type        = string
  default     = "10.0.0.0/20"

  nullable = false
}

variable "pod_cidr" {
  description = "Secondary range for pod IPs. /16 = 256 nodes at the default 110 pods/node."
  type        = string
  default     = "10.16.0.0/16"

  nullable = false
}

variable "service_cidr" {
  description = "Secondary range for ClusterIP Services."
  type        = string
  default     = "10.32.0.0/20"

  nullable = false
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public GKE control-plane endpoint. Open by default because CI runners and a laptop on a changing IP both need it; narrow it for anything left running."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  nullable = false
}

# ---------------------------------------------------------------------------
# Capacity. The system pool is always on; GPU nodes exist only while a tier's
# pods need them, and never beyond the ceilings below.
# ---------------------------------------------------------------------------

variable "system_machine_type" {
  description = "System pool machine type (Spot). e2-standard-4 = 4 vCPU / 16 GB, ~$0.08/hr Spot in us-central1."
  type        = string
  default     = "e2-standard-4"

  nullable = false
}

variable "system_max_nodes" {
  description = "Upper bound of the system pool autoscaler. Usually 1-2 nodes are in use."
  type        = number
  default     = 3

  nullable = false
}

variable "max_vcpus" {
  description = "Cluster-wide vCPU ceiling for the autoscaler, system pool included. 2 x g4-standard-48 (96) + system headroom. Keep at or below the project's CPUS-ALL-REGIONS quota (128)."
  type        = number
  default     = 120

  nullable = false
}

variable "max_memory_gb" {
  description = "Cluster-wide memory ceiling (GB). 2 x g4-standard-48 (360) + system headroom."
  type        = number
  default     = 420

  nullable = false
}

variable "max_gpus" {
  description = "Cluster-wide GPU ceilings by GKE accelerator type: the hard cost guard. A type absent here can never be provisioned. 2 RTX PRO 6000 = the gpu tier's 1->2 Spot replicas (~$3.44/hr at most)."
  type        = map(number)

  default = {
    "nvidia-rtx-pro-6000" = 2
    "nvidia-l4"           = 2
  }

  nullable = false
}

# Pinned to the llm-d v1.0.0 tested matrix, NOT to latest upstream. Istio's
# newest is 1.31.x, but llm-d v1.0 is tested against 1.29.4 — the gateway is on
# the request path for every token, so track what they test.
variable "gateway_api_version" {
  description = "Gateway API CRD version. llm-d v1.0.0 pins v1.6.2."
  type        = string
  default     = "v1.6.2"

  nullable = false
}

variable "gaie_version" {
  description = "Gateway API Inference Extension CRD version. llm-d v1.0.0 pins v1.6.2."
  type        = string
  default     = "v1.6.2"

  nullable = false
}

variable "istio_version" {
  description = "Istio version. llm-d v1.0.0 is tested against 1.29.4; kgateway was removed in v1.0."
  type        = string
  default     = "1.29.4"

  nullable = false
}

variable "prometheus_chart_version" {
  description = "kube-prometheus-stack chart version. Required: KEDA scales on EPP metrics scraped by Prometheus, and the llm-d router chart emits a ServiceMonitor, so the Prometheus Operator CRDs must exist."
  type        = string
  default     = "92.16.0"

  nullable = false
}

variable "enable_istio" {
  description = "Install Istio. NOT needed for llm-d standalone router mode, which proxies requests itself via an Envoy sidecar and is exposed by a plain LoadBalancer Service. Only turn this on for the Gateway API dataplane path."
  type        = bool
  default     = false

  nullable = false
}

variable "keda_version" {
  description = "KEDA Helm chart version. KEDA drives replica count from llm-d EPP queue depth."
  type        = string
  default     = "2.21.0"

  nullable = false
}

# ---------------------------------------------------------------------------
# GitOps (Argo CD). Terraform installs Argo CD and one root Application; the
# inference layer itself is reconciled from gitops/ in this repo.
# ---------------------------------------------------------------------------

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (https://argoproj.github.io/argo-helm). Keep aligned with local/argocd-up.sh."
  type        = string
  default     = "10.18.0"

  nullable = false
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (https://argoproj.github.io/argo-helm), which creates the root Application."
  type        = string
  default     = "2.0.8"

  nullable = false
}

variable "gitops_repo_url" {
  description = "Git repository Argo CD reconciles from. Must be readable without credentials (public)."
  type        = string
  default     = "https://github.com/didiberman/llm-d-gke-lab.git"

  nullable = false
}

variable "gitops_revision" {
  description = "Branch, tag or commit Argo CD tracks."
  type        = string
  default     = "main"

  nullable = false
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the public endpoints (model API, Open WebUI). Injected into the root Application, never committed to git. The model-server chart refuses to render on GKE if this is empty."
  type        = list(string)
  default     = []

  nullable = false
}

variable "hf_token" {
  description = "HuggingFace token, stored as the llm-d-hf-token Secret the model server reads. Optional for ungated models. Set via TF_VAR_hf_token; never commit it."
  type        = string
  default     = ""
  sensitive   = true

  nullable = false
}
