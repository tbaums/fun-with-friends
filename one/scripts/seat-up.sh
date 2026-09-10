#!/usr/bin/env bash
# Bring up ONE real implementer seat for fwf 1.0: a warm interactive Claude
# Code pane that the supervisor wakes. No /loop. No claude -p.
#
#   usage: one/scripts/seat-up.sh <floor-dir> <worktree> [session] [pane-name]
#
# floor-dir  : per-floor HOME (settings + injected auth live here; never the
#              customer repo's .claude/settings.json — --setting-sources user)
# worktree   : the seat's checkout, whose ONLY git remote is the local mirror
#
# The pane runs `claude --permission-mode dontAsk --setting-sources user`.
# Deny hooks in <floor-dir>/.claude/settings.json refuse `git push` to
# protected branches and every `gh` write; the seat holds no GitHub write
# token anyway (proven: contents:read token → 403 on label/push).
set -euo pipefail
floor="$1"; wt="$2"; session="${3:-fwf-one}"; pane="${4:-impl1}"
mkdir -p "$floor/.claude"
# A fresh per-floor HOME would show onboarding (theme picker) and the
# workspace-trust dialog; seed both as done so the pane comes up at the
# prompt. Values copied from the operator's own ~/.claude.json.
ver="$(jq -r '.lastOnboardingVersion // "2.1.0"' ~/.claude.json 2>/dev/null)"
jq -n --arg wt "$wt" --arg ver "$ver" '{hasCompletedOnboarding:true, lastOnboardingVersion:$ver, theme:"dark", autoUpdates:false, projects:{($wt):{allowedTools:[], hasTrustDialogAccepted:true, hasClaudeMdExternalIncludesApproved:true}}}' > "$floor/.claude.json"
cat > "$floor/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Read", "Write", "Edit", "Glob", "Grep", "Bash(*)"],
    "_note": "M0: Bash(*) because dontAsk refuses any compound command an allow rule does not match; the seat holds no GitHub token, its only remote is the local mirror, and the denies + PreToolUse hook below stop pushes to protected branches, gh, curl and rm -rf.",
    "deny": ["Bash(gh:*)", "Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(curl:*)", "Bash(rm -rf:*)", "WebFetch", "WebSearch"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "read -r inp; cmd=$(printf '%s' \"$inp\" | jq -r '.tool_input.command // \"\"'); case \"$cmd\" in *'push'*'staging'*|*'push'*'main'*|*'push'*'--force'*|*'push -f'*) echo 'fwfd: pushes to staging/main and force-pushes are denied for seats' >&2; exit 2;; esac; exit 0" } ] }
    ]
  }
}
JSON
tok="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken')"
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
launch="bash --noprofile --norc -c \"source '$envf' && cd '$wt' && exec claude --permission-mode dontAsk --setting-sources user --settings '$floor/.claude/settings.json' --allowedTools 'Bash(*)' 'Read' 'Write' 'Edit' 'Glob' 'Grep' --disallowedTools 'Bash(gh:*)' 'Bash(curl:*)' 'WebFetch' 'WebSearch' --add-dir '$floor/..'\""
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
