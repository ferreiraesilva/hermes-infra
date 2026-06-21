#!/usr/bin/env bash
# Provisiona/atualiza UM cliente em UM ambiente = UM container Hermes.
# Unidade: cliente x ambiente. O cliente pode ter vários profiles (1+ produtos
# cada); cada produto tem seu próprio banco/role. Nunca dois containers para o
# mesmo cliente — um único volume por cliente.
#
# Modelo de profile (manual do Hermes): cada profile é um HERMES_HOME próprio em
# /opt/data/profiles/<id> com .env, config.yaml, sessions e gateway próprios.
# O token do bot vive no .env do profile; cada profile sobe seu próprio gateway
# (`hermes -p <id> gateway start`). Não reutilize um token em dois gateways.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
[[ -n "$ENVIRONMENT" && -n "$CLIENT" ]] || { echo "uso: $0 <hml|prd> <cliente>" >&2; exit 2; }

python3 "$ROOT/scripts/validate_inventory.py"

PLAN="$(mktemp)"; trap 'rm -f "$PLAN"' EXIT
python3 "$ROOT/scripts/inventory.py" plan "$ENVIRONMENT" "$CLIENT" > "$PLAN"

field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$PLAN" "$1"; }
CONTAINER_NAME="$(field container_name)"
COMPOSE_PROJECT="$(field compose_project)"
DATA_DIR="$(field data_dir)"
POSTGRES_CONTAINER="$(field postgres_container)"
POSTGRES_HOST="$(field postgres_host)"
POSTGRES_PORT="$(field postgres_port)"

# PRD nunca roda SQL sem aprovação explícita (até o GitOps do prompt-2 existir).
if [[ "$ENVIRONMENT" == "prd" && "${HERMES_INFRA_CONFIRM_PRD:-}" != "1" ]]; then
  echo "prd exige aprovação manual: defina HERMES_INFRA_CONFIRM_PRD=1 para prosseguir" >&2
  exit 1
fi

# --- Secrets (fora do git) ---------------------------------------------------
SECRETS_ROOT="${HERMES_INFRA_SECRETS_DIR:-$HOME/.config/hermes-infra/secrets}"
COMMON_ENV="$SECRETS_ROOT/$ENVIRONMENT/common.env"
CLIENT_ENV="$SECRETS_ROOT/$ENVIRONMENT/$CLIENT.env"
[[ -f "$COMMON_ENV" ]] || { echo "secret comum ausente: $COMMON_ENV" >&2; exit 1; }
[[ -f "$CLIENT_ENV" ]] || { echo "secret do cliente ausente: $CLIENT_ENV" >&2; exit 1; }
set -a; source "$COMMON_ENV"; source "$CLIENT_ENV"; set +a

# --- Postgres saudável -------------------------------------------------------
health="$(docker inspect -f '{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || true)"
[[ "$health" == "healthy" ]] || { echo "$POSTGRES_CONTAINER não está saudável; nada será criado" >&2; exit 1; }

umask 077
mkdir -p "$DATA_DIR/product-src"
chmod 700 "$DATA_DIR"

# .env do profile default (/opt/data/.env): só credenciais comuns de LLM.
cp "$COMMON_ENV" "$DATA_DIR/.env"
chmod 600 "$DATA_DIR/.env"

# --- Bancos/roles por produto (idempotente + isolamento lógico) --------------
db_rows() { python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for d in plan["databases"]:
    print("\t".join([d["db_slug"], d["database"], d["role"], d["env_var"],
                     d["plugin_name"], d["local_source_hml"], d["ref_hml"],
                     d["migrations"], d["seed_hml"]]))
PY
}

while IFS=$'\t' read -r db_slug database role env_var plugin source_dir git_ref migrations seed; do
  pw_secret="DB_$(printf '%s' "$db_slug" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  password="${!pw_secret:-}"
  [[ -n "$password" ]] || { echo "senha ausente: defina $pw_secret em $CLIENT_ENV" >&2; exit 1; }
  [[ "$password" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "$pw_secret deve ser URL-safe" >&2; exit 1; }

  db_exists="$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -Atc \
    "SELECT 1 FROM pg_database WHERE datname='$database'")"

  docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    --set=role_name="$role" --set=db_name="$database" --set=role_password="$password" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role_name', :'role_password')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role_name') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'role_name', :'role_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'role_name')
  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') \gexec
-- Fronteira de isolamento: só o dono (e superuser) conecta neste banco.
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'db_name') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'role_name') \gexec
SQL

  # Clona o produto (read-only do repo local de homolog) e fixa a ref.
  target="$DATA_DIR/product-src/$db_slug"
  [[ -d "$target/.git" ]] || git clone --quiet "$source_dir" "$target"
  git -C "$target" fetch --quiet "$source_dir" "$git_ref"
  git -C "$target" checkout --quiet "$git_ref"
  git -C "$target" reset --quiet --hard FETCH_HEAD

  database_url="postgresql://$role:$password@$POSTGRES_HOST:$POSTGRES_PORT/$database"

  # .env do produto (lido pelo plugin): DATABASE_URL + env declarada no catálogo.
  {
    printf 'DATABASE_URL=%s\n' "$database_url"
    python3 - "$PLAN" "$db_slug" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
env = next(d["env"] for d in plan["databases"] if d["db_slug"] == sys.argv[2])
for k, v in env.items():
    print(f"{k}={v}")
PY
  } > "$target/.env"
  chmod 600 "$target/.env"

  # Migrations (idempotentes) e seed só na primeira criação, em hml.
  if [[ -n "$migrations" && -d "$target/$migrations" ]]; then
    for migration in "$target/$migrations"/*.sql; do
      [[ -e "$migration" ]] || continue
      docker exec -i -e PGPASSWORD="$password" "$POSTGRES_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$role" -d "$database" < "$migration"
    done
  fi
  if [[ -z "$db_exists" && "$ENVIRONMENT" == "hml" && -n "$seed" && -f "$target/$seed" ]]; then
    docker exec -i -e PGPASSWORD="$password" "$POSTGRES_CONTAINER" \
      psql -v ON_ERROR_STOP=1 -U "$role" -d "$database" < "$target/$seed"
  fi
done < <(db_rows)

# --- Container único do cliente (precisa estar no ar p/ criar profiles) ------
export HERMES_CONTAINER_NAME="$CONTAINER_NAME" HERMES_DATA_DIR="$DATA_DIR"
export HERMES_UID="$(id -u)" HERMES_GID="$(id -g)" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
docker compose -f "$ROOT/platform/hermes/compose.yml" up -d
sleep 8

# --- Profiles do Hermes (1 gateway + 1 bot por profile) ----------------------
# Cada profile = HERMES_HOME próprio em /opt/data/profiles/<id>. O token do bot
# vai no .env do profile; os plugins do profile são habilitados via `hermes -p`.
prof_rows() { python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for p in plan["profiles"]:
    sources = ",".join(f"{s['plugin']}:{s['db_slug']}" for s in p["plugin_sources"])
    print("\t".join([p["id"], p["telegram_secret"], sources]))
PY
}

while IFS=$'\t' read -r profile_id secret_var plugin_sources; do
  token="${!secret_var:-}"
  [[ -n "$token" ]] || { echo "token ausente: defina $secret_var em $CLIENT_ENV (profile $profile_id)" >&2; exit 1; }
  profile_home="$DATA_DIR/profiles/$profile_id"

  # Cria o profile (idempotente; semeia skills) dentro do container.
  docker exec "$CONTAINER_NAME" hermes profile create "$profile_id" 2>/dev/null || true
  mkdir -p "$profile_home/plugins"

  # .env do profile = credenciais comuns de LLM + token do bot (só secrets).
  {
    cat "$COMMON_ENV"
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
    [[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]] && printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$TELEGRAM_ALLOWED_USERS"
  } > "$profile_home/.env"
  chmod 600 "$profile_home/.env"

  # Symlink do código de cada plugin para dentro do profile e habilita via CLI
  # (escreve plugins.enabled no config.yaml do profile de forma idempotente).
  IFS=',' read -ra pairs <<< "$plugin_sources"
  for pair in "${pairs[@]}"; do
    plugin="${pair%%:*}"; slug="${pair##*:}"
    ln -sfn "/opt/data/product-src/$slug" "$profile_home/plugins/$plugin"
    docker exec "$CONTAINER_NAME" hermes -p "$profile_id" plugins enable "$plugin" || true
  done

  # Sobe o gateway próprio do profile (1 bot por profile).
  docker exec "$CONTAINER_NAME" hermes -p "$profile_id" gateway start || true
done < <(prof_rows)

docker inspect -f 'name={{.Name}} status={{.State.Status}} restarts={{.RestartCount}}' "$CONTAINER_NAME"
echo "Profiles ativos:"
docker exec "$CONTAINER_NAME" hermes profile list 2>/dev/null || true
