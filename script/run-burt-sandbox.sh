#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec systemd-run --user --pty \
  --unit=burt-sandbox \
  --description="burt sandbox" \
  --property=NoNewPrivileges=yes \
  --property=PrivateTmp=yes \
  --property=ProtectSystem=strict \
  --property=ReadWritePaths="$ROOT" \
  --property=WorkingDirectory="$ROOT" \
  bash -lc "$ROOT/script/run-burt.sh"
