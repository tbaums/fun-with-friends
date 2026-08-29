# PR body context-fold + built-with credit (issue #106).
#
# WHY: the PR body fwf raises today is thin AND fwf-flavored ("Closes #<num>.
# Owner: impl__ID__. WIP. __PROVENANCE__") — none of the ticket's why survives,
# and what little text there is leaks fwf role/seat vocabulary to an outside
# reviewer. This file gives every PR-producing template two things to fold in:
#   - fwf_context_block   — a mechanical, sanitized "## Context & rationale"
#                           distillation of the closed ticket(s), for the PR
#                           body AND (primarily) the squash-merge commit body,
#                           since only the commit travels with the repo on
#                           clone/export/mirror.
#   - fwf_credit_block    — a reviewer-facing "built with fwf + Claude" credit,
#                           analogous to (but NOT a duplicate of) #80's machine
#                           `fwf-Provenance:` trailer.
#
# MECHANICAL, NOT LLM-DRAWN (PM decision): fwf tickets are already authored in
# a structured prose format (Problem/Proposed behavior, Decisions & tradeoffs,
# Alternatives considered, Acceptance criteria, Testing). v1 mechanically lifts
# those named sections — no `claude -p` call, no fabrication risk, no per-PR
# metered spend.
#
# EXTRACTION SCOPE (PM round-2 decision — the primary leak control): the issue
# BODY's structured sections + any linked docs/proposals/<n>-*.md ONLY. The
# comment thread is excluded WHOLESALE — it is role-to-role coordination by
# construction (CLAIM/ASSIGNED/GV-SIGNOFF/"ball's back in your court") and a
# token scrub over it would leave garbled, still-leaky prose on a public body.
# A decision that lives only in a comment is a grooming bug (fold it into the
# body), not a reason to teach the extractor to mine the thread.
#
# Sourced by lib.sh (profile-independent otherwise; only needs $FWF_ISSUES /
# $FWF_REPO / $FWF_LIB_DIR, all set by the time lib.sh gets here).

# --- PR-vs-issue detection + linked-issue resolution (issue #189) -----------
# GitHub shares ONE number sequence across issues and PRs; `gh issue view`
# happily succeeds on a PR number too (PRs ARE issues in the underlying data
# model), which is exactly how #189 shipped 16 hollow squash-merge cards --
# the extractor was fed a PR number and silently folded the PR's own body.
# fwf-flag-captain.sh's gh_kind() established the detection idiom (the
# unified /issues API: a PR comes back with a non-null .pull_request); this
# mirrors it rather than sharing a function across two independently-sourced
# files, matching the file's own existing cd-into-repo pattern below.
_fwf_pr_ctx_gh() { if [ -d "${FWF_REPO:-}/.git" ]; then ( cd "$FWF_REPO" && gh "$@" ); else gh "$@"; fi; }

# $1=num -> "issue"|"pr". Local-issues mode has no PR concept at all -- every
# number there is an issue by construction.
_fwf_pr_ctx_kind() {
  [ "${FWF_ISSUES:-gh}" = "local" ] && { echo issue; return; }
  local pr
  pr="$(_fwf_pr_ctx_gh api "repos/{owner}/{repo}/issues/$1" --jq '.pull_request // empty' 2>/dev/null || true)"
  [ -n "$pr" ] && echo pr || echo issue
}

# $1=PR number -> newline-separated, deduped, numerically-sorted list of
# issue numbers the PR's OWN BODY closes (GitHub's `closingIssuesReferences`
# is empty for a PR targeting a non-default branch -- every fwf PR targets
# __STAGING__, never __DEFAULT__ -- so this greps the body text directly for
# GitHub's own recognized closing keywords, matching what actually resolves
# the issue once the squash commit reaches __DEFAULT__). Empty output = no
# linked issue found; caller decides how to fail.
_fwf_pr_ctx_pr_linked_issues() {
  local n="$1" body
  body="$(_fwf_pr_ctx_gh pr view "$n" --json body --jq '.body // ""' 2>/dev/null)" || return 0
  # A genuine "no match" makes grep exit 1, which -- under this file's
  # sourcing script's `set -o pipefail` -- would make the whole pipeline
  # (and this function) return non-zero for the ordinary, non-error case of
  # "this PR just doesn't close anything". `|| true` on the final stage
  # keeps that case indistinguishable from success; the caller reads
  # emptiness from the OUTPUT, not the exit code.
  printf '%s\n' "$body" \
    | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' \
    | sort -n -u || true
}

# --- ticket fetch (mode-aware: gh for remote, fwf-issues.sh for --issues local) ---
# $1 = issue number -> {"title":...,"body":...} JSON (gh-shaped either way).
fwf_pr_ctx_issue_json() {
  local n="$1"
  if [ "${FWF_ISSUES:-gh}" = "local" ]; then
    "$FWF_LIB_DIR/fwf-issues.sh" view "$n" --json title,body 2>/dev/null || echo '{"title":"","body":""}'
  elif [ -d "${FWF_REPO:-}/.git" ]; then
    ( cd "$FWF_REPO" && gh issue view "$n" --json title,body ) 2>/dev/null || echo '{"title":"","body":""}'
  else
    gh issue view "$n" --json title,body 2>/dev/null || echo '{"title":"","body":""}'
  fi
}

# --- section splitter ---------------------------------------------------
# stdin = a ticket body -> "title<US>content<RS>" records, one per markdown
# heading (any #-#### level; headings are not nested — every heading starts a
# new record, which is all the canonical fwf section format needs). Content
# before the first heading is dropped (fwf ticket bodies open with the title
# context inline in the first section, never orphan prose).
#
# RECORD SEPARATOR IS \x1e (RS), NOT NUL: macOS's /usr/bin/awk (the "one true
# awk" — no gawk shipped) builds printf's output as a NUL-terminated C string
# internally, so an embedded `\x00` silently ends the string right there and
# the byte itself never reaches stdout — every record boundary vanishes and
# the reading shell sees one undifferentiated blob. The consumer below reads
# with `read -r -d $'\x1e'`, NOT `read -r -d ''` (which means NUL) — they must
# use the same separator or every heading collapses into one giant record.
_fwf_pr_ctx_split() {
  awk '
    BEGIN { title = ""; buf = ""; have = 0 }
    /^#{1,6}[ \t]+/ {
      if (have) printf "%s\x1f%s\x1e", title, buf
      sub(/^#{1,6}[ \t]+/, "")
      title = $0; buf = ""; have = 1
      next
    }
    { buf = buf $0 "\n" }
    END { if (have) printf "%s\x1f%s\x1e", title, buf }
  '
}

# --- linked discovery proposal (docs/proposals/<n>-*.md), if any -------
_fwf_pr_ctx_proposal() { # $1=issue-num -> "**Design proposal (...):**\n\n<content>\n" or empty
  local n="$1" f
  f="$(find "${FWF_REPO:-.}/docs/proposals" -maxdepth 1 -name "$n-*.md" 2>/dev/null | head -1)"
  [ -n "$f" ] || return 0
  printf '\n**Design proposal (`docs/proposals/%s`):**\n\n%s\n' "$(basename "$f")" "$(cat "$f")"
}

# --- one ticket's distilled block (unsanitized — caller sanitizes the whole) --
# $1 = issue number -> "### <title>\n...\n" mechanical distillation.
# --- self-referential-fold guard (issue #135, hardens the #189 failure mode) --
# If this is ever fed a PR's own body (the exact confusion #189 fixed at the
# CALL-SITE level), the PR's own machine trailers / credit line must never
# survive into the card regardless of which section they land in under
# fail-open -- unlike heading-level denial, this is line-level so it holds no
# matter how the content is nested under whatever heading it fell under.
# stdin -> stdout with those lines removed.
_fwf_pr_ctx_strip_self_markers() {
  grep -vE '^fwf-Provenance:|^Co-Authored-By:|^Closes #[0-9]+\.?[[:space:]]*$|🏭 Built with'
}

# $1 = issue number -> "### <title>\n...\n" mechanical distillation. FAIL-OPEN
# (issue #135): every substantive section is kept by default and routed to a
# bucket by heading keyword; only a short, explicit deny-list is dropped. The
# old fail-closed version silently discarded anything outside five canonical
# headings -- the better a ticket was written, the emptier its permanent
# card. A section matching no known bucket lands in "Other context" rather
# than the void, and a DRIFT notice (never a silent one) is printed to
# stderr -- "written into the card, it is permanent noise on every commit;
# printed to stdout during a squash-merge, nobody reads it" (this ticket's
# own words) -- so the schema gap reaches someone who can act on it, without
# becoming noise on every clean merge.
_fwf_pr_ctx_one() {
  local n="$1" json title body rec t lt c
  local intro="" root_cause="" evidence="" constraints="" edge_cases=""
  local decisions="" alternatives="" acceptance="" testing="" other=""
  local seen=0 mapped=0 denied=0 other_count=0 other_titles=""
  json="$(fwf_pr_ctx_issue_json "$n")"
  title="$(printf '%s' "$json" | jq -r '.title // ""' 2>/dev/null)"
  body="$(printf '%s' "$json" | jq -r '.body // ""' 2>/dev/null)"
  : "${title:=issue #$n}"
  while IFS= read -r -d $'\x1e' rec; do
    t="${rec%%$'\x1f'*}"; c="${rec#*$'\x1f'}"
    lt="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
    c="$(printf '%s' "$c" | _fwf_pr_ctx_strip_self_markers)"
    [ -n "$(printf '%s' "$c" | tr -d '[:space:]')" ] || continue
    seen=$((seen + 1))
    case "$lt" in
      # Deny-list (issue #135's "coordination about the FUTURE, not the
      # PAST" principle) -- role-coordination noise and, defensively, the
      # extractor's own output heading, never admitted to any bucket.
      *"for pm"*|*"for gv"*|*related*|*"context & rationale"*|*"context and rationale"*)
        denied=$((denied + 1));;
      *problem*|*intent*|*proposed\ behavior*|*goal*) intro="$intro$c"; mapped=$((mapped + 1));;
      *root\ cause*)                                  root_cause="$root_cause$c"; mapped=$((mapped + 1));;
      *evidence*)                                     evidence="$evidence$c"; mapped=$((mapped + 1));;
      *constraint*|*blast-radius*|*sequencing*|*hard\ prerequisite*)
                                                        constraints="$constraints$c"; mapped=$((mapped + 1));;
      *edge\ case*)                                    edge_cases="$edge_cases$c"; mapped=$((mapped + 1));;
      *decision*)                                      decisions="$decisions$c"; mapped=$((mapped + 1));;
      *alternative*)                                   alternatives="$alternatives$c"; mapped=$((mapped + 1));;
      *acceptance\ criteria*)                          acceptance="$acceptance$c"; mapped=$((mapped + 1));;
      *testing*|*testability*)                         testing="$testing$c"; mapped=$((mapped + 1));;
      # Fail-open catch-all (A3): an unrecognized-but-substantive section is
      # kept, in source order, never silently discarded -- and counted, so
      # the drift report below can name it.
      *) other="$other$c"; other_count=$((other_count + 1)); other_titles="$other_titles, $t";;
    esac
  done < <(_fwf_pr_ctx_split <<<"$body")
  printf '### %s\n' "$title"
  [ -n "$intro" ] && printf '%s\n' "$(printf '%s' "$intro" | sed -E '/^[[:space:]]*$/d')"
  [ -n "$root_cause" ] && printf '\n**Root cause:**\n%s\n' "$root_cause"
  [ -n "$evidence" ] && printf '\n**Evidence:**\n%s\n' "$evidence"
  [ -n "$constraints" ] && printf '\n**Constraints & sequencing:**\n%s\n' "$constraints"
  [ -n "$edge_cases" ] && printf '\n**Edge cases:**\n%s\n' "$edge_cases"
  printf '\n**Decisions & tradeoffs:**\n%s\n' "${decisions:-_(none logged)_}"
  printf '\n**Alternatives considered:**\n%s\n' "${alternatives:-_(none logged)_}"
  printf '\n**Acceptance criteria:**\n%s\n' "${acceptance:-_(none logged)_}"
  printf '\n**Testing:**\n%s\n' "${testing:-_(none logged)_}"
  [ -n "$other" ] && printf '\n**Other context:**\n%s\n' "$other"
  _fwf_pr_ctx_proposal "$n"
  if [ "$other_count" -gt 0 ]; then
    echo "fwf pr-context: DRIFT on issue #$n -- $other_count of $seen section(s) landed in 'Other context' (${other_titles#, }); mapped=$mapped denied=$denied. Consider widening the bucket schema or adding a deny-list entry (lib/pr_context.sh)." >&2
  fi
}

# --- portable word-bounded substitution -------------------------------------
# macOS/BSD `sed -E` (the default, no-GNU-sed-installed shape every dev/CI box
# here must work on) does NOT support `\b` — a pattern using it silently never
# matches, which would make the whole sanitizer below a silent no-op on this
# platform. Boundaries are hand-rolled instead: a leading/trailing "not an
# identifier char" (or start/end of string) group, consumed into \1/\2 and
# re-emitted around the replacement. Consuming those chars means `s///g` would
# skip straight past an ADJACENT match sharing the same boundary char (e.g.
# "impl1 impl2 impl3" only converting the two outer ones) — so this loops a
# single (non-`g`) substitution with a branch-back (`:x` / `tx`) until no more
# matches are found, re-scanning the whole string fresh every pass instead of
# resuming past already-consumed text.
# $1 = extended-regex alternation for the token (NO capturing groups of its
#      own — every `(...)` in the compiled script must be this function's two
#      boundary groups, or \1/\2 below reference the wrong thing).
# $2 = literal replacement text (may itself contain no backreferences).
_fwf_pr_ctx_wordsub() {
  sed -E "
    :_fwfws
    s/(^|[^A-Za-z0-9_])($1)([^A-Za-z0-9_]|\$)/\\1$2\\3/I
    t_fwfws
  "
}

# --- sanitizer (constraints 1 + 3: no fwf leakage, no sensitive data) ---------
# Deny-list transform + pattern sweep + a sensitive-data scrub, applied to
# mechanically-pulled ticket content BEFORE it is folded into a public body.
# Order matters: composite/specific patterns run before any remaining generic
# rule they'd otherwise be swallowed by.
#
# issue #234: this used to also run a generic role/jargon word table (pm, gv,
# captain, conductor, impl<N>, qa<N>, floor, gate, worktree(s), product-wip,
# release-hold, "staging branch", "integration branch") over ALL prose. Two
# defects followed from treating those as ordinary vocabulary: (1) the word-
# boundary regex can't tell a flag/command from prose, so `--pm-only` became
# `--the product owner-only` -- a flag that does not exist, frozen into
# permanent history; (2) `impl1`/`impl2`/`gv`/`qa1` all collapsed into "the
# implementer"/"the reviewer", destroying which seat did what. This repo is
# public and ships 31 role-template files by name (`templates/dev/*.tmpl`),
# so there was no secret being protected by that table -- only readability,
# and readability cannot justify publishing a command that does not exist or
# erasing which reviewer signed off. Principle: substitute PROTOCOL MARKERS
# (below); never substitute the name of a thing a human types. The five
# entries that remain are markers, not identifiers -- each is justified where
# it's defined.
fwf_sanitize_pr_text() {
  sed -E '
    # --- sensitive-data scrub (constraint 3) -------------------------------
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*-----END [A-Z ]*PRIVATE KEY-----/[redacted-key]/g
    s/gh[oprsu]_[A-Za-z0-9]{20,}/[redacted-token]/g
    s/AKIA[0-9A-Z]{16}/[redacted-key]/g
    s/sk-[A-Za-z0-9]{20,}/[redacted-key]/g
    s/AIza[0-9A-Za-z_-]{35}/[redacted-key]/g
    s/((api[_-]?key|secret|password|token)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[redacted]/gI
    # --- fwf pattern sweep (composite, before single-token rules) ----------
    s/impl[0-9]+\/issue-[0-9]+-[a-z0-9-]+/[internal-branch]/g
    s/fwf-self-[A-Za-z0-9-]+/[internal-session]/g
    s#/?\.fun-with-friends/[A-Za-z0-9_./-]*#[internal-path]#g
    s#origin/staging#the pre-release branch#g
    s#origin/integration#the release-candidate branch#g
    s/__PROVENANCE__|__CREDIT__|__CONTEXT__//g
  ' |
  # kept: compresses many internal-only var names to one placeholder; unlike
  # the dropped role words it never collapses two DISTINCT identifiable
  # actors into the same string, so no information is destroyed by keeping it.
  _fwf_pr_ctx_wordsub 'FWF_[A-Z_]+' '[internal-var]' |
  sed -E '
    :_li
    s/(^|[^A-Za-z0-9_])LI-([0-9]+)([^A-Za-z0-9_]|$)/\1#\2\3/
    t_li
  ' |
  # kept: protocol-state markers, not identifiers -- "who did what" is
  # already in the diff/thread; the marker only says a claim/sign-off event
  # happened, and unlike the dropped role words it never appears inside a
  # CLI flag or command a reader would type.
  _fwf_pr_ctx_wordsub 'CLAIM impl[0-9]+|CLAIM qa[0-9]+' '(claimed)' |
  _fwf_pr_ctx_wordsub 'ASSIGNED impl[0-9]+|ASSIGNED qa[0-9]+' '(assigned)' |
  _fwf_pr_ctx_wordsub 'GV-SIGNOFF|GV-CHANGES' '(reviewed)' |
  _fwf_pr_ctx_wordsub 'QA-APPROVED:|QA-CHANGES-REQUESTED:|IMPL-ADDRESSED:' '(review note:)' |
  sed -E 's/Owner:[[:space:]]*//gI' |
  sed -E '
    :_wip
    s/(^|[^A-Za-z0-9_])WIP([^A-Za-z0-9_]|$)/\1\2/
    t_wip
  '
}

# --- runtime fail-closed guard (PM item 2) ------------------------------------
# Scans the ACTUAL rendered output (what is about to become a public PR body
# or squash-merge commit) for anything the sanitizer should have already
# caught. This is the backstop, not the primary control (extraction scope +
# the sanitizer above are) — it exists so a sanitizer gap fails closed instead
# of shipping quietly. stdin = candidate body; on a clean pass it is echoed
# back unchanged (rc 0); on a hit, nothing is emitted, the offending line(s)
# go to stderr, and rc is 1.
fwf_pr_body_guard() {
  local text hit
  text="$(cat)"
  # issue #135: this backstop's word-list had drifted from what the
  # sanitizer above it actually targets. #234 narrowed fwf_sanitize_pr_text
  # to substitute PROTOCOL MARKERS ONLY -- never a bare role/jargon word a
  # human legitimately types (this repo is public and ships 31 role-template
  # files by name) -- but this guard kept blocking those same bare words
  # (impl[0-9]+, qa[0-9]+, captain, conductor, worktree, floor, gv, pm,
  # product-wip, release-hold, "*staging branch*"/"*integration branch*"
  # prose) as if they were unsanitized leaks. A backstop that flags content
  # its own front-line control was deliberately told to leave alone isn't a
  # stricter guard, it's a DIFFERENT, un-reviewed policy -- and it made
  # fail-open's own flagship fixture (#195, whose real body legitimately
  # says "confirmed in source by GV" and "started under fwf gate --e2e in
  # one worktree") unsatisfiable: real ticket prose the sanitizer correctly
  # leaves untouched would still get the whole card refused. Narrowed to
  # exactly the sanitizer's actual substitution targets above, so this
  # guard catches a sanitizer GAP (something that should have been
  # substituted and wasn't), not a policy that never shipped in the
  # sanitizer to begin with.
  # Split case-sensitive vs case-insensitive, matching the sanitizer's OWN
  # per-rule case behavior exactly -- a blanket -i previously matched the
  # lowercase "wip" inside the legitimate label name "product-wip" against
  # the bare `WIP` term (whose sanitizer rule is deliberately uppercase-only,
  # unlike Owner:/CLAIM/GV-SIGNOFF/FWF_*/QA-*, which the sanitizer's own
  # _fwf_pr_ctx_wordsub does match case-insensitively) -- a false positive on
  # ordinary ticket prose that a single combined -i pass can't avoid.
  hit="$( { printf '%s\n' "$text" | grep -nE \
      '(^|[^A-Za-z0-9_])(LI-[0-9]+|WIP|__PROVENANCE__|__CREDIT__|__CONTEXT__|origin/staging|origin/integration)([^A-Za-z0-9_]|$)|impl[0-9]+/issue-[0-9]+-[a-z0-9-]+|/?\.fun-with-friends/[A-Za-z0-9_./-]*' \
      2>/dev/null;
    printf '%s\n' "$text" | grep -inE \
      '(^|[^A-Za-z0-9_])(impl__ID__|qa__ID__|Owner:|GV-SIGNOFF|GV-CHANGES|QA-APPROVED:|QA-CHANGES-REQUESTED:|IMPL-ADDRESSED:|CLAIM (impl|qa)[0-9]+|ASSIGNED (impl|qa)[0-9]+|FWF_[A-Z_]+|fwf-self-[A-Za-z0-9-]+)([^A-Za-z0-9_]|$)' \
      2>/dev/null; } || true)"
  if [ -n "$hit" ]; then
    echo "fwf: PR/commit body BLOCKED (issue #106 guard) — fwf-internal token(s) survived sanitization:" >&2
    printf '%s\n' "$hit" >&2
    return 1
  fi
  printf '%s' "$text"
}

# --- public entry point: multi-ticket context fold ----------------------------
# $1.. = issue numbers (any order/dupes) -> sanitized "## Context & rationale"
# block, one "### <title>" sub-section per ticket, ordered by issue number.
fwf_context_block() {
  [ $# -gt 0 ] || return 0
  local nums n out
  nums="$(printf '%s\n' "$@" | sort -n -u)"
  out="$(
    printf '## Context & rationale\n'
    for n in $nums; do
      printf '\n'
      _fwf_pr_ctx_one "$n"
    done
  )"
  printf '%s' "$out" | fwf_sanitize_pr_text
}

# --- reviewer-facing "built with fwf + Claude" credit (Part B) ----------------
# Policy: FWF_CREDIT=on|minimal|off (set in lib.sh — default on for our own
# repos, off when --issues local, since local mode IS the "not our repo"
# signal until #107 gives this a real per-target dial). `off` prints nothing
# (the placeholder substitutes to empty, never a stray line); `minimal` drops
# the descriptive "(a multi-agent Claude Code dev factory)" aside but keeps
# the full model list — the disclosure bar (every seat's model, #134) holds
# for minimal too, it only shortens the surrounding prose.
#
# Reads the seat roster from fwf_seat_model_pairs (lib.sh) — the SAME source
# fwf_provenance_block consumes — rather than its own hardcoded seat list.
# #134 was exactly this drifting: credit looped only "impl qa" while
# provenance already looped all six seats.
fwf_credit_block() {
  case "${FWF_CREDIT:-on}" in
    off) return 0;;
  esac
  local link='[fun-with-friends](https://github.com/tbaums/fun-with-friends)'
  local m seen="" models=""
  while IFS=$'\t' read -r _ m; do
    # Unconfigured seat (no override, no floor default): omit it rather than
    # rendering a blank model — never "()" or a stray leading/trailing comma.
    [ -n "$m" ] || continue
    case " $seen " in *" $m "*) ;; *) seen="$seen $m"; models="${models:+$models, }$m";; esac
  done <<< "$(fwf_seat_model_pairs)"
  local line
  if [ "${FWF_CREDIT:-on}" = "minimal" ]; then
    line="🏭 Built with $link + Claude."
  else
    line="🏭 Built with $link (a multi-agent Claude Code dev factory) + Claude."
  fi
  if [ -n "$models" ]; then printf '%s (%s)' "$line" "$models"; else printf '%s' "$line"; fi
}
