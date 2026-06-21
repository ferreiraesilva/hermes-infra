# hermes-infra

Fonte da verdade das instalações Hermes administradas por Leonardo.

Este repositório define os ambientes, o Postgres compartilhado, os produtos
contratados por cliente, seus deployments, nomes de recursos e referências de
secrets. Os produtos continuam em repositórios próprios e nunca sobem Postgres.

## Homologação inicial

Cada **cliente** é um container (`hermes-<cliente>-<ambiente>`) com um ou mais
**profiles** dentro. Cada profile tem seu próprio bot Telegram e agrupa produtos;
cada produto tem banco/role próprios.

| Cliente | Container | Profile | Produtos | Bot |
|---|---|---|---|---|
| Leonardo | `hermes-leonardo-hml` | `pessoal` | TaskMe | `TMHA_Leo_TM_Hml_bot` |
| Leonardo | `hermes-leonardo-hml` | `corretores` | MinhaIncorporadora | `TMHA_Leo_MI_Hml_bot` |
| EBM | `hermes-ebm-hml` | `corretores` | MinhaIncorporadora | `TMHA_EBM_MI_Hml_bot` |
| City | `hermes-city-hml` | `interno` | TaskMe | `TMHA_City_TM_Hml_bot` |
| City | `hermes-city-hml` | `corretores` | MinhaIncorporadora | `TMHA_City_MI_Hml_bot` |

A separação por profile impede disputa entre hooks/personas. Os cinco profiles
simultâneos precisam de cinco bots Telegram exclusivos.

## Secrets

Secrets não entram no Git. No host:

```text
~/.config/hermes-infra/secrets/<ambiente>/common.env
~/.config/hermes-infra/secrets/<ambiente>/<cliente>.env
```

O arquivo do cliente contém 1 token Telegram por profile (chave = `telegram_secret`
do inventário) e 1 senha por produto (`DB_<PRODUTO>_PASSWORD`), além de
`TELEGRAM_ALLOWED_USERS` opcional. O arquivo comum contém credenciais do provedor
de IA. Nenhum script copia, remove ou modifica dados de WhatsApp.

## Comandos

```bash
python3 scripts/validate_inventory.py
./scripts/deploy-instance.sh hml leonardo      # 1 container, todos os profiles do cliente
```

O deploy recebe `<ambiente> <cliente>` (não mais deployment) e provisiona o
container único do cliente com todos os seus profiles. Exige `postgres-hml`
saudável; se ele não existir, falha sem criar outro. `prd` exige
`HERMES_INFRA_CONFIRM_PRD=1` antes de qualquer SQL.

## Profiles e gateways

Cada cliente é um container; dentro dele, cada **profile** é um `HERMES_HOME`
próprio em `/opt/data/profiles/<id>` (`.env`, `config.yaml`, sessions e gateway
isolados). O deploy, por profile: cria o profile (`hermes profile create`),
escreve o token do bot no `.env` do profile, habilita os plugins
(`hermes -p <id> plugins enable`) e sobe o gateway (`hermes -p <id> gateway
start`). Um token de bot por profile — o Telegram rejeita polling concorrente do
mesmo token.

> **Supervisão (pendência para o prompt-2):** o `gateway start` por profile não é
> ressubido sozinho quando o container reinicia. Hoje basta reexecutar o deploy.
> A supervisão definitiva (entrypoint que sobe todos os gateways do cliente)
> entra na reestruturação GitOps.

## Convenção de nomes

Bots e recursos seguem obrigatoriamente [docs/naming.md](docs/naming.md). O
validador rejeita usernames Telegram fora do padrão `TMHA`.
