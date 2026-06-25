#!/usr/bin/env bash
# Executa um comando Hermes dentro do container de um profile sem criar arquivos
# root:root no volume /opt/data.
#
# Uso:
#   ./scripts/hermes-command.sh hml leonardo pessoal whatsapp
#   ./scripts/hermes-command.sh hml leonardo pessoal plugins list --plain
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
PROFILE="${3:-}"

if [[ -z "$ENVIRONMENT" || -z "$CLIENT" || -z "$PROFILE" ]]; then
  echo "uso: $0 <ambiente> <cliente> <profile> <comando-hermes> [args...]" >&2
  exit 2
fi
shift 3
if (($# == 0)); then
  echo "informe o comando Hermes a executar dentro do container" >&2
  exit 2
fi

PLAN="$(mktemp)"; trap 'rm -f "$PLAN"' EXIT
python3 "$ROOT/scripts/inventory.py" plan "$ENVIRONMENT" "$CLIENT" "$PROFILE" > "$PLAN"
CONTAINER_NAME="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['container_name'])" "$PLAN")"
DATA_DIR="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['data_dir'])" "$PLAN")"

uid="$(id -u)"
gid="$(id -g)"
tty_args=(-i)
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

docker run --rm \
  --entrypoint sh \
  -v "$DATA_DIR:/opt/data" \
  "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")" \
  -c "chown -R $uid:$gid /opt/data && chmod -R u+rwX /opt/data"

docker exec "${tty_args[@]}" \
  --user "$uid:$gid" \
  -e HERMES_HOME=/opt/data \
  -e HOME=/opt/data \
  "$CONTAINER_NAME" \
  /opt/hermes/.venv/bin/hermes "$@"
