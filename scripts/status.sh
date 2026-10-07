#!/usr/bin/env bash
# =============================================================================
# wg-relay — status.sh   (installed as: wg-relay-status)
# One-screen health summary. Read-only; never prints private keys.
# =============================================================================
set -Eeuo pipefail

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
# shellcheck source=../lib/common.sh
. "$(dirname -- "$SELF")/../lib/common.sh"

require_root
[[ -f $WGR_CONFIG ]] || die "wg-relay is not installed ($WGR_CONFIG missing); run install.sh first"
load_config "$WGR_CONFIG"
validate_config_static >/dev/null 2>&1 || true   # only to derive normalized values

section() { printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_RST"; }

ago() {
  local s=$1
  if   (( s < 60 ));    then printf '%ds ago' "$s"
  elif (( s < 3600 ));  then printf '%dm %ds ago' $((s / 60)) $((s % 60))
  elif (( s < 86400 )); then printf '%dh %dm ago' $((s / 3600)) $((s % 3600 / 60))
  else                       printf '%dd %dh ago' $((s / 86400)) $((s % 86400 / 3600))
  fi
}

human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"; }

unit_state() {
  printf '%s / %s' "$(systemctl is-active "$1" 2>/dev/null || true)" "$(systemctl is-enabled "$1" 2>/dev/null || true)"
}

nft_counter() {
  nft -j list table inet wg_relay 2>/dev/null \
    | jq -r --arg c "$1" '[.nftables[]? | .rule? | select(. != null and .comment == $c)
                           | .expr[] | .counter? | select(. != null) | .packets] | first // empty' 2>/dev/null || true
}

WG=$WG_INTERFACE
if [[ $WAN_INTERFACE == auto ]]; then
  WAN_IF=$(detect_wan_interface || true)
else
  WAN_IF=$WAN_INTERFACE
fi

printf '%swg-relay status%s  (v%s, %s)\n' "$C_BLD" "$C_RST" "$WGR_VERSION" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "Host"
row "OS:" "$(os_pretty_name)"
row "Kernel:" "$(uname -r)"
row "Hostname:" "$(hostname)"
row "Uptime:" "$(uptime -p 2>/dev/null || true)"

section "WAN"
row "Interface:" "${WAN_IF:-<not found>} (config: $WAN_INTERFACE)"
if [[ -n $WAN_IF ]]; then
  row "IPv4 address(es):" "$(wan_ipv4_cidrs "$WAN_IF" | paste -sd ' ' -)"
  row "MTU:" "$(link_mtu "$WAN_IF")"
  row "Public IPv4:" "$(public_ipv4 "$WAN_IF" || echo '<not discoverable>')"
fi

section "WireGuard ($WG)"
row "Service:" "wg-quick@$WG: $(unit_state "wg-quick@$WG.service")"
if ip link show dev "$WG" >/dev/null 2>&1; then
  row "Link:" "$(ip -j link show dev "$WG" | jq -r '.[0] | "\(.operstate) flags=\(.flags | join(",")) mtu=\(.mtu)"')"
  row "Address:" "$(ip -j -4 addr show dev "$WG" | jq -r '[.[0].addr_info[]? | "\(.local)/\(.prefixlen)"] | join(" ")')"
  row "Listen port:" "$(wg show "$WG" listen-port 2>/dev/null || echo '?')/udp"
  row "Server public key:" "$(wg show "$WG" public-key 2>/dev/null || echo '?')"

  declare -A HS=() EP=() RX=() TX=()
  while IFS=$'\t' read -r k v; do [[ -n $k ]] && HS[$k]=$v; done < <(wg show "$WG" latest-handshakes 2>/dev/null || true)
  while IFS=$'\t' read -r k v; do [[ -n $k ]] && EP[$k]=$v; done < <(wg show "$WG" endpoints 2>/dev/null || true)
  while IFS=$'\t' read -r k r t; do [[ -n $k ]] && RX[$k]=$r && TX[$k]=$t; done < <(wg show "$WG" transfer 2>/dev/null || true)

  if (( ${#HS[@]} == 0 )); then
    row "Peer:" "none configured (set WG_PEER_PUBLIC_KEY and re-run install.sh)"
  fi
  now=$(date +%s)
  for k in "${!HS[@]}"; do
    hs=${HS[$k]}
    row "Peer:" "$k"
    row "  endpoint:" "${EP[$k]:-(none)}"
    if [[ $hs =~ ^[0-9]+$ ]] && (( hs > 0 )); then
      age=$(( now - hs ))
      state="up"
      if (( age > 180 )); then state="STALE (no handshake for >3 min)"; fi
      row "  latest handshake:" "$(ago "$age")  [$state]"
    else
      row "  latest handshake:" "never  [DOWN]"
    fi
    row "  transfer:" "rx $(human "${RX[$k]:-0}"), tx $(human "${TX[$k]:-0}")"
  done
else
  row "Link:" "$WG does not exist"
fi

section "Forwarding"
row "IPv4 forwarding:" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?') (config: $ENABLE_IPV4_FORWARDING)"
row "IPv6 forwarding:" "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 'n/a') (config: $ENABLE_IPV6_FORWARDING)"
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  row "Conntrack:" "$(cat /proc/sys/net/netfilter/nf_conntrack_count) / $(cat /proc/sys/net/netfilter/nf_conntrack_max) entries"
fi

section "Firewall"
row "wg-relay-firewall:" "$(unit_state "$WGR_UNIT_NAME")"
row "nftables.service:" "$(unit_state nftables.service) (informational; not used by wg-relay)"
if nft list table inet wg_relay >/dev/null 2>&1; then
  row "Table inet wg_relay:" "loaded"
  row "Dropped (input):" "$(nft_counter input-drop) packets"
  row "Dropped (forward):" "$(nft_counter forward-drop) packets"
else
  row "Table inet wg_relay:" "NOT LOADED (host is unfiltered)"
fi
row "Relay egress:" "$RELAY_EGRESS (masquerade: $MASQUERADE_EGRESS)"
row "Inbound TCP fwd:" "${FWD_TCP_NORM:-none}"
row "Inbound UDP fwd:" "${FWD_UDP_NORM:-none}"

section "Routes (IPv4, main table)"
ip -4 route show | sed 's/^/  /'
printf '\n'
