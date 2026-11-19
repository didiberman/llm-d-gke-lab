output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Zone of the control plane."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "GKE API server endpoint."
  value       = local.k8s_host
}

output "project_id" {
  description = "Project the cluster lives in."
  value       = var.project_id
}

output "kubeconfig_command" {
  description = "Point kubectl at the cluster (needs gke-gcloud-auth-plugin: `gcloud components install gke-gcloud-auth-plugin`)."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${google_container_cluster.this.location} --project ${var.project_id}"
}

output "nat_count" {
  description = "Always 0. Asserted as an output so a regression shows in the plan diff, not only on the bill."
  value       = 0
}

output "argocd_ui_command" {
  description = "Open the Argo CD UI (user admin; password from the argocd-initial-admin-secret Secret)."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8090:80   # then http://localhost:8090"
}
