resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.zone # zonal -- see the zone variable for the cost rationale

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # The default node pool is created and immediately removed so the real pool
  # can be managed as its own resource (google_container_node_pool). This is the
  # standard idiom; initial_node_count is required even though it is discarded.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Track the REGULAR channel rather than pinning min_master_version: a pinned
  # version silently goes stale and eventually falls out of support, whereas the
  # channel keeps the cluster current on Google's schedule.
  release_channel {
    channel = "REGULAR"
  }

  # -------------------------------------------------------------------------
  # THE key line for this stack. Equivalent to --no-enable-managed-prometheus.
  # Left at its default, GKE runs Google Managed Prometheus collection
  # alongside the self-managed Prometheus deployed by Helm and bills per sample
  # ingested for data that is never queried.
  # -------------------------------------------------------------------------
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    managed_prometheus {
      enabled = false
    }

    # Hubble. The cluster already runs Cilium by virtue of ADVANCED_DATAPATH
    # below, so this only switches on its observability layer: an eBPF-derived
    # service map of real observed flows, rather than a diagram someone drew.
    #
    # enable_metrics stays false on purpose. It is an independent feature that
    # pushes Dataplane V2 metrics to Google Managed Prometheus - which this
    # stack disables deliberately. The relay and UI are entirely in-cluster and
    # reached by port-forward, so they do not reintroduce GMP billing.
    advanced_datapath_observability_config {
      enable_relay   = var.enable_hubble_relay
      enable_metrics = false
    }
  }

  # SYSTEM_COMPONENTS only. Adding WORKLOADS ships every container stdout to
  # Cloud Logging, billed per GiB ingested and redundant here -- the point of
  # the exercise is that Prometheus holds the telemetry.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # -------------------------------------------------------------------------
  # Dataplane V2 (eBPF). CREATE-TIME ONLY AND IRREVERSIBLE -- an existing
  # cluster cannot be converted, so this has to be decided now. It provides
  # NetworkPolicy enforcement and, relevantly here, removes kube-proxy
  # altogether. That is what makes kubeProxy.enabled=false in the Helm values
  # straightforwardly correct rather than a workaround for GKE binding
  # kube-proxy metrics to an unscrapable 127.0.0.1:10249.
  # -------------------------------------------------------------------------
  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    # Nodes have no external IPs; egress is via Cloud NAT.
    enable_private_nodes = true

    # The control-plane endpoint stays public so kubectl and port-forward work
    # from a workstation with no bastion or VPN -- access is instead narrowed by
    # master_authorized_networks_config below.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # NOTE on private clusters and the prometheus-operator admission webhook:
  # GKE automatically provisions a master -> nodes firewall rule for tcp/443 and
  # tcp/10250. The kube-prometheus-stack admission webhook listens on 10250, so
  # it falls inside the auto-allowed set and needs no extra firewall rule. A
  # webhook on any other port would hang here until one was added.

  resource_labels = local.common_labels

  deletion_protection = var.deletion_protection

  depends_on = [google_project_service.required]
}
