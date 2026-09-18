# JFrog Artifactory Local Docker Installation and PostgreSQL Configuration Runbook

## 1. Purpose

This runbook documents the installation, configuration, validation, and troubleshooting of a local JFrog Artifactory OSS instance running in Docker with PostgreSQL as the external database.

The setup is intended for local development and Jenkins build/release infrastructure testing.

### Architecture

```text
Windows Host
│
├── Docker Desktop
│
├── artifactory
│   └── JFrog Artifactory OSS
│       ├── Router
│       ├── Artifactory
│       ├── Access
│       └── PostgreSQL JDBC connection
│
└── jfrog-postgres
    └── PostgreSQL 16.8
```

Both containers communicate through the Docker network:

```text
jfrog-net
```

---

# 2. Prerequisites

## Host

Windows with Docker Desktop installed and running.

Verify:

```powershell
docker version
```

Verify Docker is running:

```powershell
docker info
```

---

# 3. Create Persistent Artifactory Storage

Create the host directory:

```powershell
New-Item -ItemType Directory -Force C:\jfrog\artifactory\var
```

The directory is mounted into the Artifactory container as:

```text
/var/opt/jfrog/artifactory
```

This preserves Artifactory configuration, logs, keys, and other persistent data when the container is restarted.

---

# 4. Create PostgreSQL Container

Create the PostgreSQL database container:

```powershell
docker run --name jfrog-postgres `
  -d `
  -e POSTGRES_USER=artifactory `
  -e POSTGRES_PASSWORD=password `
  -e POSTGRES_DB=artifactorydb `
  -p 5432:5432 `
  postgres:16.8
```

### Database parameters

| Parameter          | Value            |
| ------------------ | ---------------- |
| Container          | `jfrog-postgres` |
| PostgreSQL version | `16.8`           |
| Database           | `artifactorydb`  |
| Username           | `artifactory`    |
| Password           | `password`       |
| Port               | `5432`           |

For a shared or production environment, replace the example password with a securely managed credential.

---

# 5. Verify PostgreSQL

Check the container:

```powershell
docker ps
```

Expected:

```text
jfrog-postgres
```

Check PostgreSQL logs:

```powershell
docker logs jfrog-postgres
```

Verify PostgreSQL accepts connections:

```powershell
docker exec jfrog-postgres `
  psql -U artifactory -d artifactorydb -c "SELECT version();"
```

A PostgreSQL version should be returned.

---

# 6. Create Docker Network

Create a dedicated network for JFrog services:

```powershell
docker network create jfrog-net
```

If the network already exists, Docker will report that it already exists. This is harmless.

---

# 7. Connect PostgreSQL to the Network

```powershell
docker network connect jfrog-net jfrog-postgres
```

Verify:

```powershell
docker network inspect jfrog-net
```

The PostgreSQL container should appear under the network's containers.

---

# 8. Create Artifactory Container

Example:

```powershell
docker run --name artifactory `
  -d `
  -p 8081:8081 `
  -p 8082:8082 `
  -v C:\jfrog\artifactory\var:/var/opt/jfrog/artifactory `
  releases-docker.jfrog.io/jfrog/artifactory-oss:7.161.15
```

### Artifactory parameters

| Parameter          | Value                            |
| ------------------ | -------------------------------- |
| Container          | `artifactory`                    |
| Image              | `jfrog/artifactory-oss:7.161.15` |
| Host API port      | `8081`                           |
| Host UI port       | `8082`                           |
| Persistent storage | `C:\jfrog\artifactory\var`       |

---

# 9. Connect Artifactory to PostgreSQL Network

```powershell
docker network connect jfrog-net artifactory
```

Verify:

```powershell
docker network inspect jfrog-net
```

Both containers should be listed:

```text
artifactory
jfrog-postgres
```

---

# 10. Verify Docker DNS

From inside Artifactory:

```powershell
docker exec artifactory bash -c "getent hosts jfrog-postgres"
```

Expected result should contain an IP address for:

```text
jfrog-postgres
```

This confirms Docker's internal DNS can resolve the PostgreSQL container.

---

# 11. Verify PostgreSQL Network Connectivity

Test TCP connectivity from Artifactory:

```powershell
docker exec artifactory bash -c "bash -c '</dev/tcp/jfrog-postgres/5432' && echo PostgreSQL_OK || echo PostgreSQL_FAILED"
```

Expected:

```text
PostgreSQL_OK
```

If this returns:

```text
PostgreSQL_FAILED
```

do not continue with Artifactory database troubleshooting until Docker networking is fixed.

---

# 12. Configure Artifactory to Use PostgreSQL

The Artifactory configuration file is:

```text
/var/opt/jfrog/artifactory/etc/system.yaml
```

On the Windows host, because of the volume mapping, it is:

```text
C:\jfrog\artifactory\var\etc\system.yaml
```

Open it:

```powershell
notepad C:\jfrog\artifactory\var\etc\system.yaml
```

---

# 13. PostgreSQL Configuration

The default configuration contains a commented database section similar to:

```yaml
shared:
    database:
        #   type: postgresql
        #   driver: org.postgresql.Driver
        #   url: "jdbc:postgresql://<your db url>/artifactory"
        #   username: artifactory
        #   password: password
```

Configure it as:

```yaml
shared:
    database:
        type: postgresql
        driver: org.postgresql.Driver
        url: "jdbc:postgresql://jfrog-postgres:5432/artifactorydb"
        username: artifactory
        password: password
```

### Important

The hostname must be:

```text
jfrog-postgres
```

not:

```text
localhost
```

Inside the Artifactory container:

```text
localhost
```

means the Artifactory container itself.

Docker's service/container DNS name:

```text
jfrog-postgres
```

allows Artifactory to connect to the PostgreSQL container.

---

# 14. Back Up system.yaml

Before making configuration changes:

```powershell
docker exec artifactory `
  bash -c "cp /var/opt/jfrog/artifactory/etc/system.yaml /var/opt/jfrog/artifactory/etc/system.yaml.backup"
```

Alternatively, back up from Windows:

```powershell
Copy-Item `
  C:\jfrog\artifactory\var\etc\system.yaml `
  C:\jfrog\artifactory\var\etc\system.yaml.backup
```

---

# 15. Restart Artifactory

After changing `system.yaml`:

```powershell
docker restart artifactory
```

Check the container:

```powershell
docker ps
```

Check startup logs:

```powershell
docker logs -f artifactory
```

Allow several minutes for initial startup.

---

# 16. Validate Artifactory Services

Check container status:

```powershell
docker ps
```

The Artifactory container should show:

```text
Up
```

Check the main logs:

```powershell
docker logs artifactory
```

Check Access logs:

```powershell
docker exec artifactory `
  bash -c "tail -100 /var/opt/jfrog/artifactory/log/access-service.log"
```

---

# 17. Verify PostgreSQL Database Tables

After successful Artifactory initialization:

```powershell
docker exec jfrog-postgres `
  psql -U artifactory -d artifactorydb -c "\dt"
```

Artifactory should create its required database tables.

---

# 18. Access the Artifactory UI

With the standard Docker port mapping:

```text
http://localhost:8082/ui/
```

Artifactory's API is available through:

```text
http://localhost:8081
```

Do not confuse the host ports with the internal container ports.

---

# 19. Check Container Status

Useful command:

```powershell
docker ps -a
```

Expected services:

```text
artifactory
jfrog-postgres
```

Both should show:

```text
Up
```

---

# 20. Common Troubleshooting

## Problem: Artifactory reports Derby is not allowed

Typical error:

```text
DbTypeNotAllowedException:
DB Type derby is not allowed:
Cannot start the application with a database other than PostgreSQL.
```

### Cause

Artifactory is using the default embedded Derby database because PostgreSQL configuration is commented out.

### Resolution

Verify:

```text
C:\jfrog\artifactory\var\etc\system.yaml
```

contains:

```yaml
shared:
    database:
        type: postgresql
        driver: org.postgresql.Driver
        url: "jdbc:postgresql://jfrog-postgres:5432/artifactorydb"
        username: artifactory
        password: password
```

Then:

```powershell
docker restart artifactory
```

---

# 21. Problem: Access Service Is Not Listening on Port 8046

Check:

```powershell
docker exec artifactory `
  bash -c "curl -v http://localhost:8046/access/api/v1/system/ping"
```

If you see:

```text
Connection refused
```

check Access logs:

```powershell
docker exec artifactory `
  bash -c "grep -i -E 'Caused by:|SQLException|Connection refused|password authentication|database|postgres|jdbc|FATAL' /var/opt/jfrog/artifactory/log/access-service.log | tail -80"
```

Look for database initialization failures.

---

# 22. Problem: PostgreSQL Connection Fails

Verify PostgreSQL:

```powershell
docker ps
```

Then:

```powershell
docker logs jfrog-postgres
```

Test DNS:

```powershell
docker exec artifactory bash -c "getent hosts jfrog-postgres"
```

Test port:

```powershell
docker exec artifactory bash -c "bash -c '</dev/tcp/jfrog-postgres/5432' && echo PostgreSQL_OK || echo PostgreSQL_FAILED"
```

Verify PostgreSQL itself:

```powershell
docker exec jfrog-postgres `
  psql -U artifactory -d artifactorydb `
  -c "SELECT current_database(), current_user;"
```

Expected:

```text
current_database | current_user
-----------------+--------------
artifactorydb    | artifactory
```

---

# 23. Problem: Artifactory Container Keeps Restarting

Check:

```powershell
docker ps -a
```

Then:

```powershell
docker logs --tail 200 artifactory
```

Look specifically for:

```text
ERROR
Exception
Caused by
database
postgres
Access
Bootstrap
```

Also inspect:

```powershell
docker exec artifactory `
  bash -c "tail -200 /var/opt/jfrog/artifactory/log/artifactory-service.log"
```

and:

```powershell
docker exec artifactory `
  bash -c "tail -200 /var/opt/jfrog/artifactory/log/access-service.log"
```

---

# 24. Problem: Artifactory Cannot Resolve PostgreSQL

If:

```powershell
docker exec artifactory bash -c "getent hosts jfrog-postgres"
```

returns nothing, inspect the network:

```powershell
docker network inspect jfrog-net
```

Reconnect the containers:

```powershell
docker network connect jfrog-net jfrog-postgres
docker network connect jfrog-net artifactory
```

Then retry the DNS test.

---

# 25. Useful Daily Operations

## Start

```powershell
docker start jfrog-postgres
docker start artifactory
```

## Stop

```powershell
docker stop artifactory
docker stop jfrog-postgres
```

## Restart

```powershell
docker restart artifactory
```

## Status

```powershell
docker ps -a
```

## Artifactory logs

```powershell
docker logs -f artifactory
```

## PostgreSQL logs

```powershell
docker logs -f jfrog-postgres
```

---

# 26. Backup Strategy

At minimum, back up:

```text
C:\jfrog\artifactory\var
```

and the PostgreSQL database.

A PostgreSQL logical backup can be created with:

```powershell
docker exec jfrog-postgres `
  pg_dump -U artifactory artifactorydb `
  > C:\jfrog\artifactory\artifactorydb-backup.sql
```

Verify the backup exists:

```powershell
Get-Item C:\jfrog\artifactory\artifactorydb-backup.sql
```

For a production/shared environment, use a more formal database backup and retention strategy.

---

# 27. Important Configuration Values

Keep the following values documented for the local environment:

```text
Artifactory container:
    artifactory

PostgreSQL container:
    jfrog-postgres

Docker network:
    jfrog-net

PostgreSQL database:
    artifactorydb

PostgreSQL user:
    artifactory

PostgreSQL port:
    5432

Artifactory API:
    http://localhost:8081

Artifactory UI:
    http://localhost:8082/ui/

Artifactory persistent storage:
    C:\jfrog\artifactory\var
```

---

# 28. Final Health Check

Run the following sequence:

```powershell
docker ps
```

Both containers should be running.

Then:

```powershell
docker network inspect jfrog-net
```

Both containers should be connected.

Then:

```powershell
docker exec artifactory bash -c "getent hosts jfrog-postgres"
```

PostgreSQL should resolve.

Then:

```powershell
docker exec artifactory bash -c "bash -c '</dev/tcp/jfrog-postgres/5432' && echo PostgreSQL_OK || echo PostgreSQL_FAILED"
```

Expected:

```text
PostgreSQL_OK
```

Then:

```powershell
docker exec jfrog-postgres `
  psql -U artifactory -d artifactorydb `
  -c "SELECT current_database(), current_user;"
```

Then:

```powershell
docker logs --tail 100 artifactory
```

Finally open:

```text
http://localhost:8082/ui/
```

---

# 29. Jenkins Integration

Once Artifactory is healthy, it can be used as the artifact repository for the Jenkins build infrastructure.

Recommended flow:

```text
                    ┌─────────────────────┐
                    │       Jenkins       │
                    │                     │
                    │ Windows Build Node  │
                    └──────────┬──────────┘
                               │
                 upload/download artifacts
                               │
                               ▼
                    ┌─────────────────────┐
                    │     Artifactory     │
                    │                     │
                    │  Generic Repository │
                    │  Docker Repository  │
                    │  Maven/etc.         │
                    └──────────┬──────────┘
                               │
                               │ JDBC
                               ▼
                    ┌─────────────────────┐
                    │     PostgreSQL      │
                    │    artifactorydb    │
                    └─────────────────────┘
```

For the Windows build-tool provisioning project, Artifactory can subsequently hold immutable installers/packages such as:

```text
VS2022
Qt
LLVM
CMake
Ninja
Python
Conan
7-Zip
Git
JFrog CLI
Windows ADK
InstallShield
```

This provides a reproducible source for the Jenkins/Packer Windows build-node provisioning process.

---

# 30. Operational Principle

The important configuration decision for this environment is:

```text
Artifactory
    ↓
PostgreSQL
```

rather than:

```text
Artifactory
    ↓
Embedded Derby
```

The PostgreSQL database should be treated as persistent state, while the Artifactory Docker container itself should be considered replaceable.

Therefore:

**Container = replaceable**

**Artifactory persistent volume = preserve**

**PostgreSQL database = preserve and back up**

**system.yaml = preserve and back up**

This makes it possible to recreate or upgrade the Artifactory container without losing the repository configuration and artifact metadata.
