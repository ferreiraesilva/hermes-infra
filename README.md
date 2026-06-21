# hermes-base

Fundação executável compartilhada para instalações do **Hermes Agent**.

Toda instalação de Hermes (produção, homologação, futuros clientes) parte daqui:
um `compose.base.yml` comum + um override por ambiente + deploy **GitOps** via
GitHub Actions. **Ninguém edita produção na mão** — a fonte da verdade é este repo.

## Estrutura

```
compose.base.yml              # serviço comum do gateway (imagem oficial, /opt/data, s6, network host)
compose.prd.yml               # override de produção: hermes-prd, imagem pinada, dados /home/leo/.hermes
.github/workflows/deploy-prd.yml  # deploy de prod via runner self-hosted (label hermes-prd)
env/prd.env.example           # referência das variáveis/segredos de prod (sem valores)
```

## Produção (host `solid`)

Deploy automático no `push` para `main` (ou `workflow_dispatch`). O workflow:

1. Gera `/home/leo/.hermes/.env` a partir dos **GitHub Actions secrets**
   (hoje: `TELEGRAM_BOT_TOKEN` → `@Truemobile_HermesAgent_bot`).
2. Remove o container Hermes legado (subido na mão) preservando os dados.
3. Sobe `hermes-prd` com `gateway run`, supervisionado pelo s6, `restart: unless-stopped`.

### Pré-requisitos (uma vez)

- Runner self-hosted registrado **neste repo** com label `hermes-prd` (no `solid`).
- Secret `TELEGRAM_BOT_TOKEN` configurado no repo.

### Atualizar a versão do Hermes

Troque o digest da imagem em [`compose.prd.yml`](compose.prd.yml) e faça commit —
o GitHub Actions reaplica. Sem `latest` em prod: pin por digest = reprodutível.

## Convenção de nomes

`<serviço>-<ambiente>` (`prd`/`hml`/`dev`). Nada de nome aleatório do Docker.

## Homologação

O ambiente de homologação (MAC02) será consolidado aqui via `compose.hml.yml`
(hoje vive no repo `infra`). LAN sem IP público → sem runner; deploy local.
