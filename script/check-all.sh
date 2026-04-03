#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_check() {
  local label="$1"
  shift
  echo "== $label =="
  "$@"
  echo
}

run_check "treb syntax"   ./script/with-treb-env.sh perl -c treb.pl
run_check "burt syntax"   ./script/with-burt-env.sh perl -c burt.pl
run_check "astrid syntax" ./script/with-astrid-env.sh perl -c astrid.pl
run_check "tests"         ./script/with-burt-env.sh prove -lr t
