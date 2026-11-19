# Costs

Everything here is a **us-central1 list price in USD**, read from the Cloud
Billing catalog in November 2026 (`make prices` re-reads it). Your bill is in
your billing account's currency. GCP Spot prices change at most once a month,
far more slowly than AWS Spot.

## The machine shapes

A Compute Engine VM is billed as parts — vCPU-hours, GB-hours of RAM and
GPU-hours — so a "machine price" is a sum of three SKUs.

| Shape | GPU | vCPU / RAM | Spot $/hr | On-demand $/hr | Used by |
|-------|-----|-----------|-----------|----------------|---------|
| `e2-standard-2` | — | 2 / 8 GB | 0.040 | 0.067 | `sim` |
| `e2-standard-4` | — | 4 / 16 GB | 0.080 | 0.134 | system pool |
| `g2-standard-4` | 1× L4 24 GB | 4 / 16 GB | 0.423 | 0.707 | `small` |
| `g4-standard-48` | 1× RTX PRO 6000 96 GB | 48 / 180 GB | 1.718 | 4.500 | `gpu` |
| `g4-standard-96` | 2× RTX PRO 6000 192 GB | 96 / 360 GB | 3.436 | 9.000 | `kimi` |

Other shapes considered, for reference:

| Shape | GPU | Spot $/hr | On-demand $/hr | Why not |
|-------|-----|-----------|----------------|---------|
| `g2-standard-48` | 4× L4 96 GB | 2.39 | 4.00 | Same VRAM as one RTX PRO 6000, split four ways, for more money |
| `a2-highgpu-1g` | 1× A100 40 GB | 2.19 | 3.67 | Less VRAM than G4 at a higher Spot price; no FP8 |
| `a2-ultragpu-1g` | 1× A100 80 GB | 3.01 | 5.03 | Less VRAM than G4, 1.75× the price |
| `a3-highgpu-1g` | 1× H100 80 GB | 6.54 | 10.98 | Fastest, but 3.8× the G4 Spot price for less memory |

**Spot is the whole cost model.** G4 Spot is 62% under on-demand. Each
ComputeClass in `gitops/tiers/` lists Spot shapes only and sets
`whenUnsatisfiable: DoNotScaleUp`, so when Spot is out GKE waits rather than
silently launching a $4.50/hr on-demand node.

## What the lab costs

| State | $/hr | Per day |
|-------|------|---------|
| `make destroy` (project + state bucket only) | ~0 | ~0 |
| Cluster up, `tier: none` | ~0.09 | ~2.20 |
| `sim` | ~0.16 | ~3.80 |
| `small`, 1–2 replicas | ~0.56–1.00 | ~13–24 |
| `gpu`, 1–2 replicas | ~1.86–3.60 | ~45–86 |
| `kimi` | ~3.60 | ~86 |

What is in the always-on ~$0.09/hr:

- **GKE management fee: $0.** It is $0.10/hr per cluster, but the GKE free tier
  credits one zonal (or Autopilot) cluster per billing account. The control
  plane is zonal for exactly this reason; a regional one would bill.
- **System node:** one Spot `e2-standard-4` (~$0.080), 50 GB pd-balanced
  (~$0.007), external IP at the Spot rate (~$0.003).

What a running tier adds on top of its GPU nodes: two external passthrough
load balancers (the first five forwarding rules cost $0.025/hr together), each
node's boot disk (Hyperdisk Balanced $0.08/GB-month on G4, pd-balanced
$0.10/GB-month elsewhere) and a $0.0025/hr external IP per Spot node.

## Leaks this design avoids

| Leak | What it would cost | Here |
|------|--------------------|------|
| Cloud NAT | per VM-hour plus **$0.045/GB processed**. One `kimi` cold start pulls ~10 GB of image and 145 GB of weights: ~$7 per start, on top of the GPU | No NAT. Nodes egress directly; **ingress to GCP is free** |
| Regional control plane | $0.10/hr, $73/month | Zonal, inside the free tier |
| On-demand fallback | 2.6× the Spot price, silently | Spot-only ComputeClasses |
| Forgotten GPU | $42–86/day | `tier: none`; a budget email at 50/90% actual and 100% forecast |
| Managed Prometheus, workload logs | per sample / per GB ingested | Off. In-cluster Prometheus (6h retention) feeds KEDA; GKE logs system components only |
| Persistent volumes | a disk that bills until someone deletes it | None. Weights live on the node's boot disk and go with it |

### The lesson from AWS

The EKS version of this lab ran in public subnets for the same no-NAT reason.
Its November bill was **$10.47** for about 40 minutes of a `g7e.12xlarge`:

| Line | $ |
|------|---|
| `g7e.12xlarge` (0.68 h) | 5.61 |
| **Regional data transfer, "PublicIP-In", 241 GB** | **2.40** |
| Tax | 1.67 |
| Everything else (EKS, system nodes, S3, Cost Explorer API) | 0.79 |

AWS bills traffic that enters an instance through its **public IP** from
within the same region at $0.01/GB — and Hugging Face and the container
registries were reached that way. The fix there is a weight cache in S3 behind
a free gateway endpoint. On GCP the same download is ingress and costs nothing,
which is part of why this port keeps the no-NAT design unchanged.

## Quota is the real constraint

A new project can launch neither the GPUs nor the vCPUs this lab needs:

| Quota | Default on a new project | Requested by `00-bootstrap` |
|-------|--------------------------|-----------------------------|
| `GPUS-ALL-REGIONS-per-project` | 0 | 2 |
| `GPUS-PER-GPU-FAMILY-per-project-region`, `NVIDIA_RTX_PRO_6000` | 0 | 2 |
| `GPUS-PER-GPU-FAMILY-per-project-region`, `NVIDIA_L4` | often 0–1 | 2 |
| `CPUS-ALL-REGIONS-per-project` | 32 (one `g4-standard-48` is 48) | 128 |

Spot VMs draw on these normal limits while the separate PREEMPTIBLE quotas are
unset. Google grants or refuses each request on its own schedule; new projects
with little billing history are often refused GPUs at first. `make quota`
shows the state. While a tier lacks quota its pod stays Pending and **costs
nothing** — GKE logs a scale-up failure and waits.

## Alternatives to running your own cluster

If the goal is a model behind an API rather than learning the serving stack,
Google sells simpler options. Prices as of November 2026:

| Option | What you pay | ~$/hr for one 96 GB GPU's worth | Scales to zero | Notes |
|--------|--------------|-------------------------------|----------------|-------|
| **This lab, `gpu` tier** | Spot VM + small overhead | ~1.86 | GPUs yes; cluster ~$0.09/hr | You run llm-d, KEDA, Argo CD. Spot can be reclaimed |
| **Cloud Run with an RTX PRO 6000** | per second while an instance runs: GPU $0.000365/s, plus a 20 vCPU / 80 GiB minimum | ~3.19 (3.92 with zonal redundancy) | Yes, natively | One container, no Kubernetes. Cold starts include the weight download |
| **Cloud Run with an L4** (4 vCPU / 16 GiB) | per second | ~1.05 | Yes | The cheapest managed GPU; 24 GB fits ~8B models comfortably |
| **Vertex AI endpoint, `g4-standard-48`** | per node-hour, on-demand only | ~5.85 | No (min 1 replica) | Managed vLLM containers from Model Garden |
| **Vertex AI endpoint, `g2-standard-12` (L4)** | per node-hour | ~1.30 | No | |
| **Vertex AI Model-as-a-Service** | per token, input / output per 1M | — | Nothing to scale | Kimi K2 Thinking $0.60 / $2.50; Qwen3 Coder 480B $0.22 / $1.80; Qwen3 235B $0.22 / $0.88 |

For one person's occasional use, per-token MaaS is by far the cheapest: an
hour of heavy chatting is a few cents to a few dimes, and the models are far
larger than anything this lab can hold. This lab is worth its cost when the
point is the serving stack itself — routing, autoscaling, node provisioning —
or when you need your own weights.

## Re-measuring

```bash
make prices                 # machine shapes, Spot and on-demand
make whats-running          # anything billing in the project right now
make cost                   # link to the billing report for the project
```
