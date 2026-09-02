variable "project_id" {
  description = "Google Cloud project ID to deploy into."
  type        = string
}

variable "zone" {
  description = <<-EOT
    Compute zone for the cluster, e.g. "us-central1-a". This is a ZONAL cluster
    on purpose: the GKE management fee is a flat $0.10/cluster/hour for every
    topology, but the free tier grants $74.40/month per billing account against
    exactly one zonal Standard (or Autopilot) cluster -- which cancels the fee.
    A regional cluster pays the same fee with no credit, so ~$73/month more.
  EOT
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "gke-monitoring-demo"
}

variable "authorized_networks" {
  description = <<-EOT
    CIDR blocks permitted to reach the public control-plane endpoint. No default
    on purpose -- leaving the endpoint open to the whole internet should be a
    conscious choice, not an accident. Find your address with:

      curl -s ifconfig.me

    and set [{ cidr_block = "203.0.113.4/32", display_name = "workstation" }].
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

variable "node_machine_type" {
  description = <<-EOT
    Node machine type. E2 is chosen deliberately: N4/C4/N4D do not support
    Persistent Disk at all (Hyperdisk only), so the standard-rwo StorageClass
    that the Helm values request would fail to bind on those families unless the
    cluster is 1.35.0-gke.2232000+ with a `type: dynamic` StorageClass.
  EOT
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = <<-EOT
    Nodes in the single zone. Three keeps the node-exporter dashboards
    meaningful; the monitoring stack itself only requests ~800m CPU / 2.7Gi.
  EOT
  type        = number
  default     = 3
}

variable "node_disk_size_gb" {
  description = <<-EOT
    Boot disk per node. Set to 50 rather than accepting GKE's 100GiB default,
    which would silently double the boot-disk line on the bill.
  EOT
  type        = number
  default     = 50
}

variable "use_spot" {
  description = <<-EOT
    Spot cuts compute cost by 40%: $0.040212/hr vs $0.067011/hr per
    e2-standard-2, from the Cloud Billing Catalog for us-central1. Not 50% - E2
    Spot is a 40% discount, and there is no sustained-use discount on E2 to
    forfeit either, since SUD covers only N1, N2, N2D, C2, M1 and M2.

    Across the whole cluster that is $58.69/month, but only a 35% saving overall
    because storage costs the same either way.

    The price is 30-second preemption notices. Observed here at roughly three
    per hour: each replaces a node and leaves a gap in the Prometheus series.
    Acceptable for a demo torn down nightly, less so for anything expected to
    alert reliably.

    Because EVERY node is Spot, GKE applies no taint that needs tolerating.
  EOT
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = <<-EOT
    Defaults to false because this is an explicitly disposable demo cluster and
    a half-completed `terraform destroy` is the main way it starts costing money
    unattended. Set true for anything you intend to keep.
  EOT
  type        = bool
  default     = false
}

variable "subnet_cidr" {
  description = "Primary range for node IPs."
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary range for Pod IPs (VPC-native alias IPs)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for Service ClusterIPs."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_cidr" {
  description = "RFC1918 /28 for the control plane's private endpoint."
  type        = string
  default     = "172.16.0.0/28"
}

variable "enable_hubble_relay" {
  description = <<-EOT
    Deploys Hubble Relay + the Hubble UI, giving a live eBPF-derived service map
    of what actually talks to what. Free-riding on the Dataplane V2 choice: the
    cluster already runs Cilium, so this only turns on the observability layer.

    Deliberately paired with enable_metrics = false in cluster.tf. Those are
    independent features: metrics push to Google Managed Prometheus, which this
    stack disables on purpose, whereas the relay and its UI run entirely
    in-cluster and are reached by port-forward.

    Note: Google documents no pricing for flow observability, and warns that
    anetd Pod memory grows over time with Hubble collection - worth watching on
    8GiB nodes.
  EOT
  type        = bool
  default     = true
}
