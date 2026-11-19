#!/usr/bin/env bash
# Re-measure list prices for the machine shapes this project uses, from the
# Cloud Billing Catalog API (Compute Engine SKUs, USD).
#
# Every cost figure in README.md and docs/COSTS.md came from this script. GCP
# Spot prices change up to once a month; re-run it rather than trusting the
# committed numbers.
#
#   prices.sh [region]                    needs `gcloud auth login`
#   SKUS_FILE=skus.jsonl prices.sh        reuse a previous download (one SKU per line)
#
# A GCE machine is billed as parts: vCPU-hours + GB-RAM-hours + GPU-hours, each
# its own SKU. This script sums them per shape.
set -euo pipefail

REGION="${1:-us-central1}"
SERVICE=6F81-5844-456A # Compute Engine

need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
need jq; need curl

if [ -n "${SKUS_FILE:-}" ]; then
  skus=$SKUS_FILE
else
  need gcloud
  skus=$(mktemp); trap 'rm -f "$skus"' EXIT
  token=$(gcloud auth print-access-token)
  page=""
  while :; do
    r=$(curl -sf -H "Authorization: Bearer $token" \
      "https://cloudbilling.googleapis.com/v1/services/${SERVICE}/skus?pageSize=5000&currencyCode=USD&pageToken=${page}")
    echo "$r" | jq -c '.skus[]?' >>"$skus"
    page=$(echo "$r" | jq -r '.nextPageToken // empty')
    [ -z "$page" ] && break
  done
fi

# $/unit-hour of the first SKU in $REGION whose description matches the regex.
rate() {
  jq -rs --arg re "$1" --arg region "$REGION" '
    [ .[] | select((.serviceRegions | index($region)) and (.description | test($re)))
      | .pricingInfo[0].pricingExpression.tieredRates[-1].unitPrice
      | (.units | tonumber) + .nanos / 1e9 ] | first // empty' "$skus"
}

# Regex fragments the SKU descriptions use. (case, not associative arrays:
# macOS ships bash 3.2.)
family_re() { case $1 in e2) echo 'E2 Instance' ;; g2) echo 'G2 Instance' ;; g4) echo 'G4 Instance' ;; esac; }
gpu_re() { case $1 in nvidia-l4) echo 'Nvidia L4 GPU' ;; nvidia-rtx-pro-6000) echo 'RTX 6000 96GB' ;; esac; }

# shape  family vCPU RAM-GB gpu-type gpu-count  role
SHAPES=(
  "e2-standard-2   e2 2  8   -                   0  sim tier node"
  "e2-standard-4   e2 4  16  -                   0  system pool node (always on)"
  "g2-standard-4   g2 4  16  nvidia-l4           1  small tier: 1x L4 24GB"
  "g4-standard-48  g4 48 180 nvidia-rtx-pro-6000 1  gpu tier: 1x RTX PRO 6000 96GB"
  "g4-standard-96  g4 96 360 nvidia-rtx-pro-6000 2  kimi tier: 2x RTX PRO 6000"
)

printf '%-16s %10s %12s   %s\n' "SHAPE ($REGION)" "SPOT/hr" "ON-DEMAND/hr" "USE"
printf '%-16s %10s %12s   %s\n' "----------------" "----------" "------------" "---"
for line in "${SHAPES[@]}"; do
  read -r shape fam vcpu ram gpu ngpu use <<<"$line"
  fre=$(family_re "$fam")
  total() { # prefix-regex for spot or on-demand
    local p=$1 c r g=0
    c=$(rate "^${p}${fre} Core running in") || true
    r=$(rate "^${p}${fre} Ram running in") || true
    [ -n "$c" ] && [ -n "$r" ] || { echo "n/a"; return; }
    if [ "$ngpu" -gt 0 ]; then
      if [ -n "$p" ]; then
        g=$(rate "^$(gpu_re "$gpu") attached to Spot Preemptible VMs running in") || true
      else
        g=$(rate "^$(gpu_re "$gpu") running in") || true
      fi
      [ -n "$g" ] || { echo "n/a"; return; }
    fi
    awk -v c="$c" -v r="$r" -v g="$g" -v v="$vcpu" -v m="$ram" -v n="$ngpu" \
      'BEGIN { printf "$%.3f", c*v + r*m + g*n }'
  }
  printf '%-16s %10s %12s   %s\n' "$shape" "$(total 'Spot Preemptible ')" "$(total '')" "$use"
done

echo
echo "Plus: GKE management fee \$0.10/hr per cluster, credited for one zonal cluster"
echo "per billing account (this lab's), so \$0. The first five forwarding rules"
echo "(load balancers) cost \$0.025/hr together; tiers other than none run two."
echo "No Cloud NAT. Boot disks bill separately: pd-balanced \$0.10, Hyperdisk"
echo "Balanced \$0.08 per GB-month. Spot node external IPs \$0.0025/hr."
