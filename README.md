# hermes-infra

Fonte da verdade das instalações Hermes administradas por Leonardo.

Este repositório define os ambientes, o Postgres compartilhado, os produtos
contratados por cliente, seus deployments, nomes de recursos e referências de
secrets. Os produtos continuam em repositórios próprios e nunca sobem Postgres.

## Modelo

A unidade de instalação é o **profile**: 1 profile = 1 container = 1 bot Telegram
= 1 `gateway run` (home default, supervisionado pelo s6, image-native). Um profile
pertence a um cliente e agrupa **1+ produtos** que dividem o mesmo bot; cada produto
tem **banco/role próprios** (`db_<produto>_<cliente>`).

Produtos que servem o mesmo objetivo ficam juntos no mesmo profile (ex.: TaskMe +
Investimentos num bot só). Produtos que operam sozinhos ganham profile próprio.

| Cliente | Profile | Container | Produtos | Bot |
|---|---|---|---|---|
| Leonardo | `pessoal` | `hermes-leonardo-pessoal-hml` | TaskMe | `TMHA_Leo_TM_Hml_bot` |
| EBM | `corretores` | `hermes-ebm-corretores-hml` | MinhaIncorporadora | `TMHA_EBM_MI_Hml_bot` |
| City | `interno` | `hermes-city-interno-hml` | TaskMe | `TMHA_City_TM_Hml_bot` |
| City | `corretores` | `hermes-city-corretores-hml` | MinhaIncorporadora | `TMHA_City_MI_Hml_bot` |

A separação por profile impede disputa entre hooks/personas. Os profiles
simultâneos precisam de bots Telegram exclusivos (o Telegram rejeita polling
concorrente do mesmo token).

Leonardo mantém apenas o profile `pessoal` em homologação por enquanto. O antigo
`hermes-leonardo-corretores-hml` deve ser removido do host e não deve ser
recriado pelo deploy.

## Secrets

Secrets não entram no Git. No host:

```text
~/.config/hermes-infra/secrets/<ambiente>/common.env
~/.config/hermes-infra/secrets/<ambiente>/<cliente>.env
```

O arquivo do cliente (1 por cliente, cobre todos os profiles dele) contém 1 token
Telegram por profile (chave = `telegram_secret` do inventário) e 1 senha por
produto (`DB_<PRODUTO>_PASSWORD`), além de `TELEGRAM_ALLOWED_USERS` opcional. O
arquivo comum contém credenciais do provedor de IA. Há ainda um `auth.json`
opcional em `secrets/<ambiente>/auth.json` (auth de LLM compartilhada — o deploy
copia para cada container, pois profile novo não herda). Nenhum script copia,
remove ou modifica dados de WhatsApp.

Quando definidos no arquivo comum, `HERMES_INFERENCE_PROVIDER` e
`HERMES_INFERENCE_MODEL` fixam a combinação usada por todos os containers do
ambiente e evitam combinar um modelo de um provider com credenciais de outro.

**Divisão segredo × não-segredo.** O que *não* é segredo (username do bot,
mapeamento cliente/profile/produto) mora no inventário (git). O que *é* segredo
(token do bot, senha de banco) nunca entra no git:

- **Deploy local (hml hoje):** preencha **uma vez** com `./scripts/secrets-fill.sh
  <ambiente>` — ele pede cada token sem eco e gera as senhas de banco. Todo deploy
  reusa; você não redigita.
- **Deploy GitOps (prd, prompt-2):** os tokens viram **GitHub Environment Secrets**
  (criptografados); o workflow injeta no deploy. Mesma ideia: cadastra uma vez.

## Comandos

```bash
python3 scripts/validate_inventory.py
./scripts/deploy-instance.sh                          # escolhe cliente e ambiente em listas
./scripts/deploy-instance.sh hml leonardo            # todos os profiles do cliente (1 container cada)
./scripts/deploy-instance.sh hml leonardo pessoal    # só um profile
```

O deploy recebe `<ambiente> <cliente> [profile]`. Sem profile, itera todos os
profiles do cliente — cada um vira **seu próprio container**. Exige `postgres-hml`
saudável; se ele não existir, falha sem criar outro. `prd` exige
`HERMES_INFRA_CONFIRM_PRD=1` antes de qualquer SQL.

## Profile = container = bot

Cada profile roda como um container Hermes stock usando seu **home default**
(`/opt/data`): o `.env` traz o token do bot daquele profile + credenciais de LLM,
os produtos do profile são symlinkados em `/opt/data/plugins` e habilitados via
`hermes plugins enable`, e o container roda o `gateway run` único
(supervisionado pelo s6). Sem named-profiles internos, sem `gateway start`
(systemd) — alinhado a como a imagem foi feita para Docker.

> **auth de LLM:** um profile/container novo não herda o `auth.json` do provider;
> o deploy copia `secrets/<ambiente>/auth.json` para cada container. Em prod, cada
> cliente terá sua própria chave de LLM.

## Dashboard por profile

O dashboard é uma capacidade nativa do container Hermes, assim como `hermes chat`
e `hermes gateway`. Qualquer profile pode declarar `dashboard.enabled=true` no
inventário. Quando habilitado, o deploy habilita o serviço s6 de dashboard dentro
do mesmo container do profile, compartilhando o mesmo home (`/opt/data`) e sem
criar outro container ou outro gateway.

No profile `leonardo/pessoal`, o dashboard fica exposto em `0.0.0.0` com
`--insecure`, porque este HML roda apenas na infraestrutura doméstica. Essa regra
não deve ser copiada automaticamente para clientes ou produção.

## WhatsApp por profile

Profiles podem declarar `whatsapp.enabled=true` no inventário. Quando habilitado,
o deploy:

- grava `WHATSAPP_ENABLED=true`, `WHATSAPP_MODE` e `WHATSAPP_ALLOWED_USERS` no
  `.env` do home do container;
- configura `whatsapp.extra.bridge_port` e `whatsapp.extra.bridge_script` no
  `config.yaml`;
- habilita o plugin bundled `whatsapp-platform` antes do primeiro boot do
  gateway.

O allowlist de WhatsApp é segredo operacional e deve ficar no arquivo do cliente
em `~/.config/hermes-infra/secrets/<ambiente>/<cliente>.env`, usando a chave
declarada em `whatsapp.allowed_users_secret`. O deploy não cria nem remove a
sessão `whatsapp/session`; o pareamento por QR é uma etapa operacional separada.

## Convenção de nomes

Bots e recursos seguem obrigatoriamente [docs/naming.md](docs/naming.md). O
validador rejeita usernames Telegram fora do padrão `TMHA`.
