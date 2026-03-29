#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ -d "$HOME/perl5" ]; then
  eval "$(perl -Mlocal::lib=$HOME/perl5)"
fi
if [ -f "$ROOT/burt.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/burt.env"
fi
exec "$@"
