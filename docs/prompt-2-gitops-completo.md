Reestruturar o repositório `hermes-infra` (ferreiraesilva/hermes-infra) para GitOps
completo com GitHub Actions.

Contexto: o repo já existe com a estrutura anterior (scripts Python, catalog/,
clients/*.json). Substitua pela estrutura abaixo. KISS/YAGNI, sem secrets versionados.
Se faltar dado bloqueante, solicite-o.

## Arquitetura (não muda)

- 1 cliente = 1 container `hermes-<cliente>-<ambiente>`, 1 volume, 1 chave LLM
- Profiles = runtime dentro do container (criado por `hermes profile create`, não versionado)
- Database: 1 por (produto × cliente). Nunca compartilhe schema.
- `.env` = só secrets. Comportamento e `plugins.enabled` em `config.yaml`.
- 1 Postgres por ambiente (`postgres-hml`, `postgres-prd`). Isolamento por grants.

## Bloqueio inicial

Confirme imagem com `docker images` e obtenha o digest:

    docker inspect <ID> --format '{{.RepoDigests}}'

Use `nousresearch/hermes-agent@sha256:...` em todos os compose. Sem digest, pare.
Nunca use `:latest`.

## Estrutura-alvo

    hermes-infra/
      README.md
      RISKS.md
      .gitignore
      platform/hermes/
        compose.base.yml
        compose.prd.yml
        HERMES_VARS.md
      orchestration/
        provision.yml
        deploy.yml
        rollback.yml
      envs/hml/env.reference.md
      envs/prd/env.reference.md
      clients/_template/
        .env.example
        config.yaml
        compose.client.yml
        README.md

`.gitignore` cobre `clients/**/.env`. Só o template — sem clientes reais, sem `profiles/`.
Remova arquivos da estrutura anterior (catalog/, scripts/inventory.py, etc.).

## Convenções

- Container: `hermes-<cliente>-<ambiente>` / Volume: `~/.hermes-<cliente>-<ambiente>`
- Database: `db_<produto>_<cliente>` / Role: `role_<produto>_<cliente>`
- Variável: `DB_<PRODUTO>_URL`

`.env.example` (produtos atuais: taskme, minhaincorporadora):

    # postgresql://role_<produto>_<cliente>@postgres-<env>/db_<produto>_<cliente>
    HERMES_LLM_API_KEY=
    DB_TASKME_URL=
    DB_INCORPORADORA_URL=

## Provisionamento (`provision.yml`)

1. Container/volume + chave LLM
2. Itere pelos produtos: crie `db_<produto>_<cliente>` e `role_<produto>_<cliente>`
3. SQL idempotente: `GRANT` só no database próprio + `REVOKE CONNECT` nos demais
4. Escreva URLs no `.env` (fora do git); senhas vêm de secrets do GH Environment
5. Configure profiles e `plugins.enabled`

HML executa direto; PRD exige aprovação no Environment `prd`.

## Deploy e rollback

Deploy: PR em `clients/<cliente>/` → HML → PRD com required reviewer.
Rollback: reverta commit/tag e redeploye. Use GH Environments `hml`/`prd`.
Documente no README.

## Riscos (`RISKS.md`)

1. Postgres único/ambiente é SPOF deliberado; HA futura = réplica/failover do Postgres
2. Host único: blast radius é o ambiente inteiro; mitigue com PR obrigatório em `platform/`
3. Isolamento lógico por grants; grant errado vaza dados entre clientes
4. Backup sem restore testado é pendência crítica — registre status real

## Restrições

Não toque em repos de produto. Não versione `.env`. Não use `:latest`.
Não crie `profiles/`, clientes reais, SOPS ou secrets manager.

## Validação

- [ ] Sem `:latest` (`grep -r latest platform/`)
- [ ] `clients/**/.env` ignorado; nenhum `.env` real no git
- [ ] Estrutura-alvo completa sem `profiles/` e sem arquivos legados
- [ ] SQL idempotente com grants cruzados
- [ ] PRD com aprovação; HML sem
- [ ] `RISKS.md` com os 4 riscos

Mostre: árvore, `compose.base.yml`, `config.yaml`, `.env.example`, `RISKS.md`
e decisões por falta de informação.
