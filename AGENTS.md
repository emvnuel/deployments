# AGENTS.md - Repository Guidelines

## Project Type
This is a Kubernetes deployment repository containing YAML manifests for multiple applications.

## Commands
**Validation**: `kubectl apply --dry-run=client -f <file>.yaml`
**Deploy**: `kubectl apply -f <directory>/`
**Verify**: `kubectl get pods,services,ingress -n <namespace>`
**Lint YAML**: `yamllint <file>.yaml` (if available)

## File Structure
- Each application has its own directory (explana-app/, landing-page/, payroll/, etc.)
- Standard Kubernetes resources: deployment.yaml, service.yaml, ingress.yaml
- StatefulSets for databases (mongo/)
- ConfigMaps and PVCs where needed

## Naming Conventions
- Use kebab-case for file names and resource names
- Prefix resources with app name (e.g., explana-api, mongo-svc)
- Use descriptive labels matching the app name

## YAML Style
- Use 2-space indentation
- Include resource requests/limits for containers
- Use consistent port naming (containerPort matches service targetPort)
- Environment variables via configMapRef when possible
- Include meaningful metadata labels

## Best Practices
- Always specify resource limits and requests
- Use namespaces for production deployments
- Validate YAML syntax before applying
- Test with --dry-run before actual deployment