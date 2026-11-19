.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:

PROJECT_ID  ?= gke-llm-lab-01
REGION      ?= us-central1
ZONE        ?= us-central1-b
CLUSTER     ?= llm-d-gke-lab
REPO        ?= didiberman/llm-d-gke-lab
TF          ?= terraform
# Set AUTO=-auto-approve to apply without the interactive prompt (bootstrap and
# break-glass only).
AUTO        ?=
BOOTSTRAP   := terraform/00-bootstrap
CLUSTER_DIR := terraform/10-cluster
CONFIG      := deploy/config.yaml
STATE_BUCKET = $(PROJECT_ID)-tfstate

# User credentials (gcloud ADC) bill API calls to a "quota project". A stale
# one in ~/.config/gcloud makes every call 400 with "User project specified in
# the request is invalid", so pin it to the lab project.
export GOOGLE_CLOUD_QUOTA_PROJECT := $(PROJECT_ID)
export CLOUDSDK_BILLING_QUOTA_PROJECT := $(PROJECT_ID)
GCLOUD := gcloud --project $(PROJECT_ID)

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nllm-d-gke-lab\n"} \
	/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Desired state (git) — every change here is a commit + push; CI and Argo CD do the rest

# Edit one key of deploy/config.yaml, commit it, push it.
define set_config
	@set -e; \
	git diff --quiet -- $(CONFIG) || { echo "$(CONFIG) has uncommitted changes — commit or revert them first."; exit 1; }; \
	sed -i.bak 's/^$(1): .*/$(1): $(2)/' $(CONFIG) && rm -f $(CONFIG).bak; \
	if git diff --quiet -- $(CONFIG); then echo "$(1) is already $(2)."; exit 0; fi; \
	git add $(CONFIG) && git commit -q -m "deploy: $(1) $(2)" && git push -q; \
	echo "Pushed $(1): $(2). Follow it with: make follow"
endef

.PHONY: tier
tier: ## Run a tier: make tier TIER=none|sim|small|gpu|kimi (commits deploy/config.yaml)
	@case "$(TIER)" in none|sim|small|gpu|kimi) ;; *) echo "TIER must be none|sim|small|gpu|kimi"; exit 1 ;; esac
	$(call set_config,tier,$(TIER))

.PHONY: cluster-on
cluster-on: ## Allow CI to create/keep the GKE cluster (~$0.09/hr idle from then on)
	$(call set_config,cluster,true)

.PHONY: cluster-off
cluster-off: ## Stop CI from (re)creating the cluster — then run `make destroy`
	$(call set_config,cluster,false)

.PHONY: follow
follow: ## Follow the latest deploy workflow run
	@gh run watch $$(gh run list --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

.PHONY: deploy
deploy: ## Re-run the deploy workflow (reconcile Terraform + verify Argo CD) and follow it
	@gh workflow run deploy.yml
	@sleep 5
	@$(MAKE) --no-print-directory follow

.PHONY: destroy
destroy: ## Run the destroy workflow: tear down ALL billable infra (asks you to confirm)
	@read -p "Destroy the cluster and everything on it? Type 'destroy': " c; \
	[ "$$c" = destroy ] || { echo "Aborted."; exit 1; }; \
	gh workflow run destroy.yml -f confirm=destroy
	@sleep 5
	@gh run watch $$(gh run list --workflow destroy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status

##@ Cluster access

.PHONY: kubeconfig
kubeconfig: ## Point local kubectl at the GKE cluster (needs gke-gcloud-auth-plugin)
	@$(GCLOUD) container clusters get-credentials $(CLUSTER) --zone $(ZONE) >/dev/null
	@kubectl config rename-context gke_$(PROJECT_ID)_$(ZONE)_$(CLUSTER) $(CLUSTER) >/dev/null 2>&1 || true
	@kubectl config use-context $(CLUSTER) >/dev/null
	@echo "kubectl context: $(CLUSTER) ($(PROJECT_ID), $(ZONE))"
	@kubectl get nodes

.PHONY: argocd-ui
argocd-ui: ## Open the Argo CD UI of the current kubectl context on http://localhost:8090
	@echo "user: admin   password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "http://localhost:8090  (Ctrl-C to stop)"
	@kubectl -n argocd port-forward svc/argocd-server 8090:80

.PHONY: apps
apps: ## Argo CD application status in the current kubectl context
	@kubectl -n argocd get applications.argoproj.io

.PHONY: watch
watch: ## Watch autoscaling and node provisioning live
	@watch -n 2 'kubectl -n llm-d get scaledobject,hpa,pods 2>/dev/null; echo; kubectl get computeclasses.cloud.google.com -l app.kubernetes.io/part-of=$(CLUSTER) 2>/dev/null; echo; kubectl get nodes -L cloud.google.com/compute-class,cloud.google.com/gke-spot,node.kubernetes.io/instance-type,cloud.google.com/gke-accelerator 2>/dev/null'

.PHONY: load
load: ## Fire k6 at the model endpoint (GKE load balancer, or BASE_URL=...) and watch replicas scale
	@tier=$$(awk '/^tier:/{print $$2}' $(CONFIG)); \
	[ "$$tier" = none ] && tier=sim; \
	model=$$(awk '/^model:/{print $$2}' gitops/tiers/$$tier.yaml); \
	url="$(BASE_URL)"; \
	if [ -z "$$url" ]; then \
	  ip=$$(kubectl -n llm-d get svc llm-d-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
	  if [ -n "$$ip" ]; then url="http://$$ip"; else url="http://localhost:18080"; fi; \
	fi; \
	echo "Load target: $$url  model: $$model"; \
	if command -v k6 >/dev/null; then \
	  BASE_URL="$$url" MODEL="$$model" k6 run loadgen/k6.js; \
	else \
	  echo "k6 not installed; running it in a container instead"; \
	  docker run --rm -i --network host -e BASE_URL="$$url" -e MODEL="$$model" grafana/k6 run - < loadgen/k6.js; \
	fi

##@ Local, free — the same GitOps stack on kind

.PHONY: argocd-local
argocd-local: ## kind + Argo CD syncing this repo's branch (TIER=sim default). $0
	@./local/argocd-up.sh

.PHONY: argocd-local-down
argocd-local-down: ## Delete the local kind cluster
	@./local/argocd-down.sh

##@ Cost & safety

.PHONY: prices
prices: ## Re-measure current Spot/on-demand prices for the machine shapes this project uses
	@./scripts/prices.sh $(REGION)

.PHONY: cost
cost: ## Where to see actual spend (GCP has no CLI for it; the budget emails at 50/90/100%)
	@echo "Billing reports for this project (grouped by SKU):"
	@echo "  https://console.cloud.google.com/billing/reports?project=$(PROJECT_ID)"
	@echo "Budget alerts are set by 00-bootstrap (budget_amount)."

.PHONY: quota
quota: ## GPU/vCPU quota the tiers need, and the state of the increase requests
	@echo "== quota preferences (requested vs granted)"
	@$(GCLOUD) beta quotas preferences list \
	  --format='table(name.basename():label=REQUEST,quotaId,dimensions,quotaConfig.preferredValue:label=ASKED,quotaConfig.grantedValue:label=GRANTED,reconciling)'
	@echo "== what the tiers need: sim 2 vCPU | small 1 L4 + 4 vCPU per replica | gpu 1 RTX PRO 6000 + 48 vCPU per replica | kimi 2 RTX PRO 6000 + 96 vCPU"
	@echo "== console: https://console.cloud.google.com/iam-admin/quotas?project=$(PROJECT_ID)"

.PHONY: whats-running
whats-running: ## Anything in the project currently costing money
	@echo "== GKE clusters";       $(GCLOUD) container clusters list --format='table(name,location,status,currentNodeCount)'
	@echo "== VMs";                $(GCLOUD) compute instances list --format='table(name,zone.basename(),machineType.basename(),scheduling.provisioningModel,status)'
	@echo "== load balancers";     $(GCLOUD) compute forwarding-rules list --format='table(name,region.basename(),IPAddress)'
	@echo "== disks";              $(GCLOUD) compute disks list --format='table(name,zone.basename(),sizeGb,users.len():label=ATTACHED)'
	@echo "== Cloud NAT routers (should be empty)"; $(GCLOUD) compute routers list --format='value(name)'

##@ Bootstrap & break-glass

.PHONY: bootstrap
bootstrap: ## Apply 00-bootstrap: project, state bucket, quota requests, WIF + deploy SA (the one layer applied locally)
	cd $(BOOTSTRAP) && $(TF) init -input=false && $(TF) apply -input=false $(AUTO)

.PHONY: github-setup
github-setup: ## Set the repo's Actions variable + secrets from the bootstrap outputs (ALLOWED_CIDRS=... HF_TOKEN=... optional)
	@set -euo pipefail
	cd $(BOOTSTRAP)
	wip=$$($(TF) output -raw workload_identity_provider)
	sa=$$($(TF) output -raw deploy_service_account)
	[ -n "$$wip" ] && [ "$$wip" != null ] || { echo "No WIF provider yet — set github_repo in terraform.tfvars and run make bootstrap"; exit 1; }
	gh variable set GCP_PROJECT_ID --repo $(REPO) --body "$(PROJECT_ID)"
	gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --repo $(REPO) --body "$$wip"
	gh secret set GCP_DEPLOY_SERVICE_ACCOUNT --repo $(REPO) --body "$$sa"
	cidrs="$(ALLOWED_CIDRS)"; [ -n "$$cidrs" ] || cidrs="[\"$$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32\"]"
	gh secret set ALLOWED_CIDRS --repo $(REPO) --body "$$cidrs"
	[ -z "$(HF_TOKEN)" ] || gh secret set HF_TOKEN --repo $(REPO) --body "$(HF_TOKEN)"
	echo "Set on $(REPO): GCP_PROJECT_ID, GCP_WORKLOAD_IDENTITY_PROVIDER, GCP_DEPLOY_SERVICE_ACCOUNT, ALLOWED_CIDRS=$$cidrs"

.PHONY: cluster-plan
cluster-plan: ## Read-only: plan 10-cluster from your machine (no state lock)
	cd $(CLUSTER_DIR) && $(TF) init -input=false -reconfigure -backend-config="bucket=$(STATE_BUCKET)" && \
	  TF_VAR_allowed_cidrs='$(or $(ALLOWED_CIDRS),["203.0.113.7/32"])' \
	  $(TF) plan -input=false -lock=false -var project_id=$(PROJECT_ID) -var zone=$(ZONE) -var region=$(REGION)

.PHONY: cluster-apply-local
cluster-apply-local: ## BREAK-GLASS: apply 10-cluster locally (requires ALLOW_LOCAL=1 and ALLOWED_CIDRS)
	@[ -n "$(ALLOW_LOCAL)" ] || { echo "Deploys run in CI (make cluster-on / make deploy). Break-glass: ALLOW_LOCAL=1 ALLOWED_CIDRS='[\"x.x.x.x/32\"]' make $@"; exit 1; }
	@[ -n "$(ALLOWED_CIDRS)" ] || { echo "ALLOWED_CIDRS is required, e.g. ALLOWED_CIDRS='[\"1.2.3.4/32\"]'"; exit 1; }
	cd $(CLUSTER_DIR) && $(TF) init -input=false -reconfigure -backend-config="bucket=$(STATE_BUCKET)" && \
	  TF_VAR_allowed_cidrs='$(ALLOWED_CIDRS)' \
	  $(TF) apply -input=false $(AUTO) -var project_id=$(PROJECT_ID) -var zone=$(ZONE) -var region=$(REGION)

##@ Checks

.PHONY: render fmt validate lint
render: ## Render + schema-validate every GitOps chart, tier and environment (no cluster)
	@./scripts/render-check.sh

fmt: ## terraform fmt across all layers
	$(TF) fmt -recursive terraform/

validate: ## terraform validate across all layers, then `make render`
	@for d in $(BOOTSTRAP) $(CLUSTER_DIR); do \
	  echo "== $$d"; \
	  (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done
	@$(MAKE) --no-print-directory render

lint: ## Lint Terraform with tflint if installed
	@command -v tflint >/dev/null && tflint --recursive terraform/ || echo "tflint not installed, skipping"
