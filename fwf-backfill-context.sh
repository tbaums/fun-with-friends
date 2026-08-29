#!/usr/bin/env bash
# fwf-backfill-context.sh — issue #212: recover the 16 (or however many, at
# time of running) hollow history cards #189/#135 fixed the extractor for,
# WITHOUT rewriting any commit. Attaches the corrected card as a git note
# under a dedicated ref (refs/notes/fwf-context, never refs/notes/commits,
# so this can never collide with a contributor's own notes usage).
#
# Usage: fwf backfill-context [--to REF] [--force] [--push] [--dry-run]
#   --to REF     scan history reachable from REF (default: origin/main).
#   --force      overwrite a commit's existing note (default: skip it).
#   --push       push refs/notes/fwf-context to origin after writing.
#                Without this, notes are written LOCALLY ONLY -- inspect
#                with `git log --notes=fwf-context` before pushing for real.
#   --dry-run    list what would be backfilled; writes nothing.
#
# Mechanical identification (AC b): a commit is "affected" iff its subject
# carries this repo's squash-merge signature "(#<num>)", its card is hollow
# (every bucket "_(none logged)_"), and its linked issue genuinely has
# extractable content -- the exact predicate issue #136's guard uses,
# reused rather than re-derived (fwf_backfill_is_affected, lib/pr_context.sh).
#
# Idempotent (AC c/f): a commit that already has a note is left alone unless
# --force is passed. Never rewrites (AC d): git notes live in a SEPARATE ref
# from the commit object; this script asserts the SHA is unchanged after
# every write, as a hard refusal, not an assumption.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() { echo "usage: fwf backfill-context [--to REF] [--force] [--push] [--dry-run]" >&2; }

to="origin/main"
force=0
push=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to="${2:-}"; [ -n "$to" ] || { usage; exit 1; }; shift 2 ;;
    --force) force=1; shift ;;
    --push) push=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

NOTES_REF="refs/notes/fwf-context"

# Every git operation below (log, rev-parse, notes, push) must run IN the
# target repo, not wherever this was invoked from -- a bare `git` call
# operates on the CALLER's cwd, and this is a standalone tool a human or
# CI job may run from anywhere. Matches the cd-into-$FWF_REPO pattern
# lib/pr_context.sh's own gh-backed helpers already use.
[ -n "${FWF_REPO:-}" ] && [ -d "$FWF_REPO/.git" ] || { echo "fwf backfill-context: \$FWF_REPO ('${FWF_REPO:-<unset>}') is not a git repo" >&2; exit 1; }
cd "$FWF_REPO" || { echo "fwf backfill-context: could not cd into \$FWF_REPO ($FWF_REPO)" >&2; exit 1; }

affected="$(fwf_backfill_find_affected "$to")"
if [ -z "$affected" ]; then
  echo "fwf backfill-context: nothing to backfill (no hollow cards found reachable from $to)"
  exit 0
fi

wrote=0
skipped=0
failed=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  if git notes --ref="$NOTES_REF" show "$sha" >/dev/null 2>&1 && [ "$force" != 1 ]; then
    echo "skip $sha (already has a note under $NOTES_REF; pass --force to overwrite)"
    skipped=$((skipped + 1))
    continue
  fi
  note="$(fwf_backfill_note_for "$sha")" || {
    echo "fwf backfill-context: could not build a note for $sha (unresolvable linked issue) -- skipping, listed here rather than guessed at" >&2
    failed=$((failed + 1))
    continue
  }
  if [ "$dry_run" = 1 ]; then
    echo "[dry-run] would backfill $sha"
    wrote=$((wrote + 1))
    continue
  fi
  before_sha="$(git rev-parse "$sha")"
  git notes --ref="$NOTES_REF" add -f -m "$note" "$sha"
  after_sha="$(git rev-parse "$sha")"
  if [ "$before_sha" != "$after_sha" ]; then
    echo "fwf backfill-context: REFUSING to continue -- $sha's own SHA changed during backfill ($before_sha -> $after_sha), which must never happen (git notes live in a separate ref)" >&2
    exit 1
  fi
  echo "backfilled $sha"
  wrote=$((wrote + 1))
done <<< "$affected"

echo "fwf backfill-context: $wrote backfilled, $skipped skipped (already noted), $failed failed"

if [ "$push" = 1 ] && [ "$dry_run" != 1 ] && [ "$wrote" -gt 0 ]; then
  if ! git push origin "$NOTES_REF"; then
    echo "fwf backfill-context: push of $NOTES_REF failed -- notes were written LOCALLY only; retry the push (do not re-run the backfill first, it will just re-skip the commits you already noted)" >&2
    exit 1
  fi
  echo "fwf backfill-context: pushed $NOTES_REF"
fi
