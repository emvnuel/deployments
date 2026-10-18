# CloudNativePG Operator Installation

## Install the Operator

The operator must be installed once per cluster:

```bash
# Install CloudNativePG operator (v1.22.0)
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
```

## Verify Installation

```bash
# Check operator is running
kubectl get pods -n cnpg-system

# Check CRDs are installed
kubectl get crd | grep cnpg
```

You should see:
- `backups.postgresql.cnpg.io`
- `clusters.postgresql.cnpg.io`
- `poolers.postgresql.cnpg.io`
- `scheduledbackups.postgresql.cnpg.io`

## Uninstall

```bash
kubectl delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
```
