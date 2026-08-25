#!/usr/bin/env bash
# scripts/assert-release-assets.sh -- issue #209: assert a GitHub release's
# PUBLISHED asset set against the declarative dash-targets.json manifest,
# EXACTLY, before anyone is allowed to download it.
#
# WHY A STANDALONE SCRIPT, NOT A WORKFLOW-EMBEDDED BASH BLOCK: every fixture
# the ACs need (a dropped upload, an extended matrix, the v0.27.4 shape)
# would otherwise mean cutting throwaway tags/releases against this repo to
# exercise -- slow, noisy, outward-facing, and it will quietly become "we
# tested the happy path and reasoned about the rest." As a standalone unit
# it's an ordinary fixture test under the gate (see test/run.sh).
#
# WHY THE EXPECTED SET COMES FROM THE MANIFEST, NEVER FROM THE RUN'S OWN
# OUTPUTS: deriving the expectation from what the build legs actually
# produced (job outputs, artifact manifests) makes the check TAUTOLOGICAL --
# a leg that skips its upload also drops its own expectation, so the
# expected set shrinks to match the actual set and the check passes on
# EXACTLY the v0.27.4 failure it exists to catch. dash-targets.json is the
# single declared source of truth; nothing here may derive an expectation
# from anything else, and release.yml's matrix is built FROM this same file
# (see the load-targets job), never the other way around.
#
# Usage: assert-release-assets.sh <version> [--allow-extra NAME]...
#   <version>       the release version, e.g. 0.30.3 (no leading "v").
#   --allow-extra   an asset name to excuse from the "unexpected" check.
#                   Repeatable. A DELIBERATE, reviewable exception (issue
#                   #209 AC c) -- named distinctly in the passing output, so
#                   a release that passed WITH an exception never reads
#                   identically to a clean one in the artifact a reviewer
#                   actually reads.
#
# Reads dash-targets.json (or $ASSERT_RELEASE_MANIFEST) for the expected
# target slugs, and the ACTUAL published set via `gh release view --json
# assets` (or $ASSERT_RELEASE_GH) -- never a local file/artifact listing (AC
# e): the v0.27.4 failure was an upload that never landed, which a check
# over the workflow's own local file list would have missed entirely.
#
# Exit codes:
#   0 = exact match (asset set matches the manifest-derived expectation,
#       modulo any --allow-extra).
#   1 = MISMATCH -- missing and/or unexpected assets. Both lists are named
#       explicitly in the output, never just a count or a boolean.
#   2 = COULD NOT VERIFY -- gh failed on every retry (rate limit / API
#       outage), or a usage/setup error (bad args, jq missing, no manifest).
#       Distinguishable from both pass (0) and fail (1): a read that cannot
#       complete must not collapse into a confident value -- "UNKNOWN", not
#       a silent pass or a misleading "assets missing".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GH="${ASSERT_RELEASE_GH:-gh}"
MANIFEST="${ASSERT_RELEASE_MANIFEST:-$DIR/dash-targets.json}"
# Retry bound for reading the published set (edge case: eventual consistency
# right after upload/publish). Named, not left to taste, so the output can
# say how long it waited: 3 attempts, 10s apart -- ~20s of extra wait past
# the first try, ~30s worst case total. A slow-but-eventually-correct read
# and a genuinely missing asset must never look the same in the log.
RETRIES="${ASSERT_RELEASE_RETRIES:-3}"
RETRY_DELAY="${ASSERT_RELEASE_RETRY_DELAY:-10}"

usage() { echo "usage: assert-release-assets.sh <version> [--allow-extra NAME]..." >&2; }

version="${1:-}"
[ -n "$version" ] || { usage; exit 2; }
shift

allow_extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-extra)
      [ $# -ge 2 ] || { usage; exit 2; }
      allow_extra+=("$2"); shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
tag="v$version"

command -v jq >/dev/null 2>&1 || { echo "assert-release-assets: jq is required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "assert-release-assets: manifest not found: $MANIFEST" >&2; exit 2; }

# --- expected set: DERIVED FROM THE MANIFEST ONLY (AC j / d2) ---------------
expected=("fwf-${version}.tar.gz" "fwf-dash-${version}-checksums.txt")
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  expected+=("fwf-dash-${version}-${slug}")
done < <(jq -r '.targets[].slug' "$MANIFEST" 2>/dev/null)
[ "${#expected[@]}" -ge 3 ] || { echo "assert-release-assets: manifest has no targets — refusing to assert an empty expectation" >&2; exit 2; }

# --- actual set: THE PUBLISHED VIEW, WITH A BOUNDED RETRY (AC e, edge case) --
actual_raw=""
attempt=1
ok=0
while [ "$attempt" -le "$RETRIES" ]; do
  if actual_raw="$("$GH" release view "$tag" --json assets -q '.assets[].name' 2>/dev/null)"; then
    ok=1
    break
  fi
  [ "$attempt" -lt "$RETRIES" ] && sleep "$RETRY_DELAY"
  attempt=$(( attempt + 1 ))
done
if [ "$ok" -ne 1 ]; then
  echo "assert-release-assets: UNKNOWN — could not read the published asset set for $tag after $RETRIES attempts (~$(( (RETRIES - 1) * RETRY_DELAY ))s waited) — gh failed every time (rate limit / API outage?)" >&2
  exit 2
fi
if [ "$attempt" -gt 1 ]; then
  echo "assert-release-assets: read the published set after $(( attempt - 1 )) retr$([ "$(( attempt - 1 ))" = 1 ] && echo y || echo ies) (~$(( (attempt - 1) * RETRY_DELAY ))s waited)"
fi

# --- exact-set comparison (AC a/b/c) -----------------------------------------
actual=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  actual+=("$name")
done <<< "$actual_raw"

_contains() { # $1=needle; remaining args=haystack
  local needle="$1" hay; shift
  for hay in "$@"; do [ "$hay" = "$needle" ] && return 0; done
  return 1
}

missing=()
for e in "${expected[@]}"; do
  _contains "$e" "${actual[@]:-}" || missing+=("$e")
done

unexpected=()
allowed_seen=()
for a in "${actual[@]:-}"; do
  [ -n "$a" ] || continue
  _contains "$a" "${expected[@]}" && continue
  if _contains "$a" "${allow_extra[@]:-}"; then
    allowed_seen+=("$a")
  else
    unexpected+=("$a")
  fi
done

if [ "${#missing[@]}" -gt 0 ] || [ "${#unexpected[@]}" -gt 0 ]; then
  echo "assert-release-assets: MISMATCH for $tag" >&2
  [ "${#missing[@]}" -gt 0 ]    && printf 'assert-release-assets: missing: %s\n'    "${missing[*]}" >&2
  [ "${#unexpected[@]}" -gt 0 ] && printf 'assert-release-assets: unexpected: %s\n' "${unexpected[*]}" >&2
  exit 1
fi

echo "assert-release-assets: OK — $tag published exactly the expected ${#expected[@]} assets: ${expected[*]}"
if [ "${#allowed_seen[@]}" -gt 0 ]; then
  echo "assert-release-assets: NOTE — passed WITH an allowed exception: ${allowed_seen[*]}"
fi
exit 0
