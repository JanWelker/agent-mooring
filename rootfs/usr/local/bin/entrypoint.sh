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
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git --hostname github.com || log "gh auth setup-git failed"
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
    if [ -n "${GH_TOKEN:-}" ]; then
      log "cloning $repo"
      gh repo clone "$repo" "$dir" || log "clone of $repo failed; continuing"
    else
      log "repo $repo set but GH_TOKEN is empty; not cloning"
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
  if [ -z "${GH_TOKEN:-}" ]; then
    log "skills repo $SKILLS_REPO set but GH_TOKEN is empty; not cloning"
  elif [ -e "$SKILLS_DIR/.git" ]; then
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
# Claude is not running yet; servers added by hand are kept.
if [ -s "$MCP_SRC" ]; then
  state="$HOME/.claude.json"
  [ -s "$state" ] || echo '{}' > "$state"
  jq --slurpfile m "$MCP_SRC" '.mcpServers = ((.mcpServers // {}) + ($m[0].mcpServers // {}))' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
fi

# 4. The long-running Claude session.
/usr/local/bin/agent-session

# 5. sshd in the foreground, as PID 1's only child.
exec /usr/sbin/sshd -D -e -f "$SSHD_CONFIG"
