#!/usr/bin/env bash
# Tunnel watchdog — conservative restarts only when tunnel is really dead.
set -euo pipefail

LIB="${TUNNEL_LIB:-/usr/local/lib/tunnel-watchdog/tunnel-lib.sh}"
if [[ ! -f "$LIB" ]]; then
  LIB="$(cd "$(dirname "$0")" && pwd)/tunnel-lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB"

LOG_TAG="tunnel-watchdog"

log() {
  local msg="$*"
  logger -t "$LOG_TAG" -- "$msg" 2>/dev/null || true
  echo "$(date '+%F %T') $msg"
}

safe_key() { echo "$1" | tr -c 'A-Za-z0-9._-' '_' ; }

fail_count_path() { echo "$STATE_DIR/fail.$(safe_key "$1")" ; }
cooldown_path()   { echo "$STATE_DIR/cooldown.$(safe_key "$1")" ; }

get_fails() {
  local f; f="$(fail_count_path "$1")"
  [[ -f "$f" ]] && cat "$f" || echo 0
}

set_fails() { echo "$2" > "$(fail_count_path "$1")" ; }
clear_fails() { rm -f "$(fail_count_path "$1")" ; }

in_cooldown() {
  local p now last
  p="$(cooldown_path "$1")"
  [[ -f "$p" ]] || return 1
  last="$(cat "$p" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last < COOLDOWN_SEC ))
}

mark_cooldown() { date +%s > "$(cooldown_path "$1")" ; }

# Skip FAIL/restart while unit is still warming up after start/restart
in_grace() {
  local unit="$1" age
  age="$(unit_active_age_sec "$unit")"
  (( age < GRACE_SEC ))
}

# After install/upgrade: do not restart tunnels for SETTLE_SEC (default 10 min)
in_install_settle() {
  local f now until
  f="${STATE_DIR}/settle_until"
  [[ -f "$f" ]] || return 1
  until="$(cat "$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now < until ))
}

is_ignored_unit() {
  local unit="$1"
  # Never touch web panels / non-tunnel helpers
  echo "$unit" | grep -qiE 'webui|watchdog' && return 0
  return 1
}

do_restart() {
  local name="$1" unit="$2"
  if in_install_settle; then
    log "SKIP restart $name ($unit): install settle window"
    return 0
  fi
  if in_cooldown "$unit"; then
    log "SKIP restart $name ($unit): cooldown ${COOLDOWN_SEC}s"
    return 0
  fi
  if in_grace "$unit"; then
    log "SKIP restart $name ($unit): still in grace ${GRACE_SEC}s"
    return 0
  fi
  log "RESTART $name -> systemctl restart $unit"
  systemctl restart "$unit" || true
  mark_cooldown "$unit"
  clear_fails "$unit"
  sleep 3
  if service_active "$unit"; then
    log "OK $unit active after restart (grace ${GRACE_SEC}s starts now)"
  else
    log "FAIL $unit not active after restart"
  fi
}

handle_result() {
  local name="$1" unit="$2" kind="$3" arg="$4" healthy="$5" reason="${6:-}"
  local fails

  if [[ "$healthy" -eq 1 ]]; then
    clear_fails "$unit"
    log "OK: $name ($unit) check=$kind ${reason}"
    return 0
  fi

  if in_install_settle; then
    log "SETTLE: $name ($unit) unhealthy during install settle — not counting ($reason)"
    return 0
  fi

  if in_grace "$unit"; then
    log "GRACE: $name ($unit) unhealthy but age<${GRACE_SEC}s — not counting ($reason)"
    return 0
  fi

  fails="$(get_fails "$unit")"
  fails=$((fails + 1))
  set_fails "$unit" "$fails"
  log "FAIL($fails/$FAIL_THRESHOLD): $name ($unit) check=$kind arg=$arg — $reason"

  if (( fails >= FAIL_THRESHOLD )); then
    do_restart "$name" "$unit"
  fi
}

check_one() {
  local entry="$1"
  local name unit kind arg healthy=0

  tw_parse_entry "$entry"
  name="$_name"
  unit="$_unit"
  kind="$_kind"
  arg="$_arg"

  [[ -z "$name" || -z "$unit" ]] && return 0
  [[ "$name" =~ ^# ]] && return 0

  if is_ignored_unit "$unit"; then
    log "SKIP: $name ($unit) ignored (webui/watchdog)"
    return 0
  fi

  if evaluate_tunnel "$name" "$unit" "$kind" "$arg"; then
    healthy=1
  else
    healthy=0
  fi
  handle_result "$name" "$unit" "$kind" "$arg" "$healthy" "$HEALTH_REASON"
}

main() {
  tw_load_conf || exit 1
  FAIL_THRESHOLD="${FAIL_THRESHOLD:-5}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-300}"
  GRACE_SEC="${GRACE_SEC:-300}"
  if [[ -z "${TUNNELS:-}" ]]; then
    log "ERROR: TUNNELS empty in $CONF"
    exit 1
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    check_one "$line"
  done <<<"$TUNNELS"
}

main "$@"
