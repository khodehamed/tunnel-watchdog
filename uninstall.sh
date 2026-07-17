#!/usr/bin/env bash
# Completely remove tunnel-watchdog (idempotent).
# Does NOT touch backhaul/backpack (or any other) tunnel services.
#
#   curl -fsSL https://raw.githubusercontent.com/khodehamed/tunnel-watchdog/main/uninstall.sh -o /tmp/tw-uninstall.sh && sudo bash /tmp/tw-uninstall.sh
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root: curl -fsSL ... -o /tmp/tw-uninstall.sh && sudo bash /tmp/tw-uninstall.sh"
  exit 1
fi

echo "==> Stopping and disabling tunnel-watchdog"
systemctl stop tunnel-watchdog.timer tunnel-watchdog.service 2>/dev/null || true
systemctl disable tunnel-watchdog.timer tunnel-watchdog.service 2>/dev/null || true

echo "==> Removing systemd units"
rm -f /etc/systemd/system/tunnel-watchdog.service \
      /etc/systemd/system/tunnel-watchdog.timer \
      /etc/systemd/system/multi-user.target.wants/tunnel-watchdog.timer \
      /etc/systemd/system/timers.target.wants/tunnel-watchdog.timer \
      2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed tunnel-watchdog.service tunnel-watchdog.timer 2>/dev/null || true

echo "==> Removing binaries and library"
rm -f /usr/local/bin/tunnel-menu \
      /usr/local/bin/tunnel-watchdog.sh \
      /usr/local/bin/tunnel-watchdog \
      2>/dev/null || true
rm -rf /usr/local/lib/tunnel-watchdog 2>/dev/null || true

echo "==> Removing config and state"
rm -f /etc/tunnel-watchdog.conf 2>/dev/null || true
# backups from install upgrades
shopt -s nullglob 2>/dev/null || true
rm -f /etc/tunnel-watchdog.conf.bak.* 2>/dev/null || true
rm -rf /run/tunnel-watchdog /var/lib/tunnel-watchdog /var/run/tunnel-watchdog 2>/dev/null || true

echo
echo "Done. tunnel-watchdog fully removed."
echo "Backhaul/backpack tunnel units were NOT touched."
echo "Verify: systemctl list-timers | grep tunnel-watchdog || echo 'no watchdog timer'"
