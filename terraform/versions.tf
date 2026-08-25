terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.45"
    }
  }

  # Partial backend configuration: the bucket name is environment-specific and
  # a backend block cannot interpolate variables, so it is supplied at init:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # Create backend.hcl from backend.hcl.example (it is gitignored via *.hcl
  # being environment-specific -- see README).
  backend "gcs" {
    prefix = "gke-monitoring"
  }
}
