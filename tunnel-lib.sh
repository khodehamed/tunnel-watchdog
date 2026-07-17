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
  FAIL_THRESHOLD="${FAIL_THRESHOLD:-5}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-300}"
  GRACE_SEC="${GRACE_SEC:-300}"
  JOURNAL_LOOKBACK="${JOURNAL_LOOKBACK:-10min}"
  CONTROL_JOURNAL_SINCE="${CONTROL_JOURNAL_SINCE:-5 min ago}"
  CONTROL_ESTAB_MIN="${CONTROL_ESTAB_MIN:-4}"
  CONTROL_FRESH_MS="${CONTROL_FRESH_MS:-120000}"
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

# Parse port[:healthy_min]
# Default healthy_min=4 — 1–2 leftover CF sockets must NOT count as healthy.
parse_port_min() {
  local arg="$1"
  _cc_port="${arg%%:*}"
  if [[ "$arg" == *:* ]]; then
    _cc_min="${arg#*:}"
  else
    _cc_min="${CONTROL_ESTAB_MIN:-4}"
  fi
  [[ -n "$_cc_min" ]] || _cc_min="${CONTROL_ESTAB_MIN:-4}"
}

_cc_journal_since() {
  echo "${CONTROL_JOURNAL_SINCE:-5 min ago}"
}

_cc_relevant_last() {
  local unit="$1"
  journalctl -u "$unit" --since "$(_cc_journal_since)" --no-pager -o cat 2>/dev/null \
    | grep -iE 'control channel established successfully|failed to read from channel|bad handshake|connection reset by peer|attempting to establish a new .+ control channel' \
    | tail -1 || true
}

_cc_is_success() {
  echo "$1" | grep -qi 'control channel established successfully'
}

_cc_is_failure() {
  echo "$1" | grep -qiE 'failed to read from channel|bad handshake|connection reset by peer'
}

# ExecStart -c path for a unit (toml/config), if any
unit_config_path() {
  local unit="$1"
  systemctl show "$unit" -p ExecStart --value 2>/dev/null \
    | grep -oE '\-c[[:space:]]+[^[:space:]]+' | awk '{print $2}' | head -1 || true
}

# tun_name from backhaul/backpack toml (empty if unset / not tun mode)
unit_tun_name() {
  local unit="$1" conf
  conf="$(unit_config_path "$unit")"
  [[ -n "$conf" && -f "$conf" ]] || { echo ""; return 0; }
  grep -E '^\s*tun_name\s*=' "$conf" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^=]+=[[:space:]]*"?([^"#]+)"?.*/\1/' \
    | xargs || true
}

tun_iface_up() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  [[ -d "/sys/class/net/$iface" ]] || return 1
  local st
  st="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo down)"
  [[ "$st" == "up" || "$st" == "unknown" ]]
}

# Count ESTAB sockets to port whose lastrcv is fresher than FRESH_MS (default 120s).
# All-stale pools (zombie CF) must not count as healthy.
unit_fresh_estab_count() {
  local unit="$1" port="$2"
  local pid fresh_ms
  fresh_ms="${CONTROL_FRESH_MS:-120000}"
  pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
  if [[ -z "$pid" || "$pid" == "0" ]]; then
    echo "0"
    return 1
  fi
  ss -tiepm state established 2>/dev/null | awk -v pid="$pid" -v port="$port" -v fresh="$fresh_ms" '
    BEGIN { n=0; keep=0 }
    {
      if ($0 ~ ("pid=" pid ",") && $0 ~ (":" port)) { keep=1; next }
      if (keep) {
        if (match($0, /lastrcv:[0-9]+/)) {
          split(substr($0, RSTART, RLENGTH), a, ":")
          if (a[2]+0 <= fresh+0) n++
        }
        # end this socket block on next non-indented header-ish line or after info
        if ($0 ~ /^[0-9]/ || $0 ~ /^ESTAB/ || $0 ~ /^tcp/) keep=0
        else if (match($0, /lastrcv:[0-9]+/)) keep=0
      }
    }
    END { print n+0 }
  '
}

# Seconds since unit entered active state (huge number if unknown)
unit_active_age_sec() {
  local unit="$1" ts now
  ts="$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null || true)"
  if [[ -z "$ts" || "$ts" == "n/a" ]]; then
    echo 999999
    return
  fi
  now="$(date +%s)"
  # systemd timestamp like "Fri 2026-07-17 04:53:57 UTC"
  local epoch
  epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  if [[ "$epoch" -le 0 ]]; then
    echo 999999
    return
  fi
  echo $((now - epoch))
}

# Client liveness (Backhaul/Backpack):
#  1) If toml has tun_name → that iface MUST exist/up (zombie CF ESTAB is not enough)
#  2) Recent journal "control channel established" → OK (warmup / reconnect)
#  3) Else need ESTAB >= healthy_min (default 4) AND at least one fresh socket
#     (lastrcv within CONTROL_FRESH_MS). Pure stale ESTAB pool → FAIL.
# Never FAIL solely on a transient bad-handshake while fresh sockets + tun (if any) are OK.
control_channel_ok() {
  local unit="$1" arg="$2"
  local cnt fresh last tun
  parse_port_min "$arg"
  cnt="$(unit_estab_count "$unit" "$_cc_port")"
  fresh="$(unit_fresh_estab_count "$unit" "$_cc_port")"
  last="$(_cc_relevant_last "$unit")"
  tun="$(unit_tun_name "$unit")"

  # TUN mode: missing/down iface means tunnel is dead even with many CF ESTAB.
  if [[ -n "$tun" ]]; then
    if ! tun_iface_up "$tun"; then
      return 1
    fi
  fi

  # Last journal line in window is an unrecovered failure → dead
  if [[ -n "$last" ]] && _cc_is_failure "$last"; then
    return 1
  fi

  if [[ -n "$last" ]] && _cc_is_success "$last"; then
    return 0
  fi

  # Healthy pool: enough ESTAB and at least one recently active socket
  if [[ "${cnt:-0}" -ge "$_cc_min" && "${fresh:-0}" -ge 1 ]]; then
    return 0
  fi

  return 1
}

control_channel_detail() {
  local unit="$1" arg="$2"
  local cnt fresh last age tun tun_st
  parse_port_min "$arg"
  cnt="$(unit_estab_count "$unit" "$_cc_port")"
  fresh="$(unit_fresh_estab_count "$unit" "$_cc_port")"
  last="$(_cc_relevant_last "$unit")"
  age="$(unit_active_age_sec "$unit")"
  tun="$(unit_tun_name "$unit")"
  tun_st="n/a"
  if [[ -n "$tun" ]]; then
    if tun_iface_up "$tun"; then
      tun_st="up:${tun}"
    else
      tun_st="MISSING:${tun}"
    fi
  fi
  last="$(echo "$last" | sed -E 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | cut -c1-70)"
  echo "ESTAB=${cnt} fresh=${fresh} need>=${_cc_min} port=:${_cc_port} tun=${tun_st} age=${age}s; journal=${last:-none}"
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

# Ensure a minimal conf exists (for discover on fresh hosts)
tw_ensure_conf() {
  [[ -f "$CONF" ]] && return 0
  {
    echo "# Tunnel Watchdog — created by tunnel-menu discover"
    echo "FAIL_THRESHOLD=5"
    echo "COOLDOWN_SEC=300"
    echo "GRACE_SEC=300"
    echo "JOURNAL_LOOKBACK=15min"
    echo 'CONTROL_JOURNAL_SINCE="5 min ago"'
    echo
    echo 'TUNNELS="'
    echo '"'
  } >"$CONF"
  chmod 0644 "$CONF"
}

# Derive one conf line for a systemd unit, or empty if skipped/unsupported.
# Prints: name|unit|kind|arg
tw_guess_entry_for_unit() {
  local u="$1"
  local name conf port
  [[ -z "$u" ]] && return 1
  [[ "$u" == *.service ]] || u="${u}.service"
  name="${u%.service}"

  # skip junk
  echo "$u" | grep -qiE 'watchdog|webui' && return 1
  echo "$u" | grep -qiE 'backhaul|backpack' || return 1

  if ! systemctl cat "$u" &>/dev/null; then
    return 1
  fi

  conf="$(systemctl show "$u" -p ExecStart --value 2>/dev/null \
    | grep -oE '\-c[[:space:]]+[^[:space:]]+' | awk '{print $2}' || true)"
  port=""
  if [[ -n "$conf" && -f "$conf" ]]; then
    port="$(grep -E '^\s*remote_addr\s*=' "$conf" 2>/dev/null | head -1 | grep -oE '[0-9]+' | tail -1 || true)"
    if [[ -z "$port" ]]; then
      port="$(grep -E '^\s*bind_addr\s*=' "$conf" 2>/dev/null | head -1 | grep -oE '[0-9]+' | tail -1 || true)"
    fi
  fi

  if [[ -n "$port" ]]; then
    echo "${name}|${u}|control_channel|${port}:4"
  else
    echo "${name}|${u}|active|"
  fi
}

# Scan /etc/systemd/system for backhaul/backpack tunnel units.
# Prints candidate lines: name|unit|kind|arg
tw_discover_candidates() {
  local u entry
  ls -1 /etc/systemd/system/*.service 2>/dev/null \
    | xargs -n1 basename \
    | grep -iE 'backhaul|backpack' \
    | grep -viE 'watchdog|webui' \
    | sort -u \
    | while read -r u; do
        entry="$(tw_guess_entry_for_unit "$u" || true)"
        [[ -n "$entry" ]] && echo "$entry"
      done
}

# True if unit already present in TUNNELS
tw_unit_configured() {
  local want="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    tw_parse_entry "$entry"
    [[ "$_unit" == "$want" ]] && return 0
  done < <(tw_list_entries 2>/dev/null || true)
  return 1
}
