# RUNBOOK — Stack de logs (Loki + Alloy)

Coleta centralizada de logs: **Grafana Alloy** (DaemonSet, 4 nós) → **Loki** (single
binary, PVC local-path) → **Grafana** (Explore/dashboards) e **Alertmanager → Telegram**
(alertas de log via Ruler).

Design e decisões: `docs/adr/0003-logs-centralizados.md`.

## 1) O que é coletado

- Logs de containers (`/var/log/pods`) de **todas** as namespaces.
- Journald dos 4 nós (k3s/control-plane no master, kubelet/containerd/systemd).
- **Kubernetes Events** (OOMKilled, FailedScheduling, erros de pull...) via
  `loki.source.kubernetes_events` → query `{job="kubernetes-events"}`.
  ⚠️ Só a cópia do nó `master` é ingerida — a duplicação cluster-wide é
  filtrada no pipeline (`events_non_owner_node`; ver §5).
- Filtros de ruído do journald (drops contados em
  `loki_process_dropped_lines_total`): `apparmor_audit` (audits do kernel/k3s) e
  `sshd_preauth_noise` (desconexões rotineiras de SSH de bots; "Failed
  password" **não** é filtrado — evidência de brute-force).

Labels das streams de pods: `namespace`, `pod`, `container`, `app` (de
`app.kubernetes.io/name`), `cluster=homelab`. Journald: `job=loki.source.journal.systemd`,
`node=<nó>`. Events: `job=kubernetes-events`, `namespace`, `node=master`.

## 2) Como consultar (LogQL)

Grafana → Explore → datasource **Loki**:

```logql
{namespace="payroll"} |= "error"
{app=~"n8n.*"} |~ "(?i)fail"
{job="loki.source.journal.systemd", node="master"} |= "k3s"
{container="sistema-estoque"} |~ "(?i)severe|exception"   # stack traces vêm agrupados (multiline)
{namespace="ingress-nginx"} |= " 500 "                    # status 5xx do ingress
{job="kubernetes-events"} |= "FailedScheduling"           # events do k8s (cluster-wide)
{job="kubernetes-events", namespace="payroll"}            # events de um namespace
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
- **Datasource Loki não aparece no Grafana:** o CM `kube-prometheus-stack-grafana-datasource`
  é aplicado pelo sidecar `grafana-sc-datasources`, que dispara o reload do provisioning via
  API admin do Grafana **com as credenciais do Secret `grafana-admin`**. Se a senha divergir do
  banco live, o reload retorna 401 e o datasource novo não entra (o Grafana lê datasources só
  no boot). Rotacionar conforme ADR 0002 §4.3 e forçar um evento (mudança no CM ou restart do
  deployment).
- **Events do k8s duplicados (ou sumindo):** Events são cluster-wide e TODAS as instâncias do
  Alloy os assistem — o pipeline descarta as cópias dos nós agentes
  (`stage.match` com `{node=~".+", node!="master"}` → motivo `events_non_owner_node`).
  - `stage.drop` com `source` só lê dados **extraídos** do parser — para casar **labels**
    (ex.: `node`), use `stage.match` com seletor.
  - Se um dia reativar `clustering` global + `clustering {}` no componente (a distribuição
    nativa se mostrou não confiável na v1.20.1 — Lookup fail-open, todos assistiam tudo),
    **remova o filtro** e valide que apenas um nó ingere; senão o "dono" pode ser um agente e
    o filtro descartaria TODOS os Events.
  - Se a convenção de nomes dos nós mudar (hoje `master` + `node-*`), ajustar o matcher.

## 6) Operação

- Upgrade: bump do chart em `platform/loki/Chart.yaml` / `platform/alloy/Chart.yaml` +
  `./scripts/verify-charts.sh` + PR/commit (ArgoCD reconcilia).
- Config do Alloy: `alloy.configMap.content` no values (linguagem River). Atenção: o chart
  adiciona `checksum/config` no template dos pods — mudanças de config **recriam os pods do
  DaemonSet** (o `config-reloader` também recarrega, mas o pod já sobe com a config nova).
- Alertas do Loki (avaliados pelo Prometheus → rota Telegram):
  - do chart (`monitoring.rules.enabled: true`): `LokiRequestErrors`, `LokiRequestPanics`,
    `LokiRequestLatency`, `LokiCanaryLatency`, `LokiTooManyCompactorsRunning`;
  - nossos (`templates/prometheus-rule.yaml`): `LokiDiskUsageHigh` — disco do PVC
    (`storage-loki-0`) > 85% por 30m (local-path: reflete o filesystem do nó).
- Dashboard do Loki: ConfigMaps `loki-dashboards-*` em `logging` (label `grafana_dashboard=1`);
  o sidecar do Grafana busca em todas as namespaces.
- Métricas internas: Alloy (`loki_source_*`, `loki_write_*`) e Loki (SM `logging/loki`) são
  coletadas pelo Prometheus.
