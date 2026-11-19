#!/usr/bin/env bash
# Render every GitOps chart for every tier and environment, then validate the
# output against Kubernetes + CRD schemas when kubeconform is available.
# Runs in CI (validate workflow) and locally (`make render`). No cluster needed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
fail=0

ms() { # env tier
  local extra=()
  if [ "$1" = gke ]; then
    extra=(--set-json 'allowedCidrs=["203.0.113.7/32"]')
  fi
  helm template llm-d-model gitops/apps/model-server -f "gitops/tiers/$2.yaml" \
    --set environment="$1" ${extra[@]+"${extra[@]}"}
}

echo "== model-server chart"
for env in gke kind; do
  for t in sim small gpu kimi; do
    if ms "$env" "$t" > "$OUT/model-$env-$t.yaml" 2>"$OUT/err"; then
      printf '  ok    %-5s %-6s %s\n' "$env" "$t" "$(grep -E '^kind:' "$OUT/model-$env-$t.yaml" | awk '{print $2}' | sort | tr '\n' ' ')"
    else
      printf '  FAIL  %-5s %-6s %s\n' "$env" "$t" "$(cat "$OUT/err")"; fail=1
    fi
  done
done

echo "== root chart (app of apps)"
for env in gke kind; do
  for t in none sim small gpu kimi; do
    if helm template root gitops/root -f deploy/config.yaml --set tier="$t" --set environment="$env" \
        > "$OUT/root-$env-$t.yaml" 2>"$OUT/err"; then
      apps=$(grep -A1 '^metadata:' "$OUT/root-$env-$t.yaml" | awk '/name:/{print $2}' | tr '\n' ' ' || true)
      printf '  ok    %-5s %-6s %s\n' "$env" "$t" "${apps:-(no apps)}"
    else
      printf '  FAIL  %-5s %-6s %s\n' "$env" "$t" "$(cat "$OUT/err")"; fail=1
    fi
  done
done

echo "== guardrails must refuse bad input"
expect_fail() { # description, command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  FAIL  accepted: $d"; fail=1; else echo "  ok    refused: $d"; fi
}
expect_fail "unknown tier" helm template r gitops/root --set tier=bogus
expect_fail "unknown environment" helm template r gitops/root --set environment=eks
expect_fail "GKE endpoints with no allowedCidrs" \
  helm template m gitops/apps/model-server -f gitops/tiers/sim.yaml
expect_fail "GKE tier with no machine shapes" \
  helm template m gitops/apps/model-server -f gitops/tiers/sim.yaml \
    --set-json 'allowedCidrs=["1.2.3.4/32"]' --set-json 'capacity.priorities=[]'

echo "== deploy/config.yaml"
tier=$(awk '/^tier:/{print $2}' deploy/config.yaml)
cluster=$(awk '/^cluster:/{print $2}' deploy/config.yaml)
case "$tier" in none|sim|small|gpu|kimi) echo "  ok    tier=$tier" ;; *) echo "  FAIL  tier=$tier"; fail=1 ;; esac
case "$cluster" in true|false) echo "  ok    cluster=$cluster" ;; *) echo "  FAIL  cluster=$cluster"; fail=1 ;; esac

if command -v kubeconform >/dev/null; then
  echo "== kubeconform (Kubernetes + CRD schemas)"
  # ComputeClass, KEDA and Argo CD schemas come from the community CRD catalog.
  if kubeconform -strict -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$OUT"/*.yaml; then :; else fail=1; fi
else
  echo "== kubeconform not installed — schema validation skipped"
fi

exit $fail
