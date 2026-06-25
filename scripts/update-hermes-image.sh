#!/usr/bin/env bash
# Atualiza a imagem Hermes de um profile de forma controlada:
# - consulta a tag configurada no registry;
# - grava o digest resolvido em runtime/hermes-image.env;
# - roda o deploy idempotente existente;
# - faz smoke test básico;
# - reverte para a imagem anterior se o deploy/smoke falhar.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
PROFILE="${3:-}"

usage() {
  echo "uso: $0 <ambiente> <cliente> <profile>" >&2
  echo "ex.: $0 hml leonardo pessoal" >&2
}

[[ -n "$ENVIRONMENT" && -n "$CLIENT" && -n "$PROFILE" ]] || { usage; exit 2; }

PLAN="$(mktemp)"
TMP_IMAGE_ENV=""
ROLLBACK_REQUIRED=false
PREVIOUS_IMAGE_ENV=""

on_exit() {
  local rc=$?
  set +e
  rm -f "$PLAN"
  [[ -n "$TMP_IMAGE_ENV" ]] && rm -f "$TMP_IMAGE_ENV"

  if [[ $rc -ne 0 && "$ROLLBACK_REQUIRED" == "true" ]]; then
    echo "update falhou; revertendo imagem anterior"
    if [[ -n "$PREVIOUS_IMAGE_ENV" && -f "$PREVIOUS_IMAGE_ENV" ]]; then
      cp -f "$PREVIOUS_IMAGE_ENV" "$IMAGE_ENV"
    else
      rm -f "$IMAGE_ENV"
    fi
    "$ROOT/scripts/deploy-instance.sh" "$ENVIRONMENT" "$CLIENT" "$PROFILE" || true
  fi
  exit "$rc"
}
trap on_exit EXIT

python3 "$ROOT/scripts/validate_inventory.py"
python3 "$ROOT/scripts/inventory.py" plan "$ENVIRONMENT" "$CLIENT" "$PROFILE" > "$PLAN"

field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$PLAN" "$1"; }
jget() { python3 - "$PLAN" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print(sys.argv[3])
        raise SystemExit
    cur = cur[part]
print(str(cur).lower() if isinstance(cur, bool) else cur)
PY
}

CONTAINER_NAME="$(field container_name)"
RUNTIME_ROOT="$(field runtime_root)"
DASHBOARD_ENABLED="$(jget dashboard.enabled false)"

mkdir -p "$RUNTIME_ROOT"
exec 9>"$RUNTIME_ROOT/hermes-update.lock"
if ! flock -n 9; then
  echo "update já em execução para $ENVIRONMENT/$CLIENT/$PROFILE"
  exit 0
fi

LOG_FILE="$RUNTIME_ROOT/hermes-update.log"
exec >>"$LOG_FILE" 2>&1

IMAGE_REPOSITORY="${HERMES_IMAGE_REPOSITORY:-nousresearch/hermes-agent}"
IMAGE_TAG="${HERMES_IMAGE_TAG:-latest}"
UPSTREAM_REPOSITORY="${HERMES_IMAGE_UPSTREAM_REPOSITORY:-https://github.com/NousResearch/Hermes-Agent.git}"
UPSTREAM_REF="${HERMES_IMAGE_UPSTREAM_REF:-refs/heads/main}"
REQUIRE_UPSTREAM_MAIN="${HERMES_IMAGE_REQUIRE_UPSTREAM_MAIN:-0}"
CANDIDATE_REF="$IMAGE_REPOSITORY:$IMAGE_TAG"
IMAGE_ENV="$RUNTIME_ROOT/hermes-image.env"
PREVIOUS_IMAGE_ENV="$RUNTIME_ROOT/hermes-image.env.previous"

echo "== $(date -Is) update $ENVIRONMENT/$CLIENT/$PROFILE"
echo "consultando $CANDIDATE_REF"
docker pull "$CANDIDATE_REF"

CANDIDATE_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$CANDIDATE_REF" | grep -m1 "^$IMAGE_REPOSITORY@" || true)"
CANDIDATE_IMAGE="${CANDIDATE_DIGEST:-$CANDIDATE_REF}"
CURRENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
CANDIDATE_REVISION="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$CANDIDATE_REF" 2>/dev/null || true)"
UPSTREAM_REVISION="$(git ls-remote "$UPSTREAM_REPOSITORY" "$UPSTREAM_REF" 2>/dev/null | awk 'NR == 1 {print $1}')"

if [[ -n "$UPSTREAM_REVISION" && -n "$CANDIDATE_REVISION" && "$UPSTREAM_REVISION" != "$CANDIDATE_REVISION" ]]; then
  echo "aviso: imagem Docker não acompanha o upstream Git"
  echo "  imagem:  $CANDIDATE_REVISION ($CANDIDATE_REF)"
  echo "  upstream: $UPSTREAM_REVISION ($UPSTREAM_REF)"
  if [[ "$REQUIRE_UPSTREAM_MAIN" == "1" || "$REQUIRE_UPSTREAM_MAIN" == "true" ]]; then
    echo "HERMES_IMAGE_REQUIRE_UPSTREAM_MAIN ativo; abortando update"
    exit 1
  fi
elif [[ -n "$UPSTREAM_REVISION" && -n "$CANDIDATE_REVISION" ]]; then
  echo "imagem Docker alinhada ao upstream: $CANDIDATE_REVISION"
else
  echo "aviso: não foi possível comparar imagem Docker com upstream Git"
  echo "  imagem: ${CANDIDATE_REVISION:-<sem label org.opencontainers.image.revision>}"
  echo "  upstream: ${UPSTREAM_REVISION:-<indisponível>}"
fi

if [[ "$CURRENT_IMAGE" == "$CANDIDATE_IMAGE" ]]; then
  echo "sem atualização: $CURRENT_IMAGE"
  exit 0
fi

echo "imagem atual: ${CURRENT_IMAGE:-<container ausente>}"
echo "nova imagem: $CANDIDATE_IMAGE"

if [[ -f "$IMAGE_ENV" ]]; then
  cp -f "$IMAGE_ENV" "$PREVIOUS_IMAGE_ENV"
elif [[ -n "$CURRENT_IMAGE" ]]; then
  printf 'HERMES_IMAGE=%s\n' "$CURRENT_IMAGE" > "$PREVIOUS_IMAGE_ENV"
else
  rm -f "$PREVIOUS_IMAGE_ENV"
fi

TMP_IMAGE_ENV="$(mktemp "$RUNTIME_ROOT/hermes-image.env.XXXXXX")"
{
  printf 'HERMES_IMAGE=%s\n' "$CANDIDATE_IMAGE"
  printf 'HERMES_IMAGE_REPOSITORY=%s\n' "$IMAGE_REPOSITORY"
  printf 'HERMES_IMAGE_TAG=%s\n' "$IMAGE_TAG"
  printf 'HERMES_IMAGE_UPDATED_AT=%s\n' "$(date -Is)"
} > "$TMP_IMAGE_ENV"
mv -f "$TMP_IMAGE_ENV" "$IMAGE_ENV"
TMP_IMAGE_ENV=""

ROLLBACK_REQUIRED=true
"$ROOT/scripts/deploy-instance.sh" "$ENVIRONMENT" "$CLIENT" "$PROFILE"

running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
[[ "$running" == "true" ]] || { echo "container não ficou running: $CONTAINER_NAME"; exit 1; }

if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
  dashboard_ready=false
  for _ in {1..30}; do
    if curl -fsS --max-time 5 http://127.0.0.1:9119/ >/dev/null; then
      dashboard_ready=true
      break
    fi
    sleep 2
  done
  if [[ "$dashboard_ready" != "true" ]]; then
    echo "dashboard não respondeu em http://127.0.0.1:9119/ após 60s"
    docker logs --tail 80 "$CONTAINER_NAME" || true
    exit 1
  fi
fi

ROLLBACK_REQUIRED=false
echo "update aplicado com sucesso: $CANDIDATE_IMAGE"
