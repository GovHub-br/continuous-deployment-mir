# Airflow

Instalação do Airflow do **MIR** em um cluster Kubernetes a partir do Argo CD.  
As DAGs são sincronizadas (git-sync) a partir do repositório [`data-application-mir`](https://github.com/GovHub-br/data-application-mir).  
Antes, é necessário fazer o deploy do MinIO.

- [Airflow](#airflow)
  - [Secrets](#secrets)
    - [Usuário admin](#usuário-admin)
    - [SMTP](#smtp)
    - [Git (DAGs/Plugins)](#git-dagsplugins)
    - [Webserver Secret Key](#webserver-secret-key)
    - [Redis (Celery/CeleryKubernetes)](#redis-celerycelerykubernetes)
    - [Data Warehouse do MIR](#data-warehouse-do-mir)
    - [Conexões do Airflow (postgres_default / postgres_mir)](#conexões-do-airflow-postgres_default--postgres_mir)
    - [Imagem (GHCR)](#imagem-ghcr)
  - [Variables do Airflow](#variables-do-airflow)
  - [Bucket](#bucket)
  - [Fernet Key](#fernet-key)
    - [Gerar (sem Python)](#gerar-sem-python)
    - [Gerar (Python)](#gerar-python)
    - [Secret](#secret)
  - [PostgreSQL](#postgresql)
  - [Setup](#setup)
    - [Via Argo CD (recomendado)](#via-argo-cd-recomendado)
    - [Aplicação manual (para testes)](#aplicação-manual-para-testes)

---

## Secrets

Crie o namespace (se ainda não existir):

```bash
kubectl create namespace airflow
````

### Usuário admin

Criação do usuário admin do Airflow. Substitua os campos `USERNAME`, `EMAIL`, `FIRSTNAME`, `LASTNAME`, `PASSWORD`.

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-webserver-admin-credentials
type: Opaque
stringData:
  WEBSERVER_DEFAULT_USER_ROLE: Admin
  WEBSERVER_DEFAULT_USER_USERNAME: USERNAME
  WEBSERVER_DEFAULT_USER_EMAIL: EMAIL
  WEBSERVER_DEFAULT_USER_FIRSTNAME: FIRSTNAME
  WEBSERVER_DEFAULT_USER_LASTNAME: LASTNAME
  WEBSERVER_DEFAULT_USER_PASSWORD: PASSWORD
EOF
```

### SMTP

Secret para envio de e-mails. Substitua `USER`, `PASSWORD` e ajuste host/porta se necessário.

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-smtp
type: Opaque
stringData:
  host: smtp.gmail.com
  starttls: "True"
  ssl: "False"
  user: USER
  password: PASSWORD
  port: "587"
  mail_from: USER
EOF
```

### Git (DAGs/Plugins)

Acesso aos repositórios de DAGs e plugins. Substitua `PERSONAL_ACCESS_TOKEN`.

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-git-credentials
type: Opaque
stringData:
  GIT_SYNC_USERNAME: nonexistant
  GIT_SYNC_PASSWORD: PERSONAL_ACCESS_TOKEN
  GITSYNC_USERNAME: nonexistant
  GITSYNC_PASSWORD: PERSONAL_ACCESS_TOKEN
EOF
```

### Webserver Secret Key

Secret para a chave do webserver. Substitua `SECRET_KEY`.

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-webserver-secret-key
type: Opaque
stringData:
  webserver-secret-key: SECRET_KEY
EOF
```

### Redis (Celery/CeleryKubernetes)

Somente se estiver usando **CeleryExecutor** ou **CeleryKubernetesExecutor**. Substitua `REDIS_PASSWORD`.

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-redis-password
type: Opaque
stringData:
  password: REDIS_PASSWORD
---
apiVersion: v1
kind: Secret
metadata:
  name: airflow-broker-url
type: Opaque
stringData:
  connection: redis://:REDIS_PASSWORD@airflow-redis:6379/0
EOF
```

### Data Warehouse do MIR

O dbt do MIR (`airflow_lappis/dags/dbt/mir/profiles.yml`) lê as variáveis `DB_DW_*_MIR`.
> **O banco precisa se chamar `analytics`.** O `dbt_project.yml` do `data-application-mir` fixa `+database: analytics` para todos os modelos, e o dbt no Postgres não escreve em um banco diferente do que conectou (`Cross-db references not allowed`). Por isso `DB_DW_DBNAME_MIR` e as URLs de conexão usam `analytics`.

Sem essa secret, os pods do Airflow não sobem (`CreateContainerConfigError`).

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-dw-mir
type: Opaque
stringData:
  DB_DW_HOST_MIR: HOST
  DB_DW_PORT_MIR: "5432"
  DB_DW_DBNAME_MIR: analytics
  DB_DW_SCHEMA_MIR: mir
  DB_DW_USER_MIR: DBUSER
  DB_DW_PASSWORD_MIR: PASSWORD
EOF
```

### Conexões do Airflow (postgres_default / postgres_mir)

As DAGs do MIR usam as conexões `postgres_default` e `postgres_mir` (`get_postgres_conn("postgres_mir")`).
Elas são injetadas como variáveis de ambiente `AIRFLOW_CONN_*`, que não aparecem na UI mas funcionam normalmente.
Em geral, ambas apontam para o Data Warehouse do MIR:

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-mir-connections
type: Opaque
stringData:
  AIRFLOW_CONN_POSTGRES_DEFAULT: postgresql://DBUSER:PASSWORD@HOST:5432/analytics
  AIRFLOW_CONN_POSTGRES_MIR: postgresql://DBUSER:PASSWORD@HOST:5432/analytics
EOF
```

> Caracteres especiais na senha precisam ser *URL-encoded* (ex.: `@` → `%40`).

### Imagem (GHCR)

A imagem vem da CI do `data-application-mir` (`ghcr.io/govhub-br/airflow-mir:<sha>`), publicada a cada merge na `main` com as tags `<sha>` e `latest`.
O `base/values.yaml` fixa o SHA para o deploy ser reprodutível: atualize `defaultAirflowTag` a cada release.

O pacote é público, então não precisa de secret de pull. Se ele voltar a ser **privado**, descomente `registry.secretName` em `base/values.yaml` e crie a secret (token com `read:packages`):

```bash
kubectl -n airflow create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=GITHUB_USER \
  --docker-password=GITHUB_TOKEN
```

---

## Variables do Airflow

As DAGs do MIR leem as Variables abaixo. No ambiente local, elas são criadas pelo `make dev` do `data-application-mir`.
Crie-as uma vez após o primeiro deploy (ficam salvas no banco de metadados):

```bash
AF="kubectl -n airflow exec deploy/airflow-scheduler -c scheduler --"

$AF airflow variables set airflow_orgao 'mir'
$AF airflow variables set airflow_orgao_ted 'MIR'
$AF airflow variables set airflow_variables '{"mir":{"codigos_ug":[230002,810008]}}'
$AF airflow variables set dynamic_schedules '{"empenhos_tesouro_ingest_dag":{"type":"cron","value":"0 13 * * 1-6"},"nc_tesouro_ingest_dag":{"type":"cron","value":"0 13 * * 1-6"},"pf_tesouro_ingest_dag":{"type":"cron","value":"0 13 * * 1-6"},"visao_orcamentaria_ingest":{"type":"cron","value":"0 13 * * 1-6"}}'

# Ingestão via e-mail (Tesouro Gerencial)
$AF airflow variables set email_credentials '{"email":"EMAIL","password":"SENHA","imap_server":"IMAP_SERVER","sender_email":"REMETENTE"}'

# Exportação para o OneDrive
$AF airflow variables set secret_onedrive_credentials '{"tenant_id":"TENANT_ID","client_id":"CLIENT_ID","client_secret":"CLIENT_SECRET","onedrive_user_id":"USER_ID"}'
$AF airflow variables set onedrive_export_config '{"onedrive_folder":"PASTA","tables":[{"schema":"SCHEMA","table":"TABELA","file_name":"ARQUIVO.xlsx"}]}'
```

> Os campos de `email_credentials` e `onedrive_export_config` foram extraídos do código das DAGs, mas os valores acima são exemplos. Confira o formato exato no `data-application-mir` antes de criar.

## Bucket

O bucket **`airflow-logs`** é criado automaticamente no deploy do MinIO (ver `../minio/README.md`).
Crie uma service account **`airflow-svcacct`** no MinIO e, depois, o Secret de conexão AWS para o Airflow:

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-airflow-svcacct
type: Opaque
stringData:
  AIRFLOW_CONN_AWS_DEFAULT: '{
    "conn_type": "aws",
    "login": "ACCESS_KEY_ID",
    "password": "SECRET_ACCESS_KEY",
    "extra": {
      "endpoint_url": "http://minio-svc.minio.svc.cluster.local:9000",
      "region_name": "us-east-1"
    }
  }'
EOF
```

---

## Fernet Key

A Fernet key encripta informações sensíveis no metastore do Airflow.

### Gerar (sem Python)

```bash
head -c 32 /dev/urandom | base64 | tr '+/' '-_'
```

### Gerar (Python)

```python
from cryptography.fernet import Fernet
print(Fernet.generate_key().decode())
```

### Secret

Substitua `FERNET_KEY`:

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-fernet-key
type: Opaque
stringData:
  fernet-key: FERNET_KEY
EOF
```

---

## PostgreSQL

Crie a database e o usuário:

```sql
CREATE DATABASE DBNAME;
CREATE USER DBUSER WITH PASSWORD 'PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE DBNAME TO DBUSER;

-- PostgreSQL 15:
GRANT ALL ON SCHEMA public TO DBUSER;
```

Secret de conexão:

```bash
kubectl -n airflow apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: airflow-metadata
type: Opaque
stringData:
  connection: postgresql://DBUSER:PASSWORD@HOST:PORT/DBNAME
EOF
```

---

## Setup

### Via Argo CD (recomendado)

Este diretório é aplicado **automaticamente** pelo Argo CD através do **app-of-apps**.
Quando o `Application` raiz sincroniza, o Argo CD cria/aplica o `Application` do Airflow, respeitando a ordem definida pelas **sync-waves** (ex.: MinIO → Airflow).

* Veja o README do **Argo CD**: `../argocd/README.md`
* Veja o README do **app-of-apps**: `../app-of-apps/README.md`

### Aplicação manual (para testes)

Para testar diretamente no cluster (sem esperar a sync do Argo CD), aplique o comando dentro da pasta prod ou homolog:

```bash
kubectl kustomize . \
  --enable-helm \
  --load-restrictor=LoadRestrictionsNone \
| kubectl apply -f - -n airflow
```
