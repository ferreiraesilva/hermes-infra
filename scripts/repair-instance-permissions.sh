#!/usr/bin/env bash
# Repara ownership/permissões do home persistente de um profile Hermes.
#
# Use quando algum comando operacional tiver sido executado com `docker exec`
# sem `--user`, criando arquivos root:root em /opt/data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
PROFILE="${3:-}"

if [[ -z "$ENVIRONMENT" || -z "$CLIENT" || -z "$PROFILE" ]]; then
  echo "uso: $0 <ambiente> <cliente> <profile>" >&2
  exit 2
fi

PLAN="$(mktemp)"; trap 'rm -f "$PLAN"' EXIT
python3 "$ROOT/scripts/inventory.py" plan "$ENVIRONMENT" "$CLIENT" "$PROFILE" > "$PLAN"
CONTAINER_NAME="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['container_name'])" "$PLAN")"
DATA_DIR="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['data_dir'])" "$PLAN")"

uid="$(id -u)"
gid="$(id -g)"
image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"

docker run --rm \
  --entrypoint sh \
  -v "$DATA_DIR:/opt/data" \
  "$image" \
  -c "chown -R $uid:$gid /opt/data && chmod 700 /opt/data && chmod -R u+rwX /opt/data"

echo "permissões reparadas: $ENVIRONMENT/$CLIENT/$PROFILE ($DATA_DIR)"
