variable "project_id" {
  description = "GCP project ID to create. Globally unique, 6-30 chars."
  type        = string
  # "gke-llm-lab" itself is taken globally by another account.
  default = "gke-llm-lab-01"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Project ID must be 6-30 chars: lowercase letters, digits, hyphens; start with a letter."
  }

  nullable = false
}

variable "project_name" {
  description = "Display name shown in the console. Unlike the ID it need not be unique."
  type        = string
  default     = "gke-llm-lab"

  nullable = false
}

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) the project is charged to. Must be a paid account: free-trial billing cannot use GPUs. Set in terraform.tfvars (gitignored); never commit it."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account))
    error_message = "Billing account must look like 0X0X0X-0X0X0X-0X0X0X."
  }

  nullable = false
}

variable "org_id" {
  description = "Organization ID to create the project under. Null for an account without an organization (e.g. a personal Gmail account)."
  type        = string
  default     = null
}

variable "region" {
  description = "Region for the state bucket, the quota requests and (in 10-cluster) the cluster. us-central1 has the cheapest G4 Spot pricing and three G4 zones (b, c, f)."
  type        = string
  default     = "us-central1"

  nullable = false
}

variable "labels" {
  description = "Labels applied to the project and the state bucket. Billing reports can group spend by them."
  type        = map(string)

  default = {
    project    = "gke-llm-lab"
    managed-by = "terraform"
  }

  nullable = false
}

# ---------------------------------------------------------------------------
# Quota. A new project has 0 GPUs and 32 vCPU globally; one g4-standard-48 is
# 48 vCPU, so without these nothing in the gpu tier can ever launch.
# ---------------------------------------------------------------------------

variable "request_quota" {
  description = "File the GPU/CPU quota increase requests as Cloud Quotas preferences. Approval is Google's decision and may take minutes to days; the apply does not wait for it."
  type        = bool
  default     = true

  nullable = false
}

variable "gpu_quota" {
  description = "RTX PRO 6000 GPUs requested, both globally and in var.region. 2 = two g4-standard-48 Spot nodes, the gpu tier's 1->2 replicas."
  type        = number
  default     = 2

  nullable = false
}

variable "l4_quota" {
  description = "L4 GPUs requested in var.region, for the small tier (g2-standard-4, 1 L4 each). Counts against the same GPUS-ALL-REGIONS limit as gpu_quota. Often granted faster than RTX PRO 6000."
  type        = number
  default     = 2

  nullable = false
}

variable "cpu_quota_global" {
  description = "Global vCPU quota requested. 2 x 48 (G4 nodes) + system nodes + headroom for node surge during upgrades."
  type        = number
  default     = 128

  nullable = false
}

variable "quota_contact_email" {
  description = "Email Google may contact about the quota requests. Must be an account with quota permissions on the project. Set in terraform.tfvars; never commit it."
  type        = string
  default     = null
}

variable "quota_justification" {
  description = "Free-text reason attached to the quota requests."
  type        = string
  default     = "Learning lab for LLM inference on GKE: two Spot g4-standard-48 nodes (1 RTX PRO 6000 each), autoscaled on queue depth, scaled to zero when idle."

  nullable = false
}

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------

variable "budget_amount" {
  description = "Monthly budget for the project, in var.budget_currency. Alerts go to the billing account's admins by email at 50/90/100% actual and 100% forecast. Null to skip. A budget reports spend; `tier: none` is what stops it."
  type        = number
  default     = 100
}

variable "budget_currency" {
  description = "ISO currency of the billing account. Must match it exactly or the Budgets API rejects the request. Prices elsewhere in this repo are USD list prices."
  type        = string
  default     = "USD"

  nullable = false
}

# ---------------------------------------------------------------------------
# GitHub Actions (Workload Identity Federation). Null until the GitHub repo
# exists, so the first apply creates no external trust.
# ---------------------------------------------------------------------------

variable "github_repo" {
  description = "GitHub repo in owner/name form allowed to deploy (main branch only). Null to skip creating the Workload Identity pool and deploy service account."
  type        = string
  default     = null
}
