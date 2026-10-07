#!/usr/bin/env bash
# =============================================================================
# wg-relay — export.sh   (also: ./install.sh --export, wg-relay-export)
#
# Prints a migration block: every config.env setting plus this VPS's keys.
# On the new VPS, run ./install.sh --import and paste the block.
#
# THE BLOCK CONTAINS SECRET KEYS. It is only printed, never saved to a file.
# =============================================================================
set -Eeuo pipefail

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
# shellcheck source=../lib/common.sh
. "$(dirname -- "$SELF")/../lib/common.sh"

require_root
[[ -f $WGR_CONFIG ]] || die "wg-relay is not installed on this VPS ($WGR_CONFIG missing)"
load_config "$WGR_CONFIG"
[[ -f $WG_PRIVATE_KEY_FILE ]] || die "private key not found: $WG_PRIVATE_KEY_FILE"

print_migration_block
printf '\nW: this block contains secret keys. Paste it only into the new VPS: ./install.sh --import\n' >&2
