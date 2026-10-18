# ADR 0001 — Reorganização de diretórios do repo `deployments`

Status: proposto
Data: 2026-10-18
Contexto: repo ArgoCD + Helm (`emvnuel/deployments`), `common-chart` OCI `ghcr.io/emvnuel/charts`
Análise prévia: opencode `deepseek-v4.1-flash#max` em clone fresco (branch base `master@6edad4c`)

## 1. Diagnóstico (evidência no disco)

1. **Raiz flat com papéis misturados.** `common-chart/` (biblioteca), apps (`payroll/`, `n8n/`, `hermes-agent/`…),
   `postgres/` (YAML puro), `archived/` (morto), `argocd/` (só `RUNBOOK.md`), `scripts/`, `AGENTS.md` disputam a raiz.
   Sem `README.md` na raiz; `AGENTS.md` não diz onde criar app novo.
2. **Três padrões de "app" coexistindo.**
   - Wrapper Helm: `payroll/`, `n8n/`, `hermes-agent/`, `copilot-api/`, `landing-page/`, `personal-landing-page/`, `payroll-front/`, `sistema-estoque/` (Chart.yaml + Chart.lock + values.yaml).
   - Manifests crus: `postgres/` — 17 arquivos, sem Chart.yaml (sync como directory app, `directory.recurse`, `project: postgres`, `prune: false` — Application existia em `argocd-apps/postgres-application.yaml`, removido em `8ed4d60`).
   - Values-only sem Chart.yaml: `headlamp/values.yaml`, `kube-prometheus-stack/values.yaml`. Nenhum é validável por `helm template`, nenhum está no `verify-charts.sh`.
     O app kube-prometheus-stack consumia via multi-source `$values/...` + chart upstream `57.2.0`; headlamp usava values inline no Application (`8b5ab26`) — `headlamp/values.yaml` pode não estar consumido. **Validar no cluster:** `kubectl -n argocd get app headlamp -o yaml`, `kubectl -n argocd get app kube-prometheus-stack -o yaml`.
3. **Applications fora do git.** `AGENTS.md` manda criar manifest temporário, `kubectl apply` e apagar. Resultado: `copilot-api/application.yaml` removido em `de067eb`,
   `argocd-apps/{headlamp,postgres}-application.yaml` removidos em `8ed4d60`; hoje `argocd/` só tem `RUNBOOK.md`.
   Qualquer move de pasta exige caçar Application no cluster, sem revisão nem rollback.
4. **`sistema-estoque/` mistura Helm + build de imagem + vendor duplicado.** `charts/mysql-chart/` (fonte) + `charts/mysql-chart-0.1.1.tgz` (artefato) commitados juntos,
   apesar de `**/charts/*.tgz` no `.gitignore` (tgz commitado em `3e5960f`). `docker/mysql/Dockerfile` faz `COPY init.sql`, `docker/tomcat/Dockerfile` faz `COPY SistemaEstoque/`,
   mas o contexto está no `.gitignore` local — build quebrado num clone limpo. Localmente validado: `helm dependency build` regenera sem o `.tgz`.
5. **Docs stale + config morta.** `sistema-estoque/README.md` → `argocd-application.yaml` (inexistente); `postgres/README.md` → `argocd/project.yaml`, `argocd/application.yaml` (inexistentes);
   `postgres/SECRETS.md` → `postgres/argocd/...` (inexistente). `postgres/.argocdignore` (adicionado `3d4a79b`, "corrigido" `5d5b964`) não é feature do ArgoCD —
   o equivalente suportado é `spec.source.directory.exclude`. Verificado na doc stable + search de PRs do argo-cd.
6. **Verificação frágil e incompleta.** `scripts/verify-charts.sh` tem lista hardcoded (linha 16); `n8n`, `headlamp`, `kube-prometheus-stack`, `postgres` nunca renderizados.
   Único workflow é `publish-common-chart.yml` (push em `master` tocando `common-chart/**`); nada roda em PR.
7. **Segredo em claro.** `kube-prometheus-stack/values.yaml` tem `grafana.adminPassword: admin` — viola o próprio `AGENTS.md` ("Secrets are referenced, never created").
   `.gitignore` raiz tem paths por app (`copilot-api/secrets.yaml`, `hermes-agent/secrets.yaml`, `postgres/**/*-secrets.yaml`) — cada app inventa um path.

Bônus: `common-chart` em 0.2.0 (9 consumers) e 0.3.0 (`hermes-agent`) — pin por design, sem automação de bump.

## 2. Estrutura-alvo

```
deployments/
├── README.md                     # NOVO — mapa do repo
├── AGENTS.md
├── charts/
│   └── common-chart/             # move de common-chart/
├── apps/                         # 1 dir = 1 chart = 1 Application (path: apps/<nome>)
│   ├── copilot-api/ hermes-agent/ landing-page/ n8n/
│   ├── payroll/ payroll-front/ personal-landing-page/
│   └── sistema-estoque/          # + charts/mysql-chart/ (ou promovido — fase 4)
├── platform/
│   ├── postgres/                 # directory app, prune:false, project postgres
│   ├── kube-prometheus-stack/    # NOVO wrapper Chart.yaml + values aninhados
│   └── headlamp/                 # NOVO wrapper Chart.yaml + values aninhados
├── argocd/
│   ├── bootstrap/                # AppProjects + Application raiz (app-of-apps)
│   ├── apps/                     # 1 Application por app
│   └── RUNBOOK.md
├── archived/ (+ README.md explicando status)
├── docs/adr/
└── scripts/verify-charts.sh      # lista derivada via find, --archived opt-in
```

Convenção: **nome da pasta == `Chart.yaml: name` == `nameOverride`**.

## 3. O que mover (resumo)

| Antes | Depois | Notas |
|---|---|---|
| `common-chart/` | `charts/common-chart/` | `git mv` + bump 0.3.0→0.3.1 no mesmo commit (guard do workflow); atualizar workflow, script, README, AGENTS.md |
| `payroll/`, `payroll-front/`, `landing-page/`, `personal-landing-page/`, `copilot-api/`, `n8n/`, `hermes-agent/` | `apps/<mesmo nome>/` | `git mv` + `path:` da Application no mesmo commit |
| `sistema-estoque/` | `apps/sistema-estoque/` | + tratar `.tgz`, `docker/`, `mysql-chart` (fase 4) |
| `postgres/` | `platform/postgres/` | manter `project: postgres`; deletar `.argocdignore`, usar `directory.exclude` |
| `headlamp/values.yaml` | `platform/headlamp/{Chart.yaml,values.yaml}` | wrapper dep headlamp 0.39.0, aninhar values sob `headlamp:`; reconciliar com cluster antes |
| `kube-prometheus-stack/values.yaml` | `platform/kube-prometheus-stack/{Chart.yaml,values.yaml}` | wrapper dep upstream; trocar `adminPassword` por `grafana.admin.existingSecret` |
| `sistema-estoque/charts/mysql-chart/` | `charts/mysql-chart/` (OCI) | promover; consumer passa a `oci://ghcr.io/emvnuel/charts`; workflow vira matriz `charts/*` |
| `sistema-estoque/charts/mysql-chart-0.1.1.tgz` | deletar (após promoção ou após sync real sem ele) | validado localmente que regenera |
| `sistema-estoque/docker/` | remover (repo de imagens) | `COPY SistemaEstoque/` nunca versionado; imagem já publicada |
| `argocd/` | `argocd/{bootstrap/,apps/,RUNBOOK.md}` | estado GitOps (fase 1) |
| `scripts/verify-charts.sh` | lista derivada `find apps platform -name Chart.yaml` | incluir `n8n`/wrappers; `--archived` opt-in |
| `.gitignore` por app | globs `**/secrets.yaml`, `**/*-secrets.yaml` | editar no commit dos moves |

O que NÃO muda: `Chart.lock` dos consumers do common-chart (digest OCI não muda com move), nomes/objetos K8s. Reorg é 100% paths.

## 4. Plano de migração (para agente com cluster)

### Fase 0 — Baseline (sem mudar repo)
```bash
kubectl -n argocd get applications -o yaml > /tmp/apps-backup-$(date +%F).yaml
kubectl -n argocd get appprojects -o yaml > /tmp/projects-backup.yaml
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,PATH:.spec.source.path,REV:.spec.source.targetRevision
./scripts/verify-charts.sh
```
Anotar por app: `path`, tipo (helm/directory), `project`, `valueFiles`/inline, `prune`. Revela drifts (ex.: headlamp inline `awesomeapps.cloud` vs repo `gambiarra.space`).

### Fase 1 — Applications no git (app-of-apps, SEM mover nada)
```bash
mkdir -p argocd/apps argocd/bootstrap
for a in $(kubectl -n argocd get app -o name); do
  n=${a#application.argoproj.io/}
  kubectl -n argocd get "$a" -o yaml \
    | yq 'del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields)' \
    > argocd/apps/$n.yaml
done
```
Atenção: exportar AppProject `postgres`; decidir `resources-finalizer`; raiz:
```yaml
# argocd/bootstrap/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: root, namespace: argocd }
spec:
  project: default
  source: { repoURL: https://github.com/emvnuel/deployments.git, targetRevision: master, path: argocd/apps }
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```
`kubectl apply -f argocd/bootstrap/` (1x à mão), `argocd app sync root`, conferir filhos `Synced/Healthy`. A partir daqui: novo app = commit em `argocd/apps/`; fim do manifest temporário.

### Fase 2 — Mover apps para `apps/` (1 commit por lote)
Ordem: `landing-page`+`personal-landing-page` → `payroll-front`+`payroll` → `copilot-api` → `n8n` → `hermes-agent` → `sistema-estoque`.
```bash
git mv payroll apps/payroll
# + editar argocd/apps/payroll.yaml → path: apps/payroll (MESMO commit)
```
Validar por lote: `diff <(helm template x <antes>/) <(helm template x <depois>/)` vazio; `verify-charts.sh`; `argocd app diff <nome>` vazio após sync.

### Fase 3 — `common-chart` → `charts/`
Move não exige republicar (digest OCI igual), mas o workflow filtra `paths: common-chart/**` e o guard recusa republicar 0.3.0 → **bump 0.3.1 no mesmo commit**.
Atualizar workflow, `verify-charts.sh`, README, AGENTS.md. Validar `helm lint charts/common-chart/` + verify + run do publish publicando 0.3.1.

### Fase 4 — Especiais
- **sistema-estoque:** promover `mysql-chart` (`git mv` → `charts/`, bump, dep OCI, `helm dependency update`, deletar `.tgz`); remover `docker/`; fix README.
- **postgres:** inventariar `argocd app manifests postgres-cluster | grep kind` antes (ver se `operator/install.yaml` entrou pelo `.argocdignore` inerte);
  `git mv postgres platform/postgres` + `path:` no mesmo commit; comparar manifests antes/depois; `kubectl -n postgres get cluster,pods` inalterados.

### Fase 5 — Platform, CI, docs
Wrappers `kube-prometheus-stack`/`headlamp` (reconciliar com cluster, aninhar values, remover `adminPassword`);
`verify-charts.sh` derivado; novo `.github/workflows/verify-charts.yml` em PR (paths `apps/**`, `charts/**`, `platform/**`);
`archived/README.md`, `README.md` raiz, rewrite `AGENTS.md`, fix READMEs stale, `.gitignore` por glob. Opcional: Renovate regex-manager para bumps.

## 5. Governança proposta (texto pronto p/ AGENTS.md)

- `charts/<chart>/` — reutilizáveis, OCI GHCR, nunca `path` de Application.
- `apps/<app>/` — app novo nasce aqui: `Chart.yaml` (name == pasta) + `Chart.lock` + `values.yaml` + `README.md`.
- `platform/<comp>/` — infra compartilhada. `argocd/` — `bootstrap/` + `apps/` (1 Application por app). `archived/` — congelado.
- Novo app: dep `common-chart` via `oci://…` pinada → `helm dependency update` → `helm template` + verify verdes → commit `argocd/apps/<nome>.yaml` (`targetRevision: master`, `path: apps/<nome>`, automated sync). PROIBIDO manifest temporário.
- Segredos só por referência (`secret.name` + `secret.envFrom`); nada em claro no git.
- Move de `path`: `git mv` + Application no MESMO commit.

## 6. Riscos / validar no cluster

1. `.argocdignore` provavelmente inerte → `postgres-cluster` pode gerenciar `operator/install.yaml` (CRDs). Inventariar antes.
2. Drift headlamp/kube-prometheus-stack — reconciliar na fase 1 antes de mover.
3. App-of-apps + `prune`: remover filho do git apaga recursos se houver finalizer — definir política, começar com `prune: true` só no root.
4. Bump 0.3.1 obrigatório no commit do move.
5. ArgoCD ≥ 3.5 usa Helm 4 p/ render (cluster em 3.0.1 pelo RUNBOOK) — revalidar ao atualizar.
6. `mysql-chart` via `file://` sem `.tgz` validado localmente; confirmar com sync real (hard refresh) antes de deletar.

## 7. Handoff para o próximo agente (com `kubectl` + `argocd`)

```bash
git fetch origin && git checkout docs/adr-reorganizacao-diretorios
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status
cat docs/adr/0001-reorganizacao-diretorios.md
# começar pela Fase 0 + Fase 1 acima; não mover pastas antes do app-of-apps estar Synced
```

Checklist de continuação:
- [ ] Fase 0: backup + tabela app→path→project→prune→drift
- [ ] Fase 1: `argocd/apps/*.yaml` + `argocd/bootstrap/root.yaml` + sync root verde
- [ ] Fase 2: moves em lotes com diff vazio
- [ ] Fase 3: `charts/common-chart` + publish 0.3.1
- [ ] Fase 4: sistema-estoque + postgres
- [ ] Fase 5: wrappers platform + CI verify + docs
