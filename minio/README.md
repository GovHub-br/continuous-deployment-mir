# MinIO

Implantação do **MinIO** em Kubernetes para armazenamento de objetos (logs/artefatos).  
Este diretório/ambiente foi pensado para ser aplicado **automaticamente** pelo **Argo CD** (app-of-apps), com overlays por ambiente (`values.yaml`, `prod/values.yaml`).

- [MinIO](#minio)
  - [Requisitos](#requisitos)
  - [Secret de Admin (existingSecret)](#secret-de-admin-existingsecret)
    - [Chaves esperadas](#chaves-esperadas)
  - [Setup](#setup)
    - [Via Argo CD (recomendado)](#via-argo-cd-recomendado)

---

## Requisitos

- **Namespace** `minio` existente (ou crie: `kubectl create ns minio`).
- **StorageClass** padrão funcional para PVCs, ou configuração explícita de `storageClassName` no chart.
- Em produção, o **overlay** (`prod/values.yaml`) define:
  ```yaml
  existingSecret: "minio-credentials"
  ```
  (o chart lerá as credenciais de admin dessa Secret).

---

## Secret de Admin (existingSecret)

Crie **ANTES** do deploy a Secret **`minio-credentials`** no namespace `minio`.  

### Chaves esperadas

O chart oficial do MinIO (`charts.min.io`, usado em `prod/Chart.yaml`) lê as credenciais de admin de `existingSecret` com as chaves:
- `rootUser`
- `rootPassword`

Exemplo:

```bash
kubectl -n minio create secret generic minio-credentials \
  --from-literal=rootUser=ADMIN_USERNAME \
  --from-literal=rootPassword=ADMIN_PASSWORD
```

> Substitua `ADMIN_USERNAME` e `ADMIN_PASSWORD`. Com outras chaves (ex.: `root-user`, padrão dos charts Bitnami), os pods do MinIO não sobem.

### Imagens

As imagens oficiais do MinIO deixaram de ser públicas (`quay.io/minio/*` retorna 401 e `docker.io/minio/minio` não existe mais). O `prod/values.yaml` usa `pgsty/minio` e `pgsty/mc`, um fork comunitário que publica os mesmos binários com o mesmo entrypoint do chart.

### Bucket

O bucket **`airflow-logs`**, usado pelo remote logging do Airflow, é criado automaticamente pelo job do chart (`buckets` em `prod/values.yaml`).

## Setup

### Via Argo CD (recomendado)

Este componente é gerenciado pelo **app-of-apps**:
- O `Application` do MinIO é renderizado a partir deste diretório (ex.: `app-of-apps` aponta `path: minio` no base e `path: minio/prod` no overlay de produção).
- A ordem de instalação é controlada por **sync-waves** (ex.: MinIO na mesma wave do Postgres para paralelizar, ou em wave anterior ao Airflow).

Passos:
1. Garanta a Secret **`minio-credentials`** criada em `minio`.
2. Sincronize o **app-of-apps** no Argo CD (CLI/UI).  
3. O Argo CD aplicará o `Application` do MinIO conforme seus `values`.
