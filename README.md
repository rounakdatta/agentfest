# agentfest

<div align="center">
  <img src="assets/agentfest_logo.png" alt="agentfest logo" width="480">
</div>

A persistent remote computer whose primary UI is Claude Code.

The premise: my laptop and phone come and go, but the homelab stays connected.
So the homelab should be the computer, and everything else should be a thin
client onto it. Claude Code keeps working while the laptop is shut, the phone
is in a pocket, and I'm asleep.

**One deployment is one computer.** Each release is a single pod with a single
persistent volume holding an entire home directory. Deployments are
independent; there can be many.

```
                 phone / laptop
                       │
                  Tailscale
                       │
              Traefik + cert-manager
                       │
                   Tinyauth            ← Google OAuth, in front of everything
                       │
                    Codeman            ← sessions, PTY, mobile UI
                       │
                     tmux
                       │
                  Claude Code
                       │
        ┌──────────────┴──────────────┐
        │   PVC: /home/rounak          │
        │   workspace, ~/.claude,      │
        │   git checkouts, artifacts   │
        └──────────────────────────────┘
```

## What lives where

| Concern | Owner |
|---|---|
| What the machine *is* (vim, tmux, fish, git, claude, MCP servers) | [`dotfiles`](https://github.com/rounakdatta/dotfiles) → `hosts/festie` |
| Packaging that into an image, and deploying it | this repo |
| Sessions, terminal, mobile UI, notifications | [Codeman](https://github.com/Ark0N/Codeman) (upstream, unmodified) |
| CPU, RAM, disk, network, ingress, SSO, backups | [`homelab.setup`](https://github.com/rounakdatta/homelab.setup) |

The environment is deliberately **not** redefined here. `flake.nix` takes
dotfiles as an input and bakes `homeConfigurations.festie` into the image, so
the laptop and the remote computer cannot drift.

## Build

There is no Dockerfile. The image is a Nix derivation, built in CI:

```bash
nix build .#image          # produces a docker-archive tarball
docker load < result
```

CI pushes the image to `ghcr.io/rounakdatta/agentfest` and the chart to
`oci://ghcr.io/rounakdatta/charts`, matching the `texas-fold-em` pipeline.
`homelab.setup` then consumes the chart through a Kustomize `helmCharts` block
pinned to a version.

## Things worth knowing before deploying

**Codeman is an RCE surface by design.** It launches agents with
`--dangerously-skip-permissions` by default, so anyone who reaches the UI
controls the machine. Whatever fronts it is not a nicety; it is the only thing
between the internet and a shell running as you, with your credentials.

Be precise about what is actually in front of it, because this is easy to get
wrong. The deployed hostname resolves to a **public IP** — cert-manager's
HTTP-01 solver needs port 80 reachable — so "it's on the tailnet" is not true
of the Traefik ingress and should not be counted as a layer. Today the honest
answer for `festie` is: **Tinyauth (Google OAuth, email whitelist), and that is
it.**

Codeman's own password is available (`auth.enabled`) but off for `festie`, and
`values.yaml` explains that call at length. The short version: it is HTTP Basic
and only HTTP Basic — there is no login route in Codeman to switch to — and its
hardcoded brute-force limiter behaves badly behind a reverse proxy, because
Codeman builds Fastify without `trustProxy` so every client shares one bucket of
ten failures. Behind an authenticating proxy it locks out the owner more
reliably than an attacker.

If you want a genuine second factor here, put it at the edge where you control
it — client certificates via a Traefik `TLSOption`, or moving the ingress onto
the tailnet and switching cert-manager to a DNS-01 solver so port 80 need not be
public. Both are real work; neither is done.

**Set `codeman.allowedHosts`.** Codeman rejects unknown `Host` headers before
any handler runs, as a DNS-rebinding guard. `.ts.net` is allowed out of the
box; a Traefik ingress on a custom domain is not, and every request will come
back `403 host not allowed` until that hostname is listed.

**The SSH key is effectively required.** dotfiles' `claude-skills` module clones
`agent-smith` during home-manager activation, and that clone is not fault
tolerant. Without a key that can read it, activation fails. The entrypoint
deliberately continues anyway and starts Codeman, so a broken activation leaves
you with a reachable terminal to debug from rather than a crash-looping pod —
but the environment is incomplete until the key is mounted.

**`local-path` is node-local.** The PVC pins the pod to whichever node first
schedules it. That is fine for one computer; it is a real constraint for many.

**Homebrew works here, but it is not how anything gets installed.** brew is
bootstrapped into `~/.homebrew` on first boot so Lyric's `mic` tap can be
exercised on Linux. Making it run at all took an FHS-shaped `/bin` plus
`/usr/bin/{ldd,cc,gcc,ld,as}`, because brew hardcodes
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` and looks up its toolchain by absolute
path rather than searching PATH — see the comments in `flake.nix`. Two things
to know: `~/.homebrew` is an *unsupported* prefix (the supported one lives
outside `$HOME` and so would not survive a pod restart), which means no
bottles; and brew therefore wants to install its own glibc, gcc and binutils
before any formula, even one that compiles nothing. Anything you actually
depend on should come from `dotfiles`, which is why `mic` is installed from its
release tarball there and merely *also* available through brew.

**Codeman is pinned by the chart, not the image.** It ships several releases a
week and installs into the persistent volume, so upgrading is a `values.yaml`
bump and a pod restart — no image rebuild. Everything else follows the opposite
rule: a new CLI means a PR against dotfiles and a new image.

## Status

Proof of concept. One session, one pod, one volume. Multiple concurrent Claude
Code sessions are the next milestone, and Codeman already supports them — the
open question is resource limits, not capability.
