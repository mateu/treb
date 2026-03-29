#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -d "$HOME/perl5" ]; then
  eval "$(perl -I"$HOME/perl5/lib/perl5" -Mlocal::lib="$HOME/perl5")"
fi

if [ -f "$ROOT/treb.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/treb.env"
fi

exec "$@"
