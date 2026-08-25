resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  # Zonal cluster, so this is the absolute node count (not per-zone).
  node_count = var.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge upgrades keep the stack available while nodes roll.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    # Halves compute cost. Every node in the cluster is Spot, so GKE applies no
    # taint that workloads would need to tolerate -- no tolerations anywhere.
    spot = var.use_spot

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Required for Workload Identity; also stops workloads from reading the
    # node service-account token out of the legacy metadata server.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = local.common_labels

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
