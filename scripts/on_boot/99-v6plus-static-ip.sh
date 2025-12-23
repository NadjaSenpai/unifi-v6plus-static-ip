#!/bin/sh
# 99-v6plus-static-ip.sh
#
# Wrapper for udm-boot / on-boot-script-2.x:
# - waits until WAN has a global IPv6 address
# - then runs the static-ip script "apply"
#
# Expected on the gateway:
#   /data/v6plus.env
#   /data/v6plus-static-ip-iif.sh
#
# Optional overrides:
#   BASE=/data/v6plus-static-ip-iif.sh
#   ENV_FILE=/data/v6plus.env
#   WAN_IF=eth4

set -eu

BASE="${BASE:-/data/v6plus-static-ip-iif.sh}"
ENV_FILE="${ENV_FILE:-/data/v6plus.env}"
WAN_IF="${WAN_IF:-eth4}"

log(){ echo "[onboot-v6plus] $*"; }

# Wait up to 120s for WAN global IPv6 to appear.
i=0
while [ $i -lt 120 ]; do
  if ip link show "$WAN_IF" >/dev/null 2>&1 \
     && ip -6 addr show dev "$WAN_IF" scope global | grep -q "inet6"; then
    break
  fi
  i=$((i+1))
  sleep 1
done

if [ $i -ge 120 ]; then
  log "WAN IPv6 not ready after 120s; skip apply."
  exit 0
fi

log "Applying v6plus static IP config..."
exec env ENV_FILE="$ENV_FILE" sh "$BASE" apply
