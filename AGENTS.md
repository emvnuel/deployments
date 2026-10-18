# AGENTS.md - Development Guidelines

## Repository map

- `charts/<chart>/` — reusable charts published to OCI (`oci://ghcr.io/emvnuel/charts`); never an Application `path`
- `apps/<app>/` — 1 app = 1 chart = 1 Application (`argocd/apps/<app>.yaml`)
- `platform/<comp>/` — shared infra: `postgres/` (raw directory app), `kube-prometheus-stack/` + `headlamp/` (upstream wrappers)
- `argocd/bootstrap/` — AppProjects + root app-of-apps (`root.yaml`), applied by hand once
- `argocd/apps/` — one Application per app, reconciled by `root`
- `archived/` — frozen; excluded from `verify-charts.sh` unless `--archived`
- `docs/adr/` — architecture decisions

## Build/Lint/Test Commands

- **Verify everything**: `./scripts/verify-charts.sh` (derives chart list via `find`, runs `helm dependency build` + `helm lint` + `helm template` in a temp copy, validates `platform/postgres/**.yaml`)
- **Include archived**: `./scripts/verify-charts.sh --archived`
- **Single chart**: `helm dependency build apps/<app>/ && helm template <app> apps/<app>/`
- **Helm lint**: `helm lint charts/<chart>/`
- **YAML validation**: `yamllint <file>.yaml`

## Code Style Guidelines

- Use 2-space indentation for YAML files
- Add descriptive comments using `# --` for values.yaml documentation
- Follow Kubernetes resource naming: lowercase with hyphens
- Template names: `{{ include "chart.fullname" . }}` pattern
- Use `nindent` for proper YAML indentation in templates

## Naming Conventions

- Chart names: kebab-case and equal to the directory name (`apps/payroll/Chart.yaml` → `name: payroll`)
- Resource names: use fullname helper functions
- Values: camelCase in values.yaml
- Templates: use chart name prefix for helpers

## Common Chart Usage

- `charts/common-chart/` is published to GHCR as an OCI artifact by `.github/workflows/publish-charts.yml`; consumers pin `oci://ghcr.io/emvnuel/charts` in `Chart.yaml`
- **Bump `version` in `charts/common-chart/Chart.yaml` on every content change** — the workflow refuses to overwrite a published version
- Never vendor `common-chart` as `.tgz`; ArgoCD and `verify-charts.sh` run `helm dependency build`
- Apps inherit common-chart features via values.yaml overrides

## Deployment via ArgoCD (app-of-apps)

- The root Application (`argocd/bootstrap/root.yaml`, `path: argocd/apps`) manages every app Application
- New app: chart in `apps/<nome>/` + commit `argocd/apps/<nome>.yaml` (`targetRevision: master`, `path: apps/<nome>`)
- **NEVER** create a temporary manifest and `kubectl apply` it — the desired state is always git
- **NEVER** move an app directory without updating the Application `path:` **in the same commit**
- Reorg/moves must render identical manifests: `diff <(helm template ...) <(helm template ...)` (only `# Source:` comments may differ)
- Postgres (`platform/postgres/`) is a raw directory app with `project: postgres` and **no automated sync**; the operator install contains only Namespace + ServiceAccount
- Platform wrappers (`platform/kube-prometheus-stack/`, `platform/headlamp/`) depend on upstream charts; ArgoCD runs `helm dependency build` automatically

## Zero-downtime rules

- Keep each app's `strategy` semantics: `Recreate` when a single pod cannot run twice (ex.: `hermes-agent`), `RollingUpdate` otherwise
- Never change `path:` without the matching move in the same commit; workloads must not be recreated by a reorg
- Secrets are referenced, never created: wire an existing Secret (`secret.name` + `secret.envFrom`); keep payloads out of tracked values
- Git-ignored globs cover every app: `secrets.yaml`, `*-secrets.yaml`, `*.secret.yaml` (root `.gitignore`)
- Grafana uses `grafana.admin.existingSecret` (no plaintext password); the live Secret is protected with `argocd.argoproj.io/sync-options: Prune=false`

## Error Handling

- Always include resource limits and requests
- Use probes for health checks (liveness/readiness)
- Configure proper security contexts
- Use ConfigMaps for environment variables
