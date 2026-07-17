#!/usr/bin/env bash
# Shared tunnel health-check library (sourced by watchdog + menu).
# Do not execute directly.

CONF="${TUNNEL_WATCHDOG_CONF:-/etc/tunnel-watchdog.conf}"
STATE_DIR="${TUNNEL_WATCHDOG_STATE:-/run/tunnel-watchdog}"
JOURNAL_LOOKBACK="${JOURNAL_LOOKBACK:-10min}"

# Output of last evaluate_tunnel call:
HEALTH_STATUS=""   # OK | FAIL
HEALTH_REASON=""

tw_load_conf() {
  if [[ ! -f "$CONF" ]]; then
    echo "ERROR: missing config $CONF" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CONF"
  FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-120}"
  JOURNAL_LOOKBACK="${JOURNAL_LOOKBACK:-10min}"
  CONTROL_JOURNAL_SINCE="${CONTROL_JOURNAL_SINCE:-5 min ago}"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Print non-empty, non-comment tunnel lines from TUNNELS
tw_list_entries() {
  tw_load_conf || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    echo "$line"
  done <<<"${TUNNELS:-}"
}

tw_parse_entry() {
  # sets: _name _unit _kind _arg
  local entry="$1"
  IFS='|' read -r _name _unit _kind _arg <<<"$entry"
  _name="$(echo "${_name:-}" | xargs)"
  _unit="$(echo "${_unit:-}" | xargs)"
  _kind="$(echo "${_kind:-active}" | xargs)"
  _arg="$(echo "${_arg:-}" | xargs)"
}

service_active() { systemctl is-active --quiet "$1"; }

port_listening() {
  local hp="$1" host port
  host="${hp%:*}"
  port="${hp##*:}"
  [[ -n "$port" ]] || return 1
  if [[ "$host" == "*" || "$host" == "0.0.0.0" || "$host" == "::" || -z "$host" ]]; then
    ss -lntuH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    ss -lntuH 2>/dev/null | awk '{print $4}' | grep -Eq "^(${host}|\\[${host}\\]):${port}$" \
      || ss -lntuH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  fi
}

tcp_local() {
  local hp="$1" host port
  host="${hp%:*}"
  port="${hp##*:}"
  [[ "$host" == "*" || "$host" == "0.0.0.0" || -z "$host" ]] && host="127.0.0.1"
  timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

ping_ok() {
  ping -c 2 -W 2 "$1" >/dev/null 2>&1
}

# Count ESTABLISHED sockets for a systemd unit MainPID to remote port.
unit_estab_count() {
  local unit="$1" port="$2"
  local pid cnt
  pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
  if [[ -z "$pid" || "$pid" == "0" ]]; then
    echo "0"
    return 1
  fi
  cnt="$(ss -tnp state established 2>/dev/null \
    | grep -F "pid=$pid," \
    | grep -E ":${port}([[:space:]]|$)" \
    | wc -l | tr -d ' ')"
  echo "${cnt:-0}"
}

# Legacy: proc_substr:port[:min]
remote_estab_count() {
  local arg="$1"
  local proc port min cnt
  proc="${arg%%:*}"
  local rest="${arg#*:}"
  port="${rest%%:*}"
  if [[ "$rest" == *:* ]]; then
    min="${rest#*:}"
  else
    min=1
  fi
  [[ -n "$proc" && -n "$port" ]] || { echo "0"; return 1; }
  cnt="$(ss -tnp state established 2>/dev/null \
    | grep -F "$proc" \
    | grep -E ":${port}([[:space:]]|$)" \
    | wc -l | tr -d ' ')"
  echo "${cnt:-0}"
  [[ "${cnt:-0}" -ge "$min" ]]
}

remote_estab_ok() {
  remote_estab_count "$1" >/dev/null
}

# Parse port[:min] — default min=3
# Dead tunnels usually leave 0-2 zombie CF ESTAB; healthy pool is much higher.
parse_port_min() {
  local arg="$1"
  _cc_port="${arg%%:*}"
  if [[ "$arg" == *:* ]]; then
    _cc_min="${arg#*:}"
  else
    _cc_min=3
  fi
  [[ -n "$_cc_min" ]] || _cc_min=3
}

_cc_journal_since() {
  # Only recent logs — never punish forever for an old bad handshake.
  echo "${CONTROL_JOURNAL_SINCE:-5 min ago}"
}

_cc_relevant_last() {
  local unit="$1"
  journalctl -u "$unit" --since "$(_cc_journal_since)" --no-pager -o cat 2>/dev/null \
    | grep -iE 'control channel established successfully|attempting to establish a new .+ control channel|failed to read from channel|bad handshake|connection reset by peer|waiting for .+ control channel' \
    | tail -1 || true
}

_cc_is_success() {
  echo "$1" | grep -qi 'control channel established successfully'
}

_cc_is_failure() {
  local line="$1"
  echo "$line" | grep -qiE 'bad handshake|failed to read from channel|connection reset by peer|waiting for' \
    && ! _cc_is_success "$line"
}

# Client-mode liveness with hysteresis:
#  - ESTAB < 2            => FAIL (zombie / cut)
#  - recent journal FAIL  => FAIL (even if a few sockets linger)
#  - recent journal OK    => OK if ESTAB >= 2
#  - no recent journal    => OK only if ESTAB >= min (healthy pool), else FAIL
control_channel_ok() {
  local unit="$1" arg="$2"
  local cnt last
  parse_port_min "$arg"
  cnt="$(unit_estab_count "$unit" "$_cc_port")"
  last="$(_cc_relevant_last "$unit")"

  if [[ "${cnt:-0}" -lt 2 ]]; then
    return 1
  fi

  if [[ -n "$last" ]] && _cc_is_failure "$last"; then
    return 1
  fi

  if [[ -n "$last" ]] && _cc_is_success "$last"; then
    return 0
  fi

  # Silent window: trust pool size only
  [[ "${cnt:-0}" -ge "$_cc_min" ]]
}

control_channel_detail() {
  local unit="$1" arg="$2"
  local cnt last
  parse_port_min "$arg"
  cnt="$(unit_estab_count "$unit" "$_cc_port")"
  last="$(_cc_relevant_last "$unit")"
  last="$(echo "$last" | sed -E 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | cut -c1-100)"
  echo "ESTAB=${cnt} min=${_cc_min} port=:${_cc_port}; journal(${CONTROL_JOURNAL_SINCE:-5m})=${last:-none}"
}

iface_up() {
  local iface="$1"
  [[ -d "/sys/class/net/$iface" ]] || return 1
  local st
  st="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"
  [[ "$st" == "up" || "$st" == "unknown" ]]
}

backhaul_mapped_ok() {
  local arg="$1"
  local ports=()
  local p line left

  if [[ -f "$arg" ]]; then
    while IFS= read -r line; do
      left="$(echo "$line" | sed -n 's/.*"\([^"=]*\)=.*/\1/p')"
      [[ -n "$left" ]] && ports+=("$left")
    done < <(grep -E '^\s*"?[^"]+=.+"?' "$arg" 2>/dev/null || true)
    if [[ ${#ports[@]} -eq 0 ]]; then
      while IFS= read -r line; do
        left="$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | head -1)"
        [[ -n "$left" ]] && ports+=("$left")
      done < <(grep -E 'ports|local_addr|listen' "$arg" 2>/dev/null || true)
    fi
  else
    IFS=',' read -ra ports <<<"$arg"
  fi

  if [[ ${#ports[@]} -eq 0 ]]; then
    return 1
  fi

  for p in "${ports[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -z "$p" ]] && continue
    port_listening "$p" || return 1
    case "$p" in
      127.*:*|10.*:*|172.*:*|192.168.*:*)
        tcp_local "$p" || return 1
        ;;
    esac
  done
  return 0
}

backhaul_journal_ok() {
  local unit="$1"
  local est disc
  est="$(journalctl -u "$unit" --since "$JOURNAL_LOOKBACK" --no-pager -o cat 2>/dev/null \
    | grep -ciE 'control channel established|channel established successfully' || true)"
  disc="$(journalctl -u "$unit" --since "$JOURNAL_LOOKBACK" --no-pager -o cat 2>/dev/null \
    | grep -ciE 'failed to read from channel|waiting for .* control channel|control channel.*closed|connection reset' || true)"
  if (( est > 0 )); then
    return 0
  fi
  if (( disc > 0 )); then
    return 1
  fi
  return 1
}

backpack_ok() {
  local arg="$1"
  local part kind val
  IFS=',' read -ra parts <<<"$arg"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | xargs)"
    [[ -z "$part" ]] && continue
    if [[ "$part" == *:* ]]; then
      kind="${part%%:*}"
      val="${part#*:}"
    else
      kind="port"
      val="$part"
    fi
    case "$kind" in
      port|listen) port_listening "$val" || return 1 ;;
      tcp) tcp_local "$val" || return 1 ;;
      ping) ping_ok "$val" || return 1 ;;
      iface) iface_up "$val" || return 1 ;;
      *) port_listening "$part" || return 1 ;;
    esac
  done
  return 0
}

run_health() {
  local unit="$1" kind="$2" arg="$3"
  case "$kind" in
    active|"") return 0 ;;
    port|listen) port_listening "$arg" ;;
    tcp) tcp_local "$arg" ;;
    ping) ping_ok "$arg" ;;
    iface) iface_up "$arg" ;;
    backhaul|backhaul_mapped|backhaul_full) backhaul_mapped_ok "$arg" ;;
    backhaul_journal) backhaul_journal_ok "$unit" ;;
    backpack) backpack_ok "$arg" ;;
    remote_estab|client_estab) remote_estab_ok "$arg" ;;
    control_channel|control_alive) control_channel_ok "$unit" "$arg" ;;
    *) return 1 ;;
  esac
}

# Live evaluate: sets HEALTH_STATUS + HEALTH_REASON; returns 0 if OK
evaluate_tunnel() {
  local name="$1" unit="$2" kind="$3" arg="$4"
  local cnt detail

  HEALTH_STATUS="FAIL"
  HEALTH_REASON=""

  if [[ -z "$unit" ]]; then
    HEALTH_REASON="unit is empty"
    return 1
  fi

  if ! systemctl cat "$unit" &>/dev/null; then
    HEALTH_REASON="systemd unit not found"
    return 1
  fi

  if ! service_active "$unit"; then
    HEALTH_REASON="systemd inactive ($(systemctl is-active "$unit" 2>/dev/null || echo unknown))"
    return 1
  fi

  case "$kind" in
    control_channel|control_alive)
      detail="$(control_channel_detail "$unit" "$arg")"
      if control_channel_ok "$unit" "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="$detail"
        return 0
      fi
      HEALTH_REASON="control channel dead ($detail)"
      return 1
      ;;
    remote_estab|client_estab)
      # Prefer MainPID+min when arg is port:min; else legacy proc:port[:min]
      if [[ "$arg" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        parse_port_min "$arg"
        cnt="$(unit_estab_count "$unit" "$_cc_port")"
        if [[ "${cnt:-0}" -ge "$_cc_min" ]]; then
          HEALTH_STATUS="OK"
          HEALTH_REASON="ESTAB=${cnt}/${_cc_min} to :${_cc_port} (MainPID)"
          return 0
        fi
        HEALTH_REASON="ESTAB=${cnt}/${_cc_min} to :${_cc_port} (too few; zombies ignored)"
        return 1
      fi
      cnt="$(remote_estab_count "$arg" 2>/dev/null || echo 0)"
      if remote_estab_ok "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="ESTAB=${cnt} to :${arg#*:} via ${arg%%:*}"
        return 0
      fi
      HEALTH_REASON="no ESTAB to remote port (arg=${arg}, count=${cnt})"
      return 1
      ;;
    tcp)
      if tcp_local "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="TCP connect to ${arg} ok"
        return 0
      fi
      HEALTH_REASON="TCP connect to ${arg} failed"
      return 1
      ;;
    port|listen)
      if port_listening "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="port ${arg} is listening"
        return 0
      fi
      HEALTH_REASON="port ${arg} not listening"
      return 1
      ;;
    ping)
      if ping_ok "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="ping ${arg} ok"
        return 0
      fi
      HEALTH_REASON="ping ${arg} failed"
      return 1
      ;;
    iface)
      if iface_up "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="iface ${arg} is up"
        return 0
      fi
      HEALTH_REASON="iface ${arg} down/missing"
      return 1
      ;;
    active|"")
      HEALTH_STATUS="OK"
      HEALTH_REASON="systemd active only"
      return 0
      ;;
    *)
      if run_health "$unit" "$kind" "$arg"; then
        HEALTH_STATUS="OK"
        HEALTH_REASON="check ${kind} ok (arg=${arg})"
        return 0
      fi
      HEALTH_REASON="check ${kind} failed (arg=${arg})"
      return 1
      ;;
  esac
}

# Rewrite TUNNELS block in conf; keeps FAIL_THRESHOLD etc.
# Args: lines passed via stdin (one entry per line)
tw_write_tunnels_from_stdin() {
  local tmp header
  tmp="$(mktemp)"
  header="$(mktemp)"

  # keep everything before TUNNELS=
  awk '
    BEGIN { keep=1 }
    /^TUNNELS=/ { keep=0 }
    keep { print }
  ' "$CONF" > "$header"

  {
    cat "$header"
    echo
    echo 'TUNNELS="'
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "$line"
    done
    echo '"'
  } > "$tmp"

  install -m 0644 "$tmp" "$CONF"
  rm -f "$tmp" "$header"
}

tw_backup_conf() {
  cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}
