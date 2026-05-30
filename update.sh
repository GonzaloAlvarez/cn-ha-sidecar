#!/usr/bin/env bash
# update.sh — pull newer images for cn-ha-sidecar services and apply them.
#
# Replaces the watchtower service that was removed in 5ea1541 because it
# interferes with HA Supervisor's update orchestration (containrrr/watchtower
# is on Supervisor's UNHEALTHY_IMAGES list, which blocks ha core update).
#
# Run this on homeiot.lan whenever you want the sidecar containers refreshed.

set -euo pipefail

PROJECT=cn-ha-sidecar
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> pulling images"
docker compose -p "$PROJECT" pull

echo
echo "==> applying changes (recreate only what's stale)"
docker compose -p "$PROJECT" up -d --remove-orphans

echo
echo "==> pruning dangling images"
docker image prune -f

echo
echo "==> final state"
docker compose -p "$PROJECT" ps --format "table {{.Name}}\t{{.State}}\t{{.Status}}"
