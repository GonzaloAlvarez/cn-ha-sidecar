#!/usr/bin/env bash
# disk-maintenance.sh — keep homeiot's 14 GB root filesystem under the
# HomeIoTDiskSpaceLow threshold (80%, cn-root-docker tailnet/prometheus/alerts.yml).
#
# What grows unbounded on this host and why:
#   - /var/cache/apt (1.2 GB when this was written): 10periodic sets
#     APT::Periodic::Download-Upgradeable-Packages "1", which pre-downloads
#     every upgradable package daily — but unattended-upgrades only installs
#     the security subset, so the rest sit in the cache forever. `apt-get
#     autoclean` never removes them (they are still current in the index),
#     and a plain clean refills within a day while pre-downloading is on.
#     --install drops an apt override turning pre-downloading off;
#     unattended-upgrades still downloads whatever it actually installs.
#   - /var/log/journal: journald.conf caps retention (MaxRetentionSec=14day)
#     but not size.
#   - dangling docker images: only produced by manual update.sh runs (which
#     already prune) and Supervisor churn; pruned here as belt-and-braces.
#     Dangling-only prune never touches tagged Supervisor/add-on images.
#
# Usage:
#   sudo ./scripts/disk-maintenance.sh            # one maintenance pass
#   sudo ./scripts/disk-maintenance.sh --install  # install apt override +
#                                                 # weekly cron, then run a pass
#
# Files written by --install:
#   /etc/apt/apt.conf.d/99cn-ha-sidecar-no-predownload
#   /etc/cron.d/cn-ha-sidecar-disk-maintenance   (Sundays 04:15)
#
# Output goes to syslog (tag: disk-maintenance) → journald → promtail → Loki.

set -euo pipefail

TAG="disk-maintenance"
JOURNAL_MAX="200M"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

log() { logger -t "$TAG" -- "$*"; echo "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (sudo $0)" >&2
  exit 1
fi

if [ "${1:-}" = "--install" ]; then
  cat > /etc/apt/apt.conf.d/99cn-ha-sidecar-no-predownload <<'EOF'
// Installed by cn-ha-sidecar/scripts/disk-maintenance.sh --install.
// Overrides 10periodic: do NOT pre-download every upgradable package daily.
// unattended-upgrades still downloads the packages it actually installs.
APT::Periodic::Download-Upgradeable-Packages "0";
EOF
  chmod 644 /etc/apt/apt.conf.d/99cn-ha-sidecar-no-predownload

  cat > /etc/cron.d/cn-ha-sidecar-disk-maintenance <<EOF
# Installed by cn-ha-sidecar/scripts/disk-maintenance.sh --install.
# Weekly disk maintenance; output lands in syslog (tag: disk-maintenance).
15 4 * * 0 root ${SCRIPT_PATH} >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/cn-ha-sidecar-disk-maintenance

  log "installed apt no-predownload override + weekly cron (Sun 04:15)"
fi

used_before="$(df --output=pcent / | tail -1 | tr -dc '0-9')"

apt-get clean || log "WARNING: apt-get clean failed"
journalctl --vacuum-size="$JOURNAL_MAX" >/dev/null || log "WARNING: journal vacuum failed"
docker image prune -f >/dev/null || log "WARNING: docker image prune failed"

used_after="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
log "maintenance pass done: / ${used_before}% -> ${used_after}%"
