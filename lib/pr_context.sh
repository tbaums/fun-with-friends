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

# --- issue #512: ONE table, not two mirrored lists ---------------------------
# The guard below used to carry its own hand-written alternations, kept in
# sync with fwf_sanitize_pr_text by hand. #135 and #234 each re-aligned them;
# both re-alignments left entries behind, and the second miss shipped inside
# the fix for the first. `impl__ID__` and `qa__ID__` sat in the guard with NO
# sanitizer rule at all, so they blocked issue #472's body for quoting a
# template placeholder out of source -- refusing a QA-approved, CLEAN PR.
#
# MEMBERSHIP RULE (the thing that would have prevented #135, #234 and #512):
#   An entry belongs here ONLY if its presence in rendered output would mean
#   fwf_sanitize_pr_text FAILED to substitute something. A token the sanitizer
#   must never touch can never indicate that failure -- it can only produce
#   false positives. `impl__ID__` is a template placeholder in a public repo
#   that ships templates/*/*.tmpl by name; giving the sanitizer a rule for it
#   would corrupt on-topic prose in exactly the tickets that discuss template
#   routing, so it does not belong in the sanitizer OR in this guard.
#
# Each row is  mode%token-regex%specimen  ('%' is the field separator; no
# token regex contains one). The specimen is a literal string that the
# sanitizer MUST transform -- test/run.sh feeds every specimen through
# fwf_sanitize_pr_text and fails if any comes back unchanged, so an entry
# with no sanitizer rule fails a test instead of a merge. That check is
# behavioural, not a parse of the sanitizer's source: it cannot go blind when
# someone reformats a sed rule.
#
#   mode csb = case-sensitive, word-bounded
#   mode csr = case-sensitive, raw (composite pattern; matches mid-token)
#   mode cib = case-insensitive, word-bounded
# Case per mode mirrors the sanitizer's OWN per-rule case behaviour: a blanket
# -i previously matched the lowercase "wip" inside the legitimate label name
# "product-wip" against the uppercase-only `WIP` rule.
_fwf_pr_ctx_guard_table() {
  cat <<'_FWF_PR_CTX_TABLE_'
csb%LI-[0-9]+%LI-4210
csb%WIP%WIP
csb%__PROVENANCE__%__PROVENANCE__
csb%__CREDIT__%__CREDIT__
csb%__CONTEXT__%__CONTEXT__
csb%origin/staging%origin/staging
csb%origin/integration%origin/integration
csr%impl[0-9]+/issue-[0-9]+-[a-z0-9-]+%impl1/issue-472-qa-tmpl-idle-routing
csr%/?\.fun-with-friends/[A-Za-z0-9_./-]*%.fun-with-friends/state
cib%Owner:%Owner: somebody
cib%GV-SIGNOFF%GV-SIGNOFF
cib%GV-CHANGES%GV-CHANGES
cib%QA-APPROVED:%QA-APPROVED:
cib%QA-CHANGES-REQUESTED:%QA-CHANGES-REQUESTED:
cib%IMPL-ADDRESSED:%IMPL-ADDRESSED:
cib%CLAIM (impl|qa)[0-9]+%CLAIM impl1
cib%ASSIGNED (impl|qa)[0-9]+%ASSIGNED qa1
cib%FWF_[A-Z_]+%FWF_PROFILE
cib%fwf-self-[A-Za-z0-9-]+%fwf-self-abcd1234
_FWF_PR_CTX_TABLE_
}

# Join the token regexes for one mode into a '|' alternation. Empty output +
# rc 1 when a mode has no rows -- callers MUST fail closed on that (issue
# #512: an empty alternation would make grep -E match every line, or, worse,
# a silently-skipped branch would stop checking anything at all).
_fwf_pr_ctx_guard_alts() {
  local want="$1" mode rx alts=
  while IFS='%' read -r mode rx _spec; do
    [ "$mode" = "$want" ] || continue
    alts="${alts:+$alts|}$rx"
  done <<_FWF_PR_CTX_ALTS_
$(_fwf_pr_ctx_guard_table)
_FWF_PR_CTX_ALTS_
  [ -n "$alts" ] || return 1
  printf '%s' "$alts"
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
  local text hit csb csr cib pat_cs pat_ci
  text="$(cat)"
  csb="$(_fwf_pr_ctx_guard_alts csb)" || csb=
  csr="$(_fwf_pr_ctx_guard_alts csr)" || csr=
  cib="$(_fwf_pr_ctx_guard_alts cib)" || cib=
  # Anti-vacuity: a guard that checks nothing must refuse, never pass. If the
  # table lost a whole mode, this backstop is not "clean" -- it is broken.
  if [ -z "$csb" ] || [ -z "$csr" ] || [ -z "$cib" ]; then
    echo "fwf#512: PR/commit body guard is INOPERATIVE — the token table yielded no entries for at least one mode (csb/csr/cib). Refusing rather than passing an unchecked body." >&2
    return 1
  fi
  pat_cs="(^|[^A-Za-z0-9_])($csb)([^A-Za-z0-9_]|\$)|$csr"
  pat_ci="(^|[^A-Za-z0-9_])($cib)([^A-Za-z0-9_]|\$)"
  hit="$( { printf '%s\n' "$text" | grep -nE "$pat_cs" 2>/dev/null;
    printf '%s\n' "$text" | grep -inE "$pat_ci" 2>/dev/null; } || true)"
  if [ -n "$hit" ]; then
    echo "fwf: PR/commit body BLOCKED (issue #106 guard) — fwf-internal token(s) survived sanitization:" >&2
    printf '%s\n' "$hit" >&2
    # issue #512: name the token, not just the line. Without this the operator
    # sees 100 characters of prose and has to guess which of ~19 alternatives
    # fired -- which is exactly how #512 was misdiagnosed on first filing.
    { printf '%s\n' "$text" | grep -oE "$pat_cs" 2>/dev/null;
      printf '%s\n' "$text" | grep -oinE "$pat_ci" 2>/dev/null; } \
      | sed -E 's/^[0-9]+://' | sed -E 's/^[^A-Za-z0-9_]//; s/[^A-Za-z0-9_]$//' \
      | sort -u | sed 's/^/  matched token: /' >&2
    return 1
  fi
  printf '%s' "$text"
}

# --- "does this issue have extractable content?" (issue #136) --------------
# The shared predicate #136's history-card guard and #212's backfill both
# need: a hollow card is only a DEFECT if the linked issue actually had
# something to fold. $1 = issue number -> 0 if the body has at least one
# substantive (non-whitespace) section, 1 if it is genuinely sparse (no
# heading has any real content, or the issue is unresolvable).
fwf_pr_ctx_has_extractable_content() {
  local n="$1" json body rec c has=1
  json="$(fwf_pr_ctx_issue_json "$n")"
  body="$(printf '%s' "$json" | jq -r '.body // ""' 2>/dev/null)"
  while IFS= read -r -d $'\x1e' rec; do
    c="${rec#*$'\x1f'}"
    [ -n "$(printf '%s' "$c" | tr -d '[:space:]')" ] && { has=0; break; }
  done < <(_fwf_pr_ctx_split <<<"$body")
  return "$has"
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

# --- history-card guard (issue #136): the permanent squash-merge invariant ---
# A post-merge, per-commit verdict: does this commit's body carry the
# crafted card (fwf-Provenance:, credit per FWF_CREDIT, and -- the #189
# amendment -- is it NOT hollow while its linked issue has extractable
# content)? Never audits branch history on its own; the caller
# (fwf_history_guard_range below, or fwf-gate-promote.sh) decides the range.

# $1=commit body -> space-separated list of "Closes #N" issue numbers, or
# empty if none found. Mirrors _fwf_pr_ctx_pr_linked_issues's keyword set.
_fwf_history_closed_issues() {
  # `|| true` on the final stage: a genuine "no Closes # at all" makes the
  # first grep exit 1, which under a caller's `set -o pipefail` would make
  # this whole function return non-zero for the ordinary case of "nothing
  # matched" -- the same class of bug fixed in
  # _fwf_pr_ctx_pr_linked_issues above; the caller reads emptiness from the
  # OUTPUT, never from this function's exit status.
  printf '%s\n' "$1" \
    | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' \
    | sort -n -u | tr '\n' ' ' | sed -E 's/[[:space:]]+$//' || true
}

# $1=commit body -> 0 (hollow) if the "## Context & rationale" block, once
# its own scaffolding (the ### heading, the four canned "_(none logged)_"
# lines, blank lines) is stripped, has no remaining substantive line left --
# the exact "byte-identical 17-line empty skeleton" shape #189 audited.
_fwf_history_card_is_hollow() {
  local body="$1" block remaining
  block="$(printf '%s\n' "$body" | awk '/^## Context & rationale$/{f=1;next} /^🏭 Built with|^fwf-Provenance:|^Co-Authored-By:/{f=0} f')"
  remaining="$(printf '%s\n' "$block" \
    | grep -vE '^### |^\*\*(Decisions & tradeoffs|Alternatives considered|Acceptance criteria|Testing):\*\*$|^_\(none logged\)_$|^[[:space:]]*$')"
  [ -z "$(printf '%s' "$remaining" | tr -d '[:space:]')" ]
}

# $1=commit sha -> prints "PASS" / "FAIL <reason>" / "INDETERMINATE <reason>".
fwf_history_card_verdict() {
  local sha="$1" body issues n has_extractable=1
  body="$(git log -1 --format=%B "$sha" 2>/dev/null)" || {
    printf 'INDETERMINATE commit %s does not resolve to any object\n' "$sha"; return
  }
  issues="$(_fwf_history_closed_issues "$body")"
  if [ -z "$issues" ]; then
    printf 'INDETERMINATE %s: no resolvable "Closes #n" in the commit body\n' "$sha"
    return
  fi
  case "$body" in
    *"fwf-Provenance:"*) : ;;
    *) printf 'FAIL %s: missing fwf-Provenance trailer\n' "$sha"; return ;;
  esac
  if [ "${FWF_CREDIT:-on}" = "on" ] || [ "${FWF_CREDIT:-on}" = "minimal" ]; then
    case "$body" in
      *"Built with"*) : ;;
      *) printf 'FAIL %s: FWF_CREDIT=%s requires the credit block, none found\n' "$sha" "${FWF_CREDIT:-on}"; return ;;
    esac
  fi
  if _fwf_history_card_is_hollow "$body"; then
    has_extractable=1
    for n in $issues; do
      if fwf_pr_ctx_has_extractable_content "$n"; then has_extractable=0; break; fi
    done
    if [ "$has_extractable" = 0 ]; then
      printf 'FAIL %s: hollow card (all buckets none-logged) but issue(s) %s have extractable content\n' "$sha" "$issues"
      return
    fi
    # hollow AND every linked issue is genuinely sparse -- legitimately thin, not a defect.
  fi
  printf 'PASS %s\n' "$sha"
}

# $1=range-from(exclusive) $2=range-to(inclusive), e.g. "origin/integration" "$tip"
# -> 0 if every squash-merge commit in the range PASSes; on any FAIL/
# INDETERMINATE, prints every offending verdict (never just the first) and
# returns 1. Range-bounded BY CONSTRUCTION (issue #136 AC g0): only commits
# newly reachable from $2 but not $1 are ever inspected -- pre-existing
# branch history (the 16 known-hollow commits from #189's audit) is
# structurally unreachable to this function, not merely skipped by intent.
#
# --first-parent --no-merges walks only the branch's OWN mainline commits:
# a real `git merge` commit (a conductor promotion, a manually-merged PR)
# has 2+ parents and is excluded, and so is everything reachable ONLY
# through its non-first parent (a merged branch's individual, pre-squash
# commits) -- git log without --first-parent would otherwise walk every
# commit of every non-squash-merged PR too, none of which ever carried a
# "Closes #n" of their own. Beyond that, only a commit whose subject ends
# `(#<n>)` -- this repo's own squash-merge signature, from every PR title
# ending "<title> (#<num>)" -- is checked at all; an ordinary mainline
# commit that was never meant to close an issue (a release bump, a direct
# golden re-bless) is out of scope for this invariant entirely, not merely
# a pass -- it is never flagged, not even INDETERMINATE.
#
# issue #438: a release-bump commit stays out of scope even when it lands
# squash-merged as its own PR (subject "release: vX.Y.Z ... (#N)") -- the
# `(#N)` there is GitHub's squash-merge suffix for the release PR itself,
# not a signal that the commit was meant to close an issue. Scoping must
# therefore check the subject's *content* first (does it read as a release
# bump?) before falling back to the squash-merge shape check below.
fwf_history_guard_range() {
  local from="$1" to="$2" sha subj verdict rc=0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subj="$(git log -1 --format=%s "$sha" 2>/dev/null)"
    printf '%s' "$subj" | grep -qE '^release: v[0-9]' && continue
    printf '%s' "$subj" | grep -qE '\(#[0-9]+\)$' || continue
    verdict="$(fwf_history_card_verdict "$sha")"
    case "$verdict" in
      PASS*) : ;;
      *) echo "$verdict" >&2; rc=1 ;;
    esac
  done < <(git log --first-parent --no-merges --format=%H "$from..$to" 2>/dev/null)
  return "$rc"
}

# --- backfill (issue #212): recover hollow history cards without rewriting --
# #136's invariant is go-forward (never audits pre-existing branch history);
# this is the ONE-SHOT recovery for what it deliberately does not touch.

# $1=commit sha -> 0 if BACKFILL-AFFECTED: its card is hollow (every bucket
# none-logged) while its linked issue genuinely has extractable content.
# Deliberately narrower than fwf_history_card_verdict (#136), which ALSO
# flags missing provenance/credit -- #212 backfills only the empty-card
# problem, never touches provenance or credit.
#
# Requires the "## Context & rationale" heading to actually be PRESENT --
# a commit that predates issue #106 entirely never had one, and "no card at
# all" is out of scope for this ticket (pre-feature history, not a defect),
# not the same thing as "attempted a card and it came out empty". #136's
# go-forward check never hits this ambiguity (it only ever sees commits
# newly promoted well after #106 shipped); #212's full-history scan does.
fwf_backfill_is_affected() {
  local sha="$1" body issues n
  body="$(git log -1 --format=%B "$sha" 2>/dev/null)" || return 1
  case "$body" in *"## Context & rationale"*) : ;; *) return 1 ;; esac
  issues="$(_fwf_history_closed_issues "$body")"
  [ -n "$issues" ] || return 1
  _fwf_history_card_is_hollow "$body" || return 1
  for n in $issues; do
    fwf_pr_ctx_has_extractable_content "$n" && return 0
  done
  return 1
}

# $1=to-ref -> newline-separated SHAs of every backfill-affected commit
# reachable from $1 (full history, not range-bounded -- unlike #136's
# go-forward check, backfilling by definition targets EXISTING history).
# Mechanical identification (AC b): the same subject-signature + hollow +
# extractable-content predicate #136 already established, not a hand list.
fwf_backfill_find_affected() {
  local to="$1" sha subj
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subj="$(git log -1 --format=%s "$sha" 2>/dev/null)"
    printf '%s' "$subj" | grep -qE '\(#[0-9]+\)$' || continue
    fwf_backfill_is_affected "$sha" && printf '%s\n' "$sha"
  done < <(git log --first-parent --no-merges --format=%H "$to" 2>/dev/null)
}

# $1=commit sha -> the note content to attach, or empty + non-zero if the
# linked issue is unresolvable. AC (g): every backfilled note states it was
# RECONSTRUCTED and as of what date -- a floor that rewrites issue bodies
# routinely means a note built now is reconstructed from a LATER draft than
# the commit it's attached to, and that must never be mistaken for a
# contemporaneous record.
fwf_backfill_note_for() {
  local sha="$1" body issues n card
  body="$(git log -1 --format=%B "$sha" 2>/dev/null)" || return 1
  issues="$(_fwf_history_closed_issues "$body")"
  [ -n "$issues" ] || return 1
  n="$(printf '%s\n' "$issues" | tr ' ' '\n' | head -1)"
  card="$(fwf_context_block "$n" | fwf_pr_body_guard)" || return 1
  printf 'RECONSTRUCTED (issue #212 backfill) from issue #%s as of %s -- NOT a contemporaneous record; the issue may have been edited since this commit merged.\n\n%s\n' \
    "$n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$card"
}
