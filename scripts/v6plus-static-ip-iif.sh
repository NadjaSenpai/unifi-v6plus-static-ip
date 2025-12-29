#!/bin/sh
# =========================
# v6plus-static-ip-iif.sh
# =========================
#
# UniFi OS gateways (UDM / UDR):
# - v6plus static IPv4 (/32) delivered via IPv4-over-IPv6 (IPIP6) tunnel
# - keep native IPv6 working as-is
# - route only forwarded IPv4 traffic coming from LAN into a dedicated routing table (iif-based)
# - add provider-assigned tunnel-local IPv6 to WAN as /128 (not /64)
#
# Usage:
#   ENV_FILE=/data/v6plus.env ./v6plus-static-ip-iif.sh apply
#   ENV_FILE=/data/v6plus.env ./v6plus-static-ip-iif.sh status
#   ENV_FILE=/data/v6plus.env ./v6plus-static-ip-iif.sh off

set -eu

log(){ printf '%s\n' "[v6plus-iif] $*"; }

ENV_FILE="${ENV_FILE:-/data/v6plus.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
else
  log "ENV_FILE not found: $ENV_FILE"
  exit 1
fi

need() { eval "v=\${$1:-}"; [ -n "$v" ] || { log "Missing env: $1"; exit 1; }; }

need WAN_IF
need LAN_IF
need LAN_CIDR
need STATIC_V4
need PROVIDER_ASSIGNED_LOCAL_V6
need BR_V6
need TUN_IF
need TUN_MTU
need MSS
need ROUTE_TABLE
need RULE_PREF

detect_snat_chain() {
  if iptables -t nat -L UBIOS_POSTROUTING_USER_HOOK -n >/dev/null 2>&1; then
    echo "UBIOS_POSTROUTING_USER_HOOK"
  else
    echo "POSTROUTING"
  fi
}

ipt_add() {
  table="$1"; shift
  chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    :
  else
    iptables -t "$table" -I "$chain" 1 "$@"
  fi
}

ipt_del_once() {
  table="$1"; shift
  chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    iptables -t "$table" -D "$chain" "$@"
  else
    :
  fi
}

status() {
  SNAT_CHAIN="$(detect_snat_chain)"

  log "WAN_IF=$WAN_IF LAN_IF=$LAN_IF LAN_CIDR=$LAN_CIDR TUN_IF=$TUN_IF"
  echo

  log "== WAN global IPv6 =="
  ip -6 addr show dev "$WAN_IF" scope global || true
  ip -6 route show default || true
  echo

  log "== Tunnel =="
  ip -d link show "$TUN_IF" 2>/dev/null || echo "(tunnel $TUN_IF not present)"
  ip -4 addr show dev "$TUN_IF" 2>/dev/null || true
  echo

  log "== IPv4 policy routing rules =="
  ip -4 rule show | sed -n '1,200p' || true
  echo

  log "== IPv4 routes in table $ROUTE_TABLE =="
  ip -4 route show table "$ROUTE_TABLE" 2>/dev/null || true
  echo

  log "== Main-table IPv4 default routes =="
  ip -4 route show default || true
  echo

  log "== NAT ($SNAT_CHAIN) (top entries) =="
  iptables -t nat -L "$SNAT_CHAIN" -n -v --line-numbers | sed -n '1,120p' || true
  echo

  log "== MSS clamp (mangle/FORWARD + OUTPUT) =="
  iptables -t mangle -L FORWARD -n -v --line-numbers | sed -n '1,80p' || true
  iptables -t mangle -L OUTPUT  -n -v --line-numbers | sed -n '1,80p' || true
  echo
}

apply() {
  log "Applying..."

  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.conf.${LAN_IF}.rp_filter=2" >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.conf.${WAN_IF}.rp_filter=2" >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.conf.${TUN_IF}.rp_filter=2" >/dev/null 2>&1 || true

  # Add provider-assigned tunnel-local IPv6 to WAN as /128 (remove accidental /64)
  ip -6 addr del "${PROVIDER_ASSIGNED_LOCAL_V6}/64"  dev "$WAN_IF" 2>/dev/null || true
  ip -6 addr del "${PROVIDER_ASSIGNED_LOCAL_V6}/128" dev "$WAN_IF" 2>/dev/null || true
  ip -6 addr add "${PROVIDER_ASSIGNED_LOCAL_V6}/128" dev "$WAN_IF"

  # Recreate tunnel (IPIP6)
  ip -6 tunnel del "$TUN_IF" 2>/dev/null || true
  ip -6 tunnel add "$TUN_IF" mode ipip6 local "$PROVIDER_ASSIGNED_LOCAL_V6" remote "$BR_V6"
  ip link set "$TUN_IF" mtu "$TUN_MTU" up

  # Assign static IPv4 (/32) to tunnel IF
  ip addr add "${STATIC_V4}/32" dev "$TUN_IF" 2>/dev/null || true

  # Policy routing (iif-based) for forwarded LAN traffic only
  ip -4 rule del pref "$RULE_PREF" 2>/dev/null || true
  ip -4 route replace "$LAN_CIDR" dev "$LAN_IF" table "$ROUTE_TABLE"
  ip -4 route replace default dev "$TUN_IF" table "$ROUTE_TABLE"
  ip -4 rule add pref "$RULE_PREF" iif "$LAN_IF" lookup "$ROUTE_TABLE"

  # SNAT: LAN -> tunnel egress as static IPv4
  SNAT_CHAIN="$(detect_snat_chain)"
  ipt_del_once nat "$SNAT_CHAIN" -o "$TUN_IF" -s "$LAN_CIDR" -j SNAT --to-source "$STATIC_V4"
  ipt_add     nat "$SNAT_CHAIN" -o "$TUN_IF" -s "$LAN_CIDR" -j SNAT --to-source "$STATIC_V4"

  # MSS clamp (forwarded + gateway-originated)
  ipt_del_once mangle FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  ipt_add      mangle FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  ipt_del_once mangle OUTPUT  -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  ipt_add      mangle OUTPUT  -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

  log "Applied."
  status
}

off() {
  log "Turning OFF..."

  ip -4 rule del pref "$RULE_PREF" 2>/dev/null || true
  ip -4 route del default table "$ROUTE_TABLE" 2>/dev/null || true
  ip -4 route del "$LAN_CIDR" table "$ROUTE_TABLE" 2>/dev/null || true

  # Remove SNAT/MSS
  SNAT_CHAIN="$(detect_snat_chain)"
  ipt_del_once nat "$SNAT_CHAIN" -o "$TUN_IF" -s "$LAN_CIDR" -j SNAT --to-source "$STATIC_V4"
  ipt_del_once mangle FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
  ipt_del_once mangle OUTPUT  -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

  ip -6 tunnel del "$TUN_IF" 2>/dev/null || true
  ip -6 addr del "${PROVIDER_ASSIGNED_LOCAL_V6}/128" dev "$WAN_IF" 2>/dev/null || true

  log "OFF done."
  status
}

CMD="${1:-apply}"
case "$CMD" in
  apply)  apply ;;
  off)    off ;;
  status) status ;;
  *) echo "Usage: $0 {apply|off|status}" >&2; exit 2 ;;
esac
