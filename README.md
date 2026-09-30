# agentfest

<div align="center">
  <img src="assets/agentfest_logo.png" alt="agentfest logo" width="480">
</div>

A persistent remote computer that runs coding agents, driven from
[Paseo](https://github.com/getpaseo/paseo).

The premise: my laptop and phone come and go, but the homelab stays connected.
So the homelab should be the computer, and everything else should be a thin
client onto it. Claude Code keeps working while the laptop is shut, the phone
is in a pocket, and I'm asleep.

**One deployment is one computer.** Each release is a single pod with a single
persistent volume holding an entire home directory. Deployments are
independent; there can be many, and each shows up as its own host in the Paseo
app.

```
          Paseo app (phone / desktop)
                       │
      Paseo relay     ← end-to-end encrypted; sees only ciphertext
                       ▲
                       │  outbound only: nothing listens publicly
                       │
                 Paseo daemon          ← agents, terminals, schedules
                       │
        Claude Code (and Codex, OpenCode…)
                       │
        ┌──────────────┴──────────────┐
        │   PVC: /home/rounak          │
        │   workspace, ~/.claude,      │
        │   ~/.paseo, git checkouts    │
        └──────────────────────────────┘
```

Up to 0.1.x the UI was [Codeman](https://github.com/Ark0N/Codeman), behind a
public Traefik ingress with Tinyauth in front. 0.2.0 replaced it with Paseo:
a native mobile app instead of a terminal in a phone browser, and no public
ingress at all.

## What lives where

| Concern | Owner |
|---|---|
| What the machine *is* (vim, tmux, fish, git, claude, MCP servers) | [`dotfiles`](https://github.com/rounakdatta/dotfiles) → `hosts/festie` |
| Packaging that into an image, and deploying it | this repo |
| Agents, terminals, schedules, the phone and desktop apps | [Paseo](https://github.com/getpaseo/paseo) (upstream, one line patched — see below) |
| CPU, RAM, disk, network, secrets, backups | [`homelab.setup`](https://github.com/rounakdatta/homelab.setup) |

The environment is deliberately **not** redefined here. `flake.nix` takes
dotfiles as an input and bakes `homeConfigurations.festie` into the image, so
the laptop and the remote computer cannot drift.

## Build

There is no Dockerfile. The image is a Nix derivation, built in CI:

```bash
nix build .#image          # produces a docker-archive tarball
docker load < result
```

CI publishes on a `v*` tag only — a tag is what produces both the image and a
chart at a matching version. Pushes to `main` build nothing: they would be the
same commit a second time, and the tags a branch build produced (`main`,
`latest`, `<sha>`) are consumed by nobody, since `homelab.setup` pins an exact
chart version. So: merge, then tag.

CI pushes the image to `ghcr.io/rounakdatta/agentfest` and the chart to
`oci://ghcr.io/rounakdatta/charts`, matching the `texas-fold-em` pipeline.
`homelab.setup` then consumes the chart through a Kustomize `helmCharts` block
pinned to a version.

### Optional: `CACHIX_AUTH_TOKEN`

A repository secret. Without it the build still succeeds, it is just slower:
Cachix logs `Pushing is disabled`, nothing is ever cached, and every run
rebuilds ~160 leaf derivations (fish completions, the home-manager generation,
`veans`) from source. With a write token those land in the `rounakdatta` cache
and later runs substitute them.

It is an accelerator, never a correctness input — Nix store paths are
content-addressed and verified, so a fork without the token falls back to
`cache.nixos.org` and builds the remainder. A fresh clone needs nothing.

## What a new agent starts with, and where that is declared

Everything a client shows when you start an agent comes from the daemon, not
the app, so the phone and the desktop behave the same without being set up
twice. All of it is code:

| What | Where it is declared | How it lands |
|---|---|---|
| Default model and thinking level (Opus 5.5, Max) | dotfiles `hosts/festie` → `programs.paseo.settings` | merged into `~/.paseo/config.json` at activation |
| Agent profiles (`Claude · Max · Bypass`) | the same | the same, merged by `id` so profiles made in the app survive |
| Projects in the sidebar (`personal`, `work`) | dotfiles `programs.paseo.projects` | registered after each daemon start by `paseo-apply-declared` |
| Default permission mode (Bypass) | this chart, `paseo.claudeDefaultMode` | patched into Paseo's code at each start (`paseoDefaults`) |
| Claude Code's own settings, skills, MCP servers | dotfiles `configs/claude` | as on every other host |

Two of those break the pattern on purpose. Paseo creates projects only through
its API, never from a file, so they are applied by an idempotent script rather
than written. And Paseo hardcodes Claude's default mode to Auto with no config
key, so that one default is a patch — a soft one: if an upgrade moves the code,
Paseo starts with its own default and the log says so.

What stays per device, because it lives in the app: pairing, the notification
permission, and the app's own look and feel.

## Pairing a device

The daemon is reached through Paseo's relay, so a phone needs neither a VPN nor
a public hostname — only the pairing link and the daemon password.

1. Print the pairing link on the machine itself, in any terminal on it:

   ```bash
   paseo daemon pair
   ```

   From another pod that the NetworkPolicy admits, point it at the Service
   instead, with the daemon password in the environment:
   `PASEO_PASSWORD=… paseo daemon pair --host agentfest.apps.svc.cluster.local:6767`.

2. In the Paseo app, scan the QR code or paste the link, then enter the daemon
   password when it asks. Scan it **in the app**: opening the
   `app.paseo.sh/#offer=…` link in a browser hands it to Paseo's hosted web app
   and leaves it in the browser history.

3. On a fresh volume, open a terminal from the app and sign Claude Code in
   (`claude`, then `/login`). The home directory is new, so nothing is logged
   in yet.

Lost a phone? Delete `~/.paseo/daemon-keypair.json` and restart Paseo (see
below); every device then has to pair again. That is the only revocation there
is, and for one person it is cheap.

## Things worth knowing before deploying

**The pairing link and the password are the keys to the machine.** Paseo runs
agents as you, with your credentials, so whoever gets in controls the pod. The
relay is end-to-end encrypted and never learns the daemon's key, so it can
carry traffic but cannot read it or connect on its own; the most a hostile
relay can do is drop connections, observe timing, or replay a message you
already sent (getpaseo/paseo#359). What stands in front of the machine is
therefore the pairing link *and* the daemon password.

**That second lock needs one patch today.** Upstream admits a relay client that
sends no password at all — a stopgap kept until new mobile builds are in both
stores (getpaseo/paseo#4087). Without the patch the pairing link alone is a
full login. `paseoHarden` in `flake.nix` removes that branch at every start and
then proves the result by calling the real function; if an upgrade reshapes the
code so that proof fails, Paseo does not start. Delete it once upstream drops
the stopgap.

**The chart refuses to render without a password.** `paseo.password.existingSecret`
is required, for the reason above.

**Push notifications are not end-to-end encrypted.** They go from the daemon to
Expo and on to Apple or Google, carrying the start of the agent's last message
— tool calls included. Deny the app notification permission if that matters
for what runs here.

**A Paseo restart ends every running agent turn.** Agents are the daemon's
children. History survives, and an agent resumes (`claude --resume`) the next
time it is opened or prompted, but the turn in flight is gone. Unlike Codeman,
though, a Paseo restart no longer restarts the container: `agentfest-paseo`
restarts the daemon in place, so terminals' tmux servers, Chrome and anything
started by hand stay up. `kill` the `Paseo Supervisor` process to restart it.

**Paseo is pinned by the chart, not the image.** It ships several releases a
week and installs into the persistent volume, into its own prefix
(`~/.paseo-app`) rather than the global npm one — which is also what makes the
app's own update button refuse, so the pin is what runs. Upgrading is a
`values.yaml` bump and a pod restart. Claude Code follows the same rule. Both
are compared against the version actually installed, not a marker file, so an
install that drifted is put back. Everything else follows the opposite rule: a
new CLI means a PR against dotfiles and a new image.

**Voice is off.** Paseo's local dictation and voice mode download ~800 MB of
speech models and run them on the node's CPU. The phone keyboard's own
dictation works in the composer anyway.

**The SSH key is effectively required.** dotfiles' `claude-skills` module clones
`agent-smith` during home-manager activation, and that clone is not fault
tolerant. Without a key that can read it, activation fails. The entrypoint
deliberately continues anyway and starts Paseo, so a broken activation leaves
you with a reachable terminal to debug from rather than a crash-looping pod —
but the environment is incomplete until the key is mounted.

**`local-path` is node-local.** The PVC pins the pod to whichever node first
schedules it. Pin the pod with a `nodeSelector` from its very first deploy, or
it can land — and stay — on a worker you did not mean.

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

## Status

Running side by side with the last Codeman computer (`festie`, 0.1.39) while
Paseo proves itself. `festie` goes once this one has carried the daily work.
