# shellcheck shell=bash disable=SC1091
# The container environment (tokens, Kubernetes service address) does not
# reach ssh logins; the entrypoint writes it here on every start.
if [ -n "${BASH_VERSION:-}" ] && [ -z "${AGENT_ENV_LOADED:-}" ] && [ -r /tmp/agent/env ]; then
  . /tmp/agent/env
  export AGENT_ENV_LOADED=1
fi
