provider "google" {
  project = var.project_id
  region  = local.region
  zone    = var.zone
}

locals {
  # The cluster is zonal; the region is derived by stripping the zone suffix
  # (us-central1-a -> us-central1). Regional resources such as the subnet and
  # Cloud Router need the region, not the zone.
  region = join("-", slice(split("-", var.zone), 0, 2))

  common_labels = {
    managed-by = "terraform"
    stack      = "prometheus-grafana-demo"
  }
}
