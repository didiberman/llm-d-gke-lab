# GitOps hand-off: Terraform installs Argo CD and exactly one Application —
# the root of an app-of-apps in gitops/root. From then on the inference layer
# (llm-d router, model server, NodePool, ScaledObject, Open WebUI, NVIDIA
# device plugin) is reconciled by Argo CD from git, and `deploy/config.yaml`
# is the switch.
#
# The boundary: anything that needs GCP identities or values that must not be
# committed stays here. The root Application's valuesObject is how those
# values reach the charts:
#   - project        the cluster name, also the charts' label prefix
#   - allowedCidrs   the operator IP allowlist (a GitHub secret)
# and the HF token becomes a Kubernetes Secret below, never a git file.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  wait    = true
  timeout = 900

  # Same file local/argocd-up.sh installs on kind.
  values = [file("${path.module}/../../gitops/bootstrap/argocd-values.yaml")]

  depends_on = [google_container_node_pool.system]
}

resource "kubernetes_namespace" "llm_d" {
  metadata {
    name = "llm-d"
    labels = {
      "${local.label_prefix}/managed" = "true"
    }
  }

  depends_on = [google_container_node_pool.system]
}

# The model server mounts HF_TOKEN unconditionally; an empty value is fine for
# ungated models.
resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "llm-d-hf-token"
    namespace = kubernetes_namespace.llm_d.metadata[0].name
  }

  data = {
    HF_TOKEN = var.hf_token
  }

  type = "Opaque"
}

# The root Application, through Argo's own argocd-apps chart rather than a raw
# manifest: the helm provider plans happily before the cluster exists, while
# raw-manifest providers fail to configure against an unknown endpoint.
resource "helm_release" "root_app" {
  name       = "root-app"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        # Deleting the root app cascades through every child app and what
        # they deployed — the destroy workflow relies on this to remove the
        # load balancers and GPU ComputeClasses before the cluster goes.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "gitops/root"
          helm = {
            # The tier comes from git; everything below comes from Terraform.
            valueFiles = ["../../deploy/config.yaml"]
            valuesObject = {
              repoURL        = var.gitops_repo_url
              targetRevision = var.gitops_revision
              environment    = "gke"
              project        = var.name
              allowedCidrs   = var.allowed_cidrs
            }
          }
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
            # REQUIRED for `tier: none`. That tier renders no child apps, and
            # Argo CD refuses to auto-sync a result that would prune every
            # resource ("auto-sync will wipe out all resources") unless this
            # is set. Without it the GPUs would never be switched off.
            allowEmpty = true
          }
        }
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.keda,
    helm_release.prometheus,
    null_resource.gaie_crds,
    kubernetes_secret.hf_token,
  ]
}
