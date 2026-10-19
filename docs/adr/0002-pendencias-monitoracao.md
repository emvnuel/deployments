# ADR 0002 — Pendências da cobertura de monitoramento

Status: aberto — decisões registradas em 2026-10-18; implementação faseada (ver §7 "Ordem sugerida")
Data: 2026-10-18
Contexto: cluster k3s 4 nós (OCI) + ArgoCD + kube-prometheus-stack em `platform/kube-prometheus-stack`;
sessão de troubleshooting em 2026-10-18 (commits `cfe29a5..ed93afc`) fechou os problemas de
infraestrutura; este ADR registra o que **ainda falta** para a cobertura de métricas de aplicação
e melhorias de plataforma, para implementação futura.

## 1. Estado atual (verificado em 2026-10-18)

O que já está coberto e funcionando:

| Área | Cobertura |
|---|---|
| Nós (CPU/mem/disco/rede) | `node-exporter` 3/3 (TCP 9100 liberado na VCN; master excluído por design) |
| Containers/pods de **todas** as namespaces | kubelet/cAdvisor + kube-state-metrics |
| API server, kubelet, coredns, kube-state-metrics, operator | ServiceMonitors do stack (`job` próprios) |
| Postgres (CNPG) | PodMonitor `postgres/postgres-cluster` (instances + pooler) + dashboard + PrometheusRule |
| cert-manager, ArgoCD, ingress-nginx | ServiceMonitors/PodMonitor extras (`extraServiceMonitors` no values) |
| n8n | `N8N_METRICS=true` + ServiceMonitor próprio (`apps/n8n/templates/servicemonitor.yaml`) |
| Alertas | Alertmanager → **Telegram** (`secrets.yaml` gitignored; bot do Hermes) — 9 envios, 0 falhas |
| False positives k3s | `kubeProxy`/`kubeScheduler`/`kubeControllerManager` desabilitados (regras + SMs) |
| Capacidade do wrapper | `common-chart` v0.3.2 com bloco `serviceMonitor` opcional |

Total de alvos ativos: 40/40 `up` (2026-10-18T22:50 UTC).

## 2. P1 — Métricas de aplicação (nenhuma app expõe `/metrics` hoje)

### 2.1 payroll (Go/Gin, `myawesomeapps/payroll:3.0`)

- **Evidência:** `/actuator`, `/actuator/prometheus` e `/q/metrics` → HTTP 404; os logs mostram
  `[GIN] ... 404` — a app é **Go (Gin)**, não Spring Boot (corrigido em 2026-10-18, durante a
  implementação da stack de logs).
- **Implementação:**
  1. na imagem: expor `/metrics` com `promhttp.Handler()` (`prometheus/client_golang`);
     opcionalmente o middleware `go-gin-prometheus` para métricas por rota;
  2. no chart: subir a dependência `common-chart` para `>=0.3.2` (`apps/payroll/Chart.yaml`) e habilitar
     `common-chart.serviceMonitor.enabled: true`.
- **Aceite:** `up{job=~".*payroll.*"} == 1` e séries `go_*`/`http_*` presentes.

### 2.2 sistema-estoque (Java/Tomcat `:1.0` + MySQL `:1.1`)

- **Evidência:** `/actuator` 404 e os logs são do **Tomcat clássico** (`org.apache.catalina...`,
  formato JULI `dd-Mon-yyyy HH:mm:ss.SSS`) — é uma WAR sobre Tomcat, não Spring Boot (corrigido em
  2026-10-18). MySQL só tem métricas de container (cAdvisor).
- **Implementação:**
  1. app (Java/Tomcat): anexar o `jmx_exporter` da Prometheus como javaagent (`JAVA_OPTS`,
     expondo `:9404` com um config de Tomcat/JVM) e criar `port: metrics` no Service +
     `serviceMonitor` do common-chart; alternativa mais invasiva: micrometer na WAR;
  2. MySQL: adicionar `mysqld-exporter` — opções:
     - (a) **sidecar** no pod do `mysql-chart` (`apps/sistema-estoque/charts/mysql-chart`) com
       `MYSQLD_EXPORTER_PASSWORD` vindo de Secret existente (mais barato, porém acopla ao pod do banco);
     - (b) Deployment separado + ServiceMonitor (mais isolado, mais recursos).
     Recomendação: (a) com usuário `exporter` de menor privilégio (evitar o root do banco).
- **Aceite:** `mysql_up == 1` + target `mysql` up; séries `jvm_*`/`tomcat_*` via jmx_exporter.

### 2.3 hermes-agent

- **Evidência:** `/metrics` no :9119 → 302 para `/login` (é o dashboard, não métricas). Não há endpoint Prometheus.
- **Decisão proposta:** aceitar cobertura apenas de container (cAdvisor/ksm: CPU, mem, restarts,
  `KubePodNotReady`). Não escrever exporter próprio. Reabrir se o upstream expuser métricas.

### 2.4 Frontends nginx (`landing-page`, `personal-landing-page`, `payroll-front`)

- **Evidência:** sem `stub_status`; `/metrics` devolve HTML/404.
- **Opções:**
  - (a) `nginx-prometheus-exporter` como sidecar + habilitar `stub_status` na config de cada imagem;
  - (b) **recomendada**: confiar em ingress-nginx (após §3) + cAdvisor + kube-state-metrics —
    cobre latência/status HTTP por host no ingress e recursos por container;
  - (c) service mesh — fora de escopo.
- **Aceite:** nenhum (decisão: item (b); reavaliar por necessidade real).

### 2.5 copilot-api

- **Evidência:** `/metrics` → **401** (auth obrigatória; `API_KEY` no env do pod). Não se sabe se o
  payload é formato Prometheus.
- **Ação:** investigar com o header esperado (valor do Secret, sem colocar no git).
  Se for Prometheus: criar Secret de scrape e ServiceMonitor com `authorization`/`bearerTokenSecret`
  (o operator suporta). Se não for: encerrar o item documentando.

### 2.6 external-dns (namespace `default`)

- **Evidência:** métricas Prometheus OK em `podIP:7979` (`external_dns_controller_last_sync_timestamp_seconds`
  etc.), **mas** o Service `external-dns` está **sem endpoints**:
  - selector do Service usa `app.kubernetes.io/name=external-dns`, o pod só tem `app=external-dns`;
  - `targetPort: http` (nomeado) não existe no container (sem `ports` declaradas).
- **Opções:**
  - (a) corrigir o manifest de instalação (fora do repo): labels do pod + `containerPort http=7979`,
    depois ServiceMonitor padrão;
  - (b) Service `external-dns-metrics` no `default` com `targetPort: 7979` numérico (mesmo padrão usado
    para o ingress-nginx) + entrada em `extraServiceMonitors`.
- **Aceite:** `external_dns_controller_last_sync_timestamp_seconds` coletado.

## 3. P2 — ingress-nginx: `--enable-metrics=true`

- **Evidência:** no source da v1.12.2, `flags.Bool("enable-metrics", false, ...)`
  (`pkg/flags/flags.go:177`); o DaemonSet não passa a flag → só vêm métricas Go/process (48 samples/pod),
  **zero** `nginx_ingress_controller_*`.
- **Situação:** o scrape já está pronto (`extraServiceMonitors` → Service `ingress-nginx-controller-metrics`
  em `templates/ingress-nginx-metrics-service.yaml`); 4/4 alvos `up`.
- **Implementação:** adicionar `--enable-metrics=true` aos args do controller no manifest de instalação
  do ingress-nginx (fora deste repo) e reiniciar o DaemonSet.
- **Aceite:** `count({__name__=~"nginx_ingress_controller.*"}) > 0` e dashboards de ingress com latência/status.

## 4. P3 — Plataforma e operação

### 4.1 Upgrade do kube-prometheus-stack

- Hoje: chart **57.2.0**, Prometheus **v2.51.0**, Alertmanager 0.27 (herdado de 2024).
- Sintoma no log do Prometheus: `v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice`
  (cluster já em k8s **1.36**).
- Plano: PR dedicado com bump do chart (checar mudanças de values: `alertmanagerSpec`, subchart
  `prometheus-node-exporter`, CRDs do operator), `./scripts/verify-charts.sh`, e revisão das regras
  default reabilitáveis (alguns desligamentos por k3s permanecem).

### 4.2 Dead-man switch externo

- Hoje o `Watchdog` é roteado para o receiver `"null"`; se Prometheus/Alertmanager morrerem, **ninguém avisa**.
- Ação: rotear o `Watchdog` para um serviço externo (ex.: healthchecks.io) via webhook e configurar o alerta
  de ausência de ping. Aceite: parada simulada do Alertmanager gera notificação externa em ≤ 1h.

### 4.3 Rotação do admin do Grafana

**Status: concluído em 2026-10-18.**

- **Evidência (antes):** Secret `grafana-admin` com senha literal `admin`, divergente do banco live;
  Grafana ignora a env `GF_SECURITY_ADMIN_PASSWORD` após o primeiro boot.
- **Impacto descoberto na stack de logs:** o sidecar `grafana-sc-datasources` recarrega o
  provisioning via `/api/admin/provisioning/datasources/reload` usando as credenciais do Secret;
  com a divergência o reload retornava 401 (e o acúmulo de tentativas acionou o brute-force do
  Grafana) — por isso o datasource do Loki não aparecia. Ver `platform/loki/RUNBOOK.md` §5.
- **Executado:** `grafana cli admin reset-admin-password` (senha forte, atualizada no Secret
  `grafana-admin`, fora do git) + rollout do deployment; reload autenticado validado (200) e
  datasource inserido (`inserting datasource from configuration name=Loki`).

### 4.4 Retenção e capacidade

- Hoje 7d / 5GiB (`local-path`); ~127k séries antes das apps exporem métricas.
- Ação: após §2, monitorar `prometheus_tsdb_head_series` / uso do PVC; decidir entre ampliar o volume ou
  ajustar retenção. (Sem Thanos/multi-cluster — fora de escopo.)

### 4.5 Master sem node-exporter

- Exclusão **por design** (affinity do chart ignora `control-plane`/`master`). Decisão: manter.
  Se métricas de nó do master forem necessárias, aplicar overlay de affinity/toleration no values.

### 4.6 Drift do app postgres-cluster (fora do escopo, mas afeta confiança do "Synced")

- `postgres-cluster` segue `OutOfSync` por drift pré-existente (`CronJob postgres-smoke-test`,
  `CronJob postgres-wal-guard`, `Cluster`, `Probe postgres-cluster-rw` = `Unknown`, `ScheduledBackups`).
- Ação futura: revisar manifesto vs. live e decidir sync (a sessão de 2026-10-18 sincronizou **apenas** o
  ConfigMap do dashboard, via sync seletivo).

### 4.7 Dependências do common-chart nos apps

- Apps pinam `common-chart` 0.2.0/0.3.0; o bloco `serviceMonitor` exige `>=0.3.2`.
- Ao implementar §2.1/§2.2, subir a dependência por app (`Chart.yaml` + `helm dependency update`).

## 5. Não-objetivos (decididos agora)

- Exporters caseiros (hermes, frontends estáticos) — custo > benefício no momento.
- Service mesh / tracing distribuído / logs (Loki) — fora do escopo do Prometheus.
- Thanos/long-term storage e Alertmanager HA — cluster single-node de observabilidade é suficiente.

## 6. Como validar (comandos)

```bash
# alvos e erros
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active"
# alertas
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts"
# notificações Telegram (enviadas/falhas)
#   alertmanager_notifications_total / alertmanager_notifications_failed_total{integration="telegram"}
```

Detalhes operacionais (VCN 9100, Telegram, k3s, SMs extras): `platform/kube-prometheus-stack/RUNBOOK.md`.

## 7. Ordem sugerida de implementação

1. §3 ingress-nginx `--enable-metrics=true` (1 linha, destrava dashboards de ingress).
2. §2.1/§2.2 actuator + micrometer (+ mysqld-exporter) e `serviceMonitor` via common-chart 0.3.2.
3. §2.6 external-dns e §2.5 copilot-api (investigação).
4. §4.2 dead-man switch, §4.3 rotação Grafana, §4.1 upgrade do stack; §4.4/§4.6 conforme folga.
