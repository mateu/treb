#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/hunter/dev/treb"

exec systemd-run --user --pty \
  --unit=treb-sandbox \
  --description="treb sandbox" \
  --property=NoNewPrivileges=yes \
  --property=PrivateTmp=yes \
  --property=ProtectSystem=strict \
  --property=ReadWritePaths="$ROOT" \
  --property=WorkingDirectory="$ROOT" \
  bash -lc "$ROOT/script/run-treb.sh"
