# ArgoCD Deployment for PostgreSQL

This directory contains ArgoCD manifests to deploy and manage the PostgreSQL cluster using GitOps.

## Files

- `project.yaml` - ArgoCD AppProject defining permissions and allowed resources
- `application.yaml` - ArgoCD Application for automatic deployment

## Prerequisites

1. ArgoCD installed in your cluster
2. Git repository containing this postgres directory
3. ArgoCD has access to your git repository

## Setup Instructions

### 1. Update Git Repository URL

Edit both `project.yaml` and `application.yaml`:

```yaml
sourceRepos:
  - https://github.com/your-org/your-repo.git  # CHANGE THIS
```

Replace with your actual git repository URL.

### 2. Configure Secrets Before Deployment

**IMPORTANT:** Before applying ArgoCD manifests, you must update the secrets with actual passwords:

```bash
# Edit database passwords
vi postgres/cluster/secrets.yaml

# Edit S3 backup credentials
vi postgres/backup/backup-secrets.yaml

# Edit PostgreSQL cluster S3 bucket path
vi postgres/cluster/postgres-cluster.yaml
# Update: spec.backup.barmanObjectStore.destinationPath
```

### 3. Deploy ArgoCD Project

```bash
kubectl apply -f postgres/argocd/project.yaml
```

This creates the `postgres` AppProject with:
- Allowed source repositories
- Permitted destination namespaces
- Resource whitelists for PostgreSQL CRDs
- RBAC roles (read-only, admin)

### 4. Deploy ArgoCD Application

```bash
kubectl apply -f postgres/argocd/application.yaml
```

This creates an Application that:
- Monitors the `postgres/` directory in your git repo
- Auto-syncs changes from git to cluster
- Creates the `postgres` namespace automatically
- Deploys all PostgreSQL resources

### 5. Verify Deployment

```bash
# Check ArgoCD application status
kubectl get application -n argocd postgres-cluster

# View in ArgoCD UI
# Navigate to: https://argocd.awesomeapps.cloud (or your ArgoCD URL)

# Check PostgreSQL cluster
kubectl get cluster -n postgres
kubectl get pods -n postgres
```

## ArgoCD Features Enabled

### Automatic Sync
- **Self-Heal**: Automatically syncs when cluster state drifts from git
- **Prune**: Set to `false` by default (change to `true` to auto-delete removed resources)

### Sync Options
- **CreateNamespace**: Automatically creates the `postgres` namespace
- **PrunePropagationPolicy**: Ensures proper deletion order
- **PruneLast**: Deletes resources in reverse order

### Retry Policy
- Retries up to 5 times on sync failure
- Exponential backoff: 5s, 10s, 20s, 40s, 3m

### Ignore Differences
Ignores changes to:
- StatefulSet volume claim templates (can't be updated)
- Secret data (avoids sync loops with CloudNativePG)

## Directory Structure for GitOps

```
postgres/
├── operator/
│   └── install.yaml          # Note: Operator should be installed separately
├── cluster/
│   ├── namespace.yaml        ✓ Synced by ArgoCD
│   ├── secrets.yaml          ✓ Synced by ArgoCD
│   ├── postgres-cluster.yaml ✓ Synced by ArgoCD
│   └── postgres-pooler.yaml  ✓ Synced by ArgoCD
├── backup/
│   ├── backup-secrets.yaml   ✓ Synced by ArgoCD
│   └── scheduled-backup.yaml ✓ Synced by ArgoCD
├── monitoring/
│   └── prometheus-rules.yaml ✓ Synced by ArgoCD
└── argocd/
    ├── project.yaml          # Apply manually
    └── application.yaml      # Apply manually
```

## Important Notes

### CloudNativePG Operator

The operator (`postgres/operator/install.yaml`) should be installed **separately** before deploying the Application:

```bash
# Install operator manually (not via ArgoCD)
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
```

Or create a separate ArgoCD Application for the operator if you prefer.

### Secrets Management

**Security Warning:** Storing plain-text secrets in git is not recommended for production.

Consider these alternatives:

**Option 1: Sealed Secrets**
```bash
# Install sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Seal your secrets
kubeseal < cluster/secrets.yaml > cluster/secrets-sealed.yaml

# Commit sealed secrets to git instead
```

**Option 2: External Secrets Operator**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-app-user
  namespace: postgres
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: postgres-app-user
  data:
    - secretKey: username
      remoteRef:
        key: postgres/app-user
        property: username
    - secretKey: password
      remoteRef:
        key: postgres/app-user
        property: password
```

**Option 3: SOPS (Secrets OPerationS)**
```bash
# Encrypt secrets before committing
sops -e cluster/secrets.yaml > cluster/secrets.enc.yaml

# Use ArgoCD with SOPS plugin to decrypt
```

## Manual Sync

If auto-sync is disabled or you want to manually trigger a sync:

```bash
# Via kubectl
kubectl patch application postgres-cluster -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Via ArgoCD CLI
argocd app sync postgres-cluster

# Via ArgoCD UI
# Click "Sync" button in the application view
```

## Monitoring Sync Status

```bash
# Get application status
argocd app get postgres-cluster

# Watch sync progress
argocd app wait postgres-cluster --health

# View sync history
argocd app history postgres-cluster
```

## Troubleshooting

### Application stuck in "OutOfSync"

```bash
# Check diff between git and cluster
argocd app diff postgres-cluster

# Force sync (ignore differences)
argocd app sync postgres-cluster --force
```

### Sync failed with permission errors

Check the AppProject allows the resource:
```bash
kubectl describe appproject postgres -n argocd
```

### Secrets not updating

Secrets are in `ignoreDifferences` to prevent sync loops. To update:
1. Delete the secret manually
2. Sync the application
3. Or temporarily remove from `ignoreDifferences`

## Rollback

```bash
# List application history
argocd app history postgres-cluster

# Rollback to previous revision
argocd app rollback postgres-cluster <revision-id>
```

## Uninstall via ArgoCD

```bash
# Delete application (keeps resources by default due to prune: false)
kubectl delete application postgres-cluster -n argocd

# Delete project
kubectl delete appproject postgres -n argocd

# To delete all resources, enable prune first:
kubectl patch application postgres-cluster -n argocd \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true}}}}'
```

## Best Practices

1. **Use separate git branches** for different environments (dev, staging, prod)
2. **Tag releases** for production deployments
3. **Enable notifications** (Slack, email) for sync failures
4. **Use ApplicationSets** if managing multiple PostgreSQL clusters
5. **Encrypt secrets** before committing to git
6. **Regular backups** - verify S3 credentials are correct
7. **Test in staging** before promoting to production

## Integration with CI/CD

```yaml
# Example GitHub Actions workflow
name: Deploy PostgreSQL
on:
  push:
    branches: [main]
    paths:
      - 'postgres/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      
      - name: Trigger ArgoCD Sync
        run: |
          argocd app sync postgres-cluster --auth-token ${{ secrets.ARGOCD_TOKEN }}
```

## Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [CloudNativePG GitOps Guide](https://cloudnative-pg.io/documentation/current/gitops/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
