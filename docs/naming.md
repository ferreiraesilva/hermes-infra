# Convenção de nomes TrueMobile Hermes Agent

Esta é a convenção normativa para todas as instalações gerenciadas pelo
`hermes-infra`.

## Bots Telegram

```text
TMHA_<Cliente>_<Perfil>_<Ambiente>_bot
```

- `TMHA`: TrueMobile Hermes Agent;
- `Cliente`: código curto cadastrado em `clients/*.json`;
- `Perfil`: código curto do público/deployment (`TM`, `MI`, `INT`, etc.);
- `Ambiente`: `Hml` ou `Prd`;
- `_bot`: sufixo obrigatório do username Telegram.

Exemplos:

```text
TMHA_Leo_TM_Hml_bot
TMHA_Leo_MI_Hml_bot
TMHA_EBM_MI_Hml_bot
TMHA_City_TM_Hml_bot
TMHA_City_MI_Hml_bot
```

O código representa o profile, não limita os produtos instalados nele. Um novo
produto para o mesmo público não exige renomear o bot. O nome exibido pode ser mais descritivo, por exemplo
`TrueMobile HA — City Corretor HML`. O username é identidade operacional e não
deve ser reaproveitado entre deployments simultâneos.

## Recursos de infraestrutura

```text
Container: hermes-<deployment>-<ambiente>
Database:  hermes_<deployment_com_underscore>_<ambiente>
Role:      hermes_<deployment_com_underscore>_<ambiente>
```

O inventário e `scripts/validate_inventory.py` são a fonte da verdade.
