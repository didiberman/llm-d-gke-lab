#!/usr/bin/env bash
# Delete load balancer pieces GKE created for LoadBalancer Services and left
# behind because the cluster went before the Services did. They are not in
# Terraform state, and their firewall rules pin the VPC: `terraform destroy`
# of the network fails until they are gone.
#
#   sweep-k8s-lb.sh <project> <region> <network>
#
# Only touches resources GKE marks as its own (description naming a
# kubernetes.io/service-name, or the k8s-/k8s2-/gke-<network> name prefixes
# on firewall rules in the lab's network). Safe to run when there is nothing
# to sweep. Used by the destroy workflow.
set -uo pipefail
PROJECT=${1:?project}
REGION=${2:?region}
NETWORK=${3:?network}

g() { gcloud --project "$PROJECT" --quiet "$@"; }
del() { # kind, list-filter, extra delete flags...
  local kind=$1 filter=$2; shift 2
  for name in $(g compute "$kind" list --filter="$filter" --format='value(name)' 2>/dev/null); do
    echo "Deleting $kind $name"
    g compute "$kind" delete "$name" "$@" >/dev/null || echo "::warning::could not delete $kind $name"
  done
}

k8s='description~kubernetes.io/service-name'
del forwarding-rules "$k8s" --region "$REGION"
del target-pools "$k8s" --region "$REGION"
del backend-services "$k8s" --region "$REGION"
del health-checks "name~^k8s"
del http-health-checks "name~^k8s"
del firewall-rules "network~/${NETWORK}\$ AND (name~^k8s OR name~^gke-${NETWORK})"
echo "Sweep done."
