# common-chart

Shared Helm chart consumed by the app charts in this repository.

## Publishing (OCI)

This chart is published as an OCI artifact to GHCR by
`.github/workflows/publish-charts.yml`, which runs on every push to
`master` that touches `charts/common-chart/**`:

```
oci://ghcr.io/emvnuel/charts/common-chart --version <version>
```

Consumers reference it from their `Chart.yaml`:

```yaml
dependencies:
  - name: common-chart
    version: <version>
    repository: "oci://ghcr.io/emvnuel/charts"
```

## Rules

- **Bump `version` in `Chart.yaml` whenever the chart content changes.** The
  workflow refuses to overwrite an already-published version, and consumer
  `Chart.lock` files pin the published digest.
- Do not vendor this chart as `.tgz` inside consumer `charts/` directories
  anymore; ArgoCD and `scripts/verify-charts.sh` resolve it from GHCR via
  `helm dependency build`.
- The GHCR package must stay **public** so ArgoCD can pull it anonymously
  (if it ever needs to be private, configure repository credentials in ArgoCD).
