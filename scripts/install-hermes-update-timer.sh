#!/usr/bin/env bash
# Instala um timer systemd --user para atualização diária da imagem Hermes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${1:-}"
CLIENT="${2:-}"
PROFILE="${3:-}"
TIME_OF_DAY="${4:-04:00}"

if [[ -z "$ENVIRONMENT" || -z "$CLIENT" || -z "$PROFILE" ]]; then
  echo "uso: $0 <ambiente> <cliente> <profile> [HH:MM]" >&2
  echo "ex.: $0 hml leonardo pessoal 04:00" >&2
  exit 2
fi

UNIT_BASENAME="hermes-${ENVIRONMENT}-${CLIENT}-${PROFILE}-update"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"

cat > "$USER_SYSTEMD_DIR/$UNIT_BASENAME.service" <<EOF
[Unit]
Description=Atualiza imagem Hermes $ENVIRONMENT/$CLIENT/$PROFILE

[Service]
Type=oneshot
WorkingDirectory=$ROOT
Environment=HERMES_IMAGE_REQUIRE_UPSTREAM_MAIN=1
ExecStart=$ROOT/scripts/update-hermes-image.sh $ENVIRONMENT $CLIENT $PROFILE
EOF

cat > "$USER_SYSTEMD_DIR/$UNIT_BASENAME.timer" <<EOF
[Unit]
Description=Timer diário de atualização Hermes $ENVIRONMENT/$CLIENT/$PROFILE

[Timer]
OnCalendar=*-*-* $TIME_OF_DAY:00
RandomizedDelaySec=30m
Persistent=true
Unit=$UNIT_BASENAME.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_BASENAME.timer"
systemctl --user list-timers "$UNIT_BASENAME.timer" --no-pager
