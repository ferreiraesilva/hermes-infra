#!/usr/bin/env bash
# Provisiona/atualiza UM profile = UM container Hermes = UM bot.
# Um profile pertence a um cliente, agrupa 1+ produtos (plugins) que dividem o
# mesmo bot; cada produto tem seu próprio banco/role. Cada container roda o
# `gateway run` do seu home default (image-native, supervisionado pelo s6).
#
# Uso:
#   ./deploy-instance.sh                          # escolha cliente e ambiente
#   ./deploy-instance.sh hml leonardo pessoal     # um profile
#   ./deploy-instance.sh hml leonardo             # todos os profiles do cliente
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
PROFILE="${3:-}"

choose() {  # prompt; lê linhas "id<TAB>rótulo" da entrada padrão
  local prompt="$1" row choice i id label
  local -a options=()
  mapfile -t options
  ((${#options[@]} > 0)) || { echo "nenhuma opção disponível para $prompt" >&2; return 1; }

  printf '%s:\n' "$prompt" >&2
  for i in "${!options[@]}"; do
    IFS=$'\t' read -r id label <<< "${options[$i]}"
    printf '  %d) %s' "$((i + 1))" "$id" >&2
    [[ -n "$label" && "$label" != "$id" ]] && printf ' — %s' "$label" >&2
    printf '\n' >&2
  done
  printf 'Escolha [1-%d]: ' "${#options[@]}" >&2
  read -r choice </dev/tty || { echo >&2; return 1; }
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})) || {
    echo "opção inválida: $choice" >&2
    return 1
  }
  IFS=$'\t' read -r id label <<< "${options[$((choice - 1))]}"
  printf '%s' "$id"
}

if [[ -z "$ENVIRONMENT" && -z "$CLIENT" ]]; then
  [[ -r /dev/tty ]] || { echo "modo interativo exige um terminal; use: $0 <ambiente> <cliente> [profile]" >&2; exit 2; }
  CLIENT="$(python3 "$ROOT/scripts/inventory.py" clients | choose "Cliente")"
  ENVIRONMENT="$(python3 "$ROOT/scripts/inventory.py" environments "$CLIENT" | awk '{print $0 "\t" $0}' | choose "Ambiente")"
elif [[ -z "$ENVIRONMENT" || -z "$CLIENT" ]]; then
  echo "uso: $0 [<ambiente> <cliente> [profile]]" >&2
  echo "sem argumentos, o script abre a seleção interativa" >&2
  exit 2
fi

# Caminho do binário hermes DENTRO do container (não está no PATH).
HERMES_BIN="${HERMES_BIN:-/opt/hermes/.venv/bin/hermes}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent@sha256:4b50f1201f280e28887f6a2d7bbcd50fe370e0da3e92417d6e51778b485cf18e}"

python3 "$ROOT/scripts/validate_inventory.py"

if ! python3 "$ROOT/scripts/inventory.py" profiles "$ENVIRONMENT" "$CLIENT" >/dev/null; then
  echo "clientes disponíveis:" >&2
  python3 "$ROOT/scripts/inventory.py" clients | sed 's/^/  /' >&2
  exit 2
fi

# Sem profile explícito: itera todos os profiles do cliente (1 container cada).
if [[ -z "$PROFILE" ]]; then
  while read -r prof; do
    [[ -n "$prof" ]] || continue
    echo "===> profile $prof"
    "$0" "$ENVIRONMENT" "$CLIENT" "$prof"
  done < <(python3 "$ROOT/scripts/inventory.py" profiles "$ENVIRONMENT" "$CLIENT")
  exit 0
fi

PLAN="$(mktemp)"; trap 'rm -f "$PLAN"' EXIT
python3 "$ROOT/scripts/inventory.py" plan "$ENVIRONMENT" "$CLIENT" "$PROFILE" > "$PLAN"

field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$PLAN" "$1"; }
CONTAINER_NAME="$(field container_name)"
COMPOSE_PROJECT="$(field compose_project)"
DATA_DIR="$(field data_dir)"
POSTGRES_CONTAINER="$(field postgres_container)"
POSTGRES_HOST="$(field postgres_host)"
POSTGRES_PORT="$(field postgres_port)"
TELEGRAM_SECRET="$(field telegram_secret)"
DASHBOARD_ENABLED="$(python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('dashboard',{}).get('enabled', False)).lower())" "$PLAN")"
DASHBOARD_HOST="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('dashboard',{}).get('host', '0.0.0.0'))" "$PLAN")"
DASHBOARD_INSECURE="$(python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('dashboard',{}).get('insecure', False)).lower())" "$PLAN")"

# PRD nunca roda SQL sem aprovação explícita (até o GitOps do prompt-2 existir).
if [[ "$ENVIRONMENT" == "prd" && "${HERMES_INFRA_CONFIRM_PRD:-}" != "1" ]]; then
  echo "prd exige aprovação manual: defina HERMES_INFRA_CONFIRM_PRD=1 para prosseguir" >&2
  exit 1
fi

# --- Secrets (fora do git; 1 arquivo por cliente, cobre todos os profiles) ---
SECRETS_ROOT="${HERMES_INFRA_SECRETS_DIR:-$HOME/.config/hermes-infra/secrets}"
COMMON_ENV="$SECRETS_ROOT/$ENVIRONMENT/common.env"
CLIENT_ENV="$SECRETS_ROOT/$ENVIRONMENT/$CLIENT.env"
AUTH_SRC="$SECRETS_ROOT/$ENVIRONMENT/auth.json"   # auth de LLM compartilhada (opcional)
[[ -f "$COMMON_ENV" ]] || { echo "secret comum ausente: $COMMON_ENV" >&2; exit 1; }
[[ -f "$CLIENT_ENV" ]] || { echo "secret do cliente ausente: $CLIENT_ENV" >&2; exit 1; }
set -a; source "$COMMON_ENV"; source "$CLIENT_ENV"; set +a

token="${!TELEGRAM_SECRET:-}"
[[ -n "$token" ]] || { echo "token ausente: defina $TELEGRAM_SECRET em $CLIENT_ENV" >&2; exit 1; }

# --- Postgres saudável -------------------------------------------------------
health="$(docker inspect -f '{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || true)"
[[ "$health" == "healthy" ]] || { echo "$POSTGRES_CONTAINER não está saudável; nada será criado" >&2; exit 1; }

umask 077
mkdir -p "$DATA_DIR/plugins" "$DATA_DIR/product-src"
chmod 700 "$DATA_DIR"

# auth de LLM (provider openai-codex etc.): profile novo não herda; copiamos.
if [[ -f "$AUTH_SRC" ]]; then
  cp "$AUTH_SRC" "$DATA_DIR/auth.json"; chmod 600 "$DATA_DIR/auth.json"
else
  echo "aviso: $AUTH_SRC ausente; o container precisará de auth de LLM (rode 'hermes setup' ou copie auth.json)" >&2
fi

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

  # Plugin disponível no home default do container.
  ln -sfn "/opt/data/product-src/$db_slug" "$DATA_DIR/plugins/$plugin"
done < <(db_rows)

# --- .env do container (home default): credenciais LLM + token do bot --------
{
  cat "$COMMON_ENV"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
  [[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]] && printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$TELEGRAM_ALLOWED_USERS"
} > "$DATA_DIR/.env"
chmod 600 "$DATA_DIR/.env"

hermes_one_shot() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint "$HERMES_BIN" \
    -e HERMES_HOME=/opt/data \
    -e HOME=/opt/data \
    -v "$DATA_DIR:/opt/data" \
    "$HERMES_IMAGE" "$@"
}

# Prepara config.yaml antes do primeiro boot do gateway. Assim o container real
# já sobe com provider/modelo/plugins corretos, sem precisar emitir warnings de
# configuração no boot inicial e corrigir depois com restart.
if [[ -n "${HERMES_INFERENCE_MODEL:-}" ]]; then
  hermes_one_shot config set model.default "$HERMES_INFERENCE_MODEL"
fi
if [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]]; then
  hermes_one_shot config set model.provider "$HERMES_INFERENCE_PROVIDER"
fi
if [[ -n "${HERMES_INFERENCE_BASE_URL:-}" ]]; then
  hermes_one_shot config set model.base_url "$HERMES_INFERENCE_BASE_URL"
fi

while IFS= read -r plugin; do
  [[ -n "$plugin" ]] || continue
  hermes_one_shot plugins enable "$plugin" || true
done < <(python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1]))['plugins']))" "$PLAN")

# --- Container do profile (1 gateway run, profile default) -------------------
export HERMES_IMAGE
export HERMES_CONTAINER_NAME="$CONTAINER_NAME" HERMES_DATA_DIR="$DATA_DIR"
export HERMES_UID="$(id -u)" HERMES_GID="$(id -g)" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
  export HERMES_DASHBOARD=true
  export HERMES_DASHBOARD_HOST="$DASHBOARD_HOST"
  export HERMES_DASHBOARD_INSECURE="$DASHBOARD_INSECURE"
else
  unset HERMES_DASHBOARD HERMES_DASHBOARD_HOST HERMES_DASHBOARD_INSECURE
fi
docker compose -f "$ROOT/platform/hermes/compose.yml" up -d
sleep 8

# Instala requirements dos plugins no ambiente Python do container real e
# reinicia p/ recarregar se algo foi instalado.
NEEDS_RESTART=false
while IFS= read -r plugin; do
  [[ -n "$plugin" ]] || continue
  if docker exec "$CONTAINER_NAME" sh -c "[ -f /opt/data/plugins/$plugin/requirements.txt ]"; then
    docker exec "$CONTAINER_NAME" sh -c "uv pip install -q --python /opt/hermes/.venv/bin/python -r /opt/data/plugins/$plugin/requirements.txt" || true
    NEEDS_RESTART=true
  fi
done < <(python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1]))['plugins']))" "$PLAN")
if [[ "$NEEDS_RESTART" == "true" ]]; then
  docker restart "$CONTAINER_NAME" >/dev/null
fi

docker inspect -f 'name={{.Name}} status={{.State.Status}} restarts={{.RestartCount}}' "$CONTAINER_NAME"
docker exec "$CONTAINER_NAME" "$HERMES_BIN" plugins list 2>/dev/null || true
