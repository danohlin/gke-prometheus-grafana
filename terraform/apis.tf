# Services the stack needs. Enabling an already-enabled API is a no-op, so this
# is safe against a project that has them on already.
resource "google_project_service" "required" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  # Do NOT disable these on destroy. Other workloads in the same project almost
  # certainly depend on compute/container, and turning them off during a demo
  # teardown would break them.
  disable_on_destroy = false
}
