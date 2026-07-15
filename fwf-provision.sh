#!/usr/bin/env bash
# Provision worktrees + isolated dev-data for the selected profile (idempotent,
# additive). Creates: impl1-3 (+ paired qa1-3), pm, gv, captain, conductor.
# Optionally warms each worktree's build.
#
# Usage: [FWF_PROFILE=example] fwf-provision.sh [--build]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
log() { printf '[fwf-provision %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

DO_BUILD=false
[ "${1:-}" = "--build" ] && DO_BUILD=true

cd "$FWF_REPO"
mkdir -p "$FWF_RUN"
gh auth status >/dev/null 2>&1 || log "WARNING: gh is not authenticated. Run 'gh auth login'."

# Ensure the staging + integration branches exist. The ladder must be
# continuous: integration branches from main, and staging from the CURRENT
# integration tip (NOT main) — otherwise staging diverges from any work already
# on integration and the conductor's ff-only promote fails.
#
# LOCAL ISSUES MODE (#28): the remote is typically NOT operator-controlled, so
# the ladder is created as LOCAL branches only and NOTHING is pushed — a
# pre-push guard (below) hard-blocks every push unless a human sets
# FWF_ALLOW_PUSH=1 for that specific push.
# The no-push guard: installed in local mode, removed (if ours) in gh mode.
# Hooks live in the shared git dir, so every worktree/agent inherits it. This
# block must run BEFORE ensure_branch below — a gh-mode provision on a repo
# that previously ran local mode has the guard installed, and would otherwise
# block its own ladder push.
HOOK="$(git -C "$FWF_REPO" rev-parse --absolute-git-dir)/hooks/pre-push"
if [ "$FWF_ISSUES" = "local" ]; then
  if [ -e "$HOOK" ] && ! grep -q "fwf no-push guard" "$HOOK"; then
    log "WARNING: a pre-push hook already exists at $HOOK — NOT overwriting. Add the fwf no-push guard to it yourself, or pushes will NOT be blocked."
  else
    cat > "$HOOK" <<'GUARD'
#!/usr/bin/env sh
# fwf no-push guard — installed by fwf-provision in --issues local mode.
# This repo's remote may not be operator-controlled: ALL pushes are blocked
# unless a HUMAN explicitly authorizes this one with FWF_ALLOW_PUSH=1.
[ "${FWF_ALLOW_PUSH:-0}" = "1" ] && exit 0
echo "fwf: push BLOCKED — fun-with-friends runs here in local-issues mode and never pushes without explicit human permission." >&2
echo "fwf: a human can authorize a single push with:  FWF_ALLOW_PUSH=1 git push ..." >&2
exit 1
GUARD
    chmod +x "$HOOK"
    log "no-push guard installed ($HOOK): every push is blocked unless FWF_ALLOW_PUSH=1"
  fi
elif [ -e "$HOOK" ] && grep -q "fwf no-push guard" "$HOOK"; then
  rm -f "$HOOK"
  log "removed the fwf no-push guard (gh mode)"
fi

git fetch origin -q
ensure_branch() { # $1=branch  $2=base-branch (created from origin/$2 if missing)
  git show-ref --verify --quiet "refs/heads/$1" \
    || { log "creating $1 from $2"; git branch "$1" "origin/$2" 2>/dev/null || git branch "$1" "$2"; }
  [ "$FWF_ISSUES" = "gh" ] || return 0   # local mode: never create remote branches
  git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1 \
    || { log "pushing $1 to origin"; git push -u origin "$1"; }
}
ensure_branch "$INTEGRATION_BRANCH" "$DEFAULT_BRANCH"
ensure_branch "$STAGING_BRANCH"     "$INTEGRATION_BRANCH"

if [ "$FWF_ISSUES" = "gh" ]; then
  # Ensure the PM draft label exists (implementers skip issues that carry it).
  gh label create "$WIP_LABEL" --description "PM draft / product WIP — not ready; implementers skip until this label is removed" --color FBCA04 --force >/dev/null 2>&1 \
    && log "ensured label '$WIP_LABEL'" || log "label '$WIP_LABEL' ensure skipped (gh not ready?)"
  # Ensure the release-freeze hold label exists (implementers skip held issues until the PM lifts it post-release).
  gh label create "$HOLD_LABEL" --description "Held for a future release — implementers skip until the PM lifts it after the current release" --color 0052CC --force >/dev/null 2>&1 \
    && log "ensured label '$HOLD_LABEL'" || log "label '$HOLD_LABEL' ensure skipped (gh not ready?)"
  # Ensure the needs-captain label exists (issue #113, AC7) — belt-and-suspenders
  # alongside fwf-flag-captain.sh's own create-if-absent on every raise.
  gh label create "$NEEDS_CAPTAIN_LABEL" --description "Something needs the captain's attention — see the NEEDS-CAPTAIN: comment" --color D93F0B --force >/dev/null 2>&1 \
    && log "ensured label '$NEEDS_CAPTAIN_LABEL'" || log "label '$NEEDS_CAPTAIN_LABEL' ensure skipped (gh not ready?)"
else
  # Local issues mode (#26): labels are free-form strings in the local store —
  # nothing to create on GitHub, and we must NOT touch the repo's labels.
  mkdir -p "$FWF_ISSUES_DIR/open"
  log "local issue store ready at $FWF_ISSUES_DIR (no GitHub labels touched)"
  # gh-write guard (#34): panes get this dir first on PATH — gh mutations
  # blocked (FWF_ALLOW_GH=1 to authorize one), and `fwf` always resolvable.
  fwf_install_ghguard
  log "gh-write guard installed ($FWF_GHGUARD_DIR): gh mutations blocked in panes unless FWF_ALLOW_GH=1"
fi

add_branch_wt() { # $1=tag  $2=branch
  local d; d="$(wt_dir "$1")"
  [ -d "$d" ] && { log "exists: $d"; return; }
  log "worktree $d ($2)"
  git worktree add "$d" -b "$2" "$DEFAULT_BRANCH" 2>/dev/null || git worktree add "$d" "$2"
}
add_detached_wt() { # $1=tag
  local d; d="$(wt_dir "$1")"
  [ -d "$d" ] && { log "exists: $d"; return; }
  log "worktree $d (detached)"
  git worktree add --detach "$d" "$DEFAULT_BRANCH"
}
warm() { # $1=tag
  $DO_BUILD || return 0
  log "build: $(wt_dir "$1")"
  ( cd "$(wt_dir "$1")" && eval "$BUILD_CMD" ) || log "build FAILED: $1"
}

# A worktree-less role (FWF_NO_WORKTREE_ROLES — e.g. a source-blind user-testing
# persona) gets a throwaway scratch dir instead of a checkout (and no seed/warm,
# since there is no source to build). A suppressed role gets nothing at all.
ut_scratch() { # $1=role tag — create + announce the role's scratch dir
  local d; d="$(fwf_role_cwd "$1")"; log "scratch $d ($1: source-blind, no worktree)"
}
for id in "${PAIRS[@]}"; do
  if fwf_role_no_worktree "impl$id"; then
    ut_scratch "impl$id"
  else
    add_branch_wt "impl$id" "impl$id/work"
    seed_data "$(data_dir "impl$id")"; log "seeded $(data_dir "impl$id")"
    warm "impl$id"
  fi
  if ! fwf_role_suppressed "qa$id"; then
    add_detached_wt "qa$id"; warm "qa$id"
  fi
done
add_detached_wt "pm"
fwf_role_suppressed gv || add_detached_wt "gv"   # Grand Vizier — read-mostly critic (no build, no dev data)
add_detached_wt "captain"    # Captain — releases + direct deep work
warm "captain"
if ! fwf_role_suppressed conductor; then
  add_detached_wt "conductor"
  warm "conductor"
fi
for er in $(fwf_extra_names); do   # template-declared extra roles
  if fwf_role_no_worktree "$er"; then ut_scratch "$er"; else add_detached_wt "$er"; fi
done

# e2e deps for the conductor (it owns e2e) — only when the conductor is active.
if [ -n "${E2E_SETUP_CMD:-}" ] && ! fwf_role_suppressed conductor; then
  ( cd "$(wt_dir conductor)" && eval "$E2E_SETUP_CMD" >/dev/null 2>&1 ) \
    && log "e2e deps installed in conductor" || log "e2e deps install skipped/failed"
fi

# user-testing (issue #42): personas drive a real browser via the Playwright MCP.
# Verify it is wired (or set it up with FWF_UT_SETUP_BROWSER=1) so a trial never
# hits the "personas have no hands" wall trial one hit. Warns only; no-op elsewhere.
fwf_ut_browser_preflight

log "provision complete (profile=$PROFILE, build=$DO_BUILD)"
