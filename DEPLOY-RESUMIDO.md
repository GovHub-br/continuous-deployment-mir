# Deploy resumido

Guia curto para (1) adaptar o projeto a **repositórios novos** e (2) **subir o ambiente do zero** num cluster Kubernetes que já existe. Os detalhes de cada componente estão no README da pasta correspondente.

> **Ambientes.** `prod` e `preprod` são os ambientes do projeto. O `teste` foi criado para validar o repositório num cluster isolado: é igual ao `prod`, mas sem Ingress/HTTPS e com o Postgres dentro do cluster.

---

## 1. Se o projeto for para repositórios novos

### Novo repositório de manifestos (este, `continuous-deployment-mir`)

O Argo CD lê os manifestos pela URL deste repositório. Troque a URL em **todos** estes arquivos, com o mesmo valor (terminando em `.git`):

| Arquivo | Campo |
|---|---|
| `app-of-apps/values.yaml` | `global.spec.source.repoURL` (vale para todos os componentes) |
| `argocd/application.prod.yaml` | `spec.source.repoURL` |
| `argocd/application.teste.yaml` | `spec.source.repoURL` |
| `argocd/entrypoints/prod/entrypoint.yaml` | `spec.source.repoURL` |
| `argocd/entrypoints/preprod/entrypoint.yaml` | `spec.source.repoURL` |
| `argocd/entrypoints/teste/entrypoint.yaml` | `spec.source.repoURL` |

- Para conferir: `grep -rn repoURL --include=*.yaml .`
- Os `entrypoint.yaml` usam `targetRevision: main`. Se a branch principal tiver outro nome, ajuste.
- Se o repositório for **privado**, o Secret `repo-access` do Argo CD precisa da mesma URL e de um token com leitura nele (ver [`argocd/README.md`](./argocd/README.md)).

### Novo repositório da aplicação (`data-application-mir`)

**No próprio `data-application-mir`:**

| Arquivo | O que mudar |
|---|---|
| `.github/workflows/main.yaml` | `IMAGE_NAME`: o endereço onde a imagem será publicada (hoje `ghcr.io/govhub-br/airflow-mir`). O pacote precisa pertencer ao novo repositório; um pacote criado por outro repositório recusa o push (`permission_denied: write_package`) |

Depois do primeiro merge na `main`, confira se o pacote foi criado e se ele é **público**. Se for privado, o cluster vai precisar de um Secret de pull.

**Neste repositório (`continuous-deployment-mir`):**

| Arquivo | Campo | O que colocar |
|---|---|---|
| `airflow/base/values.yaml` | `defaultAirflowRepository` | O mesmo `IMAGE_NAME` do CI |
| `airflow/base/values.yaml` | `defaultAirflowTag` | O SHA de um commit com imagem publicada |
| `airflow/base/values.yaml` | `dags.gitSync.repo` | A URL do novo repositório da aplicação |
| `airflow/prod/`, `airflow/homolog/` e `airflow/teste/kustomization.yaml` | `dags.gitSync.branch` | A branch das DAGs (hoje `main`) |
| `airflow/base/values.yaml` | `registry.secretName` (comentado) | Só se a imagem for privada: descomente e crie o Secret de pull |

O Secret `airflow-git-credentials` precisa de um token com leitura no novo repositório da aplicação (ver [`airflow/README.md` → Git](./airflow/README.md#git-dagsplugins)).

---

## 2. Subir o ambiente do zero

Faça nesta ordem. Cada passo depende do anterior.

| # | Passo | Por que nesta ordem | Onde está o detalhe |
|---|---|---|---|
| 1 | **Preparar o cluster**: StorageClass padrão com suporte a `ReadWriteMany` (por exemplo, Longhorn). Em `prod`/`preprod`, também o **cert-manager**, um controlador de Ingress e o DNS dos domínios | O Airflow usa volumes compartilhados, e os overlays `prod`/`homolog` criam um `Issuer`, que só existe com o cert-manager. Este repositório não instala nenhum dos dois | — |
| 2 | **Instalar o Argo CD** com `argocd/values.yaml` + `argocd/values.<env>.yaml` | É ele que aplica todo o resto | [`argocd/README.md`](./argocd/README.md) |
| 3 | **Dar ao Argo CD acesso ao repositório** (Secret `repo-access`), se ele for privado | Sem isso, o Argo CD não consegue ler os manifestos | [`argocd/README.md`](./argocd/README.md#secrets-acesso-ao-repositório-git) |
| 4 | **Preparar os bancos.** Recomendado: um servidor Postgres **fora do cluster**, com os bancos de metadados do Airflow e do Data Warehouse. O Postgres do cluster (`postgres/`) é opcional e só vem ligado no `teste` | O Airflow cria as tabelas de metadados no primeiro sync e precisa do banco pronto | [`airflow/README.md` → PostgreSQL](./airflow/README.md#postgresql) |
| 5 | **Criar os namespaces e os Secrets** de cada componente: `minio`, `airflow` e, se o Postgres for do cluster, `postgresql` | Os manifestos só referenciam os Secrets. Se faltar algum, os pods não sobem | MinIO: [`minio/README.md`](./minio/README.md). Airflow: [`airflow/README.md`](./airflow/README.md#secrets). Postgres do cluster: [`DEPLOY.md`, seção 4](./DEPLOY.md#4-secrets) |
| 6 | **Aplicar o entrypoint do ambiente**: `kubectl apply -f argocd/application.<env>.yaml` (no `preprod`, `argocd/entrypoints/preprod/entrypoint.yaml`) | É o único `apply` manual. O Argo CD sobe o resto em waves: Postgres (−5) → MinIO (−4) → Airflow (0) | [`app-of-apps/README.md`](./app-of-apps/README.md) |
| 7 | **Criar as Variables do Airflow** | Elas ficam no banco de metadados, que só existe depois do passo 6 | [`airflow/README.md` → Variables](./airflow/README.md#variables-do-airflow) |
