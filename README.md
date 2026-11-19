# llm-d on GKE — autoscaled LLM inference you can afford to practice on

[![llm-d: Serving LLMs on Kubernetes](docs/llm-d-architecture-cover.webp)](https://didibe.dev/blog/llm-d-serving-llms-on-kubernetes)

**Read the article:** [llm-d in Plain English: Serving LLMs on Kubernetes](https://didibe.dev/blog/llm-d-serving-llms-on-kubernetes) - the plain-English story behind this repo and its AWS twin, [llm-d-eks-lab](https://github.com/didiberman/llm-d-eks-lab).

A learning lab: [llm-d](https://llm-d.ai) **v1.0.0** serving open-weights models
on Google Kubernetes Engine, autoscaled on **inference queue depth** (not CPU),
with Spot GPU nodes that appear when needed and disappear when idle.
**Terraform + GitHub Actions** build the infrastructure; **Argo CD** runs
everything on the cluster from git. A `git push` is the only deploy button.

It is not "production grade." It is a practice environment where a 27B model on
a 96 GB RTX PRO 6000 costs about **$1.86/hour** while you use it, a 72B model on
two of them about **$3.60/hour**, and **nothing** once you switch it off.

```
 git push ─┬─▶ GitHub Actions (OIDC → Workload Identity) ─▶ Terraform ─▶ VPC, GKE + node
           │                                                            auto-provisioning,
           │                                                            KEDA, Prometheus, Argo CD
           │
           └─▶ Argo CD (pulls from git) ───────────────────────────────▶ llm-d router + endpoint picker
                                                                         vLLM model server (KEDA-scaled)
                                                                         ComputeClass (Spot GPU nodes on demand)
                                                                         Open WebUI
```

> **New to LLM serving or Kubernetes?** Start with
> [Serving LLMs on Kubernetes, in plain English](#serving-llms-on-kubernetes-in-plain-english).
> Already know the pieces? Jump to [Quick start](#quick-start).

---

## Contents

- [Quick start](#quick-start)
- [Tiers](#tiers)
- [How deploys work](#how-deploys-work)
- [Using the model](#using-the-model)
- [Costs](#costs)
- [Guardrails](#guardrails)
- [Serving LLMs on Kubernetes, in plain English](#serving-llms-on-kubernetes-in-plain-english)
- [Architecture](#architecture)
- [From EKS to GKE](#from-eks-to-gke)
- [Setting it up in your own project](#setting-it-up-in-your-own-project)
- [Layout](#layout)
- [Commands](#commands)
- [Honest caveats](#honest-caveats)
- [Status](#status)

---

## Quick start

Everything is driven by one file, [`deploy/config.yaml`](deploy/config.yaml):

```yaml
cluster: false   # may CI create the GKE cluster?
tier: none       # none | sim | small | gpu | kimi — what Argo CD runs on it
```

Change it, push it, and CI + Argo CD converge on it. The Makefile wraps the
edit-commit-push:

```bash
make cluster-on            # cluster: true  -> CI builds GKE + Argo CD (~15 min, ~$0.09/hr)
make tier TIER=sim         # tier: sim      -> prove the whole path on a $0.04/hr CPU node
make tier TIER=gpu         # tier: gpu      -> Qwen3.6-27B on an RTX PRO 6000 (needs GPU quota)
make follow                # watch CI wait for Argo CD and smoke-test the model
make kubeconfig            # kubectl access; `make argocd-ui` for the Argo CD UI

make tier TIER=none        # GPUs gone, cluster stays (~$0.09/hr)
make cluster-off && make destroy   # everything billable gone (~$0)
```

> **Nothing switches it off for you.** A tier keeps its GPU node(s) running
> until you set `tier: none` or run `make destroy` — `gpu` at two replicas left
> on is ~$85/day. See [Guardrails](#guardrails).

**Try it for free first.** `make argocd-local` builds the same stack on a local
kind cluster — the same Argo CD install and root app, syncing this repo from
GitHub — against a vLLM simulator. **$0.00.**

---

## Tiers

Every tier is the same Helm chart (`gitops/apps/model-server`) with a different
values file in [`gitops/tiers/`](gitops/tiers). Which one runs is the `tier` key
in [`deploy/config.yaml`](deploy/config.yaml). All capacity is **Spot**.

| Tier | Model | Machine | GPU quota | Replicas | ~$/hr while up* |
|------|-------|---------|-----------|----------|------------------|
| `sim` | [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) (fake vLLM) | `e2-standard-2` | none | 1–4 | 0.16 |
| `small` | `Qwen/Qwen3.5-4B` | `g2-standard-4` — 1× L4, 24 GB | 1 L4 / replica | 1–2 | 0.56–1.00 |
| **`gpu`** ⭐ | **`Qwen/Qwen3.6-27B-FP8`** | **`g4-standard-48` — 1× RTX PRO 6000, 96 GB** | **1 RTX PRO 6000 / replica** | **1–2** | **1.86–3.60** |
| `kimi` | `moonshotai/Kimi-Dev-72B` | `g4-standard-96` — 2× RTX PRO 6000, 192 GB | 2 RTX PRO 6000 | 1 | 3.60 |
| `none` | — | — | — | 0 | 0.09 (cluster only) |

\* Including the ~$0.09/hr system node, the two load balancers a running tier
adds (~$0.025/hr together), boot disks and node IPs. us-central1 list prices, measured with `make prices`;
GCP Spot prices change at most monthly.

**Why these shapes.** The lab is sized around **two Spot `g4-standard-48`
nodes** — one RTX PRO 6000 Blackwell (96 GB) each — so the `gpu` tier can show
real 1→2 scale-out for about $3.60/hr at peak. 96 GB holds a 27B FP8 model with
~60 GB to spare for KV cache, so one card serves long contexts and real
concurrency. `kimi` puts both cards in one `g4-standard-96` for a BF16 72B
model. `small` is the cheap path on an L4, which many projects get quota for
first.

**About Kimi-Dev-72B:** a 72.7B coding model (Qwen2.5-72B base, MIT licence,
ungated). BF16 only — 145 GB of weights, ~135 GiB in VRAM — so it runs
**tensor-parallel across two 96 GB GPUs**, leaving ~34 GiB of KV cache
(~110k tokens). It reasons in a `◁think▷` block before answering, so give it a
generous `max_tokens`. The same model on the same GPU pair was measured on AWS
(g7e.12xlarge) at a ~12–15 minute cold start and ~18 tokens/s single-stream.

---

## How deploys work

Two reconcilers, each owning what it is good at:

```
push to main
   │
   ├─ terraform/10-cluster/** or deploy/config.yaml changed
   │     └─ CI: terraform plan → apply only if non-empty        (never while cluster: false)
   │        VPC, GKE, node auto-provisioning limits, KEDA, Prometheus, Argo CD + root Application
   │
   └─ gitops/** or deploy/** changed
         └─ Argo CD notices the commit and syncs the cluster to it
            CI (verify job) requests a refresh, waits until every app is
            Synced + Healthy, then smoke-tests a completion through the router
```

- **No pointless applies.** Terraform runs only for infra changes and applies
  only non-empty plans. Docs and README pushes trigger nothing.
- **No accidental spend.** While `cluster: false`, CI creates nothing.
- **Drift is impossible to keep.** Argo CD self-heals: a `kubectl edit` on the
  cluster is reverted to what git says.
- **One at a time.** Deploy and destroy share a concurrency group.
- **No keys.** GitHub Actions exchanges its OIDC token for a short-lived
  token of a deploy service account through **Workload Identity Federation**.
  The provider admits only this repository on `main`, so a pull request can
  neither deploy nor read state. Argo CD pulls the public repo with no
  credentials at all.
- **Least privilege.** The deploy service account can run GKE and the network
  (`container.admin`, `compute.networkAdmin`, `compute.securityAdmin`, read-only
  `compute.viewer`) and use one node service account. It cannot grant IAM,
  create service accounts or touch billing, so a compromised workflow cannot
  escalate to project owner.

Terraform and Argo CD split along one line: anything that needs GCP identities
or values that must not be in git (the IP allowlist, the HuggingFace token)
stays in Terraform, which hands them to Argo CD as the root Application's
`valuesObject` and a Kubernetes Secret. Everything else is plain Kubernetes in
git, where self-heal, pruning and the Argo CD UI earn their keep.

`make cluster-apply-local` is the only local apply of the cluster layer and
requires `ALLOW_LOCAL=1` (break-glass). `00-bootstrap` is applied by hand
because it creates the identity CI uses.

---

## Using the model

**Open WebUI** — a ChatGPT-style interface on its own load balancer. Its IP is
in the deploy run's summary, or:

```bash
kubectl -n llm-d get svc open-webui-public
```

No login: it is reachable only from the IPs in `ALLOWED_CIDRS`. Chats are not
persisted (no volume), so a pod restart or `tier: none` wipes them.

**OpenAI-compatible API** — the router's public endpoint, same IP allowlist:

```bash
EP=$(kubectl -n llm-d get svc llm-d-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://$EP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen3.6-27B-FP8",
  "messages": [{"role": "user", "content": "Write a palindrome checker in Python."}],
  "max_tokens": 800
}' | jq -r '.choices[0].message.content'
```

Tool calling (`tool_choice: "auto"`) is enabled on the Kimi tier with vLLM's
`hermes` parser — Open WebUI and most agent frameworks need it.

**Argo CD UI** — sync state and health of every resource:

```bash
make argocd-ui        # prints the admin password, serves http://localhost:8090
make apps             # same, in the terminal
```

**On the free kind stack** the router is at `http://localhost:18080` and Open
WebUI at `http://localhost:18081`.

**Logs and live state:**

```bash
kubectl -n llm-d logs -f deploy/llm-d-vllm-decode     # vLLM: download, load, requests
kubectl -n llm-d logs -f deploy/llm-d-epp -c epp      # router: which backend got each request
kubectl get events -A --field-selector reason=TriggeredScaleUp   # GKE adding a node
make watch                                            # pods, HPA, ComputeClasses, nodes
```

---

## Costs

us-central1 list prices (USD), November 2026, from the Cloud Billing catalog
(`make prices`). Full analysis, including alternatives such as Cloud Run GPUs
and Vertex AI, in [`docs/COSTS.md`](docs/COSTS.md).

**Whenever the cluster exists — ~$0.09/hr (~$2.20/day):**

| Item | $/hr |
|------|------|
| GKE management fee | 0.10, **credited** — the free tier covers one zonal cluster per billing account |
| 1× `e2-standard-4` Spot system node | ~0.080 |
| System node disk (50 GB pd-balanced) | ~0.007 |
| System node external IP (Spot rate) | ~0.003 |

**Added while a tier runs:**

| Tier | Per node (machine + boot disk + IP) | Load balancers | Total added |
|------|-------|----------------|-------------|
| `sim` | 0.040 + 0.006 + 0.003 | ~0.025 | ~0.07 |
| `small` | 0.423 + 0.014 + 0.003, per replica | ~0.025 | ~0.47–0.91 |
| `gpu` | 1.718 + 0.022 (200 GB Hyperdisk) + 0.003, per replica | ~0.025 | ~1.77–3.51 |
| `kimi` | 3.436 + 0.044 (400 GB Hyperdisk) + 0.003 | ~0.025 | ~3.51 |

Load balancers: the first five forwarding rules in a region cost $0.025/hr
together; a running tier uses two.

| Scenario | Cost |
|----------|------|
| 2-hour `gpu` session, one replica | ~$3.70 |
| 2-hour `kimi` session | ~$7.20 |
| Cluster idling, no GPU | ~$2.20/day |
| `make destroy` | ~$0 (empty project + a few KB of state) |

**Where money leaks, and what this repo does about it:**

| Leak | Naive cost | Here |
|------|-----------|------|
| Cloud NAT | per-VM-hour + $0.045/GB processed — a 145 GB model is ~$6.50 per cold start | **none** — nodes egress directly; GCP ingress is free |
| Regional control plane | $0.10/hr | **zonal**, inside the free tier |
| Forgotten GPU node | ~$42–84/day | `tier: none`, budget email, nothing automatic |
| On-demand fallback when Spot is out | 2.6× the Spot price | ComputeClass `whenUnsatisfiable: DoNotScaleUp` waits instead |
| Managed Prometheus / workload logs | per sample / per GB | off; in-cluster Prometheus, system logs only |

---

## Guardrails

> [!WARNING]
> There is **no scheduled shutdown**. Every tier keeps at least one model
> replica (`minReplicas: 1`), so its GPU node runs until you turn it off. End
> every session with `make tier TIER=none` (or `make destroy`).

- **`tier: none`** — Argo CD prunes the inference layer, including the tier's
  ComputeClass; GKE drains and deletes the nodes two minutes after they empty.
  The cluster stays (~$0.09/hr). CI's verify job fails if a lab ComputeClass
  remains.
- **A hard ceiling in Terraform.** Node auto-provisioning `resource_limits`
  cap the whole cluster at 120 vCPU, 420 GB and **2 RTX PRO 6000 + 2 L4**. No
  tier, autoscaler or bug can launch more; a GPU type not listed can never be
  launched at all.
- **Spot only, no silent upgrade to on-demand.** Each ComputeClass lists Spot
  shapes only and waits when none is available.
- **Destroy on demand** (`.github/workflows/destroy.yml`, `make destroy`) —
  deletes the root Argo CD app (cascading to ComputeClasses and load
  balancers), waits for GKE to remove the forwarding rules, destroys the
  cluster and VPC, sweeps any leaked `k8s-*` firewall rules, and fails if any
  cluster, VM, disk, forwarding rule, reserved IP or lab VPC remains. Run
  `make cluster-off` first so the next push can't rebuild it.
- **`cluster: false` gate** — CI never creates the cluster unless git says so.
- **Budget** — `00-bootstrap` sets a monthly budget on the project with emails
  at 50% and 90% actual and 100% forecast. It reports; it does not stop
  anything.
- **The project is the blast radius.** Everything lives in one dedicated
  project; `make whats-running` lists anything billable in it.
- **IP allowlist** on both public endpoints (`ALLOWED_CIDRS`); the chart refuses
  to render internet-facing Services on GKE if the list is empty.

---

## Serving LLMs on Kubernetes, in plain English

*Also published as [an article](https://didibe.dev/blog/llm-d-serving-llms-on-kubernetes).*

### Why an LLM is not a web app

Three things break the usual Kubernetes playbook:

1. **The model has to fit in GPU memory.** Weights live in VRAM, not RAM. Rule of thumb: about 1 byte per parameter at FP8, 2 at BF16. A 72B model in BF16 is roughly 145 GB. No single GPU here holds that, so it gets split across two.
2. **GPU utilization lies.** A GPU doing inference reads about 100% busy whether it is keeping up or hopelessly behind. CPU-style autoscaling cannot tell the difference.
3. **Requests have memory.** While generating, the model keeps notes on the conversation in VRAM. That is the **KV cache**. Send the next message to a different pod and the notes are gone - it has to re-read the whole conversation.

Everything below is a consequence of those three.

### Who decides what

Think of a busy restaurant. Customers queue at the door. A **host** decides which table each one gets. A **manager** decides how many waiters are on shift. A **staffing agency** decides how many kitchens to rent.

| Piece | In the restaurant | What it decides |
|---|---|---|
| **llm-d router** (EPP) | host | which pod gets this request |
| **KEDA** | manager | how many pods |
| **GKE node auto-provisioning** (ComputeClass) | staffing agency | how many GPU nodes |
| **vLLM** | the kitchen | actually runs the model |

Three of those sound alike. They are not. Mixing them up is the most common confusion.

### What llm-d adds

A plain Kubernetes Service round-robins. For LLMs that wastes exactly what you paid for.

llm-d puts a router in front: Envoy plus an **endpoint picker (EPP)**. For every request it scores every pod:

- **queue length** - how busy is it right now
- **KV-cache use** - how full is its memory
- **prefix-cache hit** - does it already hold this conversation's notes

The same conversation lands on the pod that already has it. No re-reading. Faster first token, less wasted GPU.

### Scale on queue depth, not GPU %

The router sees every request, so it knows how many are waiting. That is the real demand signal. KEDA reads it from Prometheus:

```yaml
triggers:
  - type: prometheus
    metricType: AverageValue
    metadata:
      query: sum(llm_d_epp_flow_control_queue_size{model_name="..."})
      threshold: "1"   # one waiting request per replica = add a pod
```

Nothing waiting: you are keeping up. Something waiting: add capacity. The whole loop:

1. Requests pile up. KEDA adds a pod.
2. No free GPU, so the pod sits **Pending**.
3. The pod names a ComputeClass; GKE reads its priorities and creates a Spot GPU node pool that fits.
4. Traffic stops. Replicas drop. The node is empty.
5. Two minutes later, GKE deletes it.

Idle GPU cost is zero. That is the whole point.

### The VRAM math

```
 +------------------ 1 x 96 GB GPU -------------------+
 |  weights ~29 GB   |        KV cache ~60 GB          |
 +-------------------+---------------------------------+
     fixed cost            how many people fit
```

Weights are a fixed cost. What is left over is KV cache, and KV cache is how many conversations fit at once. Squeeze it and requests queue - which is why queue depth is the right signal. A 27B FP8 model on one 96 GB card leaves about 60 GB for cache; a 72B BF16 model across two leaves about 34 GiB.

### The whole thing in four lines

- An LLM needs its weights in VRAM, a KV cache per conversation, and a GPU that reads 100% busy either way.
- llm-d puts a router in front that picks the pod by queue, cache use and prefix hits.
- KEDA scales pods on queue depth. GKE buys Spot GPU nodes for pending pods and returns them when empty.
- Keep it all in git and it costs about $2 an hour while you use it, nothing after.

The mental model that stuck: **llm-d is a load balancer that knows what is in each GPU's memory.**

### Jargon decoder

| Term | Meaning |
|------|---------|
| **VRAM** | Memory on the GPU. Decides which models fit. |
| **FP8 / BF16** | 1 vs 2 bytes per weight. FP8 halves memory for a small quality cost. |
| **TP / tensor parallelism** | Splitting one model across several GPUs. Kimi uses TP=2. |
| **quota** | Google's cap on what a project may launch, per GPU family, per region and globally. Starts at zero for most GPUs. |
| **Spot** | Discounted spare capacity Google can reclaim with 30 seconds' notice; 60–90% cheaper than on-demand. |
| **ComputeClass** | A GKE object listing the machine shapes a workload may use, in order of preference. GKE's answer to a Karpenter NodePool. |
| **Workload Identity Federation** | Lets GitHub Actions prove its identity to Google and get short-lived credentials — no stored keys. |
| **Cloud NAT** | A managed way out to the internet for nodes without public IPs. Bills per GB; not used here. |

---

## Architecture

```
                         Internet (ALLOWED_CIDRS only)
                     │                              │
        passthrough NLB :80 (API)        passthrough NLB :80 (Open WebUI)
                     │                              │
        ┌────────────▼─────────────┐   ┌────────────▼──────────┐
        │ llm-d router v1.0.0      │◀──│ Open WebUI            │
        │ Envoy + Endpoint Picker  │   │ (system pool)         │
        └────────────┬─────────────┘   └───────────────────────┘
                     │  picks a backend: queue, KV-cache and prefix aware
        ┌────────────▼─────────────┐
        │ vLLM 0.30 model server   │◀── KEDA: replicas from EPP queue depth
        │ (or llm-d-inference-sim) │      (Prometheus → ScaledObject → HPA)
        └────────────┬─────────────┘
                     │ nodeSelector cloud.google.com/compute-class
        ┌────────────▼─────────────┐
        │ ComputeClass per tier    │◀── GKE creates a Spot node pool for Pending
        │ Spot GPU shapes only     │    pods, deletes it when empty; capped by
        └──────────────────────────┘    the cluster's resource_limits
```

- **GKE Standard, zonal control plane** in `us-central1-b`, free under the GKE
  free tier. Node pools may use `us-central1-b/c/f`, all of which offer G4;
  L4 is in b and c. Three zones triples the chance of finding Spot capacity.
- **Standard, not Autopilot.** Autopilot bills per pod request with a GPU
  premium and hides the nodes; this lab is about watching nodes come and go.
- **One always-on system pool** (Spot `e2-standard-4`, 1–3 nodes) for Argo CD,
  KEDA, Prometheus, the router and Open WebUI, so GPU nodes can scale to zero
  without taking the platform with them.
- **GPU drivers and the device plugin are GKE's job.** The ComputeClass asks
  for `driverVersion: latest`; nothing NVIDIA is installed by hand.
- **Standalone router mode.** The llm-d router runs its own Envoy sidecar and
  is exposed by a plain LoadBalancer Service, so no Gateway API dataplane is
  needed. GKE's managed Gateway API is disabled so the v1.6.2 CRDs llm-d tests
  against are the ones installed. Istio is behind `enable_istio` (off).
- **No NAT.** Nodes have external IPs and egress directly; the VPC firewall is
  the boundary.
- **App of apps.** Terraform creates one Argo CD Application, `root` (through
  Argo's `argocd-apps` chart), pointing at `gitops/root`. It reads `tier` from
  `deploy/config.yaml` and renders one child Application per component;
  `tier: none` renders none, so Argo CD prunes them all.
- **Kubernetes auth without plugins.** Terraform's providers use the caller's
  own short-lived Google access token; CI uses `get-gke-credentials`, which
  writes a token-based kubeconfig. Nothing long-lived lands in state.

### Pinned versions

| Component | Version |
|-----------|---------|
| GKE | REGULAR release channel |
| llm-d router chart (`llm-d-router-standalone`) + EPP | v1.0.0 |
| vLLM image | `vllm/vllm-openai:v0.30.0` |
| `llm-d-inference-sim` | v1.0.0 |
| Gateway API / Inference Extension CRDs | v1.6.2 / v1.6.2 |
| KEDA | 2.21.0 |
| kube-prometheus-stack | 92.16.0 |
| Open WebUI chart | 18.3.0 |
| Argo CD chart / argocd-apps chart | 10.18.0 (Argo CD v3.6.1) / 2.0.8 |
| Terraform / google provider | 1.13 / 7.x |

The `validate` workflow checks that pinned charts and CRD URLs still resolve,
and renders every GitOps chart for every tier and environment through strict
schema validation (Kubernetes + ComputeClass/KEDA/Argo CD CRDs).

---

## From EKS to GKE

This repo is a port of [llm-d-eks-lab](https://github.com/didiberman/llm-d-eks-lab).
The GitOps design, the tiers and the safety rails carried over; the cloud
pieces map like this:

| EKS | GKE |
|-----|-----|
| Karpenter controller | node auto-provisioning (`cluster_autoscaling` in Terraform) |
| NodePool + EC2NodeClass | ComputeClass (one per tier, from Argo CD) |
| NodePool `limits.cpu` | cluster-wide `resource_limits` incl. per-GPU-type caps |
| `consolidateAfter: 1m` | `autoscalingPolicy.consolidationDelayMinutes: 2` + `OPTIMIZE_UTILIZATION` |
| NVIDIA device plugin app | built in; `gpu.driverVersion: latest` |
| IAM role via GitHub OIDC | Workload Identity Federation → service account |
| EKS access entries | IAM roles on the project (`container.admin`) |
| NLB via annotation | plain `type: LoadBalancer` (external passthrough NLB) |
| Public subnets + IGW | external node IPs, no Cloud NAT |
| S3 state bucket | GCS state bucket (native locking) |
| vCPU-denominated G/VT quota | per-GPU-family + global GPU quota, plus CPUs |
| $0.10/hr control plane | $0 (free tier: one zonal cluster) |

One lesson carried over in money: on AWS, nodes in public subnets pulling 241 GB
of weights and images through their public IPs cost **$2.41 of
"PublicIP-In" regional data transfer** on a $10 bill. Google does not charge for
ingress, so the same pattern costs nothing here.

---

## Setting it up in your own project

You need Terraform ≥ 1.13, the gcloud CLI (with `gke-gcloud-auth-plugin` for
`make kubeconfig`), `kubectl`, `helm` and the `gh` CLI. `kind` + Docker for the
free local tier; `k6` for `make load` (falls back to a container).

**1. Bootstrap — the only layer applied from your machine**, because it creates
the project and the identity CI uses. Log in with `gcloud auth
application-default login`, then create `terraform/00-bootstrap/terraform.tfvars`
(gitignored):

```hcl
project_id          = "<globally-unique-id>"   # default gke-llm-lab-01
billing_account     = "XXXXXX-XXXXXX-XXXXXX"   # a paid account; free trials get no GPUs
budget_currency     = "USD"                    # must match the billing account
quota_contact_email = "you@example.com"
github_repo         = "<owner>/<repo>"         # creates the WIF pool + deploy SA
```

On a brand-new project the state bucket does not exist yet: move
`terraform/00-bootstrap/backend.tf` aside, run `make bootstrap`, restore it, run
`terraform init -migrate-state` in that directory, and confirm the migration
succeeded before deleting the local `terraform.tfstate`. After that,
`make bootstrap` works directly. If your project ID differs, update the bucket
in `backend.tf` and `PROJECT_ID` in the Makefile, and set the repo variable
below.

**2. GPU quota.** Bootstrap files the requests (2 RTX PRO 6000, 2 L4, 128
vCPU) as Cloud Quotas preferences. Google decides; a brand-new project is often
refused and asked to build some billing history first. `make quota` shows what
was granted. `sim` needs no GPU quota at all.

**3. Repo settings.** `make github-setup` writes them from the bootstrap
outputs (it uses your current IP for `ALLOWED_CIDRS` unless you pass one):

| Kind | Name | Value |
|------|------|-------|
| variable | `GCP_PROJECT_ID` | `project_id` |
| secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `workload_identity_provider` |
| secret | `GCP_DEPLOY_SERVICE_ACCOUNT` | `deploy_service_account` |
| secret | `ALLOWED_CIDRS` | e.g. `["203.0.113.7/32"]` — who may reach the endpoints |
| secret | `HF_TOKEN` | optional; faster HuggingFace downloads |

`ALLOWED_CIDRS` and the provider name are secrets rather than variables so your
IP and project number are masked in Actions logs, which are public on a public
repo.

**4. Deploy.** `make cluster-on` (CI builds GKE and Argo CD, ~15 min), then
`make tier TIER=sim` to prove the path for pennies, then the tier you want.
If you fork the repo, set `gitops_repo_url` in `terraform/10-cluster/variables.tf`
and `repoURL` in `gitops/root/values.yaml` to your fork — Argo CD must read the
repo without credentials, so it has to be public.

**5. Protect `main`.** Workload Identity admits only workflows on `main`, and
Argo CD auto-syncs `main`, so whoever can push to `main` controls the cluster.
Block force-pushes and require reviews from anyone but you.

---

## Layout

```
deploy/config.yaml        the switch: cluster true|false, tier none|sim|small|gpu|kimi
terraform/
  00-bootstrap/           project + billing, APIs, GCS state bucket, node SA,        (local, once)
                          quota requests, budget, Workload Identity + deploy SA
  10-cluster/             VPC (no NAT), GKE + auto-provisioning limits, system pool, (CI)
                          KEDA, Prometheus, CRDs, Argo CD, root Application, HF Secret
gitops/                   everything Argo CD reconciles
  root/                   app of apps: one Application per component
  apps/model-server/      ComputeClass, model Deployment, ScaledObject, Services
  tiers/*.yaml            sim | small | gpu | kimi — the only difference between tiers
  values/                 values for the upstream charts (llm-d router, Open WebUI)
  bootstrap/              Argo CD install values (shared by Terraform and kind)
local/                    free kind proof: `make argocd-local`
scripts/                  render-check (CI), wait-for-apps (CI + local), sweep-k8s-lb (destroy), prices
loadgen/                  k6 ramp script for `make load`
.github/workflows/        deploy · destroy · validate
docs/COSTS.md             prices, tier costs, and the alternatives to running your own cluster
```

---

## Commands

```
make cluster-on / cluster-off   allow / forbid CI to create the GKE cluster (commit + push)
make tier TIER=...              set the tier Argo CD runs (commit + push)
make follow                     follow the latest deploy run
make deploy                     re-run the deploy workflow (reconcile + verify)
make destroy                    destroy workflow: everything billable, to ~$0

make kubeconfig                 kubectl access (context: llm-d-gke-lab)
make argocd-ui                  Argo CD UI on http://localhost:8090
make apps                       Argo CD application status
make watch                      live view of ScaledObject, HPA, pods, ComputeClasses and nodes
make load                       fire k6 at the endpoint and watch replicas scale

make argocd-local               the whole GitOps stack on kind, $0 (argocd-local-down to remove)
make render                     render + schema-validate every chart/tier, no cluster

make quota | cost | prices | whats-running
make validate                   terraform validate + render
make bootstrap                  apply 00-bootstrap (the one local apply)
make github-setup               write the Actions variable + secrets from bootstrap outputs
make cluster-plan               read-only plan of 10-cluster from your machine
```

---

## Honest caveats

- **llm-d's real wins need scale.** Prefix-cache routing and prefill/decode
  disaggregation pay off across many GPUs. On one or two replicas you are
  exercising the control plane, not demonstrating a speedup.
- **Spot means reclaims.** Google can take a Spot node with 30 seconds'
  notice; the model pod restarts on a new node with a full cold start.
  That is part of the lesson, not a bug.
- **Cold starts are slow.** Every new node pulls a ~10 GB vLLM image and the
  weights from Hugging Face. A ComputeClass cannot raise a Hyperdisk boot
  disk's throughput, so Kimi's 145 GB takes longer than it did on a tuned EBS
  volume.
- **Argo CD's UI is not exposed.** Reach it with `make argocd-ui`
  (port-forward); there is no ingress or SSO.
- **Endpoints have no auth.** The model API and Open WebUI are protected only
  by the IP allowlist. Widen `ALLOWED_CIDRS` and you should turn
  `WEBUI_AUTH` back on in `gitops/values/open-webui.yaml`.
- **Public nodes.** Nodes have external IPs (the no-NAT trade-off); the VPC
  firewall is the boundary. Fine for a disposable lab, not a pattern for
  production.
- **The control-plane endpoint is open to `0.0.0.0/0`** (still behind Google
  authentication) because CI runners and a laptop on a changing IP both need
  it. Narrow `api_allowed_cidrs` for anything long-lived.
- **Ephemeral by design.** No persistent volumes: Open WebUI chats and
  downloaded weights vanish with their pods.

---

## Status

As of 2026-11-19: **ready to deploy, not deployed.**

**Done and checked**

- Both Terraform layers pass `terraform validate`, and read-only plans run
  against the real project: bootstrap would add 13 resources (Workload
  Identity, the deploy service account and its roles, the L4 quota request,
  the budget) and change or destroy nothing; `10-cluster` would create 12
  (VPC, subnet, cluster, system pool, CRDs, KEDA, Prometheus, Argo CD, root
  app, namespace, HF Secret).
- Every chart renders for every tier in both environments, the guardrails
  refuse bad input, and all 60 resources pass strict schema validation,
  including the ComputeClass against GKE's CRD schema.
- The workflows pass `actionlint`.
- `cpus-all-regions` quota: 128 granted on the project.

**Waiting on Google**

- GPU quota on `gke-llm-lab-01`: RTX PRO 6000 and global GPUs are requested
  and not yet granted (0). Until then, `small`, `gpu` and `kimi` pods stay
  Pending (and cost nothing); `sim` works.

**Not yet run for real** — the first `make cluster-on` + `make tier TIER=sim`
(about $0.20 for an hour) proves: the cluster apply, Argo CD convergence,
ComputeClass-driven node creation, load balancer source ranges, the verify
job, `tier: none`, and the destroy workflow.

**To go live**

1. Create the GitHub repo and push `main`.
2. `make bootstrap` (creates Workload Identity for that repo — the plan above).
3. `make github-setup`.
4. `make cluster-on`, then `make tier TIER=sim`.

---

## License

Apache-2.0
