#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
DEPLOYMENT="${2:-}"
[[ -n "$ENVIRONMENT" && -n "$DEPLOYMENT" ]] || { echo "uso: $0 <hml|prd> <deployment>" >&2; exit 2; }

python3 "$ROOT/scripts/validate_inventory.py"
eval "$(python3 "$ROOT/scripts/inventory.py" shell "$ENVIRONMENT" "$DEPLOYMENT")"

SECRETS_ROOT="${HERMES_INFRA_SECRETS_DIR:-$HOME/.config/hermes-infra/secrets}"
COMMON_ENV="$SECRETS_ROOT/$ENVIRONMENT/common.env"
INSTANCE_ENV="$SECRETS_ROOT/$ENVIRONMENT/$DEPLOYMENT.env"
[[ -f "$COMMON_ENV" ]] || { echo "secret comum ausente: $COMMON_ENV" >&2; exit 1; }
[[ -f "$INSTANCE_ENV" ]] || { echo "secret da instância ausente: $INSTANCE_ENV" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$COMMON_ENV"
# shellcheck disable=SC1090
source "$INSTANCE_ENV"
set +a
: "${TELEGRAM_BOT_TOKEN:?defina TELEGRAM_BOT_TOKEN em $INSTANCE_ENV}"
: "${DATABASE_PASSWORD:?defina DATABASE_PASSWORD em $INSTANCE_ENV}"
[[ "$DATABASE_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "DATABASE_PASSWORD deve ser URL-safe" >&2; exit 1; }

health="$(docker inspect -f '{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || true)"
[[ "$health" == "healthy" ]] || { echo "$POSTGRES_CONTAINER não está saudável; nenhum Postgres será criado" >&2; exit 1; }

DATA_DIR="$DATA_ROOT/$DEPLOYMENT"
PRODUCT_ROOT="$DATA_DIR/product-src"
mkdir -p "$DATA_DIR/plugins" "$PRODUCT_ROOT"
chmod 700 "$DATA_DIR"

db_exists="$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='$DATABASE_NAME'")"
docker exec -i "$POSTGRES_CONTAINER" psql -U postgres -d postgres \
  --set=role_name="$DATABASE_ROLE" --set=db_name="$DATABASE_NAME" \
  --set=role_password="$DATABASE_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role_name', :'role_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role_name') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'role_name', :'role_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'role_name')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') \gexec
SQL

IFS=',' read -ra PRODUCT_IDS <<< "$PRODUCTS"
for product_id in "${PRODUCT_IDS[@]}"; do
  mapfile -t meta < <(python3 - "$ROOT" "$product_id" <<'PY'
import json, sys
from pathlib import Path
p = json.loads((Path(sys.argv[1])/'catalog'/'products'/f'{sys.argv[2]}.json').read_text())
for value in (p['local_source_hml'], p['ref_hml'], p['plugin_name'], p.get('migrations',''), p.get('seed_hml','')):
    print(value)
print(json.dumps(p.get('env',{}), separators=(',',':')))
PY
  )
  source_dir="${meta[0]}"; git_ref="${meta[1]}"; plugin_name="${meta[2]}"
  migrations="${meta[3]}"; seed="${meta[4]}"; product_env="${meta[5]}"
  target="$PRODUCT_ROOT/$product_id"

  [[ -d "$target/.git" ]] || git clone --quiet "$source_dir" "$target"
  git -C "$target" fetch --quiet "$source_dir" "$git_ref"
  git -C "$target" checkout --quiet "$git_ref"
  git -C "$target" reset --quiet --hard FETCH_HEAD

  database_url="postgresql://$DATABASE_ROLE:$DATABASE_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$DATABASE_NAME"
  {
    printf 'DATABASE_URL=%s\n' "$database_url"
    python3 - "$product_env" <<'PY'
import json, sys
for key, value in json.loads(sys.argv[1]).items(): print(f'{key}={value}')
PY
  } > "$target/.env"
  chmod 600 "$target/.env"

  if [[ -n "$migrations" && -d "$target/$migrations" ]]; then
    for migration in "$target/$migrations"/*.sql; do
      [[ -e "$migration" ]] || continue
      docker exec -i -e PGPASSWORD="$DATABASE_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$DATABASE_ROLE" -d "$DATABASE_NAME" < "$migration"
    done
  fi
  if [[ -z "$db_exists" && "$ENVIRONMENT" == "hml" && -n "$seed" && -f "$target/$seed" ]]; then
    docker exec -i -e PGPASSWORD="$DATABASE_PASSWORD" "$POSTGRES_CONTAINER" \
      psql -v ON_ERROR_STOP=1 -U "$DATABASE_ROLE" -d "$DATABASE_NAME" < "$target/$seed"
  fi

  ln -sfn "/opt/data/product-src/$product_id" "$DATA_DIR/plugins/$plugin_name"
done

# Gera somente o ambiente do gateway. Não toca em arquivos/sessões de WhatsApp existentes.
umask 077
cat "$COMMON_ENV" "$INSTANCE_ENV" > "$DATA_DIR/.env"

export HERMES_CONTAINER_NAME="$CONTAINER_NAME" HERMES_DATA_DIR="$DATA_DIR"
export HERMES_UID="$(id -u)" HERMES_GID="$(id -g)" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
docker compose -f "$ROOT/platform/hermes/compose.yml" up -d
sleep 8
docker inspect -f 'name={{.Name}} status={{.State.Status}} restarts={{.RestartCount}}' "$CONTAINER_NAME"
