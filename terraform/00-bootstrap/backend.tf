# Added after the first (local-state) apply created the bucket; the state was
# then moved here with `terraform init -migrate-state`. On a brand-new project,
# delete this file for the first apply and restore it afterwards.
terraform {
  backend "gcs" {
    bucket = "gke-llm-lab-01-tfstate"
    prefix = "00-bootstrap"
  }
}
