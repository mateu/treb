#!/usr/bin/env bash
set -euo pipefail

# The installed persistent unit owns the process and retains the sandbox.
# Setup instructions: script/README.md (Burt boot persistence).
exec systemctl --user start burt-sandbox.service
