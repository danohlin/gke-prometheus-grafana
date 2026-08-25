# ---------------------------------------------------------------------------
# A purpose-built VPC rather than the project default network, so the demo owns
# its address space and can be torn down without touching anything else.
# ---------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.cluster_name}-subnet"
  project       = var.project_id
  region        = local.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # VPC-native (alias IP) clusters require named secondary ranges for Pods and
  # Services. This is the only supported mode for new GKE clusters.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Lets nodes reach Google APIs without external IPs.
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# Cloud NAT. This is NOT optional and is the single most common way this build
# breaks: the nodes are private (no external IPs), and node-exporter,
# kube-state-metrics, prometheus-operator, and podinfo all pull images from
# quay.io and ghcr.io -- neither of which is a Google API reachable via Private
# Google Access. Without NAT every one of those pods sits in ImagePullBackOff
# and the stack never comes up.
# ---------------------------------------------------------------------------

resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  project = var.project_id
  region  = local.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name    = "${var.cluster_name}-nat"
  project = var.project_id
  region  = local.region
  router  = google_compute_router.router.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
