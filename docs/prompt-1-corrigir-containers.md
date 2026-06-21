Corrigir arquitetura de containers no `hermes-infra` (ferreiraesilva/hermes-infra).

## Problema

`deploy-instance.sh` cria 1 container por deployment (ex: `hermes-leonardo-pessoal-hml`
e `hermes-leonardo-corretores-hml` para o mesmo cliente). O correto é 1 container
por cliente com múltiplos profiles gerenciados pelo Hermes nativamente. Dois containers
para o mesmo cliente = dois volumes separados = memória e sessões isoladas sem motivo.

## Mudanças (cirúrgicas — não restructure o repo)

### `clients/*.json` — novo schema

Troque `deployments[]` flat por 1 deployment por ambiente com `profiles[]` dentro:

```json
{
  "client": {"id": "leonardo", "code": "Leo"},
  "subscriptions": ["taskme", "minhaincorporadora"],
  "deployments": [{
    "environment": "hml",
    "profiles": [
      {
        "id": "pessoal",
        "products": ["taskme"],
        "telegram_bot_username": "TMHA_Leo_TM_Hml_bot",
        "telegram_secret": "TMHA_LEO_TM_HML_BOT_TOKEN"
      },
      {
        "id": "corretores",
        "products": ["minhaincorporadora"],
        "telegram_bot_username": "TMHA_Leo_MI_Hml_bot",
        "telegram_secret": "TMHA_LEO_MI_HML_BOT_TOKEN"
      }
    ]
  }]
}
```

Atualize `leonardo.json`, `city.json` e `ebm.json`.

### Convenções

- Container: `hermes-<cliente>-<ambiente>` (1 por cliente)
- Database: `db_<produto>_<cliente>` (1 por produto × cliente, sem ambiente no nome)
- Role: `role_<produto>_<cliente>`
- Data dir: `~/.hermes-instances/<ambiente>/<cliente>`

### `scripts/deploy-instance.sh`

1. Container único por cliente: `hermes-<cliente>-<ambiente>`
2. Databases/roles por produto, sem duplicata entre profiles do mesmo cliente
3. Para cada profile: configura `plugins.enabled` e token Telegram no config do profile
4. `.env` do container contém todos os tokens Telegram + todas as DATABASE_URLs do cliente
5. Idempotente — re-executar não duplica nada

### `scripts/inventory.py` e `validate_inventory.py`

Atualize para o novo schema. O validador deve checar: username do bot no padrão
`TMHA_<code>_<telegram_code>_<Ambiente>_bot`, sem bot duplicado, sem database duplicado.

## Restrições

Não toque em repos de produto. Não versione `.env` reais. HML executa direto; PRD
exige aprovação manual antes de qualquer SQL.

## Validação

- [ ] `docker ps` mostra `hermes-leonardo-hml` — 1 container por cliente
- [ ] 2 databases: `db_taskme_leonardo` e `db_incorporadora_leonardo`
- [ ] `validate_inventory.py` passa sem erros
- [ ] Nenhum `.env` real no git status
