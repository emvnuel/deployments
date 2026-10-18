# kube-prometheus-stack Runbook (k3s + OCI)

Operational notes for the monitoring stack managed by
`argocd/apps/kube-prometheus-stack.yaml` → `platform/kube-prometheus-stack/`.

---

## 1) Quick triage

```bash
# Active targets (up/down + last error) via API server proxy
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active" \
  | python3 -c 'import json,sys; [print(t["labels"].get("job"), t["labels"].get("instance"), t["health"], t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"]]'

# Firing alerts
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts" \
  | python3 -c 'import json,sys; [print(a["labels"].get("alertname"), a["state"]) for a in json.load(sys.stdin)["data"]["alerts"]]'
```

---

## 2) node-exporter `TargetDown` on some nodes (OCI VCN firewall)

**Symptom:** `TargetDown{job="node-exporter"}` for everything except the node
running Prometheus; the node-exporter pods themselves are `Running` and respond
on `127.0.0.1:9100`.

**Root cause:** the OCI VCN security list / NSG blocks TCP **9100** between
instances. Local scrapes work, cross-node SYNs never arrive (verified with
tcpdump on both sides). Kubelet 10250 is allowed, which is why it misleads.

**Fix (preferred):** allow ingress `TCP 9100` for the node subnet
(`10.0.0.0/24`) in the VCN security list attached to the instances.

**Alternative workaround (in-cluster):** set
`prometheus-node-exporter.hostNetwork: false` in `values.yaml` so Prometheus
scrapes pod IPs over the CNI instead of host IPs.

Master node never runs node-exporter: the chart affinity intentionally excludes
`control-plane`/`master` nodes.

---

## 3) Alertmanager → Telegram

The live Alertmanager config is **not** in git: it lives in the Secret
`alertmanager-telegram-config` (namespace `monitoring`), referenced by
`alertmanagerSpec.configSecret` + `useExistingSecret: true`.

- Template: `secrets.yaml.example` (this directory).
- Real file: `secrets.yaml` (same directory, gitignored by the root `.gitignore`).

```bash
cp secrets.yaml.example secrets.yaml   # fill bot_token + chat_id
kubectl apply -f platform/kube-prometheus-stack/secrets.yaml
# roll the pods to pick it up (the operator does it automatically; force with:)
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
```

The bot is the Hermes bot (`hermes-agent/hermes-agent-secrets` →
`TELEGRAM_BOT_TOKEN`); `chat_id` is the owner's user id
(`TELEGRAM_ALLOWED_USERS`), since a private chat's id equals the user id.

**Rotate the token:** update `hermes-agent-secrets` (bot needs no change),
refresh `secrets.yaml`, re-apply, then restart Alertmanager.

---

## 4) k3s control plane: disabled scrapes/alerts (on purpose)

k3s runs kube-controller-manager, kube-scheduler and kube-proxy inside the
`k3s server` process; their metrics endpoints are not exposed. The kube-prometheus-stack
default rules use `absent()`, so `KubeControllerManagerDown`, `KubeSchedulerDown`
and `KubeProxyDown` fired as **critical forever**.

`values.yaml` therefore disables `kubeControllerManager`, `kubeScheduler` and
`kubeProxy` (both the ServiceMonitors and the `defaultRules.rules.*` entries).
Do not re-enable them on k3s unless the endpoints are actually exposed.

---

## 5) ServiceMonitors for out-of-git components

cert-manager, ArgoCD and ingress-nginx are installed outside this repo but
expose Prometheus metrics. They are scraped via the wrapper's own
`extraServiceMonitors` (values.yaml, rendered by
`templates/servicemonitors.yaml` as individual objects — not the upstream
`additional*` keys, which emit `kind: List`):

| Component | Target | Notes |
|---|---|---|
| cert-manager (controller/cainjector/webhook) | Services `:9402` | port names differ per Service |
| ArgoCD (controller/server/repo/notifications/applicationset) | Services `:8082/:8083/:8084/:9001/:8080` | |
| ingress-nginx | Pod `:10254` | dedicated metrics Service + ServiceMonitor (`templates/ingress-nginx-metrics-service.yaml`), since no chart Service exposes 10254. ⚠️ needs `--enable-metrics=true` in the controller args (v1.12 default is `false`) — without it only Go/process metrics are exposed |

To scrape a new component: verify the endpoint from inside the Prometheus pod
first (`kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -S -qO- <url>`),
then add an entry. `kubectl get svc -n <ns> -o jsonpath='{range .spec.ports[*]}{.name}{"\n"}{end}'`
gives the exact port name.

---

## 6) Known gaps / follow-ups

> Deferred work and decisions are tracked in
> `docs/adr/0002-pendencias-monitoracao.md` (ADR 0002) — keep it updated when
> closing one of the items below.

- **App metrics:** no app exposes `/metrics` today (aside from Postgres/CNPG).
  `common-chart` supports an optional `serviceMonitor` block (v0.3.2) for when
  the apps start exposing one. n8n has it enabled (`N8N_METRICS=true`).
- **Grafana `grafana-admin` Secret** holds the literal password `admin`; the
  live Grafana ignores it because the admin account already exists in its DB.
  Rotate properly via `grafana cli admin reset-admin-password` and sync the
  Secret afterwards.
- **Node metrics for the master node** are missing by chart design (see §2).
