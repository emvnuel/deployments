# Quick Setup Guide for External PostgreSQL Access

Your nginx ingress has been configured to expose PostgreSQL on port 5432 using the **shared LoadBalancer** approach.

## ✅ Already Configured

The following has been automatically applied:

1. TCP services ConfigMap created
2. Nginx ingress controller updated with TCP services support
3. LoadBalancer service patched to include port 5432

Your existing LoadBalancer now exposes:
- Port 80 (HTTP)
- Port 443 (HTTPS)  
- Port 5432 (PostgreSQL)

## Your External IPs

```
137.131.136.132
144.22.174.205
164.152.51.165
```

All these IPs now accept PostgreSQL connections on port 5432.

## Next Step: Set up DNS

Point your subdomain to any of the external IPs (I recommend using the first one):

```
postgres.awesomeapps.cloud  A  137.131.136.132
```

Example DNS record in your provider (Cloudflare, Route53, etc.):
```
Name: postgres
Type: A
Value: 137.131.136.132
TTL: 300
```

## Connect!

Once DNS is configured:

```bash
psql "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database"
```

## Example Connection String

```
postgresql://app_user:yourpassword@postgres.awesomeapps.cloud:5432/app_database
```

Or specify each parameter:
```
Host: postgres.awesomeapps.cloud
Port: 5432
Database: app_database
Username: app_user
Password: yourpassword
```

## Verify Configuration

Check that everything is working:

```bash
# Verify LoadBalancer has port 5432
kubectl get svc ingress-nginx-controller -n ingress-nginx

# Test port is open (once DNS is set)
telnet postgres.awesomeapps.cloud 5432

# Or test connection
psql "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database" -c "SELECT version();"
```

## Security Note

Add SSL and restrict IPs in production! See `ingress/README.md` for details.
