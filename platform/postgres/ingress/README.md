# External Access via Nginx Ingress

PostgreSQL is now externally accessible through your existing nginx ingress LoadBalancer using the **shared LoadBalancer** approach.

## Architecture

PostgreSQL uses TCP protocol (not HTTP), so we use nginx ingress's TCP service feature:

1. **ConfigMap** (`tcp-services`) - Maps port 5432 to PostgreSQL service
2. **Nginx Controller** - Configured to read the TCP ConfigMap
3. **Shared LoadBalancer** - Same LoadBalancer for HTTP (80/443) and PostgreSQL (5432)

## Current Configuration

Your nginx ingress LoadBalancer now exposes:
- Port 80: HTTP traffic
- Port 443: HTTPS traffic
- Port 5432: PostgreSQL traffic

**External IPs:**
```
137.131.136.132
144.22.174.205
164.152.51.165
```

All IPs accept connections on all ports.

## DNS Setup

Point your subdomain to one of the external IPs:

```
# DNS Record
Name: postgres
Type: A
Value: 137.131.136.132
TTL: 300

# Result: postgres.gambiarra.space → 137.131.136.132
```

## Verification

```bash
# Check LoadBalancer service
kubectl get svc ingress-nginx-controller -n ingress-nginx

# Should show:
# PORT(S): 80:xxxxx/TCP,443:xxxxx/TCP,5432:xxxxx/TCP
```

## Connection Examples

### From External Client (e.g., your laptop)

```bash
# Using psql with domain
psql "postgresql://app_user:password@postgres.gambiarra.space:5432/app_database"

# Or with IP directly
psql "postgresql://app_user:password@<EXTERNAL-IP>:5432/app_database"
```

### From Application

```python
# Python example
import psycopg2

conn = psycopg2.connect(
    host="postgres.gambiarra.space",
    port=5432,
    database="app_database",
    user="app_user",
    password="your-password"
)
```

```javascript
// Node.js example
const { Client } = require('pg');

const client = new Client({
  host: 'postgres.gambiarra.space',
  port: 5432,
  database: 'app_database',
  user: 'app_user',
  password: 'your-password',
});
```

## Port Mappings

By default, the following ports are exposed:

- **5432**: PostgreSQL primary (read-write) via `postgres-cluster-rw`
- **5433**: PostgreSQL via PgBouncer pooler (optional, uncomment in configs)
- **5434**: PostgreSQL read-only replicas (optional, uncomment in configs)

## Using Custom Domain

### Setup DNS A Record

Point your subdomain to the LoadBalancer IP:

```
# In your DNS provider (Cloudflare, Route53, etc.)
Name: postgres
Type: A
Value: <EXTERNAL-IP from LoadBalancer>
TTL: 300

# This creates: postgres.gambiarra.space → <EXTERNAL-IP>
```

Example commands to get your external IP:
```bash
kubectl get svc postgres-external -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Then connect:
```bash
psql "postgresql://app_user:password@postgres.gambiarra.space:5432/app_database"
```

### Option 2: NodePort (if LoadBalancer not available)

If your cluster doesn't have LoadBalancer support, edit `postgres-external-service.yaml`:

```yaml
spec:
  type: NodePort  # Change from LoadBalancer
```

Then connect using any node's IP and the assigned NodePort:

```bash
# Get the NodePort
kubectl get svc postgres-external -n ingress-nginx

# Example: NodePort is 30432
psql "postgresql://app_user:password@<NODE-IP>:30432/app_database"
```

## Security Considerations

**IMPORTANT:** Exposing PostgreSQL directly to the internet has security implications:

### 1. Use Strong Passwords
```bash
# Generate secure passwords
openssl rand -base64 32
```

### 2. Enable SSL/TLS

Edit `cluster/postgres-cluster.yaml` and add:

```yaml
postgresql:
  pg_hba:
    - hostssl all all 0.0.0.0/0 scram-sha-256
```

### 3. Restrict IP Access

**Option A: LoadBalancer with allowed IPs:**

```yaml
spec:
  loadBalancerSourceRanges:
    - "203.0.113.0/24"  # Your office IP range
    - "198.51.100.50/32"  # Specific IP
```

**Option B: Network Policies:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-external-access
  namespace: postgres
spec:
  podSelector:
    matchLabels:
      postgresql: postgres-cluster
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 203.0.113.0/24  # Allowed IP range
      ports:
        - protocol: TCP
          port: 5432
```

### 4. Use Connection Pooler

For production, prefer connecting through the pooler (port 5433):
- Better connection management
- Protects database from connection exhaustion
- Can be scaled independently

### 5. VPN Alternative

For better security, consider using a VPN instead of direct internet exposure:
- Use Tailscale, WireGuard, or OpenVPN
- Keep PostgreSQL internal
- Access via VPN tunnel

## Testing External Access

### 1. Test from within cluster
```bash
kubectl run -it --rm debug --image=postgres:16 --restart=Never -- \
  psql "postgresql://app_user:password@postgres-cluster-rw.postgres.svc.cluster.local:5432/app_database"
```

### 2. Test external connectivity
```bash
# Test port is open
telnet <EXTERNAL-IP> 5432

# Test with psql
psql "postgresql://app_user:password@<EXTERNAL-IP>:5432/app_database" -c "SELECT version();"
```

## Troubleshooting

### Port not accessible

1. Check ConfigMap is applied:
```bash
kubectl get configmap tcp-services -n ingress-nginx
```

2. Check ingress controller has the args:
```bash
kubectl describe deployment ingress-nginx-controller -n ingress-nginx | grep tcp-services
```

3. Check service is created:
```bash
kubectl get svc ingress-nginx-controller-tcp -n ingress-nginx
```

4. Check external IP is assigned:
```bash
kubectl get svc -n ingress-nginx
```

### Connection refused

1. Verify PostgreSQL is running:
```bash
kubectl get pods -n postgres
```

2. Test internal connectivity:
```bash
kubectl exec -it -n postgres postgres-cluster-1 -- psql -U postgres -c "SELECT 1;"
```

3. Check firewall rules on your cloud provider

### Can't resolve hostname

1. Verify DNS records:
```bash
dig postgres.yourdomain.com
nslookup postgres.yourdomain.com
```

2. Check LoadBalancer IP matches DNS:
```bash
kubectl get svc ingress-nginx-controller-tcp -n ingress-nginx -o wide
```

## Monitoring External Connections

Add these queries to monitor external access:

```sql
-- View current connections
SELECT datname, usename, application_name, client_addr, state
FROM pg_stat_activity
WHERE client_addr IS NOT NULL;

-- Count connections by client IP
SELECT client_addr, count(*)
FROM pg_stat_activity
WHERE client_addr IS NOT NULL
GROUP BY client_addr;
```

## Disable External Access

To remove external access:

```bash
# Remove the external service
kubectl delete -f ingress/postgres-external-service.yaml

# Remove TCP ConfigMap (optional)
kubectl delete configmap tcp-services -n ingress-nginx
```

## Best Practices

1. **Use connection pooler** (PgBouncer) for external connections
2. **Enable SSL/TLS** for encryption in transit
3. **Restrict IP ranges** using LoadBalancer source ranges
4. **Monitor connections** regularly for suspicious activity
5. **Use read replicas** for read-only external access
6. **Set connection limits** per user/database
7. **Regular security audits** of pg_hba.conf
8. **Use secrets management** for credentials (Vault, AWS Secrets Manager)

## Alternative: Use Proxy/Bastion

For better security, consider using a bastion host or proxy:

```
External Client → Bastion (with auth) → PostgreSQL
```

This allows you to:
- Add authentication layer
- Audit all connections
- Use mTLS for client certificates
- Rate limit connections
- Add WAF protection
