#!/bin/sh
. /data/v6plus.env

log() { logger -t v6plus-watch "$*"; }

fix_snat() {
  if ! iptables -t nat -L UBIOS_POSTROUTING_USER_HOOK -n 2>/dev/null | grep -q "$STATIC_V4"; then
    if ! iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "$STATIC_V4"; then
      log "SNAT rule missing, reapplying..."
      sleep 2
      ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
      log "Reapply done."
    fi
  fi
}

fix_routing() {
  if ip rule show | grep -q "lookup 201"; then
    log "Removing conflicting UniFi rules..."
    ip rule del pref 32766 2>/dev/null || true
    ip rule del pref 32502 2>/dev/null || true
    ip rule del pref 32501 2>/dev/null || true
    ip link del ip6tnl1 2>/dev/null || true
    log "Conflicting rules removed."
  fi
}

fix_dpinger() {
  if pgrep -f "dpinger.*-I $TUN_IF" >/dev/null 2>&1; then
    return 0
  fi
  DPINGER_PID=$(pgrep -f "dpinger.*-B 192.0.0.2\|dpinger.*-I ip6tnl1\|dpinger.*-I eth4") 2>/dev/null || true
  if [ -n "$DPINGER_PID" ]; then
    SOCK=$(cat /proc/$DPINGER_PID/cmdline | tr '\0' '\n' | grep -A1 "^-u$" | tail -1)
    ID=$(cat /proc/$DPINGER_PID/cmdline | tr '\0' '\n' | grep -A1 "^-i$" | tail -1)
    log "dpinger using wrong interface, hijacking..."
    kill "$DPINGER_PID" 2>/dev/null || true
    sleep 1
    dpinger -f \
      -i "$ID" \
      -B "$STATIC_V4" \
      -I "$TUN_IF" \
      -m 0x00000000 \
      -s 10s -d 1 -t 30s \
      -u "$SOCK" \
      1.1.1.1 > /dev/null 2>&1 &
    log "dpinger hijacked: id=$ID sock=$SOCK"
  fi
}

while true; do
  fix_routing
  fix_snat
  fix_dpinger
  sleep 5
done
