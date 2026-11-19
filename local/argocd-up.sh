#!/usr/bin/env bash
# Free, local proof of the GitOps design (`make argocd-local`).
#
# Builds a kind cluster with the same platform Terraform installs on GKE
# (Gateway API + Inference Extension CRDs, KEDA, Prometheus, Argo CD from the
# same values file), then hands over to Argo CD exactly as CI does: one root
# Application pointing at this GitHub repo. Everything after that — router,
# simulator model server, ScaledObject, Open WebUI — is pulled and reconciled
# by Argo CD from git.
#
# Argo CD reads GitHub, not your working tree: push the branch first.
#
#   TIER=sim                    tier to run locally (overrides deploy/config.yaml)
#   GITOPS_REVISION=<branch>    git revision Argo CD tracks (default: current branch)
#
# Cost: $0. What kind cannot exercise: GKE node auto-provisioning (ComputeClass),
# cloud load balancers, real GPUs.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=llm-d-argocd
TIER=${TIER:-sim}
REPO_URL=${REPO_URL:-https://github.com/didiberman/llm-d-gke-lab.git}
REVISION=${GITOPS_REVISION:-$(git rev-parse --abbrev-ref HEAD)}

# Keep aligned with terraform/10-cluster/variables.tf.
GATEWAY_API_VERSION=v1.6.2
GAIE_VERSION=v1.6.2
KEDA_VERSION=2.21.0
PROM_VERSION=92.16.0
ARGOCD_VERSION=10.18.0

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
need kind; need kubectl; need helm; need docker

step "Checking that Argo CD will see what you expect (it reads GitHub, not this directory)"
git fetch -q origin "$REVISION" 2>/dev/null || { echo "Branch '$REVISION' is not on origin — push it first." >&2; exit 1; }
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$REVISION")" ]; then
  echo "    WARNING: local HEAD differs from origin/$REVISION — Argo CD will deploy origin/$REVISION."
fi
echo "    repo $REPO_URL @ $REVISION, tier $TIER"

step "Creating kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    already exists, reusing"
else
  kind create cluster --config local/kind-argocd.yaml --wait 180s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

if [ "${PREPULL:-1}" = 1 ]; then
  step "Pre-pulling images on the host and loading them into kind (PREPULL=0 to skip)"
  ./local/kind-prepull.sh "$CLUSTER"
fi

step "Gateway API ($GATEWAY_API_VERSION) and Inference Extension ($GAIE_VERSION) CRDs"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" >/dev/null

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update kedacore prometheus-community argo >/dev/null

step "KEDA ($KEDA_VERSION)"
helm upgrade --install keda kedacore/keda -n keda --create-namespace --version "$KEDA_VERSION" \
  --set nodeSelector."llm-d-gke-lab/role"=system --wait --timeout 15m >/dev/null

# Release name and namespace are what the ScaledObject queries:
#   llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc:9090
step "Prometheus ($PROM_VERSION) — feeds EPP metrics to KEDA"
helm upgrade --install llmd prometheus-community/kube-prometheus-stack -n llm-d-monitoring --create-namespace \
  --version "$PROM_VERSION" \
  --set grafana.enabled=false --set alertmanager.enabled=false \
  --set nodeExporter.enabled=false --set kubeStateMetrics.enabled=false \
  --set kubeApiServer.enabled=false --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false --set kubeProxy.enabled=false --set kubeEtcd.enabled=false \
  --set prometheusOperator.nodeSelector."llm-d-gke-lab/role"=system \
  --set prometheus.prometheusSpec.nodeSelector."llm-d-gke-lab/role"=system \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  --set prometheus.prometheusSpec.retention=2h \
  --wait --timeout 15m >/dev/null

step "Argo CD ($ARGOCD_VERSION) — same values file Terraform uses on GKE"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_VERSION" \
  -f gitops/bootstrap/argocd-values.yaml --wait --timeout 15m >/dev/null

step "Namespace and HF token secret (Terraform's job on GKE — secrets never live in git)"
kubectl create namespace llm-d --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n llm-d create secret generic llm-d-hf-token --from-literal="HF_TOKEN=${HF_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Root Application — from here on, Argo CD drives everything from git"
# Same shape Terraform creates on GKE (terraform/10-cluster/argocd.tf); only the
# valuesObject differs: environment=kind and a local tier override.
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: gitops/root
    helm:
      valueFiles:
        - ../../deploy/config.yaml
      valuesObject:
        repoURL: ${REPO_URL}
        targetRevision: ${REVISION}
        environment: kind
        tier: ${TIER}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      # Required for tier none: it renders no child apps, and Argo CD refuses to
      # auto-sync a result that would prune every resource without this.
      allowEmpty: true
EOF

step "Waiting for Argo CD to sync and every app to report Healthy"
./scripts/wait-for-apps.sh 900

if [ "$TIER" != none ]; then
  step "Smoke test through the router (localhost:18080)"
  model=$(awk '/^model:/{print $2}' "gitops/tiers/${TIER}.yaml")
  for i in $(seq 1 30); do curl -sf -o /dev/null http://localhost:18080/v1/models && break; sleep 2; done
  curl -s http://localhost:18080/v1/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"prompt\":\"Hello\",\"max_tokens\":12}" | jq -c '{model, text: .choices[0].text}'
fi

cat <<EOF

$(printf '\033[1;32mGitOps stack is up on kind — cost: $0.00\033[0m')

  Model API:   http://localhost:18080/v1/models
  Open WebUI:  http://localhost:18081
  Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8090:80   -> http://localhost:8090
               user admin, password:
               kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

  Try GitOps:  change gitops/ on '${REVISION}', push, and watch Argo CD reconcile.
  Tear down:   make argocd-local-down
EOF
