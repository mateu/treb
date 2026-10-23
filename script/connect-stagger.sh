# shellcheck shell=bash
# Sourced by run-*.sh before exec'ing a bot.
#
# All bots connect from the same IP, and irc.perl.org (ircd-hybrid 7.2.3)
# refuses a connection that arrives within throttle_time (default 10s) of the
# previous attempt from that IP -- and a refused attempt restarts the clock.
# Queue starts behind a shared lock so each bot gets its own connect slot.
#
#   IRC_CONNECT_GAP=15   seconds between bot starts (0 disables)

connect_stagger() {
  local gap="${IRC_CONNECT_GAP:-15}"
  [ "$gap" -gt 0 ] 2>/dev/null || return 0

  local server="${IRC_SERVER:-irc.perl.org}"
  # Lives in the repo: the systemd units use PrivateTmp, so /tmp isn't shared.
  local dir="$ROOT/log/connect-slot"
  mkdir -p "$dir"
  local stamp="$dir/$server"

  exec 9>>"$stamp.lock"
  flock 9
  local last=0 now wait
  [ -s "$stamp" ] && last="$(cat "$stamp")"
  now="$(date +%s)"
  wait=$(( last + gap - now ))
  if [ "$wait" -gt 0 ]; then
    echo "connect-stagger: waiting ${wait}s for a $server connect slot" >&2
    sleep "$wait"
  fi
  date +%s >"$stamp"
  flock -u 9
  exec 9>&-
}

connect_stagger
