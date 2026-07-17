#!/usr/bin/env bash
# Tunnel watchdog — real connectivity checks, then systemctl restart.
set -euo pipefail

LIB="${TUNNEL_LIB:-/usr/local/lib/tunnel-watchdog/tunnel-lib.sh}"
# fallback for local/dev path next to this script
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

do_restart() {
  local name="$1" unit="$2"
  if in_cooldown "$unit"; then
    log "SKIP restart $name ($unit): cooldown ${COOLDOWN_SEC}s"
    return 0
  fi
  log "RESTART $name -> systemctl restart $unit"
  systemctl restart "$unit" || true
  mark_cooldown "$unit"
  clear_fails "$unit"
  sleep 3
  if service_active "$unit"; then
    log "OK $unit active after restart (health will re-check next ticks)"
  else
    log "FAIL $unit not active after restart"
  fi
}

handle_result() {
  local name="$1" unit="$2" kind="$3" arg="$4" healthy="$5"
  local fails

  if [[ "$healthy" -eq 1 ]]; then
    clear_fails "$unit"
    log "OK: $name ($unit) check=$kind"
    return 0
  fi

  fails="$(get_fails "$unit")"
  fails=$((fails + 1))
  set_fails "$unit" "$fails"
  log "FAIL($fails/$FAIL_THRESHOLD): $name ($unit) check=$kind arg=$arg"

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

  if evaluate_tunnel "$name" "$unit" "$kind" "$arg"; then
    healthy=1
  else
    healthy=0
    if [[ "$HEALTH_REASON" == *"systemd"* ]] || [[ "$HEALTH_REASON" == *"inactive"* ]]; then
      log "DOWN: $name ($unit) $HEALTH_REASON"
    fi
  fi
  handle_result "$name" "$unit" "$kind" "$arg" "$healthy"
}

main() {
  tw_load_conf || exit 1
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
