#!/usr/bin/env bash
# =============================================================================
# wg-relay — install.sh
#
# Turns a Debian 13 VPS into a WireGuard relay endpoint for OPNsense:
#   WireGuard (kernel + wg-quick), nftables (its own table only), IP forwarding.
#
#   ./install.sh             new tunnel, migration or reconfigure (asks which)
#   ./install.sh --export    print a migration block (settings + keys)
#   ./install.sh --import    migrate this VPS from a pasted migration block
#   ./install.sh --dry-run   show what would change; change nothing
#
# Re-running converges on config.env: files are replaced only when their
# content changes, services restart only when necessary, and keys change only
# when you choose to change them.
# =============================================================================
set -Eeuo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REQUIRED_PACKAGES=(wireguard-tools nftables jq iproute2 procps)
LOG=/var/log/wg-relay-install.log

CONFIG_SRC="$SCRIPT_DIR/config.env"
DO_EXPORT=0
DO_IMPORT=0
DRY_RUN=0
NO_CONFIRM=0
NO_PROMPT=0
VERBOSE=0
IGNORE_OTHER_FW=0

LOG_OPEN=0
INTERACTIVE=0
STAGE=""
FW_PENDING=0
ROLLBACK_CMD=""
WAN_IF=""
SSH_PORTS_NORM=""
SERVER_PUBKEY=""
MODE=""                 # new | migrate | reconfigure
PRIV_ACTION="keep"      # keep | generated | pasted
PSK_ACTION="keep"       # keep | none | generated | pasted
INST_ACTION="unchanged" # unchanged | pasted (entered or imported this run)
NEW_PRIV=""             # key material held in memory until you confirm
NEW_PSK=""
declare -A PENDING_CFG=()   # config.env changes, written after you confirm
STEP_NUM=0
STEP_TOTAL=5
STEP_LABEL=""
STEP_OPEN=0
STEP_BROKEN=0
FILES_CHANGED=()
PKG_RESULT="done"
VFAILS=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --export                  print a migration block (settings and keys) for a new VPS
  --import                  migrate this VPS from a pasted migration block
  --dry-run                 validate and show what would change; change nothing
  --config FILE             use FILE instead of ./config.env
  --no-prompt               ask nothing: reconfigure with config.env, keep or generate keys
  --no-confirm              skip the SSH access check after firewall changes
                            (also disables the automatic firewall rollback)
  --ignore-other-firewalls  continue even if ufw, firewalld or iptables rules are active
  -v, --verbose             show every step (always written to $LOG)
  -h, --help                show this help
EOF
}

# ----- Output ----------------------------------------------------------------
# Screen: steps, questions, the plan and problems. Log: everything.
logf()   { if (( LOG_OPEN )); then printf '%s\n' "$@" >&3; fi; }

# Steps print "[n/5] Label... done" on one line. If anything else is printed
# while a step is open, the line is closed first and the result repeated after.
step() {
  STEP_NUM=$((STEP_NUM + 1))
  STEP_LABEL="[$STEP_NUM/$STEP_TOTAL] $1"
  printf '%s... ' "$STEP_LABEL"
  logf "$STEP_LABEL"
  STEP_OPEN=1
  STEP_BROKEN=0
}

break_line() {
  if (( STEP_OPEN )); then printf '\n'; STEP_OPEN=0; STEP_BROKEN=1; fi
}

step_end() {
  local result=${1:-done}
  if (( STEP_OPEN )); then
    printf '%s\n' "$result"
  elif (( STEP_BROKEN )); then
    printf '%s... %s\n' "$STEP_LABEL" "$result"
  fi
  STEP_OPEN=0
  STEP_BROKEN=0
  logf "$STEP_LABEL: $result"
}


note()   { break_line; printf '%s\n' "$@"; logf "$@"; }
detail() { logf "  $*"; if (( VERBOSE )); then break_line; printf '  %s\n' "$*"; fi; }
warn()   { break_line; printf 'W: %s\n' "$*" >&2; logf "W: $*"; }
err()    { break_line; printf 'E: %s\n' "$*" >&2; logf "E: $*"; }
die()    { err "$*"; if (( LOG_OPEN )); then printf 'Details: %s\n' "$LOG" >&2; fi; exit 1; }
ok()     { detail "$@"; }
say()    { break_line; printf '%s\n' "$@" >/dev/tty; logf "$@"; }

open_log() {
  ( umask 027; : >>"$LOG" ) || die "cannot write $LOG"
  exec 3>>"$LOG"
  LOG_OPEN=1
  logf "" "===== $(date -u '+%Y-%m-%d %H:%M:%S UTC') install.sh v$WGR_VERSION $* ====="
}


# ----- Error handling --------------------------------------------------------
on_error() { err "unexpected failure (exit $1) at line $2: $3"; }

cleanup() {
  local rc=$?
  trap - EXIT
  if (( FW_PENDING )); then
    warn "exiting with an unconfirmed firewall change; restoring the previous rules"
    fw_rollback_now || true
  fi
  if [[ -n $STAGE && -d $STAGE ]]; then rm -rf -- "$STAGE"; fi
  exit "$rc"
}


trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ORIG_ARGS="$*"
while (( $# )); do
  case $1 in
    --export)                 DO_EXPORT=1; shift ;;
    --import)                 DO_IMPORT=1; shift ;;
    --dry-run)                DRY_RUN=1; shift ;;
    --config)
      (( $# >= 2 )) || die "--config needs a file argument"
      CONFIG_SRC=$(readlink -f -- "$2"); shift 2 ;;
    --no-prompt)              NO_PROMPT=1; shift ;;
    --no-confirm)             NO_CONFIRM=1; shift ;;
    --ignore-other-firewalls) IGNORE_OTHER_FW=1; shift ;;
    -v|--verbose)             VERBOSE=1; shift ;;
    -h|--help)                usage; exit 0 ;;
    *)                        usage >&2; die "unknown option: $1" ;;
  esac
done

# =============================================================================
# Preflight
# =============================================================================
check_os() {
  local id ver pretty
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot identify the OS"
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  pretty=$(os_pretty_name)
  if [[ $id == debian && $ver == 13 ]]; then
    ok "OS: $pretty"
  elif [[ $ALLOW_UNSUPPORTED_OS == yes ]]; then
    warn "OS is $pretty, not Debian 13 (continuing: ALLOW_UNSUPPORTED_OS=yes)"
  else
    die "this kit needs Debian 13; found $pretty (set ALLOW_UNSUPPORTED_OS=yes to try anyway)"
  fi
}

check_virtualization() {
  local virt
  if virt=$(systemd-detect-virt --container 2>/dev/null); then
    die "this is a container ($virt); WireGuard needs a full VM (KVM, Xen, VMware, Hyper-V)"
  fi
  ok "virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"
}

check_tty() {
  if (( NO_CONFIRM || DRY_RUN )); then return 0; fi
  if ! { : </dev/tty; } 2>/dev/null; then
    die "no terminal for the SSH confirmation; run from an SSH session or use --no-confirm"
  fi
}

ensure_packages() {
  local p
  local -a missing=()
  for p in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$'; then
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    PKG_RESULT="already installed"
    return 0
  fi
  PKG_RESULT="done"
  if (( DRY_RUN )); then
    die "dry run needs these packages first: apt-get install --no-install-recommends ${missing[*]}"
  fi
  break_line
  printf 'Packages to install: %s\n\n' "${missing[*]}"
  logf "apt-get install ${missing[*]} (apt output shown on screen, not logged)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || die "apt-get update failed"
  # --no-install-recommends: Debian's kernel already ships WireGuard; this
  # avoids pulling in DKMS and compilers on a small VPS.
  # Dpkg::Progress-Fancy: apt's progress bar at the bottom of the terminal.
  apt-get install -y --no-install-recommends -o Dpkg::Progress-Fancy=1 "${missing[@]}" \
    || die "package installation failed"
  printf '\n'
}

ensure_wireguard_module() {
  modprobe wireguard 2>/dev/null || [[ -d /sys/module/wireguard ]] \
    || die "the WireGuard kernel module is not available on this kernel"
}

resolve_wan() {
  if [[ $WAN_INTERFACE == auto ]]; then
    WAN_IF=$(detect_wan_interface) \
      || die "could not detect the WAN interface; set WAN_INTERFACE in config.env"
  else
    WAN_IF=$WAN_INTERFACE
  fi
  ip link show dev "$WAN_IF" >/dev/null 2>&1 || die "WAN interface $WAN_IF does not exist"
  [[ $WAN_IF != "$WG_INTERFACE" ]] || die "WAN interface resolved to $WG_INTERFACE; set WAN_INTERFACE"
}

resolve_ssh_ports() {
  local raw cur
  if [[ $SSH_PORTS == auto ]]; then
    raw=$(detect_ssh_ports) || die "could not detect the SSH port; set SSH_PORTS in config.env"
    SSH_PORTS_NORM=$(parse_port_list SSH_PORTS "$raw") || die "detected SSH ports look invalid: $raw"
  else
    SSH_PORTS_NORM=$(parse_port_list SSH_PORTS "$SSH_PORTS") || die "SSH_PORTS is invalid"
  fi
  if cur=$(current_session_ssh_port); then
    port_in_list "$cur" "$SSH_PORTS_NORM" \
      || die "this SSH session uses port $cur, which is not in SSH_PORTS ($SSH_PORTS_NORM); you would be locked out"
  else
    detail "current SSH session port unknown (console session?)"
  fi
}

validate_config_dynamic() {
  CFG_ERRORS=0
  local c a p mtu
  local -a wan_nets=() peer=() ssh=()
  mapfile -t wan_nets < <(wan_ipv4_cidrs "$WAN_IF")
  read -r -a peer <<<"${PEER_ALLOWED_NORM//,/ }"
  read -r -a ssh <<<"${SSH_PORTS_NORM//,/ }"

  for c in "${wan_nets[@]}"; do
    [[ -n $c ]] || continue
    if cidrs_overlap "$c" "$SERVER_NET"; then
      cfg_error "tunnel subnet $SERVER_NET overlaps WAN network $c"
    fi
    for a in "${peer[@]}"; do
      if cidrs_overlap "$c" "$a"; then
        cfg_error "WG_PEER_ALLOWED_IPS entry $a overlaps WAN network $c"
      fi
    done
  done

  if [[ -n $FWD_TCP_NORM ]]; then
    for p in "${ssh[@]}"; do
      if port_in_list "$p" "$FWD_TCP_NORM"; then
        cfg_error "FORWARD_TCP_PORTS includes SSH port $p; that would cut off SSH to this VPS"
      fi
    done
  fi

  mtu=$(link_mtu "$WAN_IF")
  if [[ $mtu =~ ^[0-9]+$ ]] && (( WG_MTU > mtu - 60 )); then
    warn "WG_MTU $WG_MTU is larger than the WAN MTU ($mtu) minus WireGuard overhead (60)"
  fi
  (( CFG_ERRORS == 0 ))
}

inventory_firewalls() {
  local conflict=0
  local -a others=()
  if [[ -f /etc/ufw/ufw.conf ]] && grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf; then
    warn "ufw is enabled; its rules can drop relay traffic"; conflict=1
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active; its rules can drop relay traffic"; conflict=1
  fi
  if command -v iptables-legacy-save >/dev/null 2>&1 && iptables-legacy-save 2>/dev/null | grep -qE '^-A '; then
    warn "legacy iptables rules are loaded; they can drop relay traffic"; conflict=1
  fi
  mapfile -t others < <(nft -j list tables 2>/dev/null \
    | jq -r '.nftables[]? | .table? | select(. != null) | "\(.family) \(.name)"' 2>/dev/null \
    | grep -vx 'inet wg_relay' || true)
  if (( ${#others[@]} > 0 )); then
    detail "other nftables tables (left untouched): $(join_by ', ' "${others[@]}")"
  fi
  if (( conflict )) && ! (( IGNORE_OTHER_FW )); then
    die "another firewall is active; disable it, or re-run with --ignore-other-firewalls"
  fi
}

# Set KEY=VALUE in config.env (replacing every line for KEY, or appending).
# Written in place so the file keeps its owner and mode.
config_set() {
  local key=$1 val=$2 tmp
  tmp=$(mktemp /tmp/wg-relay-config.XXXXXX)
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_SRC"; then
    awk -v k="$key" -v v="$val" '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k "=" v; next } { print }' \
      "$CONFIG_SRC" >"$tmp"
  else
    cat "$CONFIG_SRC" >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  fi
  cat "$tmp" >"$CONFIG_SRC"
  rm -f -- "$tmp"
}

# ask_yn "Question?" Y|N -> true for yes. Enter takes the capitalised default.
ask_yn() {
  local q=$1 def=$2 hint reply
  if [[ $def == Y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    printf '%s %s ' "$q" "$hint" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
    reply=${reply//[[:space:]]/}
    reply=${reply,,}
    [[ -n $reply ]] || reply=${def,,}
    case $reply in
      y|yes) logf "$q $hint y"; return 0 ;;
      n|no)  logf "$q $hint n"; return 1 ;;
    esac
  done
}


# =============================================================================
# Keys and questions. Nothing is written until you confirm the plan.
# Secrets are read without echo and never passed as command-line arguments.
# =============================================================================
pub_of()  { printf '%s\n' "$1" | wg pubkey; }
masked()  { printf '%s...%s' "${1:0:4}" "${1: -4}"; }
file_key(){ tr -d '[:space:]' <"$1" 2>/dev/null || true; }

# Every key is shown the same way everywhere: value, then (what happened).
#   generated  created on this VPS this run
#   pasted     entered or imported this run
#   derived    calculated from the VPS private key
#   unchanged  already in place
# Secrets are never shown in full, except a newly generated pre-shared key,
# which OPNsense needs.
priv_tag() { case $PRIV_ACTION in keep) echo unchanged ;; *) echo "$PRIV_ACTION" ;; esac; }
pub_tag()  { case $PRIV_ACTION in keep) echo unchanged ;; *) echo derived ;; esac; }
psk_tag()  { case $PSK_ACTION in keep) echo unchanged ;; *) echo "$PSK_ACTION" ;; esac; }
psk_value() {
  case $PSK_ACTION in
    generated) printf '%s' "$NEW_PSK" ;;
    pasted)    masked "$NEW_PSK" ;;
    keep)      masked "$(file_key "$WG_PRESHARED_KEY_FILE")" ;;
  esac
}
# key_row INDENT WIDTH LABEL VALUE [TAG]
key_row() {
  if [[ -n ${5:-} ]]; then
    note "$(printf "%s%-${2}s %-44s  (%s)" "$1" "$3" "$4" "$5")"
  else
    note "$(printf "%s%-${2}s %s" "$1" "$3" "$4")"
  fi
}

# Read a key from the terminal. $1 = label, $2 = public|secret, $3 = blank-ok.
read_key() {
  local label=$1 kind=$2 blank=${3:-} key
  for _ in 1 2 3; do
    printf '%s' "$label" >/dev/tty
    if [[ $kind == secret ]]; then
      IFS= read -r -s key </dev/tty || key=""
      printf '\n' >/dev/tty
    else
      IFS= read -r key </dev/tty || key=""
    fi
    key=${key//[[:space:]]/}
    if [[ -z $key && $blank == blank-ok ]]; then return 0; fi
    if is_wg_key "$key"; then printf '%s' "$key"; return 0; fi
    say "That is not a valid WireGuard key."
  done
  return 1
}

ask_private_key() {
  say "" "VPS private key"
  if ask_yn "Generate a new private key?" Y; then
    NEW_PRIV=$(wg genkey)
    PRIV_ACTION=generated
  else
    say "  Copy from: old VPS (cat $WG_PRIVATE_KEY_FILE)"
    NEW_PRIV=$(read_key "Private key (input hidden): " secret) || die "no valid private key entered; nothing was changed"
    PRIV_ACTION=pasted
  fi
}

ask_instance_key() {
  local key
  say "" "OPNsense instance public key" \
      "  Copy from: OPNsense > VPN > WireGuard > Instances > (instance) > Public key"
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then
    say "  Current: $WG_PEER_PUBLIC_KEY"
    key=$(read_key "Public key (leave blank to keep current): " public blank-ok) || die "no valid public key entered"
  else
    key=$(read_key "Public key (leave blank to skip): " public blank-ok) || die "no valid public key entered"
  fi
  if [[ -n $key && $key != "$WG_PEER_PUBLIC_KEY" ]]; then
    WG_PEER_PUBLIC_KEY=$key
    PENDING_CFG[WG_PEER_PUBLIC_KEY]=$key
    INST_ACTION=pasted
  fi
}

ask_psk() {
  say ""
  if ! ask_yn "Use a pre-shared key?" N; then
    PSK_ACTION=none
    return 0
  fi
  if ask_yn "Generate a new pre-shared key?" Y; then
    NEW_PSK=$(wg genpsk)
    PSK_ACTION=generated
  else
    say "  Copy from: OPNsense > VPN > WireGuard > Peers > (peer) > Pre-shared key"
    NEW_PSK=$(read_key "Pre-shared key (input hidden): " secret) || die "no valid pre-shared key entered; nothing was changed"
    PSK_ACTION=pasted
  fi
}

ask_all_keys() {
  ask_private_key
  ask_instance_key
  ask_psk
}

# Keys already on disk, used as-is (reconfigure / --no-prompt / dry run).
# Anything missing is generated; an undecided pre-shared key means none.
keep_keys() {
  if [[ -e $WG_PRIVATE_KEY_FILE ]]; then
    PRIV_ACTION=keep
  else
    NEW_PRIV=$(wg genkey)
    PRIV_ACTION=generated
  fi
  if psk_enabled; then
    if [[ -e $WG_PRESHARED_KEY_FILE ]]; then PSK_ACTION=keep
    else NEW_PSK=$(wg genpsk); PSK_ACTION=generated; fi
  else
    PSK_ACTION=none
  fi
}

# ----- Default-config check ----------------------------------------------------
config_is_default() {
  local k
  for k in "${WGR_KEYS[@]}"; do
    [[ ${!k} == "${WGR_DEFAULTS[$k]}" ]] || return 1
  done
}

check_default_config() {
  config_is_default || return 0
  if (( INTERACTIVE )); then
    say "" "config.env still has the default value for every setting."
    ask_yn "Continue anyway?" N || { note "Abort."; exit 1; }
  else
    warn "config.env still has the default value for every setting"
  fi
}

# ----- Installation type --------------------------------------------------------
choose_mode() {
  local def=1 reply
  if [[ -f $WGR_CONFIG ]]; then def=3; fi
  say "" "Installation type:" \
      "  1. New tunnel     set up both ends from scratch" \
      "  2. Migration      move an existing tunnel to this VPS" \
      "  3. Reconfigure    re-apply config.env on this VPS (keys kept unless you change them)"
  while true; do
    printf 'Selection [%s]: ' "$def" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
    reply=${reply//[[:space:]]/}
    [[ -n $reply ]] || reply=$def
    case $reply in
      1) MODE=new; break ;;
      2) MODE=migrate; break ;;
      3) MODE=reconfigure; break ;;
    esac
  done
  logf "installation type: $MODE"
}

# ----- Import (migration) --------------------------------------------------------
# Reads a block printed by --export on the old VPS. Input is hidden because it
# contains secret keys. Settings are shown as a diff against config.env and
# written only after you confirm.
import_block() {
  local line k v in_block=0 count=0 imp_priv="" imp_psk="" pub
  local -A got=()
  say "" "Paste the migration block from the old VPS (./install.sh --export)." \
      "Input is hidden; it ends at the -----END WG-RELAY MIGRATION----- line."
  while IFS= read -r -s line </dev/tty; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ $line == "$WGR_BLOCK_BEGIN" ]]; then in_block=1; continue; fi
    if [[ $line == "$WGR_BLOCK_END" ]]; then break; fi
    (( in_block )) || continue
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "unexpected line in the migration block"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case $k in
      WG_PRIVATE_KEY)   imp_priv=$v ;;
      WG_PRESHARED_KEY) imp_psk=$v ;;
      *)
        [[ -v "WGR_DEFAULTS[$k]" ]] || die "unknown setting in the migration block: $k"
        got[$k]=$v ;;
    esac
    count=$((count + 1))
  done
  (( in_block )) || die "no migration block found"
  (( count > 0 )) || die "the migration block is empty"
  if [[ -n $imp_priv ]] && ! is_wg_key "$imp_priv"; then die "the private key in the block is not valid"; fi
  if [[ -n $imp_psk ]] && ! is_wg_key "$imp_psk"; then die "the pre-shared key in the block is not valid"; fi

  # A named WAN interface from another provider probably doesn't exist here.
  if [[ -n ${got[WAN_INTERFACE]:-} && ${got[WAN_INTERFACE]} != auto ]] \
     && ! ip link show dev "${got[WAN_INTERFACE]}" >/dev/null 2>&1; then
    got[WAN_INTERFACE]=auto
  fi

  say "" "Changes to config.env:"
  local changed=0
  for k in "${WGR_KEYS[@]}"; do
    [[ -v "got[$k]" ]] || continue
    if [[ ${got[$k]} != "${!k}" ]]; then
      say "  $k: ${!k:-(empty)} -> ${got[$k]:-(empty)}"
      changed=1
    fi
  done
  (( changed )) || say "  none (already matches)"
  say "Keys in the block:"
  if [[ -n $imp_priv ]]; then
    pub=$(pub_of "$imp_priv")
    say "  VPS private key    public key $pub"
  else
    say "  VPS private key    (not included)"
  fi
  say "  Instance key       ${got[WG_PEER_PUBLIC_KEY]:-(not set)}"
  if [[ -n $imp_psk ]]; then say "  Pre-shared key     $(masked "$imp_psk")"; else say "  Pre-shared key     none"; fi

  ask_yn "Write these settings to config.env?" Y || { note "Abort."; exit 1; }
  if [[ -n ${got[WG_PEER_PUBLIC_KEY]:-} && ${got[WG_PEER_PUBLIC_KEY]} != "$WG_PEER_PUBLIC_KEY" ]]; then
    INST_ACTION=pasted
  fi
  for k in "${WGR_KEYS[@]}"; do
    [[ -v "got[$k]" ]] || continue
    if [[ ${got[$k]} != "${!k}" ]]; then config_set "$k" "${got[$k]}"; fi
  done
  note "config.env updated."

  # Reload and re-validate what was just written.
  load_config "$CONFIG_SRC"
  validate_config_static || die "the imported settings are invalid ($CFG_ERRORS error(s))"

  # Keys
  if [[ -n $imp_priv ]]; then
    say ""
    if ask_yn "Keep the old VPS identity (no key change on OPNsense)?" Y; then
      NEW_PRIV=$imp_priv; PRIV_ACTION=pasted
    else
      NEW_PRIV=$(wg genkey); PRIV_ACTION=generated
    fi
  else
    NEW_PRIV=$(wg genkey); PRIV_ACTION=generated
  fi
  if [[ -n $imp_psk ]]; then
    NEW_PSK=$imp_psk; PSK_ACTION=pasted
    [[ $WG_PRESHARED_KEY_FILE != none && -n $WG_PRESHARED_KEY_FILE ]] || WG_PRESHARED_KEY_FILE=$WGR_PSK_DEFAULT
  else
    PSK_ACTION=none
  fi
}

# Decide every key for the chosen installation type.
collect_keys() {
  case $MODE in
    new)
      check_default_config
      ask_all_keys ;;
    migrate)
      import_block ;;
    reconfigure)
      check_default_config
      if (( INTERACTIVE )) && [[ -e $WG_PRIVATE_KEY_FILE ]]; then
        say ""
        if ask_yn "Keep the current keys?" Y; then keep_keys; else ask_all_keys; fi
      elif (( INTERACTIVE )); then
        ask_all_keys
      else
        keep_keys
      fi ;;
  esac

  # Reflect the pre-shared key decision in config.env.
  case $PSK_ACTION in
    none)
      if [[ $WG_PRESHARED_KEY_FILE != none ]]; then
        PENDING_CFG[WG_PRESHARED_KEY_FILE]=none
      fi
      WG_PRESHARED_KEY_FILE=none ;;
    generated|pasted)
      if ! psk_enabled; then WG_PRESHARED_KEY_FILE=$WGR_PSK_DEFAULT; fi
      PENDING_CFG[WG_PRESHARED_KEY_FILE]=$WG_PRESHARED_KEY_FILE ;;
  esac
  # A key that equals what's already on disk is not a change.
  if [[ $PRIV_ACTION == pasted && -e $WG_PRIVATE_KEY_FILE && $NEW_PRIV == "$(file_key "$WG_PRIVATE_KEY_FILE")" ]]; then
    PRIV_ACTION=keep; NEW_PRIV=""
  fi
  if [[ $PSK_ACTION == pasted && -e $WG_PRESHARED_KEY_FILE && $NEW_PSK == "$(file_key "$WG_PRESHARED_KEY_FILE")" ]]; then
    PSK_ACTION=keep; NEW_PSK=""
  fi

  if [[ $PRIV_ACTION == keep ]]; then SERVER_PUBKEY=$(wg pubkey <"$WG_PRIVATE_KEY_FILE")
  else SERVER_PUBKEY=$(pub_of "$NEW_PRIV"); fi
  if [[ $WG_PEER_PUBLIC_KEY == "$SERVER_PUBKEY" ]]; then
    die "the OPNsense instance public key equals this VPS's own public key; they must differ"
  fi
}

# ----- Plan: what is about to happen, then "continue?" -----------------------
plan_row() { note "$(printf '  %-18s %s' "$1" "$2")"; }

show_plan() {
  local pair src dst label egress mode changes
  FILES_CHANGED=()
  for pair in \
      "$STAGE/wg-relay.nft:$WGR_NFT:firewall rules" \
      "$STAGE/$WG_INTERFACE.conf:/etc/wireguard/$WG_INTERFACE.conf:WireGuard config" \
      "$STAGE/sysctl.conf:$WGR_SYSCTL:kernel settings" \
      "$STAGE/$WGR_UNIT_NAME:$WGR_UNIT:firewall service"; do
    IFS=: read -r src dst label <<<"$pair"
    cmp -s "$src" "$dst" || FILES_CHANGED+=("$label")
  done
  if [[ $PRIV_ACTION != keep || $PSK_ACTION == generated || $PSK_ACTION == pasted ]]; then
    FILES_CHANGED+=("key files")
  elif [[ $PSK_ACTION == none && -n ${PENDING_CFG[WG_PRESHARED_KEY_FILE]:-} ]]; then
    FILES_CHANGED+=("key files")
  fi
  if (( ${#PENDING_CFG[@]} )); then FILES_CHANGED+=("config.env"); fi

  case $MODE in
    new) mode="New tunnel" ;; migrate) mode="Migration" ;; *) mode="Reconfigure" ;;
  esac
  if [[ $RELAY_EGRESS != yes ]]; then egress="no"
  elif [[ $MASQUERADE_EGRESS == yes ]]; then egress="yes, masqueraded"
  else egress="yes, not masqueraded"; fi

  plan_row "Installation type" "$mode"
  if [[ $SSH_PORTS_NORM == *,* ]]; then
    plan_row "WAN interface" "$WAN_IF (SSH ports $SSH_PORTS_NORM stay open)"
  else
    plan_row "WAN interface" "$WAN_IF (SSH port $SSH_PORTS_NORM stays open)"
  fi
  plan_row "Tunnel" "$WG_SERVER_ADDRESS <-> $PEER_HOST, UDP $((10#$WG_PORT)), MTU $WG_MTU"
  plan_row "Relay egress" "$egress"
  plan_row "Inbound forwards" "TCP ${FWD_TCP_NORM:-none}; UDP ${FWD_UDP_NORM:-none}"
  key_row "  " 18 "VPS private key" "(hidden)" "$(priv_tag)"
  key_row "  " 18 "VPS public key" "$SERVER_PUBKEY" "$(pub_tag)"
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then
    key_row "  " 18 "Instance key" "$WG_PEER_PUBLIC_KEY" "$INST_ACTION"
  else
    key_row "  " 18 "Instance key" "not set"
  fi
  if [[ $PSK_ACTION == none ]]; then
    key_row "  " 18 "Pre-shared key" "none"
  else
    key_row "  " 18 "Pre-shared key" "$(psk_value)" "$(psk_tag)"
  fi
  if (( ${#FILES_CHANGED[@]} )); then changes=$(join_by ', ' "${FILES_CHANGED[@]}")
  else changes="none (already up to date)"; fi
  plan_row "Changes" "$changes"
}

confirm_plan() {
  note "" "The following will be configured:"
  show_plan
  if [[ " ${FILES_CHANGED[*]} " == *" firewall rules "* ]] && (( ! NO_CONFIRM )); then
    note "Firewall changes need an SSH access check; you will be asked."
  fi
  if (( INTERACTIVE )); then
    ask_yn "Do you want to continue?" Y || { note "Abort."; exit 1; }
  fi
  note ""
}

# =============================================================================
# Apply
# =============================================================================
install_support_files() {
  local s k
  # config.env changes decided during the questions
  for k in "${!PENDING_CFG[@]}"; do
    config_set "$k" "${PENDING_CFG[$k]}"
  done
  install -d -m 750 "$WGR_ETC"
  chmod 750 "$WGR_ETC"
  if ! cmp -s "$CONFIG_SRC" "$WGR_CONFIG"; then
    install -m 600 "$CONFIG_SRC" "$WGR_CONFIG"
  fi
  install -d -m 755 "$WGR_LIB" "$WGR_LIB/lib" "$WGR_LIB/scripts"
  install -m 644 "$SCRIPT_DIR/lib/common.sh" "$WGR_LIB/lib/common.sh"
  rm -f "$WGR_BIN/wg-relay-backup" "$WGR_LIB/scripts/backup.sh"
  for s in status diagnostics export; do
    install -m 755 "$SCRIPT_DIR/scripts/$s.sh" "$WGR_LIB/scripts/$s.sh"
    ln -sfn "$WGR_LIB/scripts/$s.sh" "$WGR_BIN/wg-relay-$s"
  done
}

# Write a key from memory. printf is a builtin, so the value never appears in
# a process's argument list.
write_key() {
  local path=$1 val=$2 dir
  dir=$(dirname -- "$path")
  [[ -d $dir ]] || install -d -m 700 "$dir"
  ( umask 077; printf '%s\n' "$val" >"$path.tmp" ) || die "could not write $path"
  chown root:root "$path.tmp"
  mv -f -- "$path.tmp" "$path"
}

write_keys() {
  install -d -m 700 /etc/wireguard
  chmod 700 /etc/wireguard
  if [[ $PRIV_ACTION != keep ]]; then
    write_key "$WG_PRIVATE_KEY_FILE" "$NEW_PRIV"
    ok "wrote private key ($PRIV_ACTION)"
  else
    chown root:root "$WG_PRIVATE_KEY_FILE"; chmod 600 "$WG_PRIVATE_KEY_FILE"
  fi
  case $PSK_ACTION in
    generated|pasted)
      write_key "$WG_PRESHARED_KEY_FILE" "$NEW_PSK"
      ok "wrote pre-shared key ($PSK_ACTION)" ;;
    keep)
      chown root:root "$WG_PRESHARED_KEY_FILE"; chmod 600 "$WG_PRESHARED_KEY_FILE" ;;
    none)
      # Remove a pre-shared key that is no longer used.
      rm -f "$WGR_PSK_DEFAULT" ;;
  esac
  NEW_PRIV=""
}

# =============================================================================
# Rendering (into a staging directory; nothing is installed yet)
# =============================================================================
render_all() {
  local egress masq postup peer v4 v6 ct
  STAGE=$(mktemp -d /tmp/wg-relay.XXXXXX)

  # Single quotes are intentional below: $WG_IF etc. are nft variables.
  # shellcheck disable=SC2016
  if [[ $RELAY_EGRESS == yes ]]; then
    egress='iifname $WG_IF oifname $WAN_IF ip saddr @peer_nets accept comment "relay egress: peer -> Internet"'
  else
    egress='# relay egress disabled (RELAY_EGRESS=no)'
  fi
  # shellcheck disable=SC2016
  if [[ $RELAY_EGRESS == yes && $MASQUERADE_EGRESS == yes ]]; then
    masq='oifname $WAN_IF ip saddr @peer_nets masquerade comment "relay egress NAT"'
  else
    masq='# masquerade disabled (RELAY_EGRESS / MASQUERADE_EGRESS)'
  fi
  render_template "$SCRIPT_DIR/templates/wg-relay.nft" "$STAGE/wg-relay.nft" \
    "WAN_IF=$WAN_IF" \
    "WG_IF=$WG_INTERFACE" \
    "WG_PORT=$((10#$WG_PORT))" \
    "PEER_ADDR=$PEER_HOST" \
    "SSH_ELEMENTS=$(nft_elements "$SSH_PORTS_NORM")" \
    "PEER_NETS_ELEMENTS=$(nft_elements "$PEER_ALLOWED_NORM")" \
    "FWD_TCP_ELEMENTS=$(nft_elements "$FWD_TCP_NORM")" \
    "FWD_UDP_ELEMENTS=$(nft_elements "$FWD_UDP_NORM")" \
    "TUNNEL_TCP_ELEMENTS=$(nft_elements "$TUNNEL_TCP_NORM")" \
    "EGRESS_RULE=$egress" \
    "MASQ_RULE=$masq"

  postup="PostUp = wg set %i private-key $WG_PRIVATE_KEY_FILE"
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then
    if psk_enabled; then
      postup+=$'\n'"PostUp = wg set %i peer $WG_PEER_PUBLIC_KEY preshared-key $WG_PRESHARED_KEY_FILE"
    fi
    peer="[Peer]"$'\n'"# OPNsense. It initiates the tunnel, so no Endpoint is configured here."
    peer+=$'\n'"PublicKey = $WG_PEER_PUBLIC_KEY"$'\n'"AllowedIPs = $PEER_ALLOWED_NORM"
  else
    peer="# No peer yet: set WG_PEER_PUBLIC_KEY in config.env and re-run install.sh."
  fi
  render_template "$SCRIPT_DIR/templates/wg0.conf" "$STAGE/$WG_INTERFACE.conf" \
    "WG_SERVER_ADDRESS=$WG_SERVER_ADDRESS" \
    "WG_PORT=$((10#$WG_PORT))" \
    "WG_MTU=$WG_MTU" \
    "POSTUP=$postup" \
    "PEER_SECTION=$peer"

  if [[ $ENABLE_IPV4_FORWARDING == yes ]]; then v4=1; else v4=0; fi
  if [[ $ENABLE_IPV6_FORWARDING == yes ]]; then
    v6="net.ipv6.conf.all.forwarding = 1"
    v6+=$'\n'"# Forwarding normally makes Linux ignore router advertisements. Keep accepting"
    v6+=$'\n'"# them on the WAN, or a SLAAC-configured VPS loses its IPv6 default route."
    v6+=$'\n'"net.ipv6.conf.${WAN_IF//./\/}.accept_ra = 2"
  else
    v6="net.ipv6.conf.all.forwarding = 0"
  fi
  if [[ -n $CONNTRACK_MAX ]]; then
    ct="net.netfilter.nf_conntrack_max = $CONNTRACK_MAX"
  else
    ct="# kernel default (CONNTRACK_MAX is empty)"
  fi
  render_template "$SCRIPT_DIR/templates/sysctl.conf" "$STAGE/sysctl.conf" \
    "IPV4_FORWARD=$v4" "IPV6_BLOCK=$v6" "CONNTRACK_LINE=$ct"

  render_template "$SCRIPT_DIR/templates/wg-relay-firewall.service" "$STAGE/$WGR_UNIT_NAME" \
    "NFT_FILE=$WGR_NFT"

  nft -c -f "$STAGE/wg-relay.nft" >&3 2>&3 \
    || die "generated firewall rules failed validation (nft -c); nothing was changed"
  wg-quick strip "$STAGE/$WG_INTERFACE.conf" >/dev/null 2>&3 \
    || die "generated WireGuard config failed to parse; nothing was changed"
  ok "rendered and validated configuration"
}

show_diffs() {
  local pair src dst cmpdst changes=0
  for pair in \
      "$CONFIG_SRC:$WGR_CONFIG" \
      "$STAGE/$WG_INTERFACE.conf:/etc/wireguard/$WG_INTERFACE.conf" \
      "$STAGE/wg-relay.nft:$WGR_NFT" \
      "$STAGE/sysctl.conf:$WGR_SYSCTL" \
      "$STAGE/$WGR_UNIT_NAME:$WGR_UNIT"; do
    src=${pair%%:*}
    dst=${pair#*:}
    if ! cmp -s "$src" "$dst"; then
      changes=1
      note "Would change: $dst"
      cmpdst=$dst
      [[ -e $dst ]] || cmpdst=/dev/null
      diff -u --label "$dst (installed)" --label "$dst (new)" "$cmpdst" "$src" || true
    fi
  done
  if (( ! changes )); then note "No changes."; fi
}

fw_rollback_now() {
  systemctl stop "$WGR_ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  if [[ -n $ROLLBACK_CMD ]]; then
    /bin/sh -c "$ROLLBACK_CMD" >/dev/null 2>&1 || true
  fi
  FW_PENDING=0
  warn "previous firewall rules restored"
}

# Load new rules live with a dead-man switch. The saved copy is only replaced
# AFTER confirmation, so a reboot also returns to the last confirmed rules.
guarded_firewall_load() {
  local new=$1 answer=""
  if [[ -f $WGR_NFT ]]; then
    ROLLBACK_CMD="/usr/sbin/nft -f $WGR_NFT"
  else
    ROLLBACK_CMD="/usr/sbin/nft delete table inet wg_relay"
  fi

  if (( NO_CONFIRM )); then
    nft -f "$new"
    return 0
  fi

  # A transient systemd timer still fires if this SSH session dies.
  systemctl stop "$WGR_ROLLBACK_UNIT.timer" "$WGR_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$WGR_ROLLBACK_UNIT.timer" "$WGR_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$WGR_ROLLBACK_UNIT" \
    --description="wg-relay firewall auto-rollback" \
    --on-active="${ROLLBACK_TIMEOUT}s" --timer-property=AccuracySec=1s \
    /bin/sh -c "$ROLLBACK_CMD"
  FW_PENDING=1

  nft -f "$new"

  say "" "Firewall rules applied. They roll back in ${ROLLBACK_TIMEOUT} seconds unless kept." \
      "Open a new SSH session to this server to check access."
  printf 'Keep the new firewall rules? [y/N] ' >/dev/tty
  if read -r -t $(( ROLLBACK_TIMEOUT - 10 )) answer </dev/tty && [[ ${answer,,} == y || ${answer,,} == yes ]]; then
    logf "Keep the new firewall rules? y"
    if ! systemctl is-active --quiet "$WGR_ROLLBACK_UNIT.timer"; then
      FW_PENDING=0
      die "the rollback timer already fired; re-run install.sh"
    fi
    systemctl stop "$WGR_ROLLBACK_UNIT.timer"
    FW_PENDING=0
  else
    printf '\n' >/dev/tty
    fw_rollback_now
    die "firewall rules not kept; previous rules restored. Check SSH_PORTS in config.env and re-run"
  fi
}

apply_firewall() {
  local new="$STAGE/wg-relay.nft" newunit="$STAGE/$WGR_UNIT_NAME"
  local rules_changed=0 unit_changed=0
  cmp -s "$new" "$WGR_NFT" || rules_changed=1
  cmp -s "$newunit" "$WGR_UNIT" || unit_changed=1

  if (( rules_changed )); then
    guarded_firewall_load "$new"
    install -m 644 "$new" "$WGR_NFT"
    ok "firewall rules saved to $WGR_NFT"
  else
    ok "firewall rules unchanged"
  fi
  if (( unit_changed )); then
    install -m 644 "$newunit" "$WGR_UNIT"
    systemctl daemon-reload
  fi
  systemctl enable --quiet "$WGR_UNIT_NAME"
  if ! systemctl is-active --quiet "$WGR_UNIT_NAME"; then
    systemctl start "$WGR_UNIT_NAME"
  elif ! nft list table inet wg_relay >/dev/null 2>&1; then
    warn "firewall table was missing; reloading the saved rules"
    systemctl restart "$WGR_UNIT_NAME"
  fi
}

apply_sysctl() {
  if [[ -n $CONNTRACK_MAX ]]; then
    printf '# wg-relay: load conntrack early so nf_conntrack_max applies at boot\nnf_conntrack\n' >"$STAGE/modules.conf"
    cmp -s "$STAGE/modules.conf" "$WGR_MODULES" || install -m 644 "$STAGE/modules.conf" "$WGR_MODULES"
    modprobe nf_conntrack
  elif [[ -e $WGR_MODULES ]]; then
    rm -f -- "$WGR_MODULES"
  fi
  if ! cmp -s "$STAGE/sysctl.conf" "$WGR_SYSCTL"; then
    install -m 644 "$STAGE/sysctl.conf" "$WGR_SYSCTL"
  fi
  # -e: ignore keys that don't exist (e.g. IPv6 disabled on this host).
  sysctl -q -e -p "$WGR_SYSCTL" >&3 2>&3 || die "failed to apply $WGR_SYSCTL"
  ok "kernel settings applied"
}

wg_iface_section() { sed '/^\[Peer\]/,$d' "$1"; }

apply_wireguard() {
  local new="$STAGE/$WG_INTERFACE.conf" cur="/etc/wireguard/$WG_INTERFACE.conf"
  local svc="wg-quick@$WG_INTERFACE.service" changed=0 iface_changed=0

  if ! cmp -s "$new" "$cur"; then
    changed=1
    if [[ -f $cur ]] && ! cmp -s <(wg_iface_section "$cur") <(wg_iface_section "$new"); then
      iface_changed=1
    fi
    install -m 600 "$new" "$cur"
  fi

  systemctl enable --quiet "$svc"
  if ! systemctl is-active --quiet "$svc"; then
    systemctl start "$svc" || die "WireGuard failed to start; see: journalctl -u $svc"
    ok "started WireGuard ($WG_INTERFACE)"
  elif (( iface_changed )); then
    systemctl restart "$svc" || die "WireGuard failed to restart; see: journalctl -u $svc"
    ok "restarted WireGuard ($WG_INTERFACE) to apply interface changes"
  elif (( changed )); then
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    ok "updated the WireGuard peer live (no restart)"
  else
    ok "WireGuard unchanged"
  fi

  # Keys live outside the config, so (re)apply them explicitly.
  if (( changed )) || [[ $(wg show "$WG_INTERFACE" public-key 2>/dev/null) != "$SERVER_PUBKEY" ]]; then
    wg set "$WG_INTERFACE" private-key "$WG_PRIVATE_KEY_FILE"
  fi
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then
    if psk_enabled; then
      wg set "$WG_INTERFACE" peer "$WG_PEER_PUBLIC_KEY" preshared-key "$WG_PRESHARED_KEY_FILE"
    else
      wg set "$WG_INTERFACE" peer "$WG_PEER_PUBLIC_KEY" preshared-key /dev/null
    fi
  fi
}

# =============================================================================
# Post-install checks (failures only on screen)
# =============================================================================
vcheck() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    ok "check passed: $desc"
  else
    err "check failed: $desc"
    VFAILS=$((VFAILS + 1))
  fi
}

t_link_up() { ip -j link show dev "$WG_INTERFACE" | jq -e '.[0].flags | index("UP") != null'; }
t_addr()    { ip -j -4 addr show dev "$WG_INTERFACE" | jq -e --arg a "$SERVER_HOST" '[.[0].addr_info[]? | select(.local == $a)] | length > 0'; }
t_port()    { [[ $(wg show "$WG_INTERFACE" listen-port) == "$((10#$WG_PORT))" ]]; }
t_pubkey()  { [[ $(wg show "$WG_INTERFACE" public-key) == "$SERVER_PUBKEY" ]]; }
t_table()   { nft list table inet wg_relay; }
t_fwd4()    { [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]; }
t_peer()    { wg show "$WG_INTERFACE" peers | grep -qxF -- "$WG_PEER_PUBLIC_KEY"; }

validate_install() {
  local svc="wg-quick@$WG_INTERFACE.service"
  VFAILS=0
  vcheck "$svc active"                  systemctl is-active --quiet "$svc"
  vcheck "$svc enabled at boot"         systemctl is-enabled --quiet "$svc"
  vcheck "$WG_INTERFACE up"             t_link_up
  vcheck "$WG_INTERFACE has $WG_SERVER_ADDRESS" t_addr
  vcheck "listening on UDP $WG_PORT"    t_port
  vcheck "interface uses the key on disk" t_pubkey
  vcheck "$WGR_UNIT_NAME active"        systemctl is-active --quiet "$WGR_UNIT_NAME"
  vcheck "$WGR_UNIT_NAME enabled at boot" systemctl is-enabled --quiet "$WGR_UNIT_NAME"
  vcheck "firewall table loaded"        t_table
  if [[ $ENABLE_IPV4_FORWARDING == yes ]]; then vcheck "IPv4 forwarding on" t_fwd4; fi
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then vcheck "peer configured" t_peer; fi
  (( VFAILS == 0 )) || die "$VFAILS check(s) failed; run: sudo wg-relay-diagnostics"
}

handshake_line() {
  local ts now
  ts=$(wg show "$WG_INTERFACE" latest-handshakes | awk -v k="$WG_PEER_PUBLIC_KEY" '$1 == k {print $2}')
  now=$(date +%s)
  if [[ $ts =~ ^[0-9]+$ ]] && (( ts > 0 )); then
    note "Tunnel is up (last handshake $((now - ts))s ago)."
  else
    note "Tunnel is waiting for OPNsense to connect."
  fi
}


# =============================================================================
# Summary: every OPNsense setting, with anything you must paste marked (new).
# =============================================================================
srow() { note "$(printf '    %-15s %s' "$1" "$2")"; }

print_summary() {
  local pubip prefix
  pubip=$(public_ipv4 "$WAN_IF" || true)
  prefix=${WG_SERVER_ADDRESS#*/}

  note "" "OPNsense settings (VPN > WireGuard):"
  note "  Instances > (instance)"
  if [[ -n $WG_PEER_PUBLIC_KEY ]]; then
    key_row "    " 15 "Public key" "$WG_PEER_PUBLIC_KEY" "$INST_ACTION"
  else
    key_row "    " 15 "Public key" "not set"
  fi
  srow "Tunnel address" "$PEER_HOST/$prefix"
  srow "MTU" "$WG_MTU"
  srow "Disable routes" "checked"
  note "  Peers > (peer)"
  key_row "    " 15 "Public key" "$SERVER_PUBKEY" "$(pub_tag)"
  if [[ $PSK_ACTION == none ]]; then
    key_row "    " 15 "Pre-shared key" "none"
  else
    key_row "    " 15 "Pre-shared key" "$(psk_value)" "$(psk_tag)"
  fi
  NEW_PSK=""
  srow "Endpoint" "${pubip:-the VPS public IP} or your relay DNS name, port $((10#$WG_PORT))"
  srow "Allowed IPs" "0.0.0.0/0"
  srow "Keepalive" "25"
  note "  System > Gateways"
  srow "Gateway" "$SERVER_HOST"
  note ""
  note "OPNsense must match every key above."
  if [[ $PSK_ACTION == generated ]]; then
    note "The pre-shared key is shown in full only now; later: ${SUDO_USER:+sudo }cat $WG_PRESHARED_KEY_FILE"
  fi
  note ""

  if [[ -z $WG_PEER_PUBLIC_KEY ]]; then
    note "To finish: run ./install.sh again and enter the instance public key."
  else
    if [[ $MODE == migrate ]]; then
      note "Point your relay DNS name and the OPNsense LTE static route at this VPS."
    fi
    handshake_line
  fi
  note "Export: ./install.sh --export    Status: ${SUDO_USER:+sudo }wg-relay-status    Log: $LOG"
}

# =============================================================================
# Main
# =============================================================================
main() {
  require_root
  if (( DO_EXPORT )); then
    exec "$SCRIPT_DIR/scripts/export.sh"
  fi
  open_log "$ORIG_ARGS"
  exec 9>/run/wg-relay-install.lock
  flock -n 9 || die "another install.sh is already running"
  note "wg-relay $WGR_VERSION"

  [[ -f $CONFIG_SRC ]] || die "config not found: $CONFIG_SRC"
  if (( DO_IMPORT && (NO_PROMPT || DRY_RUN) )); then
    die "--import needs a terminal to paste into; it can't be combined with --no-prompt or --dry-run"
  fi

  # 1. Checks that change nothing.
  load_config "$CONFIG_SRC"
  validate_config_static || die "config.env has $CFG_ERRORS error(s); nothing was changed"
  check_os
  check_virtualization
  check_tty
  if (( ! NO_PROMPT && ! DRY_RUN )) && { : </dev/tty; } 2>/dev/null; then INTERACTIVE=1; fi
  if (( DO_IMPORT && ! INTERACTIVE )); then die "--import needs an interactive terminal"; fi

  # 2. Packages first, so detection works and all questions come together.
  step "Installing packages"
  ensure_packages
  ensure_wireguard_module
  step_end "$PKG_RESULT"

  # 3. Installation type, keys, then the plan and "continue?".
  if (( DO_IMPORT )); then MODE=migrate
  elif (( INTERACTIVE )); then choose_mode
  else MODE=reconfigure; fi
  collect_keys

  resolve_wan
  resolve_ssh_ports
  validate_config_dynamic || die "config.env conflicts with this host ($CFG_ERRORS error(s)); nothing was changed"
  inventory_firewalls
  render_all

  if (( DRY_RUN )); then
    note "" "The following would be configured:"
    show_plan
    note ""
    show_diffs
    return 0
  fi
  confirm_plan

  # 4. Unattended from here (apart from the SSH access check).
  step "Writing configuration and keys"
  install_support_files
  write_keys
  step_end

  step "Configuring firewall"
  apply_firewall
  step_end

  step "Configuring WireGuard"
  apply_sysctl
  apply_wireguard
  step_end

  step "Checking installation"
  validate_install
  step_end

  print_summary
}

main
