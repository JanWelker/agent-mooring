# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# The release workflow passes the version it builds; this default is for local builds.
ARG CLAUDE_CODE_VERSION=2.1.289

# Wolfi publishes only `latest`; the digest is the pin and Renovate moves it.
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:88a20e2d017bd20cdc0cb3910de603e7bea9512a6c351a8dd3c9df212ab03d73 AS tools

# The release workflow passes the build day, so the package layers refresh
# daily instead of staying cached until the base digest moves. wolfi-base pins
# its own packages to exact versions in /etc/apk/world; without the pins the
# upgrade takes the fixes released since the digest.
ARG WOLFI_REFRESH

# hadolint ignore=DL3018
RUN sed -i 's/[=~<>].*//' /etc/apk/world \
 && apk upgrade --no-cache \
 && apk add --no-cache bash coreutils curl gpg gpg-agent jq

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CLAUDE_CODE_VERSION
# Anthropic's Claude Code release signing key, from
# https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing
ARG CLAUDE_CODE_KEY=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
# renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
ARG KUBECTL_VERSION=1.37.1
# renovate: datasource=github-releases depName=helm/helm extractVersion=^v(?<version>.*)$
ARG HELM_VERSION=4.3.1
# renovate: datasource=github-releases depName=argoproj/argo-cd extractVersion=^v(?<version>.*)$
ARG ARGOCD_VERSION=3.5.6
# renovate: datasource=github-releases depName=cilium/cilium-cli extractVersion=^v(?<version>.*)$
ARG CILIUM_CLI_VERSION=0.20.1
# renovate: datasource=github-releases depName=openbao/openbao extractVersion=^v(?<version>.*)$
ARG OPENBAO_VERSION=2.7.1
# renovate: datasource=github-releases depName=archestra-ai/OpenAPPA extractVersion=^v(?<version>.*)$
ARG APPA_VERSION=0.37.0

# The release binary, checked against the manifest whose signature must come
# from the pinned key: GnuPG's VALIDSIG line ends in the primary key's
# fingerprint.
WORKDIR /dl
RUN case "$(uname -m)" in x86_64) p=linux-x64 ;; aarch64) p=linux-arm64 ;; esac \
 && base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
 && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --batch -q --import \
 && curl -fsSLO "$base/manifest.json" -O "$base/manifest.json.sig" \
 && gpg --batch --status-fd 1 --verify manifest.json.sig manifest.json 2>/dev/null \
      | grep -E "^\[GNUPG:\] VALIDSIG .* ${CLAUDE_CODE_KEY}$" >/dev/null \
 && curl -fsSLo claude "$base/$p/claude" \
 && echo "$(jq -er --arg p "$p" '.platforms[$p].checksum' manifest.json)  claude" | sha256sum -c --quiet - \
 && install -D -m 0755 claude /out/claude \
 && /out/claude --version | grep -F "${CLAUDE_CODE_VERSION}" \
 && rm -rf /dl/* "$GNUPGHOME"

# Each download is checked against the checksum file its project publishes.
RUN RUST_ARCH="$(uname -m)" \
 && case "$RUST_ARCH" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac \
 && gh="https://github.com" \
 && k8s="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
 && curl -fsSLO "$k8s" \
 && echo "$(curl -fsSL "$k8s.sha256")  kubectl" | sha256sum -c --quiet - \
 && curl -fsSLO "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      -O "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum" \
 && sha256sum -c --quiet "helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum" \
 && curl -fsSLO "$gh/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${ARCH}" \
      -O "$gh/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/cli_checksums.txt" \
 && grep -E "  argocd-linux-${ARCH}$" cli_checksums.txt | sha256sum -c --quiet - \
 && curl -fsSLO "$gh/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz" \
      -O "$gh/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz.sha256sum" \
 && sha256sum -c --quiet "cilium-linux-${ARCH}.tar.gz.sha256sum" \
 && curl -fsSLO "$gh/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz" \
      -O "$gh/openbao/openbao/releases/download/v${OPENBAO_VERSION}/checksums.txt" \
 && grep -E "  openbao_${OPENBAO_VERSION}_linux_${ARCH}\.tar\.gz$" checksums.txt | sha256sum -c --quiet - \
 && curl -fsSLO "$gh/archestra-ai/OpenAPPA/releases/download/v${APPA_VERSION}/appa-${RUST_ARCH}-unknown-linux-gnu.tar.gz" \
      -O "$gh/archestra-ai/OpenAPPA/releases/download/v${APPA_VERSION}/SHA256SUMS" \
 && grep -E "  appa-${RUST_ARCH}-unknown-linux-gnu\.tar\.gz$" SHA256SUMS | sha256sum -c --quiet - \
 && install -m 0755 kubectl /out/kubectl \
 && tar -xzO -f "helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" "linux-${ARCH}/helm" > /out/helm \
 && install -m 0755 "argocd-linux-${ARCH}" /argocd \
 && tar -xz -C /out -f "cilium-linux-${ARCH}.tar.gz" cilium \
 && tar -xz -C /out -f "openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz" bao \
 && tar -xz -C /out -f "appa-${RUST_ARCH}-unknown-linux-gnu.tar.gz" ./appa \
 && chmod 0755 /out/* \
 && rm -rf /dl/*

FROM --platform=$BUILDPLATFORM golang:1.27.1-trixie@sha256:8f58fd67ea075142d947a60e0caa4317746a55118d312f027793d382c7741734 AS tls-proxy-build

ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY cmd/ cmd/
RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -trimpath -ldflags='-s -w' -o /out/tls-proxy ./cmd/tls-proxy

# The chart's TLS sidecar, built with --target tls-proxy: one static binary,
# no shell, so it carries none of the agent image's packages.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:25ac8f0c3b2334a9eb05452266bd4697864a8c8ef0ef71e5e6480d7f92868329 AS tls-proxy

LABEL org.opencontainers.image.source="https://github.com/JanWelker/agent-mooring" \
      org.opencontainers.image.description="TLS sidecar of agent-mooring: terminates TLS and forwards to sshd" \
      org.opencontainers.image.licenses="MIT"

COPY --from=tls-proxy-build /out/tls-proxy /tls-proxy
EXPOSE 2222
ENTRYPOINT ["/tls-proxy"]

FROM cgr.dev/chainguard/wolfi-base:latest@sha256:88a20e2d017bd20cdc0cb3910de603e7bea9512a6c351a8dd3c9df212ab03d73

ARG CLAUDE_CODE_VERSION
ARG WOLFI_REFRESH

LABEL org.opencontainers.image.source="https://github.com/JanWelker/agent-mooring" \
      org.opencontainers.image.description="Claude Code as a long-running agent behind sshd and tmux" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${CLAUDE_CODE_VERSION}"

# The package names carry the Node.js and Python majors; everything else
# follows Wolfi at build time.
# hadolint ignore=DL3018
RUN sed -i 's/[=~<>].*//' /etc/apk/world \
 && apk upgrade --no-cache \
 && apk add --no-cache \
      bash ca-certificates-bundle curl gh git jq less nodejs-24 npm \
      openssh-client openssh-keygen openssh-server openssh-sftp-server procps \
      python-3.14 ripgrep rsync shadow tini tmux \
 && rm -f /etc/ssh/ssh_host_* \
 && install -d -m 0755 /run/sshd \
 && groupadd -g 1000 agent \
 && useradd -u 1000 -g 1000 -m -d /home/agent -s /bin/bash agent \
 && usermod -p '*' agent

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# claude-agent-acp and every transitive package come from acp/package-lock.json,
# so the hourly rebuilds install the same tree; Renovate bumps both files.
# npm ci runs in the directory: with --prefix it does not match the lockfile.
WORKDIR /usr/local/lib/claude-agent-acp
COPY acp/package.json acp/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
 && rm -rf node_modules/@anthropic-ai/claude-agent-sdk-linux-* \
 && install -d -m 0755 /usr/local/bin \
 && ln -s ../lib/claude-agent-acp/node_modules/.bin/claude-agent-acp /usr/local/bin/claude-agent-acp \
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
