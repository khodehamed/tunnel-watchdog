# tunnel-watchdog

Watchdog + English menu for **Backhaul / Backpack** (and similar) systemd tunnels.

Checks real tunnel liveness (`control_channel`: ESTAB pool + recent journal), not just `systemctl is-active`. Restarts unhealthy units via a systemd timer.

## Install (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/tunnel-watchdog/main/install.sh | sudo bash
```

## After install

```bash
tunnel-menu              # add / remove / restart / discover tunnels
tunnel-menu status       # live OK/FAIL
tunnel-menu discover     # scan server & auto-add missing tunnels
tunnel-menu discover --dry-run
```

In the menu: **8) Discover tunnels on this server** — lists units already configured vs new, then add all or pick one-by-one (existing TUNNELS kept).

Config: `/etc/tunnel-watchdog.conf`  
Timer: `systemctl list-timers tunnel-watchdog.timer`

## License

MIT
