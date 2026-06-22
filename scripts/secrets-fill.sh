#!/usr/bin/env bash
# Preenche os secrets de UM ambiente de uma vez só (você digita cada token uma
# única vez; todo deploy reusa). Tokens são pedidos sem eco; senhas de banco são
# geradas automaticamente. Nada disso entra no git — fica em
#   ~/.config/hermes-infra/secrets/<ambiente>/<cliente>.env
#
# Uso: ./scripts/secrets-fill.sh hml
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
[[ -n "$ENVIRONMENT" ]] || { echo "uso: $0 <hml|prd>" >&2; exit 2; }

S="${HERMES_INFRA_SECRETS_DIR:-$HOME/.config/hermes-infra/secrets}/$ENVIRONMENT"
umask 077; mkdir -p "$S"
[[ -f "$S/common.env" ]] || printf 'HERMES_TIMEZONE=America/Sao_Paulo\n' > "$S/common.env"

upsert() {  # file key value
  local f="$1" k="$2" v="$3"
  touch "$f"; chmod 600 "$f"
  grep -v "^$k=" "$f" > "$f.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f"
}
getval() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# Emite, do inventário: cliente \t kind(token|dbpw) \t var \t rótulo
rows="$(python3 - "$ROOT" "$ENVIRONMENT" <<'PY'
import json, glob, os, sys
root, env = sys.argv[1], sys.argv[2]
cat = {json.load(open(p))["id"]: json.load(open(p)) for p in glob.glob(os.path.join(root, "catalog/products/*.json"))}
for cf in sorted(glob.glob(os.path.join(root, "clients/*.json"))):
    c = json.load(open(cf)); cid = c["client"]["id"]
    for d in c["deployments"]:
        if d["environment"] != env:
            continue
        prods = set()
        for p in d["profiles"]:
            print(f"{cid}\ttoken\t{p['telegram_secret']}\t{p['telegram_bot_username']}")
            prods.update(p["products"])
        for pid in sorted(prods):
            slug = cat[pid]["db_slug"]
            print(f"{cid}\tdbpw\tDB_{slug.upper()}_PASSWORD\t{cat[pid]['name']}")
PY
)"

# Lê os tokens do terminal (/dev/tty), nunca do fluxo de dados do loop.
[[ -r /dev/tty ]] || { echo "sem terminal interativo (/dev/tty); rode num shell normal" >&2; exit 1; }

mapfile -t ROWS <<< "$rows"
for row in "${ROWS[@]}"; do
  [[ -n "$row" ]] || continue
  IFS=$'\t' read -r client kind var label <<< "$row"
  f="$S/$client.env"
  cur="$(getval "$f" "$var")"
  if [[ "$kind" == "dbpw" ]]; then
    if [[ -z "$cur" ]]; then
      pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"
      upsert "$f" "$var" "$pw"; unset pw
      echo "[$client] $var: senha de banco gerada ($label)"
    else
      echo "[$client] $var: senha já definida (mantida)"
    fi
  else
    if [[ -n "$cur" ]]; then
      printf '[%s] %s já definido (%s) — Enter mantém, ou cole novo:\n' "$client" "$var" "$label" >&2
    fi
    printf '  Token de %s  [%s]: ' "$label" "$var" >&2
    read -rs tok </dev/tty; echo >&2
    if [[ -n "$tok" ]]; then upsert "$f" "$var" "$tok"; echo "  salvo"; else echo "  (vazio — pulado)"; fi
    unset tok
  fi
done

echo "Pronto. Secrets em $S (chmod 600). Rode o deploy: ./scripts/deploy-instance.sh $ENVIRONMENT <cliente>"
