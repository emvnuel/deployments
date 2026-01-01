# PostgreSQL Connection Examples for awesomeapps.cloud

## Connection String Format

```
postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database
```

## Connection Parameters

```
Host: postgres.awesomeapps.cloud
Port: 5432
Database: app_database
Username: app_user
Password: <from postgres-app-user secret>
SSL Mode: prefer (or require for production)
```

## Language-Specific Examples

### Python (psycopg2)

```python
import psycopg2

# Using connection string
conn = psycopg2.connect(
    "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database"
)

# Or using parameters
conn = psycopg2.connect(
    host="postgres.awesomeapps.cloud",
    port=5432,
    database="app_database",
    user="app_user",
    password="your-password",
    sslmode="prefer"
)

cursor = conn.cursor()
cursor.execute("SELECT version();")
print(cursor.fetchone())
```

### Node.js (pg)

```javascript
const { Client } = require('pg');

// Using connection string
const client = new Client({
  connectionString: 'postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database'
});

// Or using parameters
const client = new Client({
  host: 'postgres.awesomeapps.cloud',
  port: 5432,
  database: 'app_database',
  user: 'app_user',
  password: 'your-password',
  ssl: false // Set to true in production with proper certs
});

await client.connect();
const res = await client.query('SELECT NOW()');
console.log(res.rows[0]);
await client.end();
```

### Go (pgx)

```go
package main

import (
    "context"
    "fmt"
    "github.com/jackc/pgx/v5"
)

func main() {
    ctx := context.Background()
    
    // Using connection string
    conn, err := pgx.Connect(ctx, 
        "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database")
    if err != nil {
        panic(err)
    }
    defer conn.Close(ctx)
    
    var version string
    err = conn.QueryRow(ctx, "SELECT version()").Scan(&version)
    if err != nil {
        panic(err)
    }
    fmt.Println(version)
}
```

### Java (JDBC)

```java
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

public class PostgresExample {
    public static void main(String[] args) {
        String url = "jdbc:postgresql://postgres.awesomeapps.cloud:5432/app_database";
        String user = "app_user";
        String password = "your-password";
        
        try (Connection conn = DriverManager.getConnection(url, user, password)) {
            Statement stmt = conn.createStatement();
            ResultSet rs = stmt.executeQuery("SELECT version()");
            
            if (rs.next()) {
                System.out.println(rs.getString(1));
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
```

### Ruby (pg gem)

```ruby
require 'pg'

# Using connection string
conn = PG.connect('postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database')

# Or using parameters
conn = PG::Connection.new(
  host: 'postgres.awesomeapps.cloud',
  port: 5432,
  dbname: 'app_database',
  user: 'app_user',
  password: 'your-password'
)

result = conn.exec('SELECT version()')
puts result.getvalue(0, 0)
conn.close
```

### PHP (PDO)

```php
<?php
try {
    $dsn = "pgsql:host=postgres.awesomeapps.cloud;port=5432;dbname=app_database";
    $pdo = new PDO($dsn, 'app_user', 'your-password');
    
    $stmt = $pdo->query('SELECT version()');
    echo $stmt->fetchColumn();
    
} catch (PDOException $e) {
    echo "Connection failed: " . $e->getMessage();
}
?>
```

### C# (.NET)

```csharp
using Npgsql;

var connString = "Host=postgres.awesomeapps.cloud;Port=5432;Database=app_database;Username=app_user;Password=your-password";

await using var conn = new NpgsqlConnection(connString);
await conn.OpenAsync();

await using var cmd = new NpgsqlCommand("SELECT version()", conn);
await using var reader = await cmd.ExecuteReaderAsync();

while (await reader.ReadAsync())
{
    Console.WriteLine(reader.GetString(0));
}
```

## Environment Variables

Set these in your application environment:

```bash
export DB_HOST="postgres.awesomeapps.cloud"
export DB_PORT="5432"
export DB_NAME="app_database"
export DB_USER="app_user"
export DB_PASSWORD="your-password"
export DATABASE_URL="postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database"
```

## Docker Compose Example

```yaml
version: '3.8'

services:
  app:
    image: your-app:latest
    environment:
      - DATABASE_URL=postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database
      # Or separate variables
      - DB_HOST=postgres.awesomeapps.cloud
      - DB_PORT=5432
      - DB_NAME=app_database
      - DB_USER=app_user
      - DB_PASSWORD=your-password
```

## Kubernetes Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      containers:
      - name: app
        image: myapp:latest
        env:
          - name: DB_HOST
            value: "postgres.awesomeapps.cloud"
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

## Testing Connection

### Using psql CLI

```bash
# Simple connection
psql -h postgres.awesomeapps.cloud -p 5432 -U app_user -d app_database

# With connection string
psql "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database"

# Test query
psql "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database" \
  -c "SELECT version();"
```

### Using pg_isready

```bash
pg_isready -h postgres.awesomeapps.cloud -p 5432 -U app_user
```

### Using telnet (test port open)

```bash
telnet postgres.awesomeapps.cloud 5432
```

### Using nc (netcat)

```bash
nc -zv postgres.awesomeapps.cloud 5432
```

## SSL/TLS Connection (Production)

For production, always use SSL:

```bash
psql "postgresql://app_user:password@postgres.awesomeapps.cloud:5432/app_database?sslmode=require"
```

Connection parameters with SSL:
```
?sslmode=require
?sslmode=verify-full&sslrootcert=/path/to/ca.crt
```

## Connection Pooling (Recommended)

For applications, connect via the pooler instead:

```
Host: postgres.awesomeapps.cloud
Port: 5432
```

The pooler provides better connection management and prevents connection exhaustion.
