# AGENTS.md - Development Guidelines

## Build/Lint/Test Commands

- **Helm lint**: `helm lint <chart-name>/` - Validate Helm chart syntax
- **Helm template**: `helm template <chart-name>/` - Test template rendering
- **YAML validation**: `yamllint <file>.yaml` - Validate YAML syntax
- **Test single chart**: `helm install --dry-run --debug <release> <chart>/`

## Code Style Guidelines

- Use 2-space indentation for YAML files
- Add descriptive comments using `# --` for values.yaml documentation
- Follow Kubernetes resource naming: lowercase with hyphens
- Template names: `{{ include "chart.fullname" . }}` pattern
- Use `nindent` for proper YAML indentation in templates

## Naming Conventions

- Chart names: kebab-case (e.g., `common-chart`, `explana-app`)
- Resource names: Use fullname helper functions
- Values: camelCase in values.yaml
- Templates: Use chart name prefix for helpers

## File Structure

- Common chart in `common-chart/` for reusable templates
- App-specific values in `<app-name>/values.yaml`
- MongoDB deployments use StatefulSets with PVCs
- Ingress uses nginx controller with cert-manager

## Common Chart Usage

- **NEVER deploy using helm install/upgrade** - Helm is for verification only
- Verify charts with: `helm template <release> common-chart/ -f <app>/values.yaml`
- Override values using `nameOverride` for app-specific naming
- Use helper functions: `{{ include "common-chart.fullname" . }}`
- Standard patterns: deployment, service, ingress, configmap, serviceaccount
- Apps inherit all common-chart features via values.yaml overrides

## Deployment via ArgoCD

- **Create a temporary ArgoCD Application manifest** for deployment:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: <app-name>
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: <git-repo-url>
      targetRevision: HEAD
      path: <app-name>
    destination:
      server: https://kubernetes.default.svc
      namespace: <target-namespace>
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
  ```
- Apply the manifest: `kubectl apply -f <temp-manifest>.yaml`
- **Delete the temporary manifest file after apply**: `rm <temp-manifest>.yaml`
- ArgoCD will sync and manage the application from the Git repository

## Error Handling

- Always include resource limits and requests
- Use probes for health checks (liveness/readiness)
- Configure proper security contexts
- Use ConfigMaps for environment variables
