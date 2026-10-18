# RUNBOOK — Stack de logs (Loki + Alloy)

Coleta centralizada de logs: **Grafana Alloy** (DaemonSet, 4 nós) → **Loki** (single
binary, PVC local-path) → **Grafana** (Explore/dashboards) e **Alertmanager → Telegram**
(alertas de log via Ruler).

Design e decisões: `docs/adr/0003-logs-centralizados.md`.

## 1) O que é coletado

- Logs de containers (`/var/log/pods`) de **todas** as namespaces.
- Journald dos 4 nós (k3s/control-plane no master, kubelet/containerd/systemd).

Labels das streams de pods: `namespace`, `pod`, `container`, `app` (de
`app.kubernetes.io/name`), `cluster=homelab`. Journald: `job=loki.source.journal.systemd`,
`node=<nó>`.

## 2) Como consultar (LogQL)

Grafana → Explore → datasource **Loki**:

```logql
{namespace="payroll"} |= "error"
{app=~"n8n.*"} |~ "(?i)fail"
{job="loki.source.journal.systemd", node="master"} |= "k3s"
{container="sistema-estoque"} |~ "(?i)severe|exception"   # stack traces vêm agrupados (multiline)
{namespace="ingress-nginx"} |= " 500 "                    # status 5xx do ingress
```

Canary (teste end-to-end): `{pod=~"loki-canary.*"}` sempre tem linhas frescas.
Equivalente via API (sem Grafana): `http://loki-gateway.logging.svc.cluster.local`.

## 3) Retenção e storage

- Retenção: **14 dias** (`loki.limits_config.retention_period`) aplicada pelo compactor.
- PVC **20Gi** local-path (`storage-loki-0` em node-2). local-path = sem HA: se o nó do volume
  morrer, os logs se perdem (mesmo trade-off do Prometheus). Futuro: backend S3
  (OCI Object Storage) — muda só o values.
- Posições de leitura do Alloy: hostPath `/var/lib/alloy` por nó (sem isso o Alloy re-ingere
  tudo a cada restart).

## 4) Regras de alerta (Ruler)

- ConfigMap `loki-rules` (em `platform/loki/templates/loki-rules.yaml`) com label
  `loki_rule: "1"` → sidecar `loki-sc-rules` copia para `/rules/fake/` (tenant "fake", exigido
  pelo rulestore local com `auth_enabled=false`) → Ruler avalia → Alertmanager → Telegram.
- Conferir carregamento: `GET /prometheus/api/v1/rules` no Loki (porta 3100) — **não** é
  `/loki/api/v1/rules` (404).
- Regra atual: `LogErrorsHigh` (>25 linhas com error/exception/fatal em 10m, por namespace).

## 5) Troubleshooting (armadilhas já encontradas)

- **Journald com 0 linhas:** confira se o initContainer `fix-machine-id` rodou
  (`kubectl logs -n logging ds/alloy -c fix-machine-id`). A imagem do Alloy tem
  `/etc/machine-id` vazio e o `sd_journal` precisa dele para achar o journal do host.
- **Regras não carregam:** `kubectl exec -n logging loki-0 -c loki-sc-rules -- ls /rules/fake/`
  deve mostrar `logs.yaml`. Se o sidecar estiver `OOMKilled` (exit 137), aumente
  `loki.sidecar.resources`.
- **Linhas com prefixo `... stdout F`:** falta `stage.cri {}` no pipeline do Alloy.
- **STS do Loki `OutOfSync` eterno no ArgoCD:** é o phantom diff de `ServerSideApply` +
  `volumeClaimTemplates` (argo-cd#11143). A Application tem
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` — não remover.
- **Volume alto no primeiro deploy:** esperado — o Alloy lê os arquivos existentes desde o
  início (posições vazias). Depois da primeira leitura, só novas linhas.

## 6) Operação

- Upgrade: bump do chart em `platform/loki/Chart.yaml` / `platform/alloy/Chart.yaml` +
  `./scripts/verify-charts.sh` + PR/commit (ArgoCD reconcilia).
- Config do Alloy: `alloy.configMap.content` no values (linguagem River). Mudanças
  hot-reloadam via `config-reloader` (sem restart de pods).
- Dashboard do Loki: ConfigMaps `loki-dashboards-*` em `logging` (label `grafana_dashboard=1`);
  o sidecar do Grafana busca em todas as namespaces.
- Métricas internas: Alloy (`loki_source_*`, `loki_write_*`) e Loki (SM `logging/loki`) são
  coletadas pelo Prometheus.
