# Sistema de Controle de Estoque

Java EE (JSP/Servlet) stock control system running on Tomcat 8.5 with MySQL 8.0.

## Components

- **App** (`myawesomeapps/sistema-estoque:1.0`) — Tomcat 8.5 + JSP/Servlet webapp, exposed on port 8080
- **MySQL** (`myawesomeapps/sistema-estoque-mysql:1.0`) — MySQL 8.0 with `sistema_estoque` schema and tables pre-loaded via `/docker-entrypoint-initdb.d/init.sql`

Both images are multi-arch (`linux/amd64` + `linux/arm64`).

## Architecture

```
┌────────────────────────┐    ┌─────────────────────────────┐
│  sistema-estoque       │───▶│ sistema-estoque-mysql:3306  │
│  (Tomcat 8.5, port     │    │ (MySQL 8.0 StatefulSet      │
│   8080)                 │    │  + PVC)                     │
└────────────────────────┘    └─────────────────────────────┘
```

The app resolves MySQL via the in-cluster DNS name `sistema-estoque-mysql:3306` (hard-coded in `ConnectionFactory.java`).

## Deploy

```bash
helm dependency update
helm template sistema-estoque .             # validate rendering
kubectl apply -f argocd-application.yaml    # let ArgoCD sync
```

See `argocd-application.yaml` for the ArgoCD Application manifest.
