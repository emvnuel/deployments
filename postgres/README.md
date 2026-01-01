# Production-Ready PostgreSQL with CloudNativePG

This directory contains a production-ready PostgreSQL setup using the CloudNativePG operator.

## Features

- High availability with 3 instances (1 primary + 2 replicas)
- Automatic failover and self-healing
- Connection pooling with PgBouncer
- Automated backups to S3-compatible storage
- Monitoring with Prometheus and Grafana
- Point-in-time recovery capability
- TLS/SSL support
- Resource management and limits

## Prerequisites

- Kubernetes cluster (1.24+)
- kubectl configured
- S3-compatible object storage (AWS S3, MinIO, GCS, etc.)
- Prometheus Operator (you already have kube-prometheus-stack installed)

## Directory Structure

```
postgres/
├── operator/           # CloudNativePG operator installation
├── cluster/            # PostgreSQL cluster configuration
├── backup/             # Backup configuration and credentials
├── monitoring/         # Prometheus rules and Grafana dashboards
├── ingress/            # External access via nginx ingress
└── README.md           # This file
```

## Installation Steps

### 1. Install CloudNativePG Operator

```bash
# Install the operator (only once per cluster)
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml

# Verify installation
kubectl get pods -n cnpg-system
```

### 2. Configure Secrets

Edit the following files with your actual credentials:

**Database passwords** (`cluster/secrets.yaml`):
```bash
# Edit with secure passwords
vi cluster/secrets.yaml
```

**Backup credentials** (`backup/backup-secrets.yaml`):
```bash
# Add your S3 credentials
vi backup/backup-secrets.yaml
```

### 3. Configure Backup Storage

Edit `cluster/postgres-cluster.yaml` and update the backup destination:

```yaml
backup:
  barmanObjectStore:
    destinationPath: "s3://your-bucket-name/postgres-backups/"  # UPDATE THIS
```

For MinIO or non-AWS S3, also set the endpoint in `backup/backup-secrets.yaml`.

### 4. Deploy PostgreSQL Cluster

```bash
# Create namespace
kubectl apply -f cluster/namespace.yaml

# Apply secrets
kubectl apply -f cluster/secrets.yaml
kubectl apply -f backup/backup-secrets.yaml

# Deploy PostgreSQL cluster
kubectl apply -f cluster/postgres-cluster.yaml

# Deploy connection pooler (optional but recommended)
kubectl apply -f cluster/postgres-pooler.yaml

# Deploy monitoring
kubectl apply -f monitoring/prometheus-rules.yaml
```

### 5. (Optional) Enable External Access

To expose PostgreSQL externally via nginx ingress:

```bash
# Apply TCP services configuration
kubectl apply -f ingress/tcp-services-configmap.yaml
kubectl apply -f ingress/postgres-external-service.yaml

# Configure nginx ingress controller (see ingress/README.md for details)
```

See `ingress/README.md` for complete external access setup and security considerations.

### 6. Verify Deployment

```bash
# Check cluster status
kubectl get cluster -n postgres

# Check pods
kubectl get pods -n postgres

# Check cluster details
kubectl describe cluster postgres-cluster -n postgres

# View logs
kubectl logs -n postgres postgres-cluster-1 -f
```

Wait for all instances to be ready. This may take 2-5 minutes.

## Connecting to PostgreSQL

### Internal Connections (from within cluster)

**Direct connection to cluster:**
```
Host: postgres-cluster-rw.postgres.svc.cluster.local
Port: 5432
Database: app_database
Username: app_user
Password: <from postgres-app-user secret>
```

**Via connection pooler (recommended for apps):**
```
Host: postgres-pooler-rw.postgres.svc.cluster.local
Port: 5432
Database: app_database
Username: app_user
Password: <from postgres-app-user secret>
```

**Read-only replicas:**
```
Host: postgres-cluster-ro.postgres.svc.cluster.local
Port: 5432
```

### External Connections (from outside cluster)

To connect from external clients (your laptop, external applications):

```
Host: <EXTERNAL-IP or your-domain.com>
Port: 5432
Database: app_database
Username: app_user
Password: <from postgres-app-user secret>
```

See `ingress/README.md` for setup instructions and security best practices.

### Connection Examples

**Using psql:**
```bash
# Connect to primary
kubectl exec -it -n postgres postgres-cluster-1 -- psql -U app_user app_database

# From another pod in the cluster
psql "postgresql://app_user:password@postgres-pooler-rw.postgres.svc.cluster.local:5432/app_database"
```

**Environment variables in deployment:**
```yaml
env:
  - name: DATABASE_URL
    value: "postgresql://app_user:password@postgres-pooler-rw.postgres.svc.cluster.local:5432/app_database"
  
  # Or using secrets
  - name: DB_HOST
    value: "postgres-pooler-rw.postgres.svc.cluster.local"
  - name: DB_PORT
    value: "5432"
  - name: DB_NAME
    value: "app_database"
  - name: DB_USER
    valueFrom:
      secretKeyRef:
        name: postgres-app-user
        key: username
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-app-user
        key: password
```

## Backup and Recovery

### Automated Backups

Backups are configured to run automatically:
- Daily backup: 2 AM UTC
- Weekly backup: Sunday 3 AM UTC
- Retention: 30 days
- Continuous WAL archiving

```bash
# List backups
kubectl get backup -n postgres

# Check backup status
kubectl describe backup -n postgres <backup-name>
```

### Manual Backup

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-manual-backup
  namespace: postgres
spec:
  cluster:
    name: postgres-cluster
  method: barmanObjectStore
EOF
```

### Point-in-Time Recovery

To restore to a specific point in time, create a new cluster from backup:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster-restored
  namespace: postgres
spec:
  instances: 3
  storage:
    size: 20Gi
  
  bootstrap:
    recovery:
      source: postgres-cluster
      recoveryTarget:
        targetTime: "2024-01-15 10:30:00"
  
  externalClusters:
    - name: postgres-cluster
      barmanObjectStore:
        destinationPath: "s3://your-bucket/postgres-backups/"
        s3Credentials:
          accessKeyId:
            name: backup-s3-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: backup-s3-credentials
            key: SECRET_ACCESS_KEY
EOF
```

## Monitoring

### Metrics

CloudNativePG automatically exports Prometheus metrics:
- Database size
- Connection count
- Transaction rate
- Replication lag
- Query performance (pg_stat_statements)
- Cache hit ratios

### Access Metrics

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Open http://localhost:9090 and query:
# cnpg_pg_database_size_bytes{namespace="postgres"}
```

### Alerts

Prometheus alerts are configured for:
- PostgreSQL instance down
- High replication lag
- High connection usage
- Low disk space
- Backup failures
- Dead tuples accumulation

## Maintenance

### Scaling

```bash
# Scale to 5 instances
kubectl patch cluster postgres-cluster -n postgres --type='json' \
  -p='[{"op": "replace", "path": "/spec/instances", "value": 5}]'
```

### Upgrade PostgreSQL Version

Edit `cluster/postgres-cluster.yaml` and update `imageName`:
```yaml
imageName: ghcr.io/cloudnative-pg/postgresql:16.3
```

Then apply:
```bash
kubectl apply -f cluster/postgres-cluster.yaml
```

The operator will perform a rolling upgrade automatically.

### Switchover (Change Primary)

```bash
# Promote replica to primary
kubectl cnpg promote postgres-cluster 2 -n postgres
```

## Troubleshooting

### Check cluster status
```bash
kubectl get cluster -n postgres
kubectl describe cluster postgres-cluster -n postgres
```

### View logs
```bash
# Primary logs
kubectl logs -n postgres postgres-cluster-1 -f

# Replica logs
kubectl logs -n postgres postgres-cluster-2 -f
```

### Check replication status
```bash
kubectl exec -it -n postgres postgres-cluster-1 -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Check backup status
```bash
kubectl get backup -n postgres
kubectl describe backup -n postgres
```

### Common issues

**Cluster not starting:**
- Check PVC provisioning: `kubectl get pvc -n postgres`
- Check storage class: `kubectl get storageclass`
- View events: `kubectl get events -n postgres`

**Backup failures:**
- Verify S3 credentials in secrets
- Check bucket permissions and path
- View backup logs: `kubectl logs -n postgres <backup-pod>`

**High replication lag:**
- Check network between nodes
- Verify replica resources
- Check primary load

## Configuration Tuning

### For small workloads (development)
```yaml
instances: 1
storage:
  size: 5Gi
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### For high-traffic production
```yaml
instances: 5
storage:
  size: 100Gi
resources:
  requests:
    memory: "4Gi"
    cpu: "2000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
postgresql:
  parameters:
    shared_buffers: "2GB"
    effective_cache_size: "6GB"
    max_connections: "500"
```

## Security Best Practices

1. **Change default passwords** in secrets immediately
2. **Use network policies** to restrict access
3. **Enable TLS** for client connections
4. **Rotate credentials** regularly
5. **Limit superuser access**
6. **Audit logs** regularly
7. **Keep operator updated**

## Uninstallation

```bash
# Delete cluster (WARNING: This will delete all data)
kubectl delete cluster postgres-cluster -n postgres

# Delete resources
kubectl delete -f monitoring/prometheus-rules.yaml
kubectl delete -f backup/scheduled-backup.yaml
kubectl delete -f backup/backup-secrets.yaml
kubectl delete -f cluster/secrets.yaml
kubectl delete namespace postgres

# Uninstall operator (if no other clusters exist)
kubectl delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
```

## Additional Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Monitoring Guide](https://cloudnative-pg.io/documentation/current/monitoring/)
- [Backup & Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)

## Support

For issues with:
- CloudNativePG: https://github.com/cloudnative-pg/cloudnative-pg/issues
- PostgreSQL: https://www.postgresql.org/support/
- This setup: Check logs and events first, then consult documentation
