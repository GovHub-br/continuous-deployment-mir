# Deploy do ambiente do MIR

Visão rápida de tudo o que o deploy exige num cluster Kubernetes já existente. Os comandos e modelos de cada componente estão nos READMEs das pastas: [`argocd/README.md`](./argocd/README.md), [`app-of-apps/README.md`](./app-of-apps/README.md), [`airflow/README.md`](./airflow/README.md) e [`minio/README.md`](./minio/README.md).

---

## 1. Pré-requisitos

### Cluster

- Kubernetes em funcionamento (validado com RKE2 v1.35: 1 manager de 4 vCPU/8 GB e 2 workers de 8 vCPU/16 GB).
- **StorageClass padrão com suporte a `ReadWriteMany`** (o Airflow usa 4 volumes compartilhados). Validado com Longhorn v1.8.2.
- **Nó do control plane protegido** (`kubectl cordon` ou *taint*), se for pequeno. Os pods do Airflow podem esgotar a memória dele e travar o etcd.
- **Acesso à internet a partir dos nós**, para baixar:
  - imagens: `ghcr.io`, `docker.io`, `quay.io`, `registry.k8s.io`;
  - charts: `argoproj.github.io`, `charts.min.io`, `charts.bitnami.com`, `gitlab.com`;
  - código: `github.com` (manifestos e DAGs).
- **Sem outro Argo CD instalado** no cluster. Os CRDs e ClusterRoles são compartilhados, e os nomes dos Applications colidiriam.
- **cert-manager**, somente para `prod` e `preprod`. Esses ambientes expõem o Airflow por Ingress com HTTPS, e o certificado do Let's Encrypt é emitido pelo cert-manager: os overlays criam um `Issuer`, que só existe com ele instalado. **Este repositório não instala o cert-manager**; sem ele, o sync do Airflow falha e o ambiente fica parado. Pode ser instalado como pré-requisito do cluster (chart oficial com os CRDs, como no cluster do LAPPIS) ou incluído no app-of-apps antes do Airflow. Se o acesso for só interno, outra saída é tirar o Ingress de `prod`, como no `teste`.

### Ferramentas

`kubectl`, `helm` e `git` na máquina de quem faz o deploy.

### Tokens do GitHub

Ambos *fine-grained*, somente leitura, com data de expiração. De preferência de uma **conta de serviço** da equipe, para não depender de uma pessoa.

| Token | Para quê | Acesso | Obrigatório? |
|---|---|---|---|
| **Argo CD** | Ler este repositório de manifestos | Só este repositório, `Contents: Read-only` | Só se o repositório for **privado** |
| **git-sync** | O Airflow baixar as DAGs do `data-application-mir` | `Public repositories (read-only)`, ou o repositório das DAGs, se for privado | **Sempre**: o chart do Airflow exige a credencial |

### Bancos de dados

Dois bancos Postgres: o de **metadados do Airflow** e o **Data Warehouse**. O Data Warehouse pode ter qualquer nome, desde que seja o mesmo em `DB_DW_DBNAME_MIR` (Secret `db-dw-mir`, usado pelo dbt) e nas URLs do Secret `airflow-mir-connections` (usado pelas DAGs de ingestão). Se os dois apontarem para bancos diferentes, as ingestões gravam num banco e o dbt procura os dados em outro. Os bancos podem ficar:

- **no cluster**: componente `postgres` ligado;
- **fora do cluster**: o servidor precisa liberar no `pg_hba.conf` o IP de cada nó que roda o Airflow, e o usuário do Data Warehouse precisa de permissão para criar schemas;
- ou um em cada lugar.

---

## 2. Onde colocar as URLs

Os manifestos têm URLs e nomes fixos. **Antes do primeiro deploy num repositório novo**, ajuste o que for diferente.

### Endereço deste repositório (sempre que ele mudar de lugar)

O Argo CD lê os manifestos a partir desta URL. Ela aparece em **6 arquivos**, e todos precisam ter **exatamente o mesmo valor** (com `.git` no final):

| Arquivo | Campo |
|---|---|
| `app-of-apps/values.yaml` | `global.spec.source.repoURL`: usado por todos os Applications filhos (Postgres, MinIO, Airflow) |
| `argocd/application.teste.yaml` | `spec.source.repoURL` |
| `argocd/application.prod.yaml` | `spec.source.repoURL` |
| `argocd/entrypoints/teste/entrypoint.yaml` | `spec.source.repoURL` |
| `argocd/entrypoints/prod/entrypoint.yaml` e `preprod/entrypoint.yaml` | `spec.source.repoURL` |

Além deles, se o repositório for privado, a mesma URL vai na chave `url` do Secret `repo-access`, no namespace `argocd`.

Para encontrar todas as ocorrências:

```bash
grep -rn 'repoURL' --include=*.yaml .
```

**Branch:** os entrypoints usam `targetRevision: main`, e os demais usam `HEAD`, que é a branch padrão do repositório. Se a branch principal tiver outro nome, ajuste os entrypoints.

### Outros endereços (só se mudarem)

| O quê | Arquivo | Campo | Valor atual |
|---|---|---|---|
| Repositório das DAGs | `airflow/base/values.yaml` | `dags.gitSync.repo` (e `branch` nos overlays) | `https://github.com/GovHub-br/data-application-mir` |
| Imagem do Airflow | `airflow/base/values.yaml` | `defaultAirflowRepository` e `defaultAirflowTag` | `ghcr.io/govhub-br/airflow-mir`, fixada por SHA |
| Domínio do Argo CD | `argocd/values.<env>.yaml` | `global.domain` | `*.mir.example.com` (placeholder) |
| Domínio do Airflow | `airflow/prod/` e `airflow/homolog/kustomization.yaml` | `ingress.web.hosts[].name` | `*.mir.example.com` (placeholder) |
| Imagens do MinIO | `minio/prod/values.yaml` | `image` e `mcImage` | `pgsty/minio` e `pgsty/mc`, porque as oficiais deixaram de ser públicas |

Os domínios só são usados em `prod` e `preprod`, que expõem o Airflow por Ingress com certificado. Esses ambientes também exigem **cert-manager** e **ingress-nginx** no cluster, e **DNS** apontando para o ingress. O ambiente `teste` usa NodePort e dispensa os três.

---

## 3. Namespaces

| Namespace | Quem cria | Precisa existir antes do deploy? |
|---|---|---|
| `argocd` | O `helm install` do Argo CD | Não |
| `postgresql` | Você | **Sim**, se o Postgres ficar no cluster: os Secrets do banco vão nele |
| `minio` | Você | **Sim**: o Secret de credenciais vai nele |
| `airflow` | Você | **Sim**: os 11 Secrets do Airflow vão nele |

O Argo CD também criaria esses namespaces sozinho (`CreateNamespace=true`), mas só na hora do sync, quando os Secrets já precisam existir.

## 4. Secrets

Nenhuma senha fica no Git. Os manifestos só referenciam Secrets pelo nome, e eles precisam ser criados à mão **antes** do deploy. Se algum faltar, o pod correspondente não sobe (`CreateContainerConfigError`).

| Namespace | Secrets |
|---|---|
| `argocd` | `repo-access` (só se o repositório for privado) |
| `postgresql` | `postgres-credentials`, `postgres-initdb` (só com o Postgres no cluster) |
| `minio` | `minio-credentials` |
| `airflow` | `airflow-metadata`, `db-dw-mir`, `airflow-mir-connections`, `minio-airflow-svcacct`, `airflow-fernet-key`, `airflow-webserver-secret-key`, `airflow-redis-password`, `airflow-broker-url`, `airflow-webserver-admin-credentials`, `airflow-smtp`, `airflow-git-credentials` |

Os modelos, com as chaves e o conteúdo de cada um, estão em [`airflow/README.md`](./airflow/README.md#secrets) e [`minio/README.md`](./minio/README.md). O Postgres do cluster não tem README próprio; os Secrets dele são:

- `postgres-credentials`: chave `postgres-password`, com a senha do superusuário `postgres`;
- `postgres-initdb`: chave `init.sql`, com o script SQL que cria os bancos e usuários (o de metadados do Airflow e o do Data Warehouse, com o schema do dbt). O script **só roda no primeiro boot**, com o volume vazio; se o volume já existir, crie os bancos à mão.

---

## 5. Como funciona o sync

```text
git push ──► repositório ──(o Argo CD verifica a cada ~3 min)──► compara com o cluster ──► aplica a diferença

argocd/application.<env>.yaml     (aplicado à mão, uma vez)
  └─ entrypoint
       └─ app-of-apps             lê app-of-apps/values.yaml + values.<env>.yaml
            ├─ postgres  wave -5
            ├─ minio     wave -4
            └─ airflow   wave  0
```

- **Um único `kubectl apply` manual.** Depois dele, toda mudança no ambiente é um commit. O Argo CD aplica sozinho, e o botão **Refresh** na interface antecipa a verificação.
- **Waves:** o Argo CD só passa para a wave seguinte quando a anterior está `Healthy`. O Airflow só sobe com o banco e o MinIO prontos.
- **Ligar e desligar componentes:** `disable: true|false` em `app-of-apps/values.<env>.yaml`. Com `prune: false`, **desligar não apaga** o Application: é preciso apagá-lo à mão.
- **Self-heal:** nos componentes (Postgres, MinIO, Airflow), mudanças feitas direto no cluster, em recursos que o Argo CD gerencia, são desfeitas. Altere pelo Git.
- **Jobs do Airflow:** a migração do banco e a criação do usuário admin rodam **a cada sync** do Application `airflow`.
- **O que o sync não cobre:**
  - **Secrets:** não estão no Git. Depois de trocar um, é preciso reiniciar o Airflow (`kubectl rollout restart`).
  - **DAGs e projeto dbt:** chegam pelo **git-sync**, direto da `main` do `data-application-mir`, em poucos minutos, sem passar pelo Argo CD.
  - **Dependências Python:** vêm da **imagem**. Uma versão nova exige trocar o `defaultAirflowTag` (um commit).
- **Sync travado:** se um sync fica esperando um recurso que nunca fica saudável, novos commits não são aplicados. Na interface: **Terminate**, depois **Sync**.

---

## 6. Ordem de execução

1. Preparar o cluster: StorageClass, proteção do control plane e, em `prod`/`preprod`, cert-manager, Ingress e DNS (seção 1).
2. Ajustar as URLs (seção 2), fazer commit e push.
3. Instalar o Argo CD: `helm install` com `argocd/values.yaml` e `argocd/values.<env>.yaml`.
4. Criar o Secret `repo-access`, se o repositório for privado.
5. Preparar os bancos externos, se houver.
6. Criar os namespaces e os Secrets (seções 3 e 4).
7. `kubectl apply -f argocd/application.<env>.yaml`. No `preprod`, que não tem `application.preprod.yaml`, aplique `argocd/entrypoints/preprod/entrypoint.yaml`.
8. Validar: Applications `Synced`/`Healthy`, DAGs sem erro de import, logs das tasks na interface e dbt conectando.
9. Criar as Variables do Airflow ([`airflow/README.md`](./airflow/README.md#variables-do-airflow)).

## 7. Acessos (ambiente `teste`)

| Serviço | Endereço | Credenciais |
|---|---|---|
| Airflow | `http://<IP-de-um-nó>:31151` | Secret `airflow-webserver-admin-credentials` |
| Argo CD | `https://<IP-de-um-nó>:30009` | `admin` / Secret `argocd-initial-admin-secret` |
| MinIO | `http://<IP-de-um-nó>:30006` | Secret `minio-credentials` |
| Postgres do cluster | `kubectl -n postgresql port-forward svc/postgres-release-postgresql 15432:5432` | Usuários criados no `postgres-initdb` |

Sem a porta no endereço, a resposta é **404**, dada pelo ingress do cluster. As NodePorts são únicas por cluster: se ele já tiver serviços nessas portas, altere-as nos values.
