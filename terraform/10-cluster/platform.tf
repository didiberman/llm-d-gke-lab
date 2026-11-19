# Platform layer: the CRDs and controllers llm-d expects to already exist.
#
# Version pinning here follows the llm-d v1.0.0 tested matrix, not upstream
# latest. Istio ships 1.31.x but llm-d tests 1.29.4, and the gateway sits on the
# request path for every token — track what they test.
#
# CRDs go in via kubectl rather than a Helm chart because both projects publish
# them as plain multi-document YAML releases. That makes this layer dependent on
# a kubectl binary on the machine running terraform, which is a real wart; the
# alternative (splitting multi-doc YAML into kubectl_manifest resources) is
# worse to maintain and breaks whenever upstream adds a document.
#
# kubectl authenticates with the same short-lived Google token the providers
# use, passed by environment (never in triggers, so never in state) — no
# kubeconfig and no gke-gcloud-auth-plugin needed.

locals {
  kubectl_env = {
    KUBE_HOST  = local.k8s_host
    KUBE_CA    = google_container_cluster.this.master_auth[0].cluster_ca_certificate
    KUBE_TOKEN = data.google_client_config.this.access_token
  }

  kubectl_prelude = <<-EOT
    set -euo pipefail
    ca=$(mktemp); trap 'rm -f "$ca"' EXIT
    printf '%s' "$KUBE_CA" | base64 -d > "$ca"
    k() { kubectl --server="$KUBE_HOST" --certificate-authority="$ca" --token="$KUBE_TOKEN" "$@"; }
  EOT
}

resource "null_resource" "gateway_api_crds" {
  triggers = {
    version = var.gateway_api_version
    cluster = google_container_cluster.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_prelude}
      k apply --server-side -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml
    EOT
  }

  depends_on = [google_container_node_pool.system]
}

# Gateway API Inference Extension: the InferencePool CRD. This is what llm-d's
# endpoint picker binds to, and what makes the router inference-aware rather
# than a plain HTTP load balancer.
#
# `v1-manifests.yaml`, not `manifests.yaml`, to match what llm-d's own
# quickstart applies. The release ships three variants:
#
#   v1-manifests.yaml           inferencepools (v1)                  <- this
#   manifests.yaml              the above + inferencepoolimports (v1alpha1)
#   experimental-manifests.yaml alpha features
#
# manifests.yaml would also work (it is a superset), but the extra
# InferencePoolImport CRD is for multi-cluster routing we do not use, and
# matching upstream keeps the surface to exactly what llm-d tests.
resource "null_resource" "gaie_crds" {
  triggers = {
    version = var.gaie_version
    cluster = google_container_cluster.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_prelude}
      k apply --server-side -f \
        https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${var.gaie_version}/v1-manifests.yaml
    EOT
  }

  depends_on = [null_resource.gateway_api_crds]
}

resource "helm_release" "istio_base" {
  count = var.enable_istio ? 1 : 0

  name             = "istio-base"
  namespace        = "istio-system"
  create_namespace = true
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version

  wait = true

  depends_on = [null_resource.gateway_api_crds]
}

# OFF BY DEFAULT. llm-d standalone router mode runs its own Envoy sidecar and
# is exposed by a plain Service of type LoadBalancer (a passthrough Network
# Load Balancer on GKE), so no
# Gateway API dataplane is needed. Istio is kept behind a flag for the
# gateway-mode path, which this lab does not use — running it anyway would just
# consume system-node CPU that Prometheus and the router need.
resource "helm_release" "istiod" {
  count = var.enable_istio ? 1 : 0

  name       = "istiod"
  namespace  = "istio-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version

  wait = true

  values = [yamlencode({
    pilot = {
      nodeSelector = { "${local.label_prefix}/role" = "system" }
      resources = {
        requests = { cpu = "200m", memory = "1Gi" }
      }
    }
  })]

  depends_on = [helm_release.istio_base]
}

# KEDA scales model server replicas from the EPP queue-depth metric. Queue
# depth, not GPU utilisation: a saturated GPU and a comfortable one both read
# ~100%, so utilisation cannot tell you when to add capacity.
resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_version

  wait = true

  values = [yamlencode({
    nodeSelector = { "${local.label_prefix}/role" = "system" }
  })]

  depends_on = [google_container_node_pool.system]
}

# Prometheus. NOT optional: KEDA's prometheus scaler is how EPP demand signals
# reach the autoscaler, and the llm-d router chart emits a ServiceMonitor that
# needs the Prometheus Operator CRDs. Without this the ScaledObject's query
# returns nothing and the cluster never scales.
#
# Release name and namespace are pinned because the upstream keda-epp
# ScaledObject hardcodes this address:
#   llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc.cluster.local:9090
# Renaming either breaks that query silently.
#
# Grafana, Alertmanager and the control-plane scrape jobs are all disabled —
# this exists to feed KEDA, not to be an observability stack, and the full
# bundle will not fit alongside everything else on the small system pool.
resource "helm_release" "prometheus" {
  name             = "llmd"
  namespace        = "llm-d-monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_chart_version

  wait    = true
  timeout = 900

  values = [yamlencode({
    grafana      = { enabled = false }
    alertmanager = { enabled = false }

    kubeApiServer         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    kubeEtcd              = { enabled = false }
    nodeExporter          = { enabled = false }
    kubeStateMetrics      = { enabled = false }

    prometheusOperator = {
      nodeSelector = { "${local.label_prefix}/role" = "system" }
      resources    = { requests = { cpu = "100m", memory = "256Mi" } }
    }

    prometheus = {
      prometheusSpec = {
        nodeSelector = { "${local.label_prefix}/role" = "system" }
        retention    = "6h"
        # Scrape every ServiceMonitor in the cluster rather than only those
        # carrying this release's labels — the router chart's ServiceMonitor
        # does not know about this Helm release.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        # 15s so KEDA (pollingInterval 15) is not reacting to stale samples.
        scrapeInterval = "15s"
        resources = {
          requests = { cpu = "200m", memory = "1Gi" }
          limits   = { memory = "2Gi" }
        }
        # Ephemeral on purpose: 6h of lab metrics is not worth a persistent
        # disk that outlives the cluster.
      }
    }
  })]

  depends_on = [google_container_node_pool.system]
}
