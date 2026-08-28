#!/usr/bin/env bash
# fwf-gate-revoke.sh — issue #237 AC (k2): the human/captain-facing side of
# gate-fingerprint revocation. Populating the list is a governance decision
# this script does not make; it only makes the mechanism reachable once
# someone has decided a fingerprint should be revoked.
#
# Usage: fwf gate-revoke <fingerprint> [reason]
#   Appends <fingerprint> to $FWF_STATE_DIR/gate-revoked-fingerprints
#   (idempotent — revoking the same fingerprint twice is a no-op, not a
#   duplicate entry). Every `fwf gate-promote` call thereafter refuses any
#   green record carrying this fingerprint.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf gate-revoke <fingerprint> [reason]" >&2; }

fingerprint="${1:-}"
if [ -z "$fingerprint" ]; then usage; exit 2; fi
reason="${2:-}"

fwf_gate_revoke_fingerprint "$fingerprint" "$reason"
echo "fwf gate-revoke: $fingerprint is now revoked — every fwf gate-promote will refuse a green record carrying it"
