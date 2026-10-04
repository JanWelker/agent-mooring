# claude-agent

A container image and Helm chart that run [Claude Code](https://code.claude.com)
as a long-running agent on Kubernetes. One release is one session: a pod with
Claude Code in tmux, reachable over SSH through a Gateway API `TLSRoute` and
from claude.ai/code through Remote Control.

```text
ssh -> openssl s_client -> :443 Gateway (TLS passthrough, SNI <session>.ssh.wlkr.ch)
    -> Service :2222 -> tls sidecar (socat, cert-manager certificate) -> sshd 127.0.0.1:2223
```

| Artifact | Reference |
| --- | --- |
| Image | `ghcr.io/janwelker/claude-agent:<claude-code-version>` (amd64, arm64) |
| Chart | `oci://ghcr.io/janwelker/charts/claude-agent` |

A release workflow checks npm every hour. Each new Claude Code version gets an
image tagged with that version and a chart whose `appVersion` is that version,
so an instance only ever bumps the chart version.

## Image

Debian trixie, uid/gid 1000 (`agent`), home `/home/agent`. Works with
`readOnlyRootFilesystem`; the writable paths are `$HOME` and `/tmp`, plus
`/dev/shm/agent` as `XDG_RUNTIME_DIR`: Claude Code refuses to put its
cross-session messaging sockets under a directory that `fsGroup` made
shared-writable without the sticky bit.

| Contents | |
| --- | --- |
| Claude Code | native binary, `/usr/local/bin/claude`, auto-updater off |
| Shell | openssh-server, socat, tmux, git, gh, jq, ripgrep, rsync, python3, vim-tiny, less |
| Node.js | `node`, `npm`, `npx` for MCP servers; `claude-agent-acp`, also as `claude-code-acp` |
| Cluster | kubectl, helm, argocd, cilium, hubble, bao |

The entrypoint ([`entrypoint.sh`](rootfs/usr/local/bin/entrypoint.sh)) runs on
every start and is idempotent:

1. Generates SSH host keys once under `~/.ssh/host`.
2. Copies `authorized_keys` from `/etc/claude-agent/authorized_keys`.
3. With `GH_TOKEN`: `gh auth setup-git`, the git identity from the token's
   user, and a one-time clone of each of `AGENT_REPOS` (space-separated) into `~/<name>`;
   existing clones are never pulled or reset, the agent owns them. A failed
   clone is logged and skipped.
   With `AGENT_SKILLS_REPO` too: clones it to `~/.claude/skills` (a non-git
   directory there is moved to `~/.claude/skills.local-<timestamp>`, never
   deleted), or fast-forwards an existing checkout; a pull that cannot
   fast-forward is logged and left alone. Network steps run under `timeout`,
   so sshd always starts.
4. Merges `/etc/claude-agent/mcp.json` into `~/.claude.json`.
5. Writes the container environment to `/tmp/agent/env`, which login shells
   source, since sshd does not pass it on.
6. Starts tmux session `main` with
   `claude --remote-control claude-<session> --continue`, in the repository
   directory when there is exactly one repository, otherwise in `~`.
7. Execs `sshd -D` on `127.0.0.1:2223` with a config generated in `/tmp/agent`.

An SSH login without a command attaches `main`; a login with a command runs it,
so `scp`, `rsync`, `sftp` and ACP work.

The chart runs the same image a second time as a native sidecar,
[`tls-proxy`](rootfs/usr/local/bin/tls-proxy): socat terminates TLS on :2222
with the session's certificate and forwards to sshd. socat reads the
certificate only at start, so `tls-proxy` restarts the listener within a
minute of a renewal; open connections keep running.

## Chart values

| Value | Default | Meaning |
| --- | --- | --- |
| `session` | required | DNS label. Resources are `claude-<session>`; SSH host `<session>.<ssh.domain>` |
| `repos` | `[]` | `owner/name` list, each cloned once into `~/<name>`. One PAT covers all. Empty (and no `repo` or `skills.repo`): no PAT, no clone, no GitHub egress |
| `skills.repo` | `""` | `owner/name` of the shared skills repository, cloned to `~/.claude/skills` and fast-forwarded on start and at each session start. Its root has the layout of `~/.claude/skills`. The PAT must cover it; set alone, it still gets the PAT and GitHub egress |
| `skills.ref` | `main` | Branch cloned |
| `repo` | `""` | Deprecated alias: appended to `repos`, duplicates dropped |
| `image.digest` | `""` | `sha256:...` manifest digest appended to the tag. The release workflow sets it in the published chart, so a re-pushed tag is pulled again despite `IfNotPresent` |
| `image.repository` | `ghcr.io/janwelker/claude-agent` | |
| `image.tag` | `""` | Empty: the chart's `appVersion` |
| `image.pullPolicy` | `IfNotPresent` | |
| `kubernetes.access` | `none` | `none`: own ServiceAccount, no token. `read`/`write`: `claude-reader`/`claude-writer` with a token |
| `argocd.enabled` | `false` | Mounts the Argo CD token and sets `ARGOCD_SERVER`, `ARGOCD_OPTS=--grpc-web` |
| `argocd.server` | `argo-grpc.infra.k8s.wlkr.ch` | |
| `ssh.authorizedKeys` | `[]` | Public key lines |
| `ssh.gateway` | `apps-gateway`/`kube-system`/`ssh` | `TLSRoute` parent: name, namespace, sectionName |
| `ssh.domain` | `ssh.wlkr.ch` | |
| `tls.issuerRef` | `letsencrypt-prod`, `ClusterIssuer` | Issuer of the `claude-<session>-tls` certificate the sidecar serves |
| `acp.enabled` | `false` | Opens npm registry egress for ACP clients |
| `mcpServers` | `{}` | User-scope MCP servers, `.mcp.json` format |
| `extraEgressFQDNs` | `[]` | `[{matchName: host, port: 443}]` or `[{matchPattern: "*.host"}]` |
| `settings` | `{}` | Merged over the default `managed-settings.json` |
| `claudeMd` | `""` | Managed `CLAUDE.md` for every session in the pod |
| `persistence.existingClaim` | `""` | Use this PVC instead of creating `claude-<session>` |
| `persistence.size` | `20Gi` | |
| `persistence.storageClass` | `rook-ceph-block` | |
| `resources` | 500m/2Gi, limit 8Gi | |
| `secretStore` | `openbao`, `ClusterSecretStore` | External Secrets store |
| `extraEnv` | `[]` | Extra container env |
| `nodeSelector`, `tolerations`, `affinity` | empty | |

[`values.schema.json`](chart/claude-agent/values.schema.json) validates every
value. Secrets come from the store, without the `kv/` prefix:

| Secret | Key | When |
| --- | --- | --- |
| `claude-<session>-github` → `GH_TOKEN` | `claude-<session>/github`, property `token`; one PAT for all repositories | `repos`, `repo` or `skills.repo` set |
| `claude-<session>-argocd` → `ARGOCD_AUTH_TOKEN` | `claude-agents/argocd`, property `token` | `argocd.enabled` |

### Managed settings

The chart's [defaults](chart/claude-agent/templates/_helpers.tpl) turn on
Remote Control for every session, drop commit and PR attribution, allow
read-only `kubectl`, `gh pr checks` and `argocd app get`, deny
`gh pr merge --admin`, pushes to `main` and force pushes, and run a
SessionStart hook that tells Claude which GitHub user, cloned repositories, Kubernetes access and
Argo CD server it has. `settings` merges over them; a list replaces the
default list.

### Network policy

The `CiliumNetworkPolicy` lets port 2222 in from the `ingress`, `host` and
`remote-node` entities, and lets out:

| Egress | When |
| --- | --- |
| DNS to kube-dns | always |
| Claude Code's hosts from the [network requirements](https://code.claude.com/docs/en/network-config#network-access-requirements) | always |
| `github.com`, `api.github.com`, `*.githubusercontent.com`, `ghcr.io` | `repos`, `repo` or `skills.repo` set |
| `registry.npmjs.org` | `acp.enabled` or `mcpServers` set |
| `kube-apiserver` entity | `kubernetes.access` not `none` |
| `argocd.server` | `argocd.enabled` |
| `extraEgressFQDNs` | listed |

## SSH

The Gateway passes TLS for `*.ssh.wlkr.ch` through by SNI and the pod
terminates it, so the client wraps SSH in TLS. Add this to `~/.ssh/config`:

```text
Host *.ssh.wlkr.ch
  User agent
  ProxyCommand openssl s_client -quiet -verify_return_error -servername %h -connect %h:443
```

Then `ssh <session>.ssh.wlkr.ch` attaches the tmux session. Detach with
`C-b d`; Claude keeps running.

## First run

1. `ssh <session>.ssh.wlkr.ch`.
2. In the Claude pane, `/login`, or `claude auth login` in a second tmux window.
3. `/config` → **Enable Remote Control for all sessions**.
4. The session appears at claude.ai/code as `claude-<session>`.

Login and the conversation live on the PVC, so they survive restarts and image
updates; `--continue` resumes the last conversation.

## ACP from Zed

Zed runs the agent over SSH. In `settings.json`:

```json
{
  "agent_servers": {
    "claude-homelab": {
      "command": "ssh",
      "args": ["homelab.ssh.wlkr.ch", "claude-code-acp"]
    }
  }
}
```

## Development

```bash
container build -t claude-agent:dev .        # or docker build
container run --rm --read-only --tmpfs /tmp --tmpfs /home/agent claude-agent:dev check   # sshd -t
helm lint chart/claude-agent -f chart/claude-agent/ci/full-values.yaml
```

CI runs hadolint, `helm lint`, `helm template` through kubeconform, and an image
smoke test that logs in over SSH through the TLS sidecar with a self-signed
certificate.
