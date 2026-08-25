variable "project_id" {
  description = "Google Cloud project ID that will own the state bucket."
  type        = string
}

variable "region" {
  description = "Region for the state bucket. Independent of the cluster zone."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique name for the Terraform state bucket. GCS bucket names share
    one namespace across all of Google Cloud, so prefixing with the project ID
    is the conventional way to stay unique.
  EOT
  type        = string
}
