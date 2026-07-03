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

# Se CLIENT contiver hífen e PROFILE for vazio, divide no formato cliente-profile
if [[ "$CLIENT" =~ - && -z "$PROFILE" ]]; then
  PROFILE="${CLIENT#*-}"
  CLIENT="${CLIENT%%-*}"
fi


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
HERMES_IMAGE_DEFAULT="nousresearch/hermes-agent@sha256:4b50f1201f280e28887f6a2d7bbcd50fe370e0da3e92417d6e51778b485cf18e"
HERMES_IMAGE="${HERMES_IMAGE:-$HERMES_IMAGE_DEFAULT}"

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
RUNTIME_ROOT="$(field runtime_root)"
FILES_DIR="$(field files_dir)"
POSTGRES_CONTAINER="$(field postgres_container)"
POSTGRES_HOST="$(field postgres_host)"
POSTGRES_PORT="$(field postgres_port)"
TELEGRAM_SECRET="$(field telegram_secret)"
TELEGRAM_ADMIN_USERS="$(python3 -c "import json,sys;print(','.join(json.load(open(sys.argv[1])).get('telegram',{}).get('admin_users',[])))" "$PLAN")"
TELEGRAM_HOME_CHANNEL="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegram',{}).get('home_channel',''))" "$PLAN")"
TELEGRAM_UNAUTHORIZED_DM_MESSAGE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegram',{}).get('unauthorized_dm_message',''))" "$PLAN")"
TENANT_NAME="$(field tenant_name)"
DASHBOARD_ENABLED="$(python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('dashboard',{}).get('enabled', False)).lower())" "$PLAN")"
DASHBOARD_HOST="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('dashboard',{}).get('host', '0.0.0.0'))" "$PLAN")"
DASHBOARD_INSECURE="$(python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('dashboard',{}).get('insecure', False)).lower())" "$PLAN")"
DASHBOARD_BASIC_AUTH_USERNAME="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('dashboard',{}).get('basic_auth_username', ''))" "$PLAN")"
DASHBOARD_BASIC_AUTH_PASSWORD_SECRET="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('dashboard',{}).get('basic_auth_password_secret', ''))" "$PLAN")"
WHATSAPP_ENABLED="$(python3 -c "import json,sys;print(str(json.load(open(sys.argv[1])).get('whatsapp',{}).get('enabled', False)).lower())" "$PLAN")"
WHATSAPP_MODE_VALUE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('mode', 'bot'))" "$PLAN")"
WHATSAPP_BRIDGE_PORT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('bridge_port', 3000))" "$PLAN")"
WHATSAPP_BRIDGE_SCRIPT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('bridge_script', '/opt/data/runtime/whatsapp-bridge/bridge.js'))" "$PLAN")"
WHATSAPP_SESSION_PATH="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('session_path', '/opt/data/whatsapp/session'))" "$PLAN")"
WHATSAPP_ALLOWED_USERS_SECRET="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('allowed_users_secret', ''))" "$PLAN")"
WHATSAPP_DM_POLICY="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('dm_policy', 'open'))" "$PLAN")"
WHATSAPP_GROUP_POLICY="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('whatsapp',{}).get('group_policy', 'open'))" "$PLAN")"

mkdir -p "$RUNTIME_ROOT"
IMAGE_ENV="$RUNTIME_ROOT/hermes-image.env"
if [[ -f "$IMAGE_ENV" ]]; then
  set -a; source "$IMAGE_ENV"; set +a
  HERMES_IMAGE="${HERMES_IMAGE:-$HERMES_IMAGE_DEFAULT}"
fi

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
if [[ "$DASHBOARD_ENABLED" == "true" && -n "$DASHBOARD_BASIC_AUTH_PASSWORD_SECRET" ]]; then
  dashboard_basic_auth_password="${!DASHBOARD_BASIC_AUTH_PASSWORD_SECRET:-}"
  [[ -n "$DASHBOARD_BASIC_AUTH_USERNAME" ]] || { echo "dashboard basic auth exige basic_auth_username no inventário" >&2; exit 1; }
  [[ -n "$dashboard_basic_auth_password" ]] || { echo "senha do dashboard ausente: defina $DASHBOARD_BASIC_AUTH_PASSWORD_SECRET em $CLIENT_ENV" >&2; exit 1; }
fi
if [[ "$WHATSAPP_ENABLED" == "true" && "$WHATSAPP_DM_POLICY" == "allowlist" ]]; then
  [[ -n "$WHATSAPP_ALLOWED_USERS_SECRET" ]] || { echo "whatsapp habilitado exige allowed_users_secret no inventário" >&2; exit 1; }
  whatsapp_allowed_users="${!WHATSAPP_ALLOWED_USERS_SECRET:-}"
  [[ -n "$whatsapp_allowed_users" ]] || { echo "allowlist WhatsApp ausente: defina $WHATSAPP_ALLOWED_USERS_SECRET em $CLIENT_ENV" >&2; exit 1; }
fi

# --- Postgres saudável -------------------------------------------------------
health="$(docker inspect -f '{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || true)"
[[ "$health" == "healthy" ]] || { echo "$POSTGRES_CONTAINER não está saudável; nada será criado" >&2; exit 1; }

umask 077
mkdir -p "$DATA_DIR/plugins" "$DATA_DIR/product-src" "$DATA_DIR/runtime/whatsapp-bridge" \
  "$DATA_DIR/runtime/hermes-agent-overlay"
chmod 700 "$DATA_DIR"
mkdir -p "$FILES_DIR"; chmod 700 "$FILES_DIR"

# Garante que upgrades de imagem e execuções anteriores como root não deixem o
# home do Hermes travado para os one-shots que rodam como o usuário do host.
docker run --rm \
  --entrypoint sh \
  -v "$DATA_DIR:/opt/data" \
  "$HERMES_IMAGE" \
  -c "chown -R $(id -u):$(id -g) /opt/data && chmod -R u+rwX /opt/data"

# auth de LLM (provider openai-codex etc.): profile novo não herda; copiamos.
if [[ -f "$AUTH_SRC" ]]; then
  docker run --rm \
    --entrypoint sh \
    -v "$DATA_DIR:/opt/data" \
    -v "$AUTH_SRC:/tmp/hermes-auth.json:ro" \
    "$HERMES_IMAGE" \
    -c "cp /tmp/hermes-auth.json /opt/data/auth.json && chown $(id -u):$(id -g) /opt/data/auth.json && chmod 600 /opt/data/auth.json"
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

  # Pre-create vector extension as superuser since migrations run as non-superuser
  docker exec -i "$POSTGRES_CONTAINER" psql -U postgres -d "$database" -c "CREATE EXTENSION IF NOT EXISTS vector;"

  # Clona o produto (read-only do repo local de homolog) e fixa a ref.
  target="$DATA_DIR/product-src/$db_slug"
  [[ -d "$target/.git" ]] || git clone --quiet "$source_dir" "$target"
  git -C "$target" fetch --quiet "$source_dir" "$git_ref"
  git -C "$target" checkout --quiet "$git_ref"
  git -C "$target" reset --quiet --hard FETCH_HEAD

  database_url="postgresql://$role:$password@$POSTGRES_HOST:$POSTGRES_PORT/$database"

  # .env do produto (lido pelo plugin): DATABASE_URL + nome do tenant + env do catálogo.
  {
    printf 'DATABASE_URL=%s\n' "$database_url"
    printf 'HERMES_TENANT_NAME=%s\n' "$TENANT_NAME"
    python3 - "$PLAN" "$db_slug" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
env = next(d["env"] for d in plan["databases"] if d["db_slug"] == sys.argv[2])
for k, v in env.items():
    print(f"{k}={v}")
PY
  [[ -n "${OPENROUTER_API_KEY:-}" ]] && echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}"
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

# --- SOUL do home (identidade nativa do agente), gerada a partir do template -----
# Um produto pode declarar "soul" no catálogo (caminho relativo ao repo). O deploy
# renderiza {{INCORPORADORA}} com o nome do tenant e grava em /opt/data/SOUL.md.
# Substitui a edição manual no host (antes frágil e fora do versionamento).
mapfile -t soul_entries < <(python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for s in plan["plugin_sources"]:
    if s.get("soul"):
        print("\t".join([s["db_slug"], s["soul"]]))
PY
)
if ((${#soul_entries[@]} > 1)); then
  echo "aviso: mais de um produto declara soul neste profile; SOUL não gerado (defina soul_product no inventário)" >&2
elif ((${#soul_entries[@]} == 1)); then
  IFS=$'\t' read -r soul_slug soul_rel <<< "${soul_entries[0]}"
  soul_src="$DATA_DIR/product-src/$soul_slug/$soul_rel"
  soul_dst="$DATA_DIR/SOUL.md"
  if [[ -f "$soul_src" ]]; then
    # Backup único de um SOUL pré-existente não gerenciado (ex.: editado à mão).
    if [[ -f "$soul_dst" && ! -f "$soul_dst.pre-managed.bak" ]]; then
      cp -p "$soul_dst" "$soul_dst.pre-managed.bak"
      echo "SOUL pré-existente preservado em $soul_dst.pre-managed.bak" >&2
    fi
    TENANT_NAME="$TENANT_NAME" python3 - "$soul_src" "$soul_dst" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
name = os.environ.get("TENANT_NAME") or "incorporadora"
txt = open(src, encoding="utf-8").read().replace("{{INCORPORADORA}}", name)
open(dst, "w", encoding="utf-8").write(txt)
PY
    chmod 644 "$soul_dst"
    echo "SOUL gerado para '$TENANT_NAME' a partir de $soul_slug/$soul_rel"
  else
    echo "aviso: soul declarado mas template ausente: $soul_src" >&2
  fi
fi

# --- .env do container (home default): credenciais LLM + token do bot --------
{
  cat "$COMMON_ENV"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
  printf 'HERMES_TENANT_NAME=%s\n' "$TENANT_NAME"
  [[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]] && printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$TELEGRAM_ALLOWED_USERS"
  [[ -n "$TELEGRAM_HOME_CHANNEL" ]] && printf 'TELEGRAM_HOME_CHANNEL=%s\n' "$TELEGRAM_HOME_CHANNEL"
  if [[ "$WHATSAPP_ENABLED" == "true" ]]; then
    printf 'WHATSAPP_ENABLED=true\n'
    printf 'WHATSAPP_MODE=%s\n' "$WHATSAPP_MODE_VALUE"
    printf 'HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT=120\n'
    if [[ "$WHATSAPP_DM_POLICY" == "allowlist" ]]; then
      printf 'WHATSAPP_ALLOWED_USERS=%s\n' "$whatsapp_allowed_users"
    elif [[ "$WHATSAPP_DM_POLICY" == "open" ]]; then
      printf 'WHATSAPP_ALLOWED_USERS=*\n'
    fi
  fi
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

display_rows() {
  python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
display = plan.get("display") or {}
platforms = display.get("platforms") or {}
for platform, settings in platforms.items():
    if not isinstance(settings, dict):
        continue
    tool_progress = settings.get("tool_progress")
    if tool_progress is not None:
        print(f"display.platforms.{platform}.tool_progress\t{tool_progress}")
PY
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
while IFS=$'\t' read -r config_path config_value; do
  [[ -n "$config_path" ]] || continue
  hermes_one_shot config set "$config_path" "$config_value"
done < <(display_rows)

if [[ -n "$TELEGRAM_ADMIN_USERS" ]]; then
  hermes_one_shot config set platforms.telegram.extra.allow_admin_from "$TELEGRAM_ADMIN_USERS"
fi
if [[ -n "$TELEGRAM_UNAUTHORIZED_DM_MESSAGE" ]]; then
  hermes_one_shot config set platforms.telegram.extra.unauthorized_dm_message "$TELEGRAM_UNAUTHORIZED_DM_MESSAGE"
fi

# --- Hermes Agent overlay: caption nativa exclusivamente para videos --------
# Parte sempre da imagem pinada e reaplica um patch versionado. Se a imagem
# mudar e os anchors deixarem de casar, o deploy falha antes de reiniciar o
# gateway, evitando drift ou edicao manual dentro do container.
HERMES_AGENT_OVERLAY="$DATA_DIR/runtime/hermes-agent-overlay"
HERMES_VIDEO_CAPTION_PATCH="$ROOT/patches/hermes-agent/video-caption.patch"
HERMES_ACCESS_CONTROL_PATCH="$ROOT/patches/hermes-agent/access-control.patch"
[[ -f "$HERMES_VIDEO_CAPTION_PATCH" ]] || {
  echo "patch de caption de video ausente: $HERMES_VIDEO_CAPTION_PATCH" >&2
  exit 1
}
[[ -f "$HERMES_ACCESS_CONTROL_PATCH" ]] || {
  echo "patch de controle de acesso ausente: $HERMES_ACCESS_CONTROL_PATCH" >&2
  exit 1
}
docker run --rm \
  --entrypoint sh \
  -v "$DATA_DIR/runtime:/runtime" \
  "$HERMES_IMAGE" \
  -c "rm -rf /runtime/hermes-agent-overlay && mkdir -p /runtime/hermes-agent-overlay/gateway/platforms && cp /opt/hermes/gateway/platforms/base.py /runtime/hermes-agent-overlay/gateway/platforms/base.py && cp /opt/hermes/gateway/pairing.py /runtime/hermes-agent-overlay/gateway/pairing.py && cp /opt/hermes/gateway/run.py /runtime/hermes-agent-overlay/gateway/run.py && cp /opt/hermes/gateway/stream_consumer.py /runtime/hermes-agent-overlay/gateway/stream_consumer.py && chown -R $(id -u):$(id -g) /runtime/hermes-agent-overlay"
chmod -R u+w "$HERMES_AGENT_OVERLAY"
(
  cd "$HERMES_AGENT_OVERLAY"
  git apply --check "$HERMES_VIDEO_CAPTION_PATCH"
  git apply "$HERMES_VIDEO_CAPTION_PATCH"
  git apply --check "$HERMES_ACCESS_CONTROL_PATCH"
  git apply "$HERMES_ACCESS_CONTROL_PATCH"
  python3 -m py_compile gateway/platforms/base.py gateway/pairing.py gateway/run.py gateway/stream_consumer.py
)

if [[ "$WHATSAPP_ENABLED" == "true" ]]; then
  docker run --rm \
    --entrypoint sh \
    -v "$DATA_DIR/runtime:/runtime" \
    "$HERMES_IMAGE" \
    -c "rm -rf /runtime/whatsapp-bridge && mkdir -p /runtime/whatsapp-bridge && cp -a /opt/hermes/scripts/whatsapp-bridge/. /runtime/whatsapp-bridge/ && chown -R $(id -u):$(id -g) /runtime/whatsapp-bridge"

  chmod -R u+w "$DATA_DIR/runtime/whatsapp-bridge"

  if [[ -f "$DATA_DIR/product-src/taskme/ci/patch_hermes_bridge.py" ]]; then
    echo "Aplicando patch do whatsapp-bridge do TaskMe..."
    python3 "$DATA_DIR/product-src/taskme/ci/patch_hermes_bridge.py" --bridge "$DATA_DIR/runtime/whatsapp-bridge/bridge.js" --no-restart
  fi

  if [[ -f "$ROOT/scripts/patch_bridge_caption.py" ]]; then
    echo "Aplicando patch de legenda (caption) do whatsapp-bridge..."
    python3 "$ROOT/scripts/patch_bridge_caption.py" --bridge "$DATA_DIR/runtime/whatsapp-bridge/bridge.js"
  fi

  if [[ -f "$ROOT/scripts/patch_bridge_anti_ban.py" ]]; then
    echo "Aplicando patch de mitigação de ban (anti-ban) do whatsapp-bridge..."
    python3 "$ROOT/scripts/patch_bridge_anti_ban.py" --bridge "$DATA_DIR/runtime/whatsapp-bridge/bridge.js"
  fi


  # The WhatsApp adapter reads runtime-only bridge settings from
  # PlatformConfig.extra, which is populated from platforms.whatsapp.extra.
  # Keep the older top-level whatsapp.extra keys as harmless documentation /
  # backwards compatibility, but make platforms.whatsapp.extra authoritative.
  hermes_one_shot config set platforms.whatsapp.enabled true
  hermes_one_shot config set platforms.whatsapp.extra.bridge_port "$WHATSAPP_BRIDGE_PORT"
  hermes_one_shot config set platforms.whatsapp.extra.bridge_script "$WHATSAPP_BRIDGE_SCRIPT"
  hermes_one_shot config set platforms.whatsapp.extra.session_path "$WHATSAPP_SESSION_PATH"
  hermes_one_shot config set platforms.whatsapp.extra.dm_policy "$WHATSAPP_DM_POLICY"
  hermes_one_shot config set platforms.whatsapp.extra.group_policy "$WHATSAPP_GROUP_POLICY"
  hermes_one_shot config set whatsapp.extra.bridge_port "$WHATSAPP_BRIDGE_PORT"
  hermes_one_shot config set whatsapp.extra.bridge_script "$WHATSAPP_BRIDGE_SCRIPT"
  hermes_one_shot config set whatsapp.extra.session_path "$WHATSAPP_SESSION_PATH"
  hermes_one_shot config set whatsapp.extra.dm_policy "$WHATSAPP_DM_POLICY"
  hermes_one_shot config set whatsapp.extra.group_policy "$WHATSAPP_GROUP_POLICY"
fi

# --- Telegram Platform Adapter (Copia da imagem e aplica patch se necessário) ---
docker run --rm \
  --entrypoint sh \
  -v "$DATA_DIR/runtime:/runtime" \
  "$HERMES_IMAGE" \
  -c "rm -rf /runtime/telegram-platform && mkdir -p /runtime/telegram-platform && cp -a /opt/hermes/plugins/platforms/telegram/. /runtime/telegram-platform/ && chown -R $(id -u):$(id -g) /runtime/telegram-platform"

chmod -R u+w "$DATA_DIR/runtime/telegram-platform"

if [[ -f "$DATA_DIR/product-src/taskme/ci/patch_telegram_adapter.py" ]]; then
  echo "Aplicando patch do Telegram adapter do TaskMe..."
  python3 "$DATA_DIR/product-src/taskme/ci/patch_telegram_adapter.py" --adapter "$DATA_DIR/runtime/telegram-platform/adapter.py"
fi


while IFS= read -r plugin; do
  [[ -n "$plugin" ]] || continue
  hermes_one_shot plugins enable "$plugin" || true
done < <(python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1]))['plugins']))" "$PLAN")
if [[ "$WHATSAPP_ENABLED" == "true" ]]; then
  hermes_one_shot plugins enable whatsapp-platform || true
fi

# --- Container do profile (1 gateway run, profile default) -------------------
export HERMES_IMAGE
export HERMES_CONTAINER_NAME="$CONTAINER_NAME" HERMES_DATA_DIR="$DATA_DIR"
export HERMES_FILES_DIR="$FILES_DIR"
export HERMES_UID="$(id -u)" HERMES_GID="$(id -g)" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
  export HERMES_DASHBOARD=true
  export HERMES_DASHBOARD_HOST="$DASHBOARD_HOST"
  export HERMES_DASHBOARD_INSECURE="$DASHBOARD_INSECURE"
  if [[ -n "$DASHBOARD_BASIC_AUTH_PASSWORD_SECRET" ]]; then
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$DASHBOARD_BASIC_AUTH_USERNAME"
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$dashboard_basic_auth_password"
  else
    unset HERMES_DASHBOARD_BASIC_AUTH_USERNAME HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  fi
else
  unset HERMES_DASHBOARD HERMES_DASHBOARD_HOST HERMES_DASHBOARD_INSECURE
  unset HERMES_DASHBOARD_BASIC_AUTH_USERNAME HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
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
