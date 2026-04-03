#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

systemctl --user reset-failed treb-sandbox.service >/dev/null 2>&1 || true

exec systemd-run --user --pty --collect \
  --unit=treb-sandbox \
  --description="treb sandbox" \
  --property=NoNewPrivileges=yes \
  --property=PrivateTmp=yes \
  --property=ProtectSystem=strict \
  --property=ReadWritePaths="$ROOT" \
  --property=WorkingDirectory="$ROOT" \
  bash -lc "$ROOT/script/run-treb.sh"
