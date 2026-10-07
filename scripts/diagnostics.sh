#!/usr/bin/env bash
# =============================================================================
# wg-relay — diagnostics.sh   (installed as: wg-relay-diagnostics)
#
# Prints a troubleshooting dump. It contains NO private or preshared keys
# ("wg show" hides them, and config files are filtered), but it does contain
# public IP addresses and the peer's public endpoint.
#
#   sudo wg-relay-diagnostics > wg-relay-diag.txt
# =============================================================================
set -Eeuo pipefail

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
# shellcheck source=../lib/common.sh
. "$(dirname -- "$SELF")/../lib/common.sh"

require_root

CONFIG_OK=0
if [[ -f $WGR_CONFIG ]]; then
  load_config "$WGR_CONFIG"
  CONFIG_OK=1
else
  WG_INTERFACE=wg0
fi
WG=$WG_INTERFACE

header() { printf '\n==================== %s ====================\n' "$*"; }

# Run a command, show it, never abort the dump on failure.
run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || printf '(exit status %d)\n' "$?"
}

# Defensive: strip anything key-like from a file before printing it.
redact() {
  sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 (redacted)/I' "$1"
}

header "wg-relay diagnostics v$WGR_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
run hostname
run uname -a
printf '\nOS: %s\n' "$(os_pretty_name)"
run systemd-detect-virt
run uptime

header "Configuration ($WGR_CONFIG)"
if (( CONFIG_OK )); then
  grep -vE '^[[:space:]]*(#|$)' "$WGR_CONFIG" || true
  printf '\n-- validation --\n'
  if validate_config_static 2>&1; then printf 'config valid\n'; else printf 'config has %d error(s)\n' "$CFG_ERRORS"; fi
else
  printf 'not installed: %s missing\n' "$WGR_CONFIG"
fi

header "Detection"
printf 'WAN interface (auto-detect): %s\n' "$(detect_wan_interface 2>/dev/null || echo '<none>')"
printf 'SSH ports (auto-detect):     %s\n' "$(detect_ssh_ports 2>/dev/null || echo '<none>')"
printf 'Current SSH session port:    %s\n' "$(current_session_ssh_port 2>/dev/null || echo '<unknown>')"

header "Interfaces and addresses"
run ip -br link
run ip -br addr
run ip -d link show dev "$WG"

header "Routing"
run ip -4 rule show
run ip -4 route show table all
run ip -6 route show
run ip -4 route get 1.1.1.1

header "WireGuard"
run wg show "$WG"
printf '\n-- /etc/wireguard/%s.conf (keys redacted) --\n' "$WG"
if [[ -f /etc/wireguard/$WG.conf ]]; then redact "/etc/wireguard/$WG.conf"; else printf '(missing)\n'; fi
printf '\n-- key files (metadata only) --\n'
psk_list=()
if psk_enabled; then psk_list=("$WG_PRESHARED_KEY_FILE"); fi
for f in "${WG_PRIVATE_KEY_FILE:-/etc/wireguard/private.key}" "${psk_list[@]}"; do
  if [[ -e $f ]]; then stat -c '%n  mode=%a owner=%U:%G size=%s' "$f"; else printf '%s  (missing)\n' "$f"; fi
done
if [[ -f ${WG_PRIVATE_KEY_FILE:-} ]]; then
  printf 'public key derived from key file: %s\n' "$(wg pubkey <"$WG_PRIVATE_KEY_FILE" 2>/dev/null || echo '<invalid>')"
fi

header "Kernel settings"
run sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
           net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  printf 'nf_conntrack: %s / %s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_count)" "$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
fi
run lsmod
printf '\n-- %s --\n' "$WGR_SYSCTL"
cat "$WGR_SYSCTL" 2>/dev/null || printf '(missing)\n'

header "Firewall"
run nft list tables
run nft list table inet wg_relay
printf '\n-- full ruleset (includes tables owned by other software) --\n'
run nft list ruleset
if command -v iptables-legacy-save >/dev/null 2>&1; then
  run iptables-legacy-save
fi
if [[ -f /etc/ufw/ufw.conf ]]; then grep -H '^ENABLED' /etc/ufw/ufw.conf || true; fi

header "Services"
run systemctl --no-pager status "wg-quick@$WG.service"
run systemctl --no-pager status "$WGR_UNIT_NAME"
run systemctl --no-pager status nftables.service
run systemctl --no-pager list-timers "$WGR_ROLLBACK_UNIT.timer"

header "Listening sockets"
run ss -Hltnp
run ss -Hlunp

header "Connectivity tests"
if command -v ping >/dev/null 2>&1; then
  run ping -4 -c 3 -W 2 1.1.1.1
  if [[ -n ${WG_PEER_ADDRESS:-} ]]; then
    run ping -4 -c 3 -W 2 "${WG_PEER_ADDRESS%/*}"
  fi
else
  printf 'ping not installed (apt-get install iputils-ping)\n'
fi

header "Recent logs"
run journalctl --no-pager -n 60 -u "wg-quick@$WG.service" -u "$WGR_UNIT_NAME" -u "$WGR_ROLLBACK_UNIT.service"
run journalctl --no-pager -k -n 40 --grep 'wireguard|nf_conntrack|nft'

printf '\n==================== end of diagnostics ====================\n'
