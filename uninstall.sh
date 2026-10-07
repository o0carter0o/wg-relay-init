#!/usr/bin/env bash
# =============================================================================
# wg-relay — uninstall.sh
#
# Removes everything install.sh created, with no prompts:
#   services, firewall table, configs, keys, helper commands, sysctl settings,
#   the install log, and the packages the installer added
#   (wireguard-tools, nftables, jq).
#
# Your repo copy (including config.env) is left alone.
# THE WIREGUARD KEYS ARE DELETED. A later install generates new ones.
#
#   sudo ./uninstall.sh
# =============================================================================
set -uo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "E: must be run as root (use sudo)" >&2; exit 1; }

# Defaults, overridden by the installed config if it exists.
WG_INTERFACE=wg0
WG_PRIVATE_KEY_FILE=/etc/wireguard/private.key
WG_PRESHARED_KEY_FILE=
CONF=/etc/wg-relay/config.env
if [[ -f $CONF ]]; then
  while IFS='=' read -r k v; do
    v=${v%%[[:space:]]#*}; v=${v//\"/}; v=${v//\'/}; v=${v//[[:space:]]/}
    case $k in
      WG_INTERFACE|WG_PRIVATE_KEY_FILE|WG_PRESHARED_KEY_FILE) [[ -n $v ]] && printf -v "$k" '%s' "$v" ;;
    esac
  done < <(grep -E '^[[:space:]]*(WG_INTERFACE|WG_PRIVATE_KEY_FILE|WG_PRESHARED_KEY_FILE)[[:space:]]*=' "$CONF" | tr -d ' \t')
fi

echo "Removing wg-relay..."

# Services and firewall
systemctl stop wg-relay-rollback.timer wg-relay-rollback.service >/dev/null 2>&1
systemctl disable --now "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1
systemctl disable --now wg-relay-firewall.service >/dev/null 2>&1
nft delete table inet wg_relay >/dev/null 2>&1
ip link delete "$WG_INTERFACE" >/dev/null 2>&1
echo "  stopped WireGuard and removed the firewall table"

# Files
rm -f "/etc/wireguard/$WG_INTERFACE.conf" \
      "$WG_PRIVATE_KEY_FILE" "$WG_PRIVATE_KEY_FILE.tmp" \
      /etc/wireguard/preshared.key /etc/wireguard/preshared.key.tmp
if [[ -n $WG_PRESHARED_KEY_FILE && $WG_PRESHARED_KEY_FILE != none ]]; then
  rm -f "$WG_PRESHARED_KEY_FILE" "$WG_PRESHARED_KEY_FILE.tmp"
fi
rm -f /etc/systemd/system/wg-relay-firewall.service \
      /etc/sysctl.d/99-wg-relay.conf \
      /etc/modules-load.d/wg-relay.conf \
      /usr/local/sbin/wg-relay-status \
      /usr/local/sbin/wg-relay-diagnostics \
      /usr/local/sbin/wg-relay-backup \
      /usr/local/sbin/wg-relay-export \
      /var/log/wg-relay-install.log \
      /run/wg-relay-install.lock
rm -rf /etc/wg-relay /usr/local/lib/wg-relay
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1
echo "  removed configs, keys, helper commands and the install log"

# Kernel settings back to Debian defaults (live; nothing sets them at boot now)
sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1
sysctl -q -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1
echo "  IP forwarding off"

# Packages the installer added
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y -q wireguard-tools nftables jq >/dev/null 2>&1
apt-get autoremove -y -q --purge >/dev/null 2>&1
rmdir /etc/wireguard 2>/dev/null
echo "  removed packages: wireguard-tools nftables jq"

echo "Done. Your repo copy and its config.env were not touched."
