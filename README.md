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

## Atualização automática da imagem Hermes

O deploy usa uma imagem Hermes pinada por digest para manter reprodutibilidade.
Para não ficar desatualizado, o host pode instalar um timer diário que consulta
`nousresearch/hermes-agent:latest`, resolve o digest publicado, grava o override
em `runtime_root/hermes-image.env` e redeploya o profile usando o mesmo
`deploy-instance.sh`.

No HML pessoal:

```bash
./scripts/update-hermes-image.sh hml leonardo pessoal
./scripts/install-hermes-update-timer.sh hml leonardo pessoal 04:00
```

O update é protegido por lock, escreve log em
`~/.local/share/hermes-infra/runtime/<ambiente>/hermes-update.log`, preserva o
home do container (`/opt/data`) e faz rollback para a imagem anterior se o deploy
ou o smoke test falhar. Para usar outra fonte de imagem, defina
`HERMES_IMAGE_REPOSITORY` e/ou `HERMES_IMAGE_TAG` no ambiente da execução.

Nota: o comando nativo `hermes update` não atualiza instalações Docker. Dentro
do container ele informa que o Hermes está rodando como imagem publicada e que a
atualização correta é puxar uma imagem nova e recriar/reiniciar o container. O
cron interno do Hermes é útil para tarefas do agente, mas não deve controlar o
upgrade do próprio container, porque isso exigiria dar acesso ao Docker do host
para dentro do container e ainda dependeria do gateway estar saudável.

O script também compara o commit declarado na imagem Docker
(`org.opencontainers.image.revision`) com `refs/heads/main` de
`https://github.com/NousResearch/Hermes-Agent.git`. O timer do HML roda com
`HERMES_IMAGE_REQUIRE_UPSTREAM_MAIN=1`; se o Docker Hub estiver atrasado em
relação ao GitHub, o update aborta e registra o motivo no log em vez de marcar
sucesso com uma imagem defasada.

## Ownership do home persistente

O volume `/opt/data` é persistente e deve pertencer ao usuário Hermes do
container (mesmo UID/GID do usuário do host que roda o deploy). Não execute
comandos operacionais com `docker exec` puro, porque Docker entra como `root`
por padrão e pode criar arquivos `root:root` no home persistente. Isso quebra
fluxos como dashboard, WhatsApp, setup e leitura do `.env`.

Use sempre o wrapper versionado:

```bash
./scripts/hermes-command.sh hml leonardo pessoal whatsapp
./scripts/hermes-command.sh hml leonardo pessoal plugins list --plain
```

Se algum comando já tiver criado arquivos `root:root`, repare antes de reiniciar
ou parear novamente:

```bash
./scripts/repair-instance-permissions.sh hml leonardo pessoal
```

O deploy também normaliza permissões no início de cada execução, mas isso não
substitui o wrapper para comandos manuais executados entre deploys.

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

Nota operacional: imagens Hermes atuais recusam dashboard non-loopback sem
provedor de autenticação, mesmo quando `HERMES_DASHBOARD_INSECURE` está definido.
Por isso, o HML pessoal usa basic auth simples via secret declarada em
`dashboard.basic_auth_password_secret`.

## WhatsApp por profile

Profiles podem declarar `whatsapp.enabled=true` no inventário. Quando habilitado,
o deploy:

- grava `WHATSAPP_ENABLED=true`, `WHATSAPP_MODE` e `WHATSAPP_ALLOWED_USERS` no
  `.env` do home do container;
- configura `platforms.whatsapp.extra.bridge_port`,
  `platforms.whatsapp.extra.bridge_script` e
  `platforms.whatsapp.extra.session_path` no `config.yaml` — este é o caminho
  consumido pelo `PlatformConfig.extra` do adapter;
- habilita o plugin bundled `whatsapp-platform` antes do primeiro boot do
  gateway.

O allowlist de WhatsApp é segredo operacional e deve ficar no arquivo do cliente
em `~/.config/hermes-infra/secrets/<ambiente>/<cliente>.env`, usando a chave
declarada em `whatsapp.allowed_users_secret`. O deploy não cria nem remove a
sessão `whatsapp/session`; o pareamento por QR é uma etapa operacional separada.

Profiles com número dedicado podem usar `whatsapp.dm_policy=open` sem
`allowed_users_secret`. Nesse caso o número pareado pertence ao produto/cliente,
o deploy grava `WHATSAPP_ALLOWED_USERS=*` e os DMs são aceitos pelo adapter. Para
produtos voltados a atendimento por DM, prefira `group_policy=disabled` até haver
uma decisão explícita para grupos.

`whatsapp.account_phone` é metadado operacional do inventário: documenta qual
número deve ser pareado naquele profile, mas o vínculo real acontece no QR code
gerado por `hermes whatsapp` dentro do container.

Como os containers Hermes rodam com `network_mode: host`, `whatsapp.bridge_port`
precisa ser exclusivo por profile ativo na mesma máquina. Reutilizar a mesma porta
faz um gateway falar com o bridge de outro container.

## Display por plataforma

Profiles podem declarar overrides de display em `display.platforms`. O deploy
aplica esses valores com `hermes config set` no home gerenciado do container
antes do gateway subir.

Hoje o inventário suporta `display.platforms.<plataforma>.tool_progress` com os
valores `off`, `new`, `all` ou `verbose`. Use isso para controlar mensagens
intermediárias do gateway, como chamadas de ferramenta (`session_search`,
`terminal`, plugins etc.), sem alterar o diretório de trabalho/home escolhido
em runtime pelo comando `/sethome`.

Exemplo usado no HML pessoal do Leonardo:

```json
"display": {
  "platforms": {
    "whatsapp": {
      "tool_progress": "off"
    }
  }
}
```

## Convenção de nomes

Bots e recursos seguem obrigatoriamente [docs/naming.md](docs/naming.md). O
validador rejeita usernames Telegram fora do padrão `TMHA`.
