#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

systemctl --user reset-failed critic-sandbox.service >/dev/null 2>&1 || true

exec systemd-run --user --pty --collect \
  --unit=critic-sandbox \
  --description="critic sandbox" \
  --property=NoNewPrivileges=yes \
  --property=PrivateTmp=yes \
  --property=ProtectSystem=strict \
  --property=ReadWritePaths="$ROOT" \
  --property=WorkingDirectory="$ROOT" \
  bash -lc "$ROOT/script/run-critic.sh"
