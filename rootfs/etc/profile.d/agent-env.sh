# shellcheck shell=bash disable=SC1091
# The container environment (tokens, Kubernetes service address) does not
# reach ssh logins; the entrypoint writes it here on every start.
if [ -n "${BASH_VERSION:-}" ] && [ -z "${AGENT_ENV_LOADED:-}" ] && [ -r /tmp/agent/env ]; then
  . /tmp/agent/env
  export AGENT_ENV_LOADED=1
fi
# For tools other than gh, git and argocd (which read the files per call):
# the token as of this shell's start.
if [ -n "${BASH_VERSION:-}" ]; then
  if _t="$(/usr/local/bin/agent-token github)"; then export GH_TOKEN="$_t"; fi
  if _t="$(/usr/local/bin/agent-token argocd)"; then export ARGOCD_AUTH_TOKEN="$_t"; fi
  unset _t
fi
