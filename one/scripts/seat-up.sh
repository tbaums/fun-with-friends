#!/usr/bin/env bash
# Bring up ONE real implementer seat for fwf 1.0: a warm interactive Claude
# Code pane that the supervisor wakes. No /loop. No claude -p.
#
#   usage: one/scripts/seat-up.sh <floor-dir> <worktree> [session] [pane-name] [model]
#
# floor-dir  : per-floor HOME (settings + injected auth live here; never the
#              customer repo's .claude/settings.json — --setting-sources user)
# worktree   : the seat's checkout, whose ONLY git remote is the local mirror
#
# The pane runs `claude --permission-mode dontAsk --setting-sources user`.
# Deny hooks in <floor-dir>/.claude/settings.json refuse `git push` to
# protected branches and every `gh` write; the seat holds no GitHub write
# token anyway (proven: contents:read token → 403 on label/push). The push
# policy itself is `seat-push-guard.sh`, installed beside those settings.
set -euo pipefail
floor="$1"; wt="$2"; session="${3:-fwf-one}"; pane="${4:-impl1}"; model="${5:-opus}"
mkdir -p "$floor/.claude"
# A fresh per-floor HOME would show onboarding (theme picker) and the
# workspace-trust dialog; seed both as done so the pane comes up at the
# prompt. Values copied from the operator's own ~/.claude.json.
ver="$(jq -r '.lastOnboardingVersion // "2.1.0"' ~/.claude.json 2>/dev/null)"
# Merge (never overwrite): every seat's worktree must stay trusted.
existing="$floor/.claude.json"; [ -s "$existing" ] || echo '{}' > "$existing"
jq --arg wt "$wt" --arg ver "$ver" '. + {hasCompletedOnboarding:true, lastOnboardingVersion:$ver, theme:"dark", autoUpdates:false} | .projects = ((.projects // {}) + {($wt):{allowedTools:[], hasTrustDialogAccepted:true, hasClaudeMdExternalIncludesApproved:true}})' "$existing" > "$existing.tmp" && mv "$existing.tmp" "$existing"
# The whole push policy is one program (#621): `permissions.deny` globs match
# by prefix, so a glob for a bare force also refused
# `--force-with-lease=<ref>:<sha>` — the compare-and-swap the rework prompt
# instructs — and every rework that rebased ended in a refusal. The guard
# below judges whole arguments, so the qualified lease passes and a bare
# force, an unqualified lease and a +refspec do not. The floor gets its own
# copy so the pane does not depend on this checkout staying where it is.
guard="$floor/.claude/push-guard.sh"
install -m 0755 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seat-push-guard.sh" "$guard"
cat > "$floor/.claude/settings.json" <<JSON
{
  "permissions": {
    "allow": ["Read", "Write", "Edit", "Glob", "Grep", "Bash(*)"],
    "_note": "M0: Bash(*) because dontAsk refuses any compound command an allow rule does not match; the seat holds no GitHub token, its only remote is the local mirror, and the denies + PreToolUse hook below stop pushes to protected branches, force-pushes without a qualified lease, gh, curl and rm -rf.",
    "deny": ["Bash(gh:*)", "Bash(curl:*)", "Bash(rm -rf:*)", "WebFetch", "WebSearch"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$guard" } ] }
    ]
  }
}
JSON
# Prefer a long-lived headless token (`claude setup-token`, saved 0600 at
# ~/.fwf/seat-token); fall back to a copy of the Keychain access token, which
# rotates and was revoked mid-job once (2026-09-09 22:40).
if [ -s ~/.fwf/seat-token ]; then tok="$(tr -d '[:space:]' < ~/.fwf/seat-token)"; else
tok="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken')"; fi
[ -n "$tok" ] && [ "$tok" != null ] || { echo "seat-up: no OAuth token in Keychain" >&2; exit 3; }
# Secrets never go through the keyboard: the pane sources a 0600 env file.
# (A typed token ends up in tmux scrollback; the first attempt proved it, and
# a swallowed first keystroke turned `export` into `xport`.)
umask 077
envf="$floor/env.sh"
printf "export HOME='%s' CLAUDE_CODE_OAUTH_TOKEN='%s' FWFD_SEAT='%s'\n" "$floor" "$tok" "$pane" > "$envf"
# Launch claude DIRECTLY as the pane's command (no interactive shell, so no
# prompt noise, no oh-my-zsh update dialog, nothing typed): bash --norc
# sources the env file and execs claude.
launch="bash --noprofile --norc -c \"source '$envf' && cd '$wt' && exec claude --model '$model' --permission-mode dontAsk --setting-sources user --settings '$floor/.claude/settings.json' --allowedTools 'Bash(*)' 'Read' 'Write' 'Edit' 'Glob' 'Grep' --disallowedTools 'Bash(gh:*)' 'Bash(curl:*)' 'WebFetch' 'WebSearch' --add-dir '$floor/..'\""
if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -n "$pane" -c "$wt" -x 200 -y 50 "$launch"
else
  tmux new-window -t "$session" -n "$pane" -c "$wt" "$launch"
fi
target="$session:$pane"
# Wait until the pane's foreground command is claude.
for _ in $(seq 1 60); do
  cur="$(tmux display-message -p -t "$target" '#{pane_current_command}')"
  case "$cur" in claude|[0-9]*)
    echo "seat up: $target (worktree $wt, process $cur)"; exit 0 ;;
  esac
  sleep 0.5
done
echo "seat-up: pane $target did not reach 'claude' within 30s" >&2; exit 4
