# Backstop only: a budget tells you after the money is spent. `tier: none`
# (GPUs gone) or the destroy workflow is what stops it.
#
# Scoped to the project, so it is exact: everything this lab costs is in it.
# Recipients are the billing account's admins (the default), so no email
# address has to be put anywhere.

resource "google_billing_budget" "this" {
  provider = google.in_project
  count    = var.budget_amount == null ? 0 : 1

  billing_account = var.billing_account
  display_name    = "${var.project_id} monthly"

  budget_filter {
    projects = ["projects/${google_project.this.number}"]
  }

  amount {
    specified_amount {
      # Must match the billing account's currency (the API 400s otherwise),
      # so it is a variable rather than hardcoded USD.
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  # Each threshold_percent may appear once across rules (the API 400s on a
  # duplicate), so 100% is forecast-only: the alert that actually saves money,
  # since a GPU left on trips the forecast days before the actual spend arrives.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.this]
}
