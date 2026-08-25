output "state_bucket" {
  description = "Bucket name to place in the main configuration's backend block."
  value       = google_storage_bucket.tfstate.name
}

output "backend_config" {
  description = "Ready-to-paste backend block for ../versions.tf."
  value       = <<-EOT
    terraform {
      backend "gcs" {
        bucket = "${google_storage_bucket.tfstate.name}"
        prefix = "gke-monitoring"
      }
    }
  EOT
}
