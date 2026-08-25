# Prometheus + Grafana on GKE

A self-managed `kube-prometheus-stack` on a disposable **zonal GKE Standard** cluster, with
**podinfo** as the workload being monitored. Terraform owns Google Cloud; Helm owns the cluster.

Grafana is reachable by `kubectl port-forward` only — no Ingress, no public IP, no certificate.

---

## Cost

Roughly **$0.13/hour**, about **$5 for a 40-hour week**. us-central1 list prices, before
sustained-use discount:

| Line item | Monthly | Hourly |
|---|---:|---:|
| Control plane — $0.10/hr less the $74.40/mo free-tier credit | **$0.00** | $0.0000 |
| 3× `e2-standard-2` **Spot** @ $0.0335/hr | $73.37 | $0.1005 |
| Boot disks 3× 50 GiB `pd-balanced` @ $0.10/GiB-mo | $15.00 | $0.0205 |
| PVCs 65 GiB (Prometheus 50 + Grafana 10 + Alertmanager 5) | $6.50 | $0.0089 |
| **Total** | **≈ $95** | **≈ $0.13** |

Two things that quietly inflate this if you are not careful, both already handled:

- **Boot disks are pinned to 50 GiB.** GKE defaults to 100 GiB, which would double that row.
- **Teardown order.** `Teardown.ps1` deletes PVCs *before* the cluster. See [Teardown](#teardown).

The free-tier credit assumes you are not already spending it on another zonal cluster in the
same billing account. Switch to on-demand (~$168/mo) with `use_spot = false`.

---

## Prerequisites

| Tool | Needed |
|---|---|
| `gcloud` | authenticated, with a project and billing enabled |
| `terraform` | >= 1.15.0 |
| `helm` | **4.x** — the deploy script rejects Helm 3 |
| `kubectl` | any recent version |
| `gke-gcloud-auth-plugin` | **required**; without it kubectl auth against GKE fails with an opaque error |

```powershell
gcloud components install gke-gcloud-auth-plugin
gcloud auth login
gcloud auth application-default login
```

---

## Quickstart

### 1. State bucket (once per project)

```powershell
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit project_id + bucket name
terraform init
terraform apply
```

### 2. Cluster

```powershell
cd ../                                          # terraform/
cp backend.hcl.example backend.hcl              # bucket from step 1
cp terraform.tfvars.example terraform.tfvars    # project_id, zone, authorized_networks

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`authorized_networks` has **no default** on purpose — leaving the control-plane endpoint open
to the whole internet should be a deliberate act. Find your address with `curl -s ifconfig.me`.

```powershell
# terraform prints the exact command:
terraform output -raw get_credentials_command
kubectl get nodes                               # expect 3 Ready
```

### 3. Monitoring stack

```powershell
cd ..
./scripts/Bootstrap-Secrets.ps1                 # prints the Grafana password ONCE
./scripts/Deploy-Monitoring.ps1
```

### 4. Demo workload

```powershell
./scripts/Deploy-Podinfo.ps1
./scripts/Generate-Load.ps1 -Latency
```

### 5. Look at it

```powershell
./scripts/Connect-Grafana.ps1                   # Grafana        http://localhost:3000
./scripts/Connect-Grafana.ps1 -All              # + Prometheus 9090, Alertmanager 9093
```

---

## Verification

Worth walking once — several steps check things that fail *silently*.

| # | Check | Expected |
|---|---|---|
| 1 | `kubectl get nodes` | 3 × `Ready` |
| 2 | `kubectl get ns gmp-system` | **NotFound** — a `gmp-system` namespace means Google Managed Prometheus is collecting in parallel and billing per sample |
| 3 | `kubectl -n monitoring get pods` | all `Running`/`Completed`. `ImagePullBackOff` here means **Cloud NAT** — nodes are private and these images come from quay.io/ghcr.io |
| 4 | `kubectl -n monitoring get pvc` | 3 × `Bound` |
| 5 | `kubectl -n monitoring get ds -l app.kubernetes.io/name=prometheus-node-exporter` | desired == ready == 3. This is precisely what GKE Autopilot could not do |
| 6 | Prometheus `/targets` | everything `UP`, **and no** scheduler / controller-manager / etcd / kube-proxy entries at all. Targets *present but down* means the GKE overrides did not apply |
| 7 | Prometheus: `count(up == 1)` | nonzero; `node_cpu_seconds_total` returns per-node series |
| 8 | Grafana → *Kubernetes / Compute Resources / Node (Pods)* | populated — proves node-exporter → Prometheus → datasource → dashboard |
| 9 | Alertmanager `9093` | `Watchdog` firing. It is designed to always fire, so it confirms rules evaluate and reach Alertmanager even with no receiver |
| 10 | After `Deploy-Podinfo.ps1`, Prometheus `/targets` | a `podinfo` job appears within ~15s **with no redeploy of the stack** — the real test that the selector settings work |
| 11 | `Generate-Load.ps1 -Latency`, then *podinfo / RED* | p95/p99 climb; `-Errors` moves the error-ratio panel |

---

## Teardown

```powershell
./scripts/Teardown.ps1
```

**Order matters, and getting it wrong costs money silently.** Helm does not delete PVCs created
from a StatefulSet `volumeClaimTemplate` — deliberate upstream behaviour so an accidental
uninstall does not destroy data. If you delete the *cluster* while those PVCs still exist, their
reclaim logic never runs and the backing Compute Engine disks are orphaned: still provisioned,
still billing, attached to nothing, and no longer visible to any Kubernetes API.

So the script uninstalls releases → deletes PVCs → waits for the PVs to go → destroys the
cluster → runs `gcloud compute disks list --filter="-users:*"` to prove nothing is left.

`./scripts/Teardown.ps1 -KeepCluster` removes the workloads and disks but leaves the cluster up.

---

## Design decisions

**GKE Standard, not Autopilot.** Autopilot bans `hostPID`/`hostNetwork` and does not allowlist
`hostPath` reads of `/proc` or `/sys`, all of which node-exporter requires — node metrics would
be missing and the stock node dashboards would render empty. Autopilot also cannot disable
Google Managed Prometheus, so you would pay for ingestion you never query.

**Zonal, not regional.** The GKE management fee is a flat $0.10/cluster/hour for *every*
topology. The saving is the free tier — $74.40/month per billing account, applicable to one
zonal Standard or Autopilot cluster — which cancels the fee. A regional cluster pays the same
fee with no credit. Zonal also simplifies storage: every node shares a zone, so a preempted Spot
node's replacement can always re-attach the ReadWriteOnce disk.

**`managed_prometheus { enabled = false }`** in [terraform/cluster.tf](terraform/cluster.tf) is
the single most important line in the Terraform. Left at its default, GKE runs GMP collection
alongside the self-managed Prometheus and bills per sample ingested for data nothing queries.

**Cloud NAT is not optional.** Nodes are private; node-exporter, kube-state-metrics,
prometheus-operator, and podinfo all pull from quay.io and ghcr.io, neither reachable via
Private Google Access. Without NAT, every one of those pods sits in `ImagePullBackOff` and the
stack silently never comes up. This is the most common way this build breaks.

**Dataplane V2 is create-time only and irreversible.** An existing cluster cannot be converted,
so it had to be decided up front. It gives eBPF service routing and NetworkPolicy, and removes
kube-proxy entirely — which is what makes `kubeProxy.enabled=false` plainly correct rather than
a workaround for GKE binding kube-proxy metrics to an unscrapable `127.0.0.1:10249`.

**Control-plane scrapes are disabled** for scheduler, controller-manager, and etcd in
[helm/kube-prometheus-stack/values.yaml](helm/kube-prometheus-stack/values.yaml). These are
Google-managed with no reachable endpoint; left enabled the stack fires `KubeSchedulerDown`,
`KubeControllerManagerDown`, and `etcdMembersDown` within minutes and never stops. `coreDns` is
off and `kubeDns` on because GKE runs kube-dns.

**The five `...NilUsesHelmValues: false` lines** are what make the stack extensible. The chart
default of `true` means "with no selector set, match only objects carrying *this release's* Helm
labels" — so a ServiceMonitor from any other release is silently ignored. Setting them false
renders the selectors as `{}`, matching every namespace, which is why podinfo is discovered
with no change to the monitoring release.

**CRDs are applied server-side.** Helm installs CRDs on first install only and never upgrades
them. These total ~4.4 MB with the largest single file ~814 KB, far past the 262 KB
`last-applied-configuration` annotation limit that client-side apply would hit. `Deploy-Monitoring.ps1`
pulls the chart at the pinned version and runs `kubectl apply --server-side --force-conflicts`,
then installs with `--skip-crds`.

**No committed credentials.** `values.yaml` uses `admin.existingSecret: grafana-admin` rather
than `adminPassword`. The Secret is generated by `Bootstrap-Secrets.ps1` from a CSPRNG and
printed once; it is written to no file in this repo.

**Alerting is inert by design.** The ~100 built-in kubernetes-mixin rules evaluate and collect in
the Alertmanager UI, but no receiver is configured — so you can see what *would* have paged
before committing to a channel, and no webhook secret goes near the repo.

---

## Versions

Pinned deliberately; all current stable as of 2026-08-25, none deprecated or end-of-life.

| Component | Pinned | Where |
|---|---|---|
| Terraform | `>= 1.15.0` | [terraform/versions.tf](terraform/versions.tf) |
| `hashicorp/google` | `~> 7.45` | [terraform/versions.tf](terraform/versions.tf) |
| Helm CLI | 4.x enforced at runtime | [scripts/Deploy-Monitoring.ps1](scripts/Deploy-Monitoring.ps1) |
| `kube-prometheus-stack` | `88.5.4` (operator `v0.93.1`) | [helm/kube-prometheus-stack/VERSION](helm/kube-prometheus-stack/VERSION) |
| ├ grafana subchart | 12.11.2 | bundled |
| ├ prometheus-node-exporter | 4.56.1 | bundled |
| └ kube-state-metrics | 8.4.0 | bundled |
| `podinfo` | `6.14.1` | [helm/podinfo/VERSION](helm/podinfo/VERSION) |
| GKE | `REGULAR` channel, unpinned | [terraform/cluster.tf](terraform/cluster.tf) |

GKE is tracked by release channel rather than a pinned `min_master_version`, which would go
stale and eventually fall out of support.

Helm 3 is deliberately avoided: it reaches end of life in November 2026, with security fixes
ending February 2027. The deploy script uses the Helm 4 spelling `--rollback-on-failure` (Helm 3's
`--atomic` was renamed).

---

## Layout

```
terraform/
  bootstrap/       GCS state bucket (local state, run once)
  cluster.tf       GKE Standard, zonal, GMP disabled, Dataplane V2
  network.tf       VPC, secondary ranges, Cloud NAT
  nodepool.tf      3x e2-standard-2 Spot, 50GiB pd-balanced
helm/
  kube-prometheus-stack/   values.yaml + VERSION
  podinfo/                 values.yaml + VERSION
dashboards/
  podinfo-red.json         RED dashboard, imported by the Grafana sidecar
scripts/
  Bootstrap-Secrets.ps1    Grafana admin Secret
  Deploy-Monitoring.ps1    CRDs server-side, then the release
  Deploy-Podinfo.ps1       demo workload + dashboard ConfigMap
  Generate-Load.ps1        -Latency / -Errors / -Panic
  Connect-Grafana.ps1      port-forwards
  Teardown.ps1             ordered destroy, orphan-disk check
```
