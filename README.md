# deployments

GitOps do cluster k3s: charts Helm + Applications do ArgoCD (app-of-apps).

## Mapa do repositório

| Caminho | Papel |
|---|---|
| `apps/<app>/` | 1 app = 1 chart Helm = 1 Application (`argocd/apps/<app>.yaml`) |
| `charts/<chart>/` | Charts reutilizáveis publicados em OCI (`oci://ghcr.io/emvnuel/charts`) |
| `platform/<comp>/` | Infra compartilhada: `postgres/`, `kube-prometheus-stack/`, `headlamp/` (wrappers) |
| `argocd/bootstrap/` | AppProjects + Application raiz (`root.yaml`, app-of-apps) — aplicado 1x à mão |
| `argocd/apps/` | 1 Application por app, reconciliada pelo root |
| `archived/` | Apps congelados; fora da verificação padrão |
| `docs/adr/` | Decisões de arquitetura (ver `0001-reorganizacao-diretorios.md`) |
| `scripts/verify-charts.sh` | `helm dependency build` + `lint` + `template` + YAML cru de platform/postgres |

## Fluxo GitOps

O ArgoCD reconcilia `argocd/apps/` através da Application `root`
(`argocd/bootstrap/root.yaml`). Para criar ou mudar um app:

1. Chart em `apps/<nome>/` (`Chart.yaml` com `name` igual à pasta, `Chart.lock`, `values.yaml`).
2. Application em `argocd/apps/<nome>.yaml` (`path: apps/<nome>`, `targetRevision: master`).
3. `./scripts/verify-charts.sh` verde antes do commit.

**Nunca** crie manifest temporário com `kubectl apply` para deploy: o estado
desejado é sempre o git.

## Zero downtime

- **Nunca** mova a pasta de um app sem atualizar `path:` da Application **no mesmo commit**.
- Mudanças de path/reorg não alteram manifests renderizados: valide com
  `diff <(helm template ...) <(helm template ...)` (só comentários `# Source:` podem mudar).
- `strategy` por app: `Recreate` quando um único pod não pode rodar em duplicidade
  (ex.: `hermes-agent`); `RollingUpdate` nos demais.
- Grafana referencia `Secret` existente (`grafana.admin.existingSecret`); o Secret
  carrega `argocd.argoproj.io/sync-options: Prune=false` para não ser podado.

## Verificação

```bash
./scripts/verify-charts.sh            # apps/ + charts/ + platform/ + YAML do postgres
./scripts/verify-charts.sh --archived # inclui archived/
helm template <release> apps/<app>/   # render isolado
```
