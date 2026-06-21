# hermes-infra

Fonte da verdade das instalações Hermes administradas por Leonardo.

Este repositório define os ambientes, o Postgres compartilhado, os produtos
contratados por cliente, seus deployments, nomes de recursos e referências de
secrets. Os produtos continuam em repositórios próprios e nunca sobem Postgres.

## Homologação inicial

| Cliente | Deployment | Público | Produtos |
|---|---|---|---|
| Leonardo | `leonardo-pessoal` | pessoal | TaskMe |
| Leonardo | `leonardo-corretores` | corretores | MinhaIncorporadora |
| EBM | `ebm-corretores` | corretores | MinhaIncorporadora |
| City | `city-interno` | interno | TaskMe |
| City | `city-corretores` | corretores | MinhaIncorporadora |

A separação por público impede disputa entre hooks/personas. Os cinco deployments
simultâneos precisam de cinco bots Telegram exclusivos.

## Secrets

Secrets não entram no Git. No host:

```text
~/.config/hermes-infra/secrets/<ambiente>/common.env
~/.config/hermes-infra/secrets/<ambiente>/<deployment>.env
```

O arquivo da instância contém `TELEGRAM_BOT_TOKEN`, `DATABASE_PASSWORD` e,
opcionalmente, `TELEGRAM_ALLOWED_USERS`. O arquivo comum contém credenciais do
provedor de IA. Nenhum script copia, remove ou modifica dados de WhatsApp.

## Comandos

```bash
python3 scripts/validate_inventory.py
./scripts/deploy-instance.sh hml leonardo-pessoal
```

O deploy exige `postgres-hml` saudável; se ele não existir, falha sem criar outro.
