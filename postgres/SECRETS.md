# Secrets Management for PostgreSQL

## Overview

Secrets are **NOT stored in Git** for security reasons. They must be created manually in the cluster before deploying PostgreSQL via ArgoCD.

## Required Secrets

### 1. Database User Secrets

**File:** `postgres/cluster/secrets.yaml` (local only, not in git)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser
  namespace: postgres
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: "YOUR_SECURE_PASSWORD_HERE"
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app-user
  namespace: postgres
type: kubernetes.io/basic-auth
stringData:
  username: app_user
  password: "YOUR_SECURE_APP_PASSWORD_HERE"
```

### 2. Backup S3 Credentials

**File:** `postgres/backup/backup-secrets.yaml` (local only, not in git)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: backup-s3-credentials
  namespace: postgres
type: Opaque
stringData:
  ACCESS_KEY_ID: "your-s3-access-key"
  SECRET_ACCESS_KEY: "your-s3-secret-key"
  # Optional: for MinIO or custom S3 endpoint
  # AWS_S3_ENDPOINT: "https://minio.example.com"
  # AWS_REGION: "us-east-1"
```

## Initial Setup

### Step 1: Generate Secure Passwords

```bash
# Generate random passwords
openssl rand -base64 32  # For postgres superuser
openssl rand -base64 32  # For app_user
```

### Step 2: Create Local Secret Files

Create the secret files locally (they won't be committed to git):

```bash
# Create secrets.yaml
cat > postgres/cluster/secrets.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser
  namespace: postgres
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: "PASTE_GENERATED_PASSWORD_HERE"
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app-user
  namespace: postgres
type: kubernetes.io/basic-auth
stringData:
  username: app_user
  password: "PASTE_GENERATED_PASSWORD_HERE"
EOF

# Create backup-secrets.yaml
cat > postgres/backup/backup-secrets.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: backup-s3-credentials
  namespace: postgres
type: Opaque
stringData:
  ACCESS_KEY_ID: "your-access-key"
  SECRET_ACCESS_KEY: "your-secret-key"
EOF
```

### Step 3: Apply Secrets to Cluster

```bash
# Create namespace if not exists
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -

# Apply secrets
kubectl apply -f postgres/cluster/secrets.yaml
kubectl apply -f postgres/backup/backup-secrets.yaml
```

### Step 4: Verify Secrets

```bash
# List secrets
kubectl get secrets -n postgres

# View secret (base64 encoded)
kubectl get secret postgres-app-user -n postgres -o yaml

# Decode password (for verification)
kubectl get secret postgres-app-user -n postgres -o jsonpath='{.data.password}' | base64 -d
```

## ArgoCD Deployment

Once secrets are applied manually, deploy via ArgoCD:

```bash
# Apply ArgoCD project and application
kubectl apply -f postgres/argocd/project.yaml
kubectl apply -f postgres/argocd/application.yaml

# ArgoCD will sync everything EXCEPT secrets (excluded via .argocdignore)
```

## Updating Secrets

### Update Database Passwords

```bash
# Edit the local file
vi postgres/cluster/secrets.yaml

# Apply changes
kubectl apply -f postgres/cluster/secrets.yaml

# For app_user password changes to take effect, restart pooler
kubectl rollout restart deployment postgres-pooler -n postgres

# For superuser password, PostgreSQL picks it up automatically
```

### Update S3 Credentials

```bash
# Edit the local file
vi postgres/backup/backup-secrets.yaml

# Apply changes
kubectl apply -f postgres/backup/backup-secrets.yaml

# Restart cluster to pick up new credentials (if backups fail)
kubectl delete pod -n postgres -l postgresql=postgres-cluster
```

## Secret Rotation Best Practices

1. **Regular Rotation**: Rotate passwords every 90 days
2. **Audit Access**: Review who has access to secrets
3. **Use Strong Passwords**: Minimum 32 characters, random
4. **Backup Secrets**: Store securely in password manager
5. **Monitor Usage**: Watch for failed authentication attempts

## Alternative: External Secrets Management

For production, consider using external secrets management:

### Option 1: Sealed Secrets

```bash
# Install sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Seal secrets
kubeseal < postgres/cluster/secrets.yaml > postgres/cluster/secrets-sealed.yaml

# Commit sealed secrets (safe to store in git)
git add postgres/cluster/secrets-sealed.yaml
git commit -m "Add sealed secrets"
git push
```

### Option 2: External Secrets Operator

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace

# Create SecretStore (e.g., AWS Secrets Manager)
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets
  namespace: postgres
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
EOF

# Create ExternalSecret
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-app-user
  namespace: postgres
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets
    kind: SecretStore
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
EOF
```

### Option 3: HashiCorp Vault

```bash
# Install Vault Agent Injector
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --namespace vault --create-namespace

# Use Vault annotations in pod spec
# See: https://developer.hashicorp.com/vault/docs/platform/k8s/injector
```

## Troubleshooting

### Secret Not Found

```bash
# Check if secret exists
kubectl get secret postgres-app-user -n postgres

# If not, apply it
kubectl apply -f postgres/cluster/secrets.yaml
```

### Connection Authentication Failed

```bash
# Verify secret value
kubectl get secret postgres-app-user -n postgres -o jsonpath='{.data.password}' | base64 -d

# Check PostgreSQL logs
kubectl logs -n postgres postgres-cluster-1 | grep -i auth
```

### ArgoCD Trying to Delete Secrets

If ArgoCD tries to delete manually-created secrets:

```bash
# Add label to prevent ArgoCD from managing it
kubectl label secret postgres-app-user -n postgres argocd.argoproj.io/instance=postgres-cluster-manual
```

## Security Checklist

- [ ] Secrets files added to `.gitignore`
- [ ] Secrets patterns added to `.argocdignore`
- [ ] Strong passwords generated (32+ chars)
- [ ] Secrets applied to cluster manually
- [ ] Secret access limited via RBAC
- [ ] Secrets backed up securely (password manager)
- [ ] Rotation schedule documented
- [ ] Team trained on secret management
- [ ] No secrets in git history (verify with: `git log --all --full-history -- "*secret*"`)

## Emergency: Remove Secrets from Git History

If secrets were accidentally committed:

```bash
# Remove from entire git history
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch postgres/cluster/secrets.yaml postgres/backup/backup-secrets.yaml" \
  --prune-empty --tag-name-filter cat -- --all

# Force push (WARNING: rewrites history)
git push origin --force --all

# Rotate all exposed credentials immediately!
```

## Team Onboarding

When adding new team members:

1. Share secret files securely (1Password, encrypted email, etc.)
2. Have them apply secrets to their local cluster
3. Verify they can deploy via ArgoCD
4. Remind them NEVER to commit secret files
5. Add them to secret rotation schedule
