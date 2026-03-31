#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Default mode is deterministic. Override with:
#   --mode real
# or:
#   IRC_HARNESS_MODE=real
exec python3 "$ROOT/script/irc_harness.py" "$@"
