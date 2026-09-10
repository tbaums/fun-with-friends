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
cat > "$floor/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "deny": ["Bash(gh pr merge:*)", "Bash(gh issue close:*)", "Bash(gh api -X PATCH:*)", "Bash(gh api -X PUT:*)", "Bash(gh api -X DELETE:*)"]
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
if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -n "$pane" -c "$wt" -x 200 -y 50
else
  tmux new-window -t "$session" -n "$pane" -c "$wt"
fi
target="$session:$pane"
# Auth and HOME are per-pane environment, never persisted to disk here.
tmux send-keys -t "$target" -l "export HOME='$floor' CLAUDE_CODE_OAUTH_TOKEN='$tok' FWFD_SEAT='$pane'; clear; exec claude --permission-mode dontAsk --setting-sources user"
tmux send-keys -t "$target" Enter
# Wait until the pane's foreground command is claude.
for _ in $(seq 1 60); do
  if [ "$(tmux display-message -p -t "$target" '#{pane_current_command}')" = claude ]; then
    echo "seat up: $target (worktree $wt)"; exit 0
  fi
  sleep 0.5
done
echo "seat-up: pane $target did not reach 'claude' within 30s" >&2; exit 4
