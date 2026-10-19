# ADR 0003 — Logs centralizados com Loki + Grafana Alloy

Status: implementado em 2026-10-18 (charts `grafana/loki` 7.3.0 e `grafana/alloy` 1.13.1)
Data: 2026-10-18
Contexto: cluster k3s 4 nós (OCI) + ArgoCD; Grafana já existente (kube-prometheus-stack);
alertas de métricas já roteando para o Telegram (ver ADR 0002). Objetivo: coleta centralizada
de logs com GitOps, sem introduzir Elastic.

## 1. Decisão

- **Loki** (chart `grafana/loki` 7.3.0) em modo **SingleBinary**, 1 réplica, storage
  filesystem em PVC local-path (20Gi), retenção 14d via compactor.
- **Grafana Alloy** (chart `grafana/alloy` 1.13.1) como **DaemonSet** nos 4 nós:
  coleta logs de containers (`/var/log/pods`) de todos os namespaces e o **journald** do host.
- Integrações: datasource no Grafana existente; **Ruler → Alertmanager → Telegram** para
  alertas de log; canary do chart como teste end-to-end; dashboards oficiais do Loki.

## 2. Alternativas descartadas

- **Elastic/OpenSearch**: 2+ GiB só de JVM; operação pesada demais para 4 nós.
- **OCI Logging (cloud)**: acopla query/IAM à OCI, sai do GitOps e custa por ingestão.
- **Fluent Bit** como coletor: mais leve, porém fora do ecossistema Grafana (Alloy também é o
  sucessor oficial do Promtail, EOL 03/2026).
- **VictoriaLogs**: single-binary ainda mais econômico, mas exige plugin no Grafana e tem
  ecossistema menor (mantido como plano B).

## 3. Decisões de implementação (com as armadilhas encontradas)

1. **Tenant "fake"**: com `auth_enabled=false`, o rulestore local do Loki exige a subpasta do
   tenant; o sidecar de regras do chart foi apontado para `/rules/fake` (folder=/rules/fake).
2. **Template `loki-rules`** (ConfigMap com label `loki_rule=1`) → sidecar `loki-sc-rules`
   copia para `/rules/fake/` → Ruler avalia → Alertmanager (mesma rota Telegram já existente).
3. **Journald leu 0 linhas — causa raiz**: a imagem do Alloy tem `/etc/machine-id` **vazio** e
   o `sd_journal_open` usa o machine-id local para localizar o journal do host. Correção:
   initContainer `fix-machine-id` descobre o ID do nó (diretório do journal que contém
   `system.journal`), grava num emptyDir montado por cima de `/etc/machine-id`; o componente usa
   `path = "/var/log/journal"`. (Comportamento sem o fix era inconsistente: em alguns nós o
   `open_directory` achava os arquivos, no node-2 não — 0 linhas.)
4. **Prefixo CRI**: `loki.source.file` entrega linhas com o cabeçalho CRI do kubelet
   (`<timestamp> stdout F ...`). O pipeline tem `stage.cri {}` **antes** do multiline.
5. **Multiline escopado**: o estágio multiline (formato JULI do Tomcat) vale apenas para o
   container `sistema-estoque` — o container MySQL do mesmo namespace usa prefixo ISO e não
   deve ser agrupado.
6. **Sidecar OOMKill**: `loki-sc-rules` com limit de 64Mi (restart loop, regras não copiadas);
   subiu para 256Mi e `RESOURCE=configmap` (secrets não são usados).
7. **Phantom diff do StatefulSet**: com `ServerSideApply=true`, o STS do Loki ficava
   permanentemente `OutOfSync` (defaults do k8s + `status` do volumeClaimTemplate,
   argo-cd#11143). Correção: annotation `argocd.argoproj.io/compare-options: ServerSideDiff=true`
   na Application `loki`.
8. **Posições persistentes**: Alloy grava as posições de leitura em hostPath `/var/lib/alloy`
   (sem isso, cada restart re-ingere todos os arquivos de log).
9. **Caches/memcached desligados** (escala pequena) e gateway nginx do chart mantido como
   endpoint único de push/query.

## 4. Consequências

- ✅ Logs sobrevivem a restart/OOM de pods (o kubelet descarta arquivos antigos; o Loki mantém).
- ✅ Histórico consultável no Grafana (Explore + dashboard Loki logs) e alertas de log no
  Telegram, sem stack nova de observabilidade.
- ✅ 14 dias de retenção; PVC de 20Gi com folga confortável ao volume atual.
- ⚠️ local-path = sem HA; perda se o nó do volume falhar (mesmo trade-off do Prometheus).
  Próximo passo natural: backend S3 (OCI Object Storage), muda só o values.
- ⚠️ O maior volume vem dos access logs do ingress (bots); filtros/limites podem ser
  adicionados depois (ex.: descartar 404 de scanners).
- ⚠️ Conferir com atenção ao editar valores: `rulerConfig` (não `ruler`) é a chave do config do
  ruler no chart 7.x; `sidecar.resources` pequeno demais derruba o sidecar por OOM.

## 5. Validação (2026-10-18)

- [x] Apps `loki` e `alloy` `Synced/Healthy`; 49/49 targets do Prometheus `up`
      (inclui SM do Loki, do Alloy e das 4 réplicas do canary)
- [x] Journald coletando nos **4 nós** (`{node=~".+"}` no Loki; métrica
      `loki_source_journal_target_lines_total` > 0 em cada pod do Alloy)
- [x] Regras carregadas no Ruler (`/prometheus/api/v1/rules` → grupo `logs`, alerta `LogErrorsHigh`)
- [x] Datasource Loki provisionado no Grafana (`kube-prometheus-stack-grafana-datasource`)
      e dashboards oficiais do Loki provisionados (sidecar `searchNamespace: ALL`)
- [x] Prefixo CRI removido (linhas limpas no Explore); multiline do Tomcat escopado
- [x] Sidecar de regras sem restarts; `LogErrorsHigh` no formato do Alertmanager (v2)
- [x] Ingestão inicial (~272k linhas de arquivos + journald) concluída sem impacto nos nós

## 6. Adendo (2026-10-19) — Events, filtros de ruído e alertas

- **Kubernetes Events** adicionados (`loki.source.kubernetes_events` →
  `{job="kubernetes-events"}`; validado com pod de teste: events chegam, e o
  contador `events_non_owner_node` cresce nos agentes). A distribuição nativa
  via `clustering` do componente **não é confiável** na Alloy v1.20.1: o
  memberlist formava (métricas `cluster_node_peers`/`gossip_alive_peers` = 4) e
  mesmo assim **todos** os nós assistiam tudo (Lookup do ckit falhava-aberto →
  duplicados ×nós). Solução determinística: todos assistem (watch é barato),
  e o pipeline descarta as cópias dos agentes
  (`stage.match { selector = "{node=~\".+\", node!=\"master\"}" }`).
  Clustering global do Alloy revertido (nenhum componente o usa agora).
  ⚠️ `stage.drop` com `source` só lê dados **extraídos** — para casar labels,
  `stage.match` é o mecanismo correto.
- **Filtro de ruído do journald**: drops de `apparmor_audit` (audits do kernel)
  e `sshd_preauth_noise` (desconexões de SSH de bots, padrão `[preauth]`).
  "Failed password" preservado (brute-force). Contadores em
  `loki_process_dropped_lines_total{reason=...}`.
- **Alertas do Loki**: regras oficiais do chart habilitadas (`monitoring.rules`
  → `LokiRequestErrors/Panics/Latency`, `LokiCanaryLatency`,
  `LokiTooManyCompactorsRunning`) + `LokiDiskUsageHigh` (nosso
  `templates/prometheus-rule.yaml`: disco do PVC > 85% por 30m; local-path
  reflete o filesystem do nó).
