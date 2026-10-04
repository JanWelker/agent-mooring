#!/bin/bash
# Container entrypoint, run by tini as uid 1000 on a read-only root.
# Writable: $HOME (the PVC) and /tmp (an emptyDir). Safe to run on every start.
#
#   entrypoint.sh          prepare, start the tmux session, exec sshd
#   entrypoint.sh check    prepare and validate the sshd config, then exit
set -euo pipefail

: "${HOME:=/home/agent}"
SESSION="${AGENT_SESSION:-agent}"
# AGENT_REPO is the pre-0.2.0 single-repository variable.
REPOS="${AGENT_REPOS:-${AGENT_REPO:-}}"
# Loopback only: the TLS sidecar on :2222 is the way in.
SSHD_PORT="${SSHD_PORT:-2223}"
SSHD_LISTEN="${SSHD_LISTEN:-127.0.0.1}"
AUTHORIZED_KEYS_SRC="${AGENT_AUTHORIZED_KEYS:-/etc/claude-agent/authorized_keys}"
MCP_SRC="${AGENT_MCP_CONFIG:-/etc/claude-agent/mcp.json}"
RUNTIME_DIR=/tmp/agent
HOST_KEY_DIR="$HOME/.ssh/host"
SSHD_CONFIG="$RUNTIME_DIR/sshd_config"

log() { echo "entrypoint: $*" >&2; }

umask 077
mkdir -p "$RUNTIME_DIR" "$HOST_KEY_DIR" "$HOME/.local/bin"
# Where claude doctor looks for the native launcher; updates stay off.
ln -sfn /usr/local/bin/claude "$HOME/.local/bin/claude"

# 1. Host keys, once, on the PVC so the fingerprint survives restarts.
for type in ed25519 ecdsa; do
  key="$HOST_KEY_DIR/ssh_host_${type}_key"
  if [ ! -s "$key" ]; then
    log "generating $type host key"
    rm -f "$key" "$key.pub"
    ssh-keygen -q -t "$type" -N '' -C "claude-$SESSION" -f "$key"
  fi
done

# 2. authorized_keys: the mounted ConfigMap is the source of truth.
if [ -r "$AUTHORIZED_KEYS_SRC" ]; then
  install -m 0600 "$AUTHORIZED_KEYS_SRC" "$HOME/.ssh/authorized_keys"
else
  log "no authorized_keys at $AUTHORIZED_KEYS_SRC; nobody can log in"
  : > "$HOME/.ssh/authorized_keys"
fi

# fsGroup leaves /tmp and $HOME shared-writable without the sticky bit, which
# Claude refuses for its messaging sockets. /dev/shm is a sticky tmpfs.
if [ -z "${XDG_RUNTIME_DIR:-}" ] && mkdir -p /dev/shm/agent 2>/dev/null; then
  export XDG_RUNTIME_DIR=/dev/shm/agent
fi

# sshd and every login get the container env through this file, so tokens
# stay on the emptyDir and never land on the PVC.
export -p \
  | grep -vE '^declare -x (HOME|HOSTNAME|OLDPWD|PWD|SHLVL|TERM|USER|LOGNAME|SHELL|MAIL|_|AGENT_ENV_LOADED)(=|$)' \
  | sed 's/^declare -x /export /' > "$RUNTIME_DIR/env"

cat > "$SSHD_CONFIG" <<CONF
ListenAddress $SSHD_LISTEN
Port $SSHD_PORT
HostKey $HOST_KEY_DIR/ssh_host_ed25519_key
HostKey $HOST_KEY_DIR/ssh_host_ecdsa_key
PidFile $RUNTIME_DIR/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers agent
# fsGroup leaves the PVC root group-writable and owned by root.
StrictModes no
PermitUserEnvironment no
AllowAgentForwarding no
AllowTcpForwarding local
X11Forwarding no
PermitTunnel no
PrintMotd no
ClientAliveInterval 30
ClientAliveCountMax 4
AcceptEnv LANG LC_* COLORTERM
Subsystem sftp /usr/lib/openssh/sftp-server
ForceCommand /usr/local/bin/agent-shell
CONF

if [ "${1:-}" = check ]; then
  exec /usr/sbin/sshd -t -f "$SSHD_CONFIG"
fi

# 3. Git over HTTPS with the PAT, and the repository, cloned once.
has_github() { /usr/local/bin/agent-token github >/dev/null; }
if has_github; then
  # What gh auth setup-git writes, but through the wrapper: /usr/bin/gh alone
  # has no token. Rewritten on every start, which also fixes older configs.
  for host in https://github.com https://gist.github.com; do
    git config --global --unset-all "credential.$host.helper" || true
    git config --global --add "credential.$host.helper" ""
    git config --global --add "credential.$host.helper" "!/usr/local/bin/gh auth git-credential"
  done
  if [ -z "$(git config --global user.email || true)" ]; then
    if user="$(gh api user --jq '[.login, (.id|tostring), (.name // .login)] | @tsv' 2>/dev/null)"; then
      IFS=$'\t' read -r login id name <<<"$user"
      git config --global user.name "$name"
      git config --global user.email "${id}+${login}@users.noreply.github.com"
    else
      log "could not read the GitHub user; git identity left unset"
    fi
  fi
fi
WORKDIR="$HOME"
cloned=()
for repo in $REPOS; do
  dir="$HOME/${repo##*/}"
  if [ ! -d "$dir/.git" ]; then
    if has_github; then
      log "cloning $repo"
      gh repo clone "$repo" "$dir" || log "clone of $repo failed; continuing"
    else
      log "repo $repo set but there is no GitHub token; not cloning"
    fi
  fi
  [ -d "$dir/.git" ] && cloned+=("$dir")
done
# 3b. The shared skills repository at ~/.claude/skills. Unlike the work repos
# it is kept current: fast-forward only, and never fatal. Every network step
# has a timeout so a hung GitHub cannot keep sshd from starting.
SKILLS_REPO="${AGENT_SKILLS_REPO:-}"
SKILLS_REF="${AGENT_SKILLS_REF:-main}"
SKILLS_DIR="$HOME/.claude/skills"
if [ -n "$SKILLS_REPO" ]; then
  if ! has_github; then
    log "skills repo $SKILLS_REPO set but there is no GitHub token; not cloning"
  elif [ -e "$SKILLS_DIR/.git" ]; then
    # Follow a changed skills.ref: switch only when the checkout is clean.
    if [ "$(git -C "$SKILLS_DIR" symbolic-ref -q --short HEAD || true)" != "$SKILLS_REF" ]; then
      if [ -n "$(git -C "$SKILLS_DIR" status --porcelain 2>/dev/null)" ]; then
        log "skills checkout has local changes; not switching to $SKILLS_REF"
      elif timeout 60 git -C "$SKILLS_DIR" fetch -q origin "$SKILLS_REF" \
        && git -C "$SKILLS_DIR" checkout -q "$SKILLS_REF"; then
        log "skills switched to $SKILLS_REF"
      else
        log "could not switch skills to $SKILLS_REF; leaving the checkout as is"
      fi
    fi
    if timeout 60 git -C "$SKILLS_DIR" pull --ff-only -q; then
      log "skills $SKILLS_REPO pulled (fast-forward only)"
    else
      log "skills pull of $SKILLS_REPO did not fast-forward; leaving the checkout as is"
    fi
  else
    mkdir -p "$HOME/.claude"
    tmp="$HOME/.claude/skills.clone-$$"
    rm -rf "$tmp"
    log "cloning skills $SKILLS_REPO ($SKILLS_REF)"
    # Clone aside first: a failed or timed-out clone must not displace what is there.
    if timeout 120 gh repo clone "$SKILLS_REPO" "$tmp" -- --branch "$SKILLS_REF"; then
      if [ -e "$SKILLS_DIR" ] || [ -L "$SKILLS_DIR" ]; then
        aside="$SKILLS_DIR.local-$(date +%Y%m%d-%H%M%S)"
        log "moving existing $SKILLS_DIR to $aside"
        mv "$SKILLS_DIR" "$aside" || log "could not move $SKILLS_DIR aside"
      fi
      if [ ! -e "$SKILLS_DIR" ]; then
        mv "$tmp" "$SKILLS_DIR" || log "could not move the skills clone into place"
      fi
    else
      log "clone of skills $SKILLS_REPO failed; continuing"
    fi
    rm -rf "$tmp"
  fi
fi

# One repository: start in it. Several: start in $HOME.
[ "${#cloned[@]}" -eq 1 ] && [ "$(wc -w <<<"$REPOS")" -eq 1 ] && WORKDIR="${cloned[0]}"
echo "$WORKDIR" > "$RUNTIME_DIR/workdir"

# User-scope MCP servers from the chart, merged into ~/.claude.json while
# Claude is not running yet. The names the chart set last time are kept in
# ~/.claude/agent-mcp-servers.json, so a server dropped from the chart is
# removed; servers added by hand are kept.
if [ -r "$MCP_SRC" ]; then
  state="$HOME/.claude.json"
  managed="$HOME/.claude/agent-mcp-servers.json"
  mkdir -p "$HOME/.claude"
  [ -s "$state" ] || echo '{}' > "$state"
  [ -s "$managed" ] || echo '[]' > "$managed"
  if jq --slurpfile m "$MCP_SRC" --slurpfile prev "$managed" '
      ($m[0].mcpServers // {}) as $new
      | .mcpServers = (((.mcpServers // {})
          | with_entries(select(.key as $k | ($prev[0] | index($k)) == null)))
        + $new)' "$state" > "$state.tmp" \
    && jq '.mcpServers // {} | keys' "$MCP_SRC" > "$managed.tmp"; then
    mv "$state.tmp" "$state"
    mv "$managed.tmp" "$managed"
  else
    log "could not merge MCP servers from $MCP_SRC; ~/.claude.json left unchanged"
    rm -f "$state.tmp" "$managed.tmp"
  fi
fi

# 3c. OpenAPPA (https://openappa.com). `appa plugin install claude-code`
# writes its hooks to ~/.claude/settings.json, the `appa` MCP server, the
# appa-guide skill, the policy in ~/.config/appa, and the runtime and the
# `clappa` launcher under ~/.local. The hooks act only in sessions clappa
# starts, and agent-claude starts the main session with clappa. The install
# fetches the release of the image's appa from GitHub, so it runs only when
# that version is not deployed yet; it keeps an existing policy.
APPA_DATA="$HOME/.local/share/appa"
CLAPPA="$HOME/.local/bin/clappa"
if [ "${AGENT_APPA:-false}" = true ]; then
  want="$(appa --version | awk '{print $2}')"
  have="$("$APPA_DATA/bin/appa" --version 2>/dev/null | awk '{print $2}' || true)"
  if [ "$want" != "$have" ] || [ ! -x "$CLAPPA" ]; then
    log "installing OpenAPPA $want for Claude Code"
    if timeout 300 appa plugin install claude-code --revision "v$want" --no-agent-yell --json \
      > "$RUNTIME_DIR/appa-install.json" 2> "$RUNTIME_DIR/appa-install.log"; then
      log "OpenAPPA $want installed"
    else
      log "OpenAPPA install failed; see $RUNTIME_DIR/appa-install.log"
    fi
  fi
  # The skill lands in the skills checkout; keep it out of git status, which
  # gates switching skills.ref.
  exclude="$SKILLS_DIR/.git/info/exclude"
  if [ -d "$SKILLS_DIR/.git" ] && ! grep -qxF /appa-guide/ "$exclude" 2>/dev/null; then
    mkdir -p "${exclude%/*}" && echo /appa-guide/ >> "$exclude"
  fi
elif [ -x "$CLAPPA" ]; then
  # Turned off: drop the hooks, MCP server, skill and clappa; the policy and
  # data stay for a later install.
  log "removing OpenAPPA's Claude Code registration"
  timeout 60 "$APPA_DATA/bin/appa" plugin remove claude-code --json > /dev/null \
    || log "could not remove OpenAPPA's Claude Code registration"
fi

# 4. The long-running Claude session.
/usr/local/bin/agent-session

# 5. sshd in the foreground, as PID 1's only child.
exec /usr/sbin/sshd -D -e -f "$SSHD_CONFIG"
