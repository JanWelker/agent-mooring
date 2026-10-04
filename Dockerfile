# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# The release workflow passes the version it builds; this default is for local builds.
ARG CLAUDE_CODE_VERSION=2.1.289

FROM node:24.21.0-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe AS node

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS tools

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION
# renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
ARG KUBECTL_VERSION=1.37.1
# renovate: datasource=github-releases depName=helm/helm extractVersion=^v(?<version>.*)$
ARG HELM_VERSION=4.3.0
# renovate: datasource=github-releases depName=argoproj/argo-cd extractVersion=^v(?<version>.*)$
ARG ARGOCD_VERSION=3.5.3
# renovate: datasource=github-releases depName=cilium/cilium-cli extractVersion=^v(?<version>.*)$
ARG CILIUM_CLI_VERSION=0.20.1
# renovate: datasource=github-releases depName=cilium/hubble extractVersion=^v(?<version>.*)$
ARG HUBBLE_VERSION=1.19.4
# renovate: datasource=github-releases depName=openbao/openbao extractVersion=^v(?<version>.*)$
ARG OPENBAO_VERSION=2.7.1

WORKDIR /out

# The native installer, pinned to the release; the launcher it leaves in
# ~/.local/bin is a symlink into ~/.local/share/claude/versions.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
 && cp -L /root/.local/bin/claude /out/claude \
 && /out/claude --version | grep -F "${CLAUDE_CODE_VERSION}"

RUN ARCH="$(dpkg --print-architecture)" \
 && curl -fsSLo kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
 && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xzO "linux-${ARCH}/helm" > helm \
 && curl -fsSLo /argocd "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${ARCH}" \
 && curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz" | tar -xz cilium \
 && curl -fsSL "https://github.com/cilium/hubble/releases/download/v${HUBBLE_VERSION}/hubble-linux-${ARCH}.tar.gz" | tar -xz hubble \
 && curl -fsSL "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz" | tar -xz bao \
 && chmod 0755 /out/* /argocd

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CLAUDE_CODE_VERSION
# renovate: datasource=npm depName=@agentclientprotocol/claude-agent-acp
ARG CLAUDE_AGENT_ACP_VERSION=0.85.1

LABEL org.opencontainers.image.source="https://github.com/JanWelker/claude-agent" \
      org.opencontainers.image.description="Claude Code as a long-running agent behind sshd and tmux" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${CLAUDE_CODE_VERSION}"

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSLo /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gh git jq less openssh-client openssh-server procps python3 ripgrep rsync socat tini tmux vim-tiny \
 && apt-get purge -y gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && install -d -m 0755 /run/sshd \
 && groupadd -g 1000 agent \
 && useradd -u 1000 -g 1000 -m -d /home/agent -s /bin/bash agent \
 && usermod -p '*' agent

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g --omit=dev "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}" \
 && rm -rf /usr/local/lib/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-* \
 && ln -s claude-agent-acp /usr/local/bin/claude-code-acp \
 && npm cache clean --force

COPY --from=tools /out/ /usr/local/bin/
# /usr/local/bin/argocd and gh are wrappers that read the current token.
COPY --from=tools /argocd /usr/local/libexec/argocd
COPY rootfs/ /

# claude-agent-acp runs /usr/local/bin/claude (CLAUDE_CODE_EXECUTABLE below), so
# the SDK's bundled copy of the binary is dropped above.
# Interactive non-login shells (tmux panes) read bash.bashrc, not profile.d.
RUN echo '. /etc/profile.d/agent-env.sh' >> /etc/bash.bashrc

ENV HOME=/home/agent \
    LANG=C.UTF-8 \
    PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    NPM_CONFIG_UPDATE_NOTIFIER=false

USER 1000:1000
WORKDIR /home/agent
EXPOSE 2223

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
