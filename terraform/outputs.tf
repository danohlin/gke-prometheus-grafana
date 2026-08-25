output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.primary.name
}

output "zone" {
  description = "Zone the cluster runs in."
  value       = google_container_cluster.primary.location
}

output "get_credentials_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.project_id}"
}

output "managed_prometheus_enabled" {
  description = "Should be false. True means GMP is collecting in parallel with the self-managed stack and billing per sample."
  value       = google_container_cluster.primary.monitoring_config[0].managed_prometheus[0].enabled
}

output "spot_nodes" {
  description = "Whether the node pool is running on Spot VMs."
  value       = google_container_node_pool.primary.node_config[0].spot
}
