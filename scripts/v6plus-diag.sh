#!/bin/sh
. /data/v6plus.env

echo "=== Tunnel Interface ==="
ip -d link show "$TUN_IF" 2>/dev/null && echo "present" || echo "missing"

echo ""
echo "=== IPv4 address (tunnel) ==="
ip -4 addr show "$TUN_IF" 2>/dev/null | grep "$STATIC_V4" && echo "present" || echo "missing"

echo ""
echo "=== IP rule ==="
ip -4 rule | grep "$ROUTE_TABLE" && echo "present" || echo "missing"

echo ""
echo "=== Routing table $ROUTE_TABLE ==="
ip -4 route show table "$ROUTE_TABLE" 2>/dev/null || echo "missing"

echo ""
echo "=== SNAT (iptables) ==="
if iptables -t nat -L UBIOS_POSTROUTING_USER_HOOK -n 2>/dev/null | grep -q "$STATIC_V4"; then
  iptables -t nat -L UBIOS_POSTROUTING_USER_HOOK -n -v | grep "$STATIC_V4"
  echo "present (UBIOS_POSTROUTING_USER_HOOK)"
elif iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "$STATIC_V4"; then
  iptables -t nat -L POSTROUTING -n -v | grep "$STATIC_V4"
  echo "present (POSTROUTING)"
else
  echo "missing"
fi

echo ""
echo "=== MSS clamp ==="
iptables -t mangle -L FORWARD -n -v | grep "TCPMSS" && echo "present" || echo "missing"

echo ""
echo "=== Outbound IP check ==="
curl -4 -s --max-time 5 --interface "$TUN_IF" https://api.ipify.org && echo "" || echo "no response"
