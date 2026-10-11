# Argo CD UI "cache: key is missing" Recovery Runbook (K3s + Redis)

This runbook documents the exact failure pattern we hit after cluster maintenance and the recovery sequence that worked.

Use this when:
- Argo CD UI shows `Unable to load data: error getting cached app managed resources: cache: key is missing` when clicking any resource (Service, Pod, Ingress, Deployment, ...)
- It happens for some applications but not others (or all, after a Redis restart)

---

## How the cache works (30 seconds)

- `argocd-redis` is a **pure cache** (no persistence). The password lives in secret `argocd/argocd-redis` (key `auth`).
- `app|managed-resources|<app>|<cache-version>.gz` is **written by `argocd-application-controller`** during its reconciliation cycles (~2 min) and **read by `argocd-server`** when the UI opens a resource panel. TTL is ~1h and is renewed by the controller.
- Same pattern for `app|resources-tree|...` (UI tree) and `mfst|...` (manifests, written by repo-server).
- Wiping Redis is **safe** — everything rebuilds. The failure below is a **controller <-> Redis write race**, not data loss.

---

## 1) Fast Triage

```bash
# Which apps are erroring (server side)
kubectl -n argocd logs deploy/argocd-server --since=10m | grep "key is missing"

# Which apps are missing their managed-resources key in Redis
PASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
HAVE=$(kubectl -n argocd exec deploy/argocd-redis -- sh -c "redis-cli -a '$PASS' --no-auth-warning --scan --pattern 'app|managed-resources|*'" 2>/dev/null | sed -E 's/^app\|managed-resources\|([^|]+)\|.*/\1/' | sort -u)
for app in $(kubectl -n argocd get applications -o name | cut -d/ -f2 | sort); do
  echo "$HAVE" | grep -qx "$app" && echo "OK      $app" || echo "MISSING $app"
done
```

Raw key listing (quick look):

```bash
kubectl -n argocd exec deploy/argocd-redis -- sh -c "redis-cli -a '$PASS' --no-auth-warning keys 'app|managed-resources|*'"
```

Optional live forensics (see the controller write behavior in real time):

```bash
PASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
# terminal 1 (30s capture):
kubectl -n argocd exec deploy/argocd-redis -- sh -c "timeout 30 redis-cli -a '$PASS' --no-auth-warning monitor" | grep -E "managed-resources"
# terminal 2 (trigger a refresh while capturing):
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
# symptom in this incident: a "publish" (cache invalidation) with no corresponding "set"
```

Expected bad state during this incident:
- Some apps `MISSING` (the ones the UI fails on)
- `argocd-redis` and/or `argocd-application-controller` recently restarted (node drains, k3s upgrades, evictions)

---

## 2) Fix (lightest first)

### 2.1 Hard refresh the affected apps

```bash
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
```

All apps at once:

```bash
for app in $(kubectl -n argocd get applications -o name | cut -d/ -f2); do
  kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite
done
```

The annotation is consumed automatically by the controller. Wait ~1-2 minutes and re-run the checker from section 1.

### 2.2 If keys are still missing: restart the application-controller

```bash
kubectl -n argocd rollout restart statefulset argocd-application-controller
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=240s
```

Wait ~1-2 minutes, re-run the checker, and hard-refresh any app still `MISSING`.

### 2.3 Last resort: flush Redis (safe - cache only)

```bash
PASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
kubectl -n argocd exec deploy/argocd-redis -- redis-cli -a "$PASS" --no-auth-warning flushall
kubectl -n argocd rollout restart statefulset argocd-application-controller
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=240s
# then hard refresh all apps (2.1) and re-check
```

Expect a few minutes of degraded Argo CD performance while caches rebuild. No persistent data is lost.

---

## 3) Validate Recovery

```bash
# 1. every app has its managed-resources key (checker from section 1)

# 2. fresh UI reads return OK:
kubectl -n argocd logs deploy/argocd-server --since=10m | grep ManagedResources | grep '"grpc.code":"OK"' | tail -5

# 3. no new errors:
kubectl -n argocd logs deploy/argocd-server --since=10m | grep -c "key is missing"
```

- Open a resource panel in the UI (hard reload the browser first: Cmd/Ctrl+Shift+R).
- Critical success signal: the panel loads and `"grpc.code":"OK"` appears in the server log for that call.

---

## 4) Root Cause & Prevention

The chain (observed 2026-10-11 during the k3s v1.32.4 -> v1.36.5 rolling upgrade):

1. Node maintenance restarts `argocd-redis` (empty cache) and `argocd-application-controller` in the same window.
2. For some apps the controller published the cache invalidation but did **not** rewrite the `app|managed-resources|*` key (`redis-cli monitor` evidence: `publish` without `set`). Those apps did not self-heal until an explicit hard refresh.
3. `argocd-server` reads the missing key -> UI error on every resource click for that app.

Prevention:

- Treat this as **expected post-maintenance hygiene**: after any maintenance that restarts `argocd-redis` and/or `argocd-application-controller`, run the checker and hard-refresh the `MISSING` apps (one-command snapshot below).
- A Redis restart alone is harmless. The race needs both restarts nearby — no action needed upfront, just run the hygiene step at the end of maintenance.
- Do not delete/recreate the `argocd-redis` secret (it holds the stable cache password).
- The cache-key format includes a version suffix (observed `1.8.3.gz` on Argo CD v3.0.1) — always use the wildcard pattern `app|managed-resources|*` in checks, never the literal suffix.

---

## 5) One-Command Health Snapshot

```bash
kubectl -n argocd get pods -o wide && \
PASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d) && \
HAVE=$(kubectl -n argocd exec deploy/argocd-redis -- sh -c "redis-cli -a '$PASS' --no-auth-warning --scan --pattern 'app|managed-resources|*'" 2>/dev/null | sed -E 's/^app\|managed-resources\|([^|]+)\|.*/\1/' | sort -u) && \
for app in $(kubectl -n argocd get applications -o name | cut -d/ -f2 | sort); do \
  echo "$HAVE" | grep -qx "$app" && echo "OK      $app" || echo "MISSING $app"; \
done
```

---

## 6) Incident History

- **2026-10-11** — during the k3s v1.32.4 -> v1.36.5 zero-downtime rolling upgrade, Redis and the application-controller restarted multiple times. Three apps were left without their managed-resources key: `copilot-api`, `headlamp`, `personal-landing-page`. Symptom: `Unable to load data: error getting cached app managed resources: cache: key is missing` on any resource click. Forensics with `redis-cli monitor` showed `publish` without `set` for `copilot-api`. Recovery: hard refresh of the affected apps + application-controller restart; validated with a UI click returning `"grpc.code":"OK"` at 20:34:35Z.
