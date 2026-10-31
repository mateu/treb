#!/usr/bin/env bash
# Host launcher. Not mounted into Burt's namespace. No model-controlled argv.
set -euo pipefail
repo="${BURT_SOURCE_ROOT:-$HOME/dev/treb}"
state="$HOME/.local/share/burt-irc"
ipc="${BURT_WORKBENCH_IPC_ROOT:-$HOME/.local/share/burt-workbench/ipc}"
mode="${1:-start}"
extra_mounts=()
case "$mode" in
  start) command=(/usr/bin/perl /app/burt.pl) ;;
  check) command=(/usr/bin/perl -c /app/burt.pl) ;;
  model-check|model-repo-check|model-repo-continue-check)
    extra_mounts=(--ro-bind "$repo/script/workbench/model-smoke.pl" /smoke.pl)
    smoke_mode=gist
    [[ "$mode" != model-repo-check ]] || smoke_mode=repo-start
    [[ "$mode" != model-repo-continue-check ]] || smoke_mode=repo-continue
    command=(/usr/bin/perl -I/app/lib /smoke.pl "$smoke_mode") ;;
  model-repair-check)
    extra_mounts=(--ro-bind "$repo/script/workbench/repair-smoke.pl" /smoke.pl
      --ro-bind "$repo/script/workbench/repair-fixture.json" /repair-fixture.json)
    command=(/usr/bin/perl -I/app/lib /smoke.pl) ;;
  probe) command=(/usr/bin/python3 -I -c '
import os, pathlib, socket, json
hidden=["/home/hunter", "/run/user", "/app/astrid.env", "/app/treb.sqlite", "/app/script", "/publisher", "/state/gist.token"]
assert all(not pathlib.Path(p).exists() for p in hidden), "host files visible"
assert not pathlib.Path("/proc/1/root/home/hunter").exists()
try: pathlib.Path("/app/burt.pl").write_text("bad")
except OSError: pass
else: raise AssertionError("code is writable")
assert pathlib.Path("/state/burt.sqlite").exists()
s=socket.socket(socket.AF_UNIX); s.settimeout(35); s.connect("/broker/broker.sock")
scope="e"*64
channel="#ai"
network="irc.perl.org"
request=dict(action="run",scope=scope,requester="probe",channel=channel,network=network,title="namespace IPC probe",files={"main.py":"print(42)\n"},argv=["/usr/bin/python3","-I","/work/main.py"])
s.sendall(json.dumps(request).encode()+b"\n")
result=json.loads(s.makefile().readline()); s.close()
assert result.get("state")=="passed" and result["result"]["output"]=="42\n", result
assert not any(k in os.environ for k in ("SSH_AUTH_SOCK","DBUS_SESSION_BUS_ADDRESS","GH_TOKEN","GITHUB_TOKEN"))
print("bot namespace: hidden host/credentials/other bots; readonly code; own state; clean environment; broker execution passed")
') ;;
  *) echo 'Expected start, check, probe, model-check, model-repo-check, model-repo-continue-check (publish public artifacts), or model-repair-check (no publication)' >&2; exit 2 ;;
esac
exec /usr/bin/bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
  --unshare-cgroup --die-with-parent --new-session --cap-drop ALL \
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 --proc /proc --dev /dev \
  --ro-bind /etc/resolv.conf /etc/resolv.conf --ro-bind /etc/hosts /etc/hosts \
  --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf --ro-bind /etc/ssl/certs /etc/ssl/certs \
  --ro-bind /etc/localtime /etc/localtime \
  --ro-bind "$HOME/perl5" /perl5 \
  --ro-bind "$repo/lib" /app/lib --ro-bind "$repo/burt.pl" /app/burt.pl \
  --ro-bind "$repo/base.persona.txt" /app/base.persona.txt \
  --ro-bind "$repo/burt.persona.txt" /app/burt.persona.txt \
  --ro-bind "$repo/burt.mission.txt" /app/burt.mission.txt \
  --ro-bind "$state/burt.env" /app/burt.env \
  --bind "$state/data" /state --ro-bind "$ipc" /broker \
  "${extra_mounts[@]}" \
  --size 33554432 --tmpfs /tmp --chdir /app --remount-ro / \
  --clearenv --setenv PATH /usr/bin:/bin --setenv HOME /tmp \
  --setenv USER burt --setenv LANG C.UTF-8 \
  /bin/bash --noprofile --norc -c '
    set -euo pipefail
    eval "$(perl -I/perl5/lib/perl5 -Mlocal::lib=/perl5)"
    set -a
    source /app/burt.env
    set +a
    export DB_FILE=/state/burt.sqlite BURT_WORKBENCH_SOCKET=/broker/broker.sock
    exec "$@"
  ' burt "${command[@]}"
