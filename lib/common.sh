# shellcheck shell=bash
# shellcheck disable=SC2034  # constants and derived values are used by the sourcing scripts
# =============================================================================
# wg-relay — lib/common.sh
#
# Shared helpers sourced by install.sh and scripts/*.sh.
# Nothing in this file changes system state; it only defines functions and
# constants.
# =============================================================================

WGR_VERSION="0.9.1"

# ----- Installed locations ---------------------------------------------------
WGR_ETC="/etc/wg-relay"
WGR_CONFIG="$WGR_ETC/config.env"
WGR_NFT="$WGR_ETC/wg-relay.nft"
WGR_UNIT_NAME="wg-relay-firewall.service"
WGR_UNIT="/etc/systemd/system/$WGR_UNIT_NAME"
WGR_SYSCTL="/etc/sysctl.d/99-wg-relay.conf"
WGR_MODULES="/etc/modules-load.d/wg-relay.conf"
WGR_LIB="/usr/local/lib/wg-relay"
WGR_BIN="/usr/local/sbin"
WGR_ROLLBACK_UNIT="wg-relay-rollback"
WGR_PSK_DEFAULT="/etc/wireguard/preshared.key"

# ----- Output ----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_BLD=$'\033[1m';    C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '  %s\n' "$*"; }
warn() { printf 'W: %s\n' "$*" >&2; }
err()  { printf 'E: %s\n' "$*" >&2; }
die()  { printf 'E: %s\n' "$*" >&2; exit 1; }
row()  { printf '  %-20s %s\n' "$1" "$2"; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must be run as root (use sudo)"
}

join_by() {
  local sep=$1 out="" x
  shift
  for x in "$@"; do out+="${out:+$sep}$x"; done
  printf '%s' "$out"
}

os_pretty_name() {
  ( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" ) || printf 'unknown'
}

# =============================================================================
# Configuration
#
# config.env is PARSED, never sourced/executed. Lines are KEY=value; values may
# be wrapped in single or double quotes; "# comments" are allowed on their own
# line or after an unquoted value. Unknown keys are rejected (catches typos).
# =============================================================================
WGR_KEYS=(
  WG_INTERFACE WG_PORT WG_SERVER_ADDRESS WG_PEER_ADDRESS WG_MTU
  WG_PRIVATE_KEY_FILE WG_PRESHARED_KEY_FILE WG_PEER_PUBLIC_KEY WG_PEER_ALLOWED_IPS
  WAN_INTERFACE SSH_PORTS ENABLE_IPV4_FORWARDING ENABLE_IPV6_FORWARDING CONNTRACK_MAX
  RELAY_EGRESS MASQUERADE_EGRESS FORWARD_TCP_PORTS FORWARD_UDP_PORTS TUNNEL_INPUT_TCP_PORTS
  ROLLBACK_TIMEOUT ALLOW_UNSUPPORTED_OS PUBLIC_IP_LOOKUP_URL
)

declare -gA WGR_DEFAULTS=(
  [WG_INTERFACE]="wg0"
  [WG_PORT]="51820"
  [WG_SERVER_ADDRESS]="10.250.0.1/24"
  [WG_PEER_ADDRESS]="10.250.0.2/32"
  [WG_MTU]="1380"
  [WG_PRIVATE_KEY_FILE]="/etc/wireguard/private.key"
  [WG_PRESHARED_KEY_FILE]=""
  [WG_PEER_PUBLIC_KEY]=""
  [WG_PEER_ALLOWED_IPS]="10.250.0.2/32"
  [WAN_INTERFACE]="auto"
  [SSH_PORTS]="auto"
  [ENABLE_IPV4_FORWARDING]="yes"
  [ENABLE_IPV6_FORWARDING]="no"
  [CONNTRACK_MAX]=""
  [RELAY_EGRESS]="yes"
  [MASQUERADE_EGRESS]="yes"
  [FORWARD_TCP_PORTS]=""
  [FORWARD_UDP_PORTS]=""
  [TUNNEL_INPUT_TCP_PORTS]=""
  [ROLLBACK_TIMEOUT]="120"
  [ALLOW_UNSUPPORTED_OS]="no"
  [PUBLIC_IP_LOOKUP_URL]="https://api.ipify.org"
)

load_config() {
  local file=$1 line key val lineno=0 k
  [[ -f $file ]] || die "config file not found: $file"
  [[ -r $file ]] || die "config file not readable: $file"

  for k in "${WGR_KEYS[@]}"; do
    printf -v "$k" '%s' "${WGR_DEFAULTS[$k]}"
  done

  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -z $line || $line == \#* ]] && continue

    if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      die "$file line $lineno: expected KEY=value, got: $line"
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}

    if [[ ! -v "WGR_DEFAULTS[$key]" ]]; then
      die "$file line $lineno: unknown setting '$key' (typo?)"
    fi

    if [[ $val =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      val=${BASH_REMATCH[1]}
    elif [[ $val =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      val=${BASH_REMATCH[1]}
    else
      [[ $val == \#* ]] && val=""
      val="${val%%[[:space:]]#*}"               # strip trailing " # comment"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    printf -v "$key" '%s' "$val"
  done <"$file"
}

# ----- Value checks ----------------------------------------------------------
is_yes_no()   { [[ $1 == yes || $1 == no ]]; }
# WG_PRESHARED_KEY_FILE: "" = not decided yet (asked on a new install),
# "none" = no pre-shared key (decided), a path = use a PSK from that file.
psk_enabled() { [[ -n ${WG_PRESHARED_KEY_FILE:-} && $WG_PRESHARED_KEY_FILE != none ]]; }
is_uint()     { [[ $1 =~ ^[0-9]{1,9}$ ]]; }
is_port()     { is_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_ifname()   { [[ $1 =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
is_safe_path(){ [[ $1 =~ ^/[A-Za-z0-9._/-]+$ && $1 != */ ]]; }
# 32 bytes base64: 43 chars + "=", and the last char carries 2 zero bits.
is_wg_key()   { [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]]; }

is_ipv4() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' i
  [[ $1 =~ $re ]] || return 1
  for i in 1 2 3 4; do
    (( 10#${BASH_REMATCH[$i]} <= 255 )) || return 1
  done
}

is_ipv4_cidr() {
  [[ $1 == */* ]] || return 1
  local ip=${1%/*} p=${1#*/}
  is_ipv4 "$ip" && [[ $p =~ ^[0-9]{1,2}$ ]] && (( 10#$p <= 32 ))
}

# ----- IPv4 arithmetic -------------------------------------------------------
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%d' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

int2ip() {
  local i=$1
  printf '%d.%d.%d.%d' $(( (i >> 24) & 255 )) $(( (i >> 16) & 255 )) $(( (i >> 8) & 255 )) $(( i & 255 ))
}

prefix_mask() {
  local p=$((10#$1))
  if (( p == 0 )); then printf '0'; else printf '%d' $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); fi
}

# "192.168.1.5/24" -> "192.168.1.0/24"
cidr_normalize() {
  local ip=${1%/*} p=$((10#${1#*/})) i m
  i=$(ip2int "$ip")
  m=$(prefix_mask "$p")
  printf '%s/%d' "$(int2ip $(( i & m )))" "$p"
}

# True if two IPv4 CIDRs share any address.
cidrs_overlap() {
  local pa=$((10#${1#*/})) pb=$((10#${2#*/})) p ia ib m
  p=$(( pa < pb ? pa : pb ))
  ia=$(ip2int "${1%/*}")
  ib=$(ip2int "${2%/*}")
  m=$(prefix_mask "$p")
  (( (ia & m) == (ib & m) ))
}

is_public_ipv4() {
  is_ipv4 "$1" || return 1
  local c
  for c in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 \
           198.51.100.0/24 203.0.113.0/24 224.0.0.0/3; do
    if cidrs_overlap "$c" "$1/32"; then return 1; fi
  done
  return 0
}

# ----- Port lists ------------------------------------------------------------
# parse_port_list NAME "80 443,8000-8010" -> prints "80, 443, 8000-8010"
parse_port_list() {
  local name=$1 raw=$2 tok lo hi
  local -a toks=() out=()
  read -r -a toks <<<"${raw//,/ }"
  for tok in "${toks[@]}"; do
    if [[ $tok =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
      lo=${BASH_REMATCH[1]}
      hi=${BASH_REMATCH[3]:-$lo}
    else
      err "config: $name: '$tok' is not a port or port range"
      return 1
    fi
    if ! is_port "$lo" || ! is_port "$hi" || (( 10#$lo > 10#$hi )); then
      err "config: $name: '$tok' is out of range (1-65535)"
      return 1
    fi
    lo=$((10#$lo)); hi=$((10#$hi))
    if (( lo == hi )); then out+=("$lo"); else out+=("$lo-$hi"); fi
  done
  join_by ', ' "${out[@]}"
}

# port_in_list 22 "22, 8000-8010" -> true/false
port_in_list() {
  local p=$1 tok lo hi
  local -a toks=()
  read -r -a toks <<<"${2//,/ }"
  for tok in "${toks[@]}"; do
    lo=${tok%-*}; hi=${tok#*-}
    if (( p >= lo && p <= hi )); then return 0; fi
  done
  return 1
}

nft_elements() {
  if [[ -n $1 ]]; then printf 'elements = { %s }' "$1"; fi
}

# ----- Validation (static: needs no tools beyond bash) ----------------------
# Derived values, set by validate_config_static:
PEER_HOST="" SERVER_HOST="" SERVER_NET="" PEER_ALLOWED_NORM=""
FWD_TCP_NORM="" FWD_UDP_NORM="" TUNNEL_TCP_NORM=""
CFG_ERRORS=0

cfg_error() { err "config: $*"; CFG_ERRORS=$((CFG_ERRORS + 1)); }

validate_config_static() {
  CFG_ERRORS=0
  local v n t c found
  local -a toks=() norm=()

  is_ifname "$WG_INTERFACE" || cfg_error "WG_INTERFACE '$WG_INTERFACE' is not a valid interface name"
  is_port "$WG_PORT"        || cfg_error "WG_PORT '$WG_PORT' must be 1-65535"

  if is_ipv4_cidr "$WG_SERVER_ADDRESS"; then
    SERVER_HOST=${WG_SERVER_ADDRESS%/*}
    n=$((10#${WG_SERVER_ADDRESS#*/}))
    if (( n < 8 || n > 30 )); then
      cfg_error "WG_SERVER_ADDRESS prefix /$n must be between /8 and /30"
    fi
    SERVER_NET=$(cidr_normalize "$WG_SERVER_ADDRESS")
  else
    cfg_error "WG_SERVER_ADDRESS '$WG_SERVER_ADDRESS' must be an IPv4 address with prefix, e.g. 10.250.0.1/24"
  fi

  v=$WG_PEER_ADDRESS
  [[ $v == */* ]] || v="$v/32"
  if is_ipv4_cidr "$v" && (( 10#${v#*/} == 32 )); then
    PEER_HOST=${v%/*}
    WG_PEER_ADDRESS="$PEER_HOST/32"
  else
    cfg_error "WG_PEER_ADDRESS '$WG_PEER_ADDRESS' must be a single IPv4 address (/32)"
  fi

  if [[ -n $SERVER_HOST && -n $PEER_HOST ]]; then
    if [[ $SERVER_HOST == "$PEER_HOST" ]]; then
      cfg_error "WG_SERVER_ADDRESS and WG_PEER_ADDRESS use the same address"
    elif ! cidrs_overlap "$WG_SERVER_ADDRESS" "$PEER_HOST/32"; then
      warn "WG_PEER_ADDRESS $PEER_HOST is outside the tunnel subnet $SERVER_NET (unusual)"
    fi
  fi

  if is_uint "$WG_MTU" && (( 10#$WG_MTU >= 1280 && 10#$WG_MTU <= 1500 )); then
    WG_MTU=$((10#$WG_MTU))
  else
    cfg_error "WG_MTU '$WG_MTU' must be 1280-1500"
  fi

  is_safe_path "$WG_PRIVATE_KEY_FILE" \
    || cfg_error "WG_PRIVATE_KEY_FILE must be an absolute path using only A-Z a-z 0-9 . _ - /"
  if psk_enabled; then
    is_safe_path "$WG_PRESHARED_KEY_FILE" \
      || cfg_error "WG_PRESHARED_KEY_FILE must be an absolute path using only A-Z a-z 0-9 . _ - /"
    [[ $WG_PRESHARED_KEY_FILE != "$WG_PRIVATE_KEY_FILE" ]] \
      || cfg_error "WG_PRESHARED_KEY_FILE must differ from WG_PRIVATE_KEY_FILE"
  fi

  if [[ -n $WG_PEER_PUBLIC_KEY ]] && ! is_wg_key "$WG_PEER_PUBLIC_KEY"; then
    cfg_error "WG_PEER_PUBLIC_KEY is not a valid WireGuard public key (44 base64 characters ending in '=')"
  fi

  read -r -a toks <<<"${WG_PEER_ALLOWED_IPS//,/ }"
  if (( ${#toks[@]} == 0 )); then
    cfg_error "WG_PEER_ALLOWED_IPS must not be empty (at minimum, the peer's tunnel address)"
  fi
  for t in "${toks[@]}"; do
    if [[ $t == *:* ]]; then
      cfg_error "WG_PEER_ALLOWED_IPS: IPv6 entry '$t' not supported (the tunnel is IPv4-only)"
      continue
    fi
    [[ $t == */* ]] || t="$t/32"
    if ! is_ipv4_cidr "$t"; then
      cfg_error "WG_PEER_ALLOWED_IPS: '$t' is not a valid IPv4 CIDR"
      continue
    fi
    if (( 10#${t#*/} == 0 )); then
      cfg_error "WG_PEER_ALLOWED_IPS must not contain a /0 ('$t'): wg-quick would route this VPS's own traffic into the tunnel and cut off SSH"
      continue
    fi
    c=$(cidr_normalize "$t")
    [[ $c == "$t" ]] || warn "WG_PEER_ALLOWED_IPS: '$t' normalized to '$c'"
    norm+=("$c")
  done
  PEER_ALLOWED_NORM=$(join_by ', ' "${norm[@]}")
  if [[ -n $PEER_HOST ]] && (( ${#norm[@]} > 0 )); then
    found=0
    for c in "${norm[@]}"; do
      if cidrs_overlap "$c" "$PEER_HOST/32"; then found=1; fi
    done
    (( found )) || cfg_error "WG_PEER_ALLOWED_IPS must include WG_PEER_ADDRESS ($PEER_HOST)"
  fi

  if [[ $WAN_INTERFACE != auto ]]; then
    is_ifname "$WAN_INTERFACE" || cfg_error "WAN_INTERFACE '$WAN_INTERFACE' must be 'auto' or an interface name"
    [[ $WAN_INTERFACE != "$WG_INTERFACE" ]] || cfg_error "WAN_INTERFACE and WG_INTERFACE must differ"
  fi

  if [[ $SSH_PORTS != auto ]]; then
    if ! v=$(parse_port_list SSH_PORTS "$SSH_PORTS"); then
      CFG_ERRORS=$((CFG_ERRORS + 1))
    elif [[ -z $v ]]; then
      cfg_error "SSH_PORTS must be 'auto' or a list of ports"
    elif [[ $v == *-* ]]; then
      cfg_error "SSH_PORTS must list individual ports, not ranges"
    fi
  fi

  for n in ENABLE_IPV4_FORWARDING ENABLE_IPV6_FORWARDING RELAY_EGRESS MASQUERADE_EGRESS ALLOW_UNSUPPORTED_OS; do
    is_yes_no "${!n}" || cfg_error "$n must be 'yes' or 'no' (got '${!n}')"
  done

  if [[ -n $CONNTRACK_MAX ]]; then
    if ! is_uint "$CONNTRACK_MAX" || (( 10#$CONNTRACK_MAX < 4096 )); then
      cfg_error "CONNTRACK_MAX must be empty or an integer >= 4096"
    else
      CONNTRACK_MAX=$((10#$CONNTRACK_MAX))
    fi
  fi

  if ! FWD_TCP_NORM=$(parse_port_list FORWARD_TCP_PORTS "$FORWARD_TCP_PORTS"); then
    CFG_ERRORS=$((CFG_ERRORS + 1))
  fi
  if ! FWD_UDP_NORM=$(parse_port_list FORWARD_UDP_PORTS "$FORWARD_UDP_PORTS"); then
    CFG_ERRORS=$((CFG_ERRORS + 1))
  fi
  if ! TUNNEL_TCP_NORM=$(parse_port_list TUNNEL_INPUT_TCP_PORTS "$TUNNEL_INPUT_TCP_PORTS"); then
    CFG_ERRORS=$((CFG_ERRORS + 1))
  fi
  if [[ -n $FWD_UDP_NORM ]] && is_port "$WG_PORT" && port_in_list "$((10#$WG_PORT))" "$FWD_UDP_NORM"; then
    cfg_error "FORWARD_UDP_PORTS includes WG_PORT ($WG_PORT); that would hijack the tunnel itself"
  fi

  if [[ $ENABLE_IPV4_FORWARDING != yes ]]; then
    if [[ $RELAY_EGRESS == yes || -n $FWD_TCP_NORM || -n $FWD_UDP_NORM ]]; then
      cfg_error "RELAY_EGRESS and port forwards require ENABLE_IPV4_FORWARDING=yes"
    fi
  fi
  if [[ $RELAY_EGRESS == yes && $MASQUERADE_EGRESS == no ]]; then
    warn "RELAY_EGRESS=yes with MASQUERADE_EGRESS=no: peer traffic leaves with its own (likely private) source addresses"
  fi

  if ! is_uint "$ROLLBACK_TIMEOUT" || (( 10#$ROLLBACK_TIMEOUT < 30 || 10#$ROLLBACK_TIMEOUT > 3600 )); then
    cfg_error "ROLLBACK_TIMEOUT must be 30-3600 seconds"
  else
    ROLLBACK_TIMEOUT=$((10#$ROLLBACK_TIMEOUT))
  fi

  if [[ -n $PUBLIC_IP_LOOKUP_URL && ! $PUBLIC_IP_LOOKUP_URL =~ ^https?://[^[:space:]]+$ ]]; then
    cfg_error "PUBLIC_IP_LOOKUP_URL must be empty or an http(s) URL"
  fi

  (( CFG_ERRORS == 0 ))
}

# =============================================================================
# Detection (uses machine-readable output: ip -j + jq wherever possible)
# =============================================================================

# Interface that carries this host's route to the Internet.
detect_wan_interface() {
  local dev=""
  dev=$(ip -j -4 route get 1.1.1.1 2>/dev/null | jq -r '.[0].dev // empty' 2>/dev/null) || dev=""
  if [[ -z $dev || $dev == "${WG_INTERFACE:-wg0}" ]]; then
    dev=$(ip -j -4 route show default 2>/dev/null \
      | jq -r --arg wg "${WG_INTERFACE:-wg0}" \
          '[.[] | select(.dev != $wg)] | sort_by(.metric // 0) | .[0].dev // empty' 2>/dev/null) || dev=""
  fi
  [[ -n $dev ]] || return 1
  printf '%s\n' "$dev"
}

# Global-scope IPv4 addresses on an interface, as CIDRs.
wan_ipv4_cidrs() {
  ip -j -4 addr show dev "$1" 2>/dev/null \
    | jq -r '.[0].addr_info[]? | select(.scope == "global") | "\(.local)/\(.prefixlen)"' 2>/dev/null || true
}

link_mtu() {
  ip -j link show dev "$1" 2>/dev/null | jq -r '.[0].mtu // empty' 2>/dev/null || true
}

# Public IPv4: from the WAN interface if it carries one, otherwise (1:1 NAT
# providers) from PUBLIC_IP_LOOKUP_URL if curl is installed.
public_ipv4() {
  local wan=$1 c ip
  while read -r c; do
    [[ -n $c ]] || continue
    ip=${c%/*}
    if is_public_ipv4 "$ip"; then printf '%s\n' "$ip"; return 0; fi
  done < <(wan_ipv4_cidrs "$wan")
  if [[ -n ${PUBLIC_IP_LOOKUP_URL:-} ]] && command -v curl >/dev/null 2>&1; then
    ip=$(curl -4 -fsS --max-time 5 "$PUBLIC_IP_LOOKUP_URL" 2>/dev/null | tr -d '[:space:]' || true)
    if is_public_ipv4 "$ip"; then printf '%s\n' "$ip"; return 0; fi
  fi
  return 1
}

# Server-side port of the SSH session this script runs under. sudo strips
# SSH_CONNECTION from the environment, so walk up the process tree.
current_session_ssh_port() {
  local pid=$$ line port _a _b _c
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r _a _b _c port <<<"$SSH_CONNECTION"
    if is_port "${port:-}"; then printf '%s\n' "$((10#$port))"; return 0; fi
  fi
  while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    line=$(tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" | grep -m1 '^SSH_CONNECTION=' || true)
    if [[ -n $line ]]; then
      read -r _a _b _c port <<<"${line#SSH_CONNECTION=}"
      if is_port "${port:-}"; then printf '%s\n' "$((10#$port))"; return 0; fi
    fi
    pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
  done
  return 1
}

# Union of every source of truth about where sshd listens. Prints ports
# space-separated, or fails if none were found.
detect_ssh_ports() {
  local p
  local -a ports=() valid=()
  if [[ -x /usr/sbin/sshd ]]; then
    while read -r p; do ports+=("$p"); done \
      < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true)
  fi
  # ss has no JSON mode; with -H the column layout is fixed (local addr = $4).
  while read -r p; do ports+=("$p"); done \
    < <(ss -Hltnp 2>/dev/null | awk '/users:\(\("sshd",/ { n = split($4, a, ":"); print a[n] }' || true)
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    while read -r p; do ports+=("$p"); done \
      < <(systemctl show -p Listen --value ssh.socket 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+' || true)
  fi
  if p=$(current_session_ssh_port); then ports+=("$p"); fi

  for p in "${ports[@]}"; do
    if is_port "$p"; then valid+=("$((10#$p))"); fi
  done
  (( ${#valid[@]} > 0 )) || return 1
  printf '%s\n' "${valid[@]}" | sort -nu | paste -sd ' ' -
}

# =============================================================================
# Templates: replaces @TOKEN@ placeholders; fails on any leftover token.
# =============================================================================
render_template() {
  local src=$1 dst=$2 kv k v content
  shift 2
  content=$(<"$src")
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    content=${content//"@${k}@"/"$v"}
  done
  if [[ $content =~ @[A-Z0-9_]+@ ]]; then
    die "template $src: unresolved placeholder ${BASH_REMATCH[0]}"
  fi
  # Strip trailing whitespace left behind by empty placeholders.
  printf '%s\n' "$content" | sed 's/[[:space:]]*$//' >"$dst"
}

# =============================================================================
# Migration block (install.sh --export / --import)
# =============================================================================
WGR_BLOCK_BEGIN="-----BEGIN WG-RELAY MIGRATION-----"
WGR_BLOCK_END="-----END WG-RELAY MIGRATION-----"

# Print every setting from the loaded config plus the key material.
print_migration_block() {
  local k
  printf '%s\n' "$WGR_BLOCK_BEGIN"
  printf '# wg-relay %s, exported from %s, %s\n' "$WGR_VERSION" "$(hostname)" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  for k in "${WGR_KEYS[@]}"; do
    printf '%s=%s\n' "$k" "${!k}"
  done
  printf 'WG_PRIVATE_KEY=%s\n' "$(tr -d '[:space:]' <"$WG_PRIVATE_KEY_FILE")"
  if psk_enabled && [[ -f $WG_PRESHARED_KEY_FILE ]]; then
    printf 'WG_PRESHARED_KEY=%s\n' "$(tr -d '[:space:]' <"$WG_PRESHARED_KEY_FILE")"
  fi
  printf '%s\n' "$WGR_BLOCK_END"
}
