# fwf toolchain image — everything a factory pane needs: bash, tmux, git, gh,
# and the claude CLI. Auth is NEVER baked in: mount ~/.claude, ~/.claude.json,
# and ~/.config/gh from the host at run time (see docs/containers.md, `fwf shell`).
FROM debian:bookworm-slim

# Base toolchain for every pane.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less openssh-client procps tmux unzip \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI from the official apt repo, pinned to its keyring.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -qq && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Non-root agent user; agents never need root inside the floor.
RUN useradd -m -s /bin/bash friend
USER friend
WORKDIR /home/friend

# Claude Code CLI via the native installer (lands in ~/.local/bin). ~/.claude
# must exist so a credentials file can be mounted into it at run time.
RUN curl -fsSL https://claude.ai/install.sh | bash && mkdir -p /home/friend/.claude
ENV PATH="/home/friend/.local/bin:${PATH}"

# Atomic terminal redraws under tmux (same default as config.sh).
ENV CLAUDE_CODE_FORCE_SYNC_OUTPUT=1

CMD ["bash"]
