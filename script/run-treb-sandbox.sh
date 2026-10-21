#!/usr/bin/env bash
set -euo pipefail

# The installed persistent unit owns the process and retains the sandbox.
# Setup instructions: script/README.md (Persistent bot services).
exec systemctl --user start treb-sandbox.service
