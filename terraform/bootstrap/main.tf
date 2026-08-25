# ---------------------------------------------------------------------------
# Bootstrap: creates the GCS bucket that holds remote state for the main
# configuration in ../. This config keeps its OWN state local (and gitignored)
# to break the chicken-and-egg problem of storing state in a bucket that does
# not exist yet.
#
# Run once:
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
#
# Losing this local state is not a problem: the bucket is trivially re-imported
# with `terraform import`, or simply left alone.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.45"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "tfstate" {
  name     = var.state_bucket_name
  project  = var.project_id
  location = var.region

  # Terraform state is a single small object rewritten on every apply.
  storage_class = "STANDARD"

  # Object versioning is the recovery path for a corrupted or truncated state
  # write. Without it, a bad apply is unrecoverable.
  versioning {
    enabled = true
  }

  # Retain a bounded history of prior state versions rather than growing
  # without limit.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  # State is never public and never should be reachable by ACL.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Guard against a stray `terraform destroy` deleting the state history of
  # every other stack that uses this bucket.
  force_destroy = false
}
