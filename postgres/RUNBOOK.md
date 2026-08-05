# Postgres CNPG Outage Recovery Runbook (Argo CD + K3s)

This runbook documents the exact incident pattern we hit and the recovery sequence that worked.

Use this when:
- `postgres.awesomeapps.cloud:5432` returns `connection refused`
- CNPG cluster is stuck in `Switchover`
- `postgres-cluster-rw` has no endpoints
- one CNPG instance is evicted or missing

---

## 1) Fast Triage

```bash
kubectl -n postgres get pods -o wide
kubectl -n postgres get svc,endpoints
kubectl -n postgres get cluster.postgresql.cnpg.io postgres-cluster -o jsonpath='{.status.currentPrimary}{"\n"}{.status.targetPrimary}{"\n"}{.status.phase}{"\n"}{.status.phaseReason}{"\n"}{.status.instancesStatus}{"\n"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
kubectl get node master -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{.reason}{"\n"}{end}{"taints="}{.spec.taints}{"\n"}'
```

Expected bad state during this incident:
- `postgres-cluster-rw` endpoint empty
- CNPG `phase=Switchover`, `Ready=False`
- `master` had `DiskPressure=True`

---

## 2) Stop Control-Plane Churn First

### 2.1 Pause Argo auto-sync (temporary)

```bash
kubectl -n argocd patch application postgres-cluster --type=json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

### 2.2 Suspend ScheduledBackups (temporary)

```bash
kubectl -n postgres patch scheduledbackup.postgresql.cnpg.io postgres-daily-backup --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n postgres patch scheduledbackup.postgresql.cnpg.io postgres-weekly-backup --type=merge -p '{"spec":{"suspend":true}}'
```

### 2.3 Delete pending backup CRs

```bash
kubectl -n postgres get backup.postgresql.cnpg.io
kubectl -n postgres delete backup.postgresql.cnpg.io --all
```

---

## 3) Fix Node Pressure (Root Trigger)

The primary PVCs were node-affined to `master`. While `master` had disk pressure, primary could not stabilize.

SSH to master and free space:

```bash
ssh ubuntu@140.238.191.33
sudo journalctl --disk-usage
sudo journalctl --vacuum-size=300M
df -h /
sudo systemctl restart k3s
```

Re-check:

```bash
kubectl get node master -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{.reason}{"\n"}{end}{"taints="}{.spec.taints}{"\n"}'
```

Target:
- `DiskPressure=False`
- no `node.kubernetes.io/disk-pressure` taint

---

## 4) Unstick CNPG Switchover Loop

If cluster is still deadlocked (`both instances not ready`, `rw` empty), force primary intent:

```bash
kubectl -n postgres patch cluster.postgresql.cnpg.io postgres-cluster --subresource=status --type=merge -p '{"status":{"currentPrimary":"postgres-cluster-2","targetPrimary":"postgres-cluster-2","phase":"Switchover","phaseReason":"Force bootstrap primary postgres-cluster-2"}}'
```

If an instance is hard-stuck/corrupted, remove the broken replica resources and let CNPG rebuild.

In our incident, `postgres-cluster-1` was broken and had to be removed completely:

```bash
kubectl -n postgres delete pod postgres-cluster-1 --wait=false
kubectl -n postgres delete pvc postgres-cluster-1 postgres-cluster-1-wal
```

If PVC is stuck in `Terminating`:

```bash
kubectl -n postgres patch pvc postgres-cluster-1 --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n postgres patch pvc postgres-cluster-1-wal --type=merge -p '{"metadata":{"finalizers":[]}}'
```

---

## 5) Validate Recovery

```bash
kubectl -n postgres get pods -o wide
kubectl -n postgres get svc,endpoints
kubectl -n postgres get cluster.postgresql.cnpg.io postgres-cluster -o jsonpath='{.status.phase}{"\n"}{.status.phaseReason}{"\n"}{.status.currentPrimary}{"\n"}{.status.instancesStatus}{"\n"}'
```

Critical success signal:
- `endpoints/postgres-cluster-rw` contains at least one IP:5432

In-cluster connectivity check:

```bash
kubectl -n postgres run psql-check --image=ghcr.io/cloudnative-pg/postgresql:16.2 --restart=Never --command -- sh -c 'timeout 8 pg_isready -h postgres-cluster-rw -p 5432 -U postgres || true'
kubectl -n postgres logs psql-check
kubectl -n postgres delete pod psql-check --ignore-not-found
```

Expected output:
- `postgres-cluster-rw:5432 - accepting connections`

This check is automated on a schedule by `monitoring/smoke-test.yaml` (CronJob + Probe), and covered by the `PostgresRwNoBackends`, `PostgresRwUnreachable` and `PostgresSmokeTestFailed` alerts.

---

## 6) Post-Incident Cleanup (Important)

### 6.1 Re-enable Argo auto-sync (after Git is corrected)

```bash
kubectl -n argocd patch application postgres-cluster --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### 6.2 Re-enable backups

```bash
kubectl -n postgres patch scheduledbackup.postgresql.cnpg.io postgres-daily-backup --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n postgres patch scheduledbackup.postgresql.cnpg.io postgres-weekly-backup --type=merge -p '{"spec":{"suspend":false}}'
```

### 6.3 Fix backup credentials and destination

During incident we used temporary/dummy backup credentials to unblock control loops.
Replace with real values and validate S3 access, otherwise CNPG logs keep showing `HeadBucket 403`.

---

## 7) Prevention Checklist

- Ensure `master` has enough free disk and alert on `DiskPressure`
- Avoid local-path PV for primary database in production (node pinning risk)
- Keep backup credentials valid and tested
- Keep ScheduledBackup cron definitions explicit and reviewed
- Keep a tested CNPG failover procedure documented and rehearsed

---

## 8) One-Command Health Snapshot

```bash
kubectl -n postgres get pods -o wide && \
kubectl -n postgres get svc,endpoints && \
kubectl -n postgres get cluster.postgresql.cnpg.io postgres-cluster -o jsonpath='{.status.phase}{"\n"}{.status.currentPrimary}{"\n"}{.status.instancesStatus}{"\n"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
```

---

## 9) Root Cause & Prevention Chain

The root cause was a chain: broken S3 backup creds → WAL never archived → disk filled → DiskPressure taint → cluster frozen. Prevent at each link:

1. **Fix the actual trigger — valid backups (highest priority)**
   - Replace the placeholder `s3://your-bucket-name/` + dummy creds with a real bucket (`cluster/postgres-cluster.yaml`, `backup/backup-secrets.yaml`). This is why ContinuousArchiving is still failing.
   - Alert when CNPG's ContinuousArchiving condition turns False (`CnpgWalArchivingFailing` — see `monitoring/prometheus-rules.yaml`).
   - Alert on pg_wal volume usage (`PostgresWalVolumeHigh`). 80% → warn, 90% → page.

2. **Alert on disk pressure before it taints**
   - Node DiskPressure=True is a kubelet-level eviction signal that arrives late. Watch node free-space directly (`NodeDiskPressureSoon` / `NodeDiskPressureCritical`), alert at ~75–80%, not kubelet's default ~85–90%.

3. **Avoid local-path PV for production DBs**
   - local-path PVs pin data to one node (master) — one full disk kills the whole cluster. Move to a real network storage class (Longhorn, Rook-Ceph, NFS, or a managed CSI).
   - If you must stay on local-path, at minimum size walStorage with headroom and set archive_mode so WAL rotates instead of piling up.

4. **Make WAL overflow survivable**
   - Fix archiving (fixes the pile-up at the source).
   - Consider reducing max_connections/workload churn — a 37M DB generated 38G of WAL, so a checkpoint/wal tuning review helps.
   - Keep a retry/backoff alerting on archive_command failures (currently silent while failing for months).

5. **Control-plane hygiene**
   - Re-enable Argo auto-sync only after Git matches reality (it was pushing `instances: 2` against a 1-instance live cluster — the operator kept reconciling a dead replica).
   - Runbook smoke test (`monitoring/smoke-test.yaml`) runs pg_isready + endpoints non-empty on a schedule so this is caught in minutes, not weeks.
