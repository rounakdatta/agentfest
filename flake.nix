{
  description = "agentfest — a persistent remote computer that runs coding agents, driven from Paseo";

  inputs = {
    # festie — the definition of what the machine *is* — lives in dotfiles.
    # agentfest only packages and deploys it, so vim/tmux/fish/git/claude
    # settings are never duplicated here.
    dotfiles.url = "github:rounakdatta/dotfiles";

    # Deliberately follow dotfiles' pin rather than declaring our own: the
    # container and the laptop must never drift onto different nixpkgs.
    nixpkgs.follows = "dotfiles/nixpkgs";
  };

  outputs = { self, nixpkgs, dotfiles }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        # claude-code is unfree; same reasoning as dotfiles' festie config.
        config.allowUnfree = true;
      };

      user = "rounak";
      uid = 1000;
      gid = 100; # "users", home-manager's default primary group
      homeDir = "/home/${user}";

      # Where standalone home-manager actually puts the profile. ~/.nix-profile
      # is the legacy location and does not exist here, so anything that hard
      # codes it finds an empty PATH.
      hmProfileBin = "${homeDir}/.local/state/nix/profiles/home-manager/home-path/bin";
      npmBin = "${homeDir}/.npm-global/bin";

      # Where dotfiles' activation drops release binaries it fetches itself —
      # currently just mic (configs/mic). Named here rather than left to
      # home.sessionPath alone because sessionPath only reaches shells that
      # source hm-session-vars.sh; an MCP server spawned by Claude Code may not
      # be one, and `command = "mic"` has to resolve there too.
      localBin = "${homeDir}/.local/bin";

      # Homebrew, in an unsupported prefix on purpose — see the bootstrap step
      # in the entrypoint.
      brewPrefix = "${homeDir}/.homebrew";
      brewBin = "${brewPrefix}/bin";

      # Paseo installs into a prefix of its own rather than the global one
      # (~/.npm-global), on purpose. The app's "update" button runs
      # `npm i -g @getpaseo/cli` and refuses unless the daemon itself runs from
      # that global install. Outside it the button fails safely, so the version
      # that runs is always the one the chart pins -- instead of drifting out of
      # band the way claude-code's did behind its marker file. The entrypoint
      # links the CLI into paseoBin; nothing else in the prefix is on PATH.
      paseoPrefix = "${homeDir}/.paseo-app";
      paseoBin = "${paseoPrefix}/bin";

      # localBin leads so a mic fetched by dotfiles wins over one installed by
      # brew: it needs nothing but gh, where brew's copy depends on a whole
      # package manager having bootstrapped correctly. The brew copy stays
      # reachable at its absolute path for deliberate testing.
      #
      # The home-manager profile deliberately precedes the npm prefix: dotfiles'
      # `claude` is a wrapper that layers hierarchical skills on, and the npm
      # package installs a bin of the same name. The wrapper has to win the PATH
      # lookup and reach the real binary through CLAUDE_REAL_BINARY instead.
      # This matters more than it did under Codeman: Paseo launches whichever
      # `claude` the daemon's PATH resolves first, so this order is what decides
      # whether its agents get the inherited skills.
      basePath = "${localBin}:${paseoBin}:${hmProfileBin}:${npmBin}:${homeDir}/.nix-profile/bin:${brewBin}:/bin:/usr/bin";

      # The whole point of the exercise: the image's environment IS the
      # laptop's environment, evaluated for Linux.
      homeActivation = dotfiles.homeConfigurations.festie.activationPackage;

      # Paseo ships several releases a week, so it is pinned by the *chart*
      # rather than baked into the image: bumping it is a values.yaml edit and
      # a pod restart, not an image rebuild. It installs into the persistent
      # volume, so it survives restarts and is only fetched when the pin moves.
      defaultPaseoVersion = "latest";

      # Claude Code comes from npm, not nixpkgs, for the same reason the laptop
      # takes it from Homebrew: the client version gates which models it can
      # see. nixpkgs pinned at 2026-03-28 carries 2.1.86, which predates Opus 5
      # entirely and silently falls back to Opus 4.6 — and a read-only Nix store
      # means `claude update` cannot dig itself out. Installed into the
      # persistent volume, so it survives restarts and stays updatable in place.
      defaultClaudeCodeVersion = "latest";

      # Claude Code's npm package ships a prebuilt native binary (claude.exe)
      # whose ELF interpreter is the FHS path /lib64/ld-linux-x86-64.so.2. A
      # Nix-built image has no /lib64 at all, so exec fails with the famously
      # unhelpful "cannot execute: required file not found" — the *interpreter*
      # is missing, not the binary. Providing the loader (and the handful of
      # libraries such binaries expect to find on a default search path) is
      # what makes any non-Nix prebuilt executable runnable here.
      #
      # Deliberately not LD_LIBRARY_PATH: that would leak into Nix binaries
      # which already carry absolute RPATHs, and is a well-known way to break
      # them. Populating /lib64 only affects binaries that go looking there.
      fhsLoader = pkgs.runCommand "agentfest-fhs-loader" { } ''
        mkdir -p "$out/lib64"
        ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 "$out/lib64/ld-linux-x86-64.so.2"
        for lib in ${pkgs.glibc}/lib/lib*.so*; do
          ln -sf "$lib" "$out/lib64/$(basename "$lib")" 2>/dev/null || true
        done
        for lib in ${pkgs.stdenv.cc.cc.lib}/lib/lib*.so*; do
          ln -sf "$lib" "$out/lib64/$(basename "$lib")" 2>/dev/null || true
        done

        # A minimal FHS /usr/bin, for the same class of reason as /lib64 above:
        # programs that look for a fixed absolute path rather than searching
        # PATH. Adding these to /bin does nothing — the lookups are literal.
        #
        # Homebrew needs all of them, and each failure is fatal and opaque:
        #
        #   ldd  — vendor-install runs `/usr/bin/ldd --version` to check the
        #          system glibc is >= 2.13 before fetching Portable Ruby, and
        #          odie()s if it can't parse the output. Without it: "Failed to
        #          detect system Glibc version" and brew never runs at all.
        #
        #   cc / gcc / ld / as — DevelopmentTools.locate on Linux
        #          (extend/os/linux/development_tools.rb) tries
        #          HOMEBREW_PREFIX/opt/{binutils,glibc}/bin, then
        #          HOMEBREW_PREFIX/bin, then /usr/bin/<tool>. PATH is never
        #          consulted, so a compiler in /bin is invisible and every
        #          `brew install` — even one that compiles nothing — stops at
        #          "No developer tools installed".
        #
        # gcc and binutils are already in this image's closure (the entrypoint's
        # runtimeInputs pull them in for node-gyp), so these cost symlinks.
        mkdir -p "$out/usr/bin"
        ln -s ${pkgs.glibc.bin}/bin/ldd "$out/usr/bin/ldd"
        for tool in gcc cc; do
          ln -sf ${pkgs.gcc}/bin/$tool "$out/usr/bin/$tool"
        done
        for tool in ld as; do
          ln -sf ${pkgs.binutils}/bin/$tool "$out/usr/bin/$tool"
        done
      '';

      # dockerTools.fakeNss only knows root and nobody. Paseo, tmux and
      # Claude Code all want a real user with a real home.
      nssFiles = pkgs.runCommand "agentfest-nss" { } ''
        mkdir -p "$out/etc"

        cat > "$out/etc/passwd" <<EOF
        root:x:0:0:System administrator:/root:${pkgs.bashInteractive}/bin/bash
        ${user}:x:${toString uid}:${toString gid}:Rounak Datta:${homeDir}:${pkgs.bashInteractive}/bin/bash
        nobody:x:65534:65534:Nobody:/homeless-shelter:/noshell
        EOF

        cat > "$out/etc/group" <<EOF
        root:x:0:
        users:x:${toString gid}:
        nogroup:x:65534:
        EOF

        cat > "$out/etc/nsswitch.conf" <<EOF
        hosts: files dns
        EOF

        # Cosmetic but worth having. Homebrew sources /etc/os-release purely to
        # read PRETTY_NAME into its version string and user agent, falling back
        # to `uname -r`; without the file every brew invocation prints two
        # "No such file or directory" lines from bash before doing anything.
        # A Nix-built image has no distro to describe, so this says so.
        cat > "$out/etc/os-release" <<EOF
        NAME="agentfest"
        ID=agentfest
        PRETTY_NAME="agentfest (Nix-built container)"
        HOME_URL="https://github.com/rounakdatta/agentfest"
        EOF

        # A login shell (`bash -lc`, `su -`, and anything that shells out via
        # `\$SHELL -lc`) ignores the image's Env and rebuilds PATH from
        # scratch. Without this file that PATH contains none of the profile,
        # so `node`, `git` and friends vanish — which is exactly how
        # claude-mem's hooks fail: they do
        # `export PATH="\$(\$SHELL -lc 'echo \$PATH')"` and get nothing back.
        cat > "$out/etc/profile" <<EOF
        export PATH="${basePath}:\$PATH"
        EOF
      '';

      # Closes the one gap in Paseo's relay authentication (getpaseo/paseo#4087).
      #
      # The relay is end-to-end encrypted and never learns the daemon's key, so
      # it cannot connect on its own. What it does not do yet is require the
      # daemon password: a relay client that sends no password at all is let in
      # as owner, a stopgap upstream keeps until new mobile builds reach both
      # stores (`COMPAT(relayPasswordOptional)` in session-admission-auth).
      # Until then the pairing link alone is a full login. Removing that one
      # branch makes the link AND the password necessary; current apps already
      # send the password inside the encrypted channel.
      #
      # Fails closed. The result is proven by calling the real function, not by
      # trusting the text: if an upgrade reshapes the code so the patch no
      # longer applies, the self-test fails and Paseo does not start. Once
      # upstream drops the stopgap there is nothing to patch and the test still
      # passes, so this can be deleted then.
      paseoHarden = pkgs.writeText "agentfest-paseo-harden.mjs" ''
        import { readFileSync, writeFileSync } from "node:fs";
        import path from "node:path";
        import { pathToFileURL } from "node:url";

        const serverRoot = process.argv[2];
        const file = path.join(serverRoot, "dist/server/server/session-admission-auth.js");
        const exemption = 'if (transport === "relay") {';
        const closed = 'if (false /* agentfest: relay clients need the password too */) {';

        const source = readFileSync(file, "utf8");
        const found = source.split(exemption).length - 1;
        if (found > 1) {
          console.error("[agentfest] " + found + " relay exemptions in " + file + ", expected at most 1");
          process.exit(1);
        }
        if (found === 1) writeFileSync(file, source.replace(exemption, closed));

        const { resolveSessionAdmission } = await import(pathToFileURL(file).href);
        const result = await resolveSessionAdmission({
          credential: undefined,
          passwordHash: "set",
          localCredential: null,
          transport: "relay",
        });
        if (!result.rejection) {
          console.error("[agentfest] a relay client with no password is still admitted");
          process.exit(1);
        }
        console.log("[agentfest] relay clients must present the daemon password");
      '';

      # What tini runs: Paseo's own supervisor, restarted if it ever exits.
      #
      # Paseo's supervisor already restarts its worker after a crash; this loop
      # covers the supervisor itself. It is what lets Paseo stop -- for an
      # upgrade, a config change, or a crash -- without the container going with
      # it. Under Codeman that was not true: Codeman was tini's only child, so
      # every Codeman exit restarted the pod and took every session with it.
      # A Paseo restart still ends every running agent turn (agents are the
      # daemon's children), but the container, its terminals' tmux servers,
      # Chrome and anything else started by hand all stay up.
      #
      # The pid lock is removed before each start because it lives on the
      # persistent volume: after an unclean container stop, its pid can belong
      # to an unrelated process in the new container, and Paseo then refuses to
      # start with "Another Paseo daemon is already running". Nothing else in
      # this container starts a daemon on this home, so the file is always stale
      # here.
      paseoRun = pkgs.writeShellApplication {
        name = "agentfest-paseo";
        runtimeInputs = with pkgs; [ coreutils nodejs ];
        text = ''
          log() { printf '[agentfest] %s\n' "$*"; }

          SERVER_ROOT="$1"
          PASEO_HOME="''${PASEO_HOME:-$HOME/.paseo}"
          export PASEO_HOME

          stopping=0
          child=""
          on_signal() {
            stopping=1
            if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi
          }
          trap on_signal TERM INT

          while [ "$stopping" = 0 ]; do
            if ! node ${paseoHarden} "$SERVER_ROOT"; then
              log "ERROR: not starting Paseo: the relay password check could not be enforced"
              log "ERROR: retrying in 60s; fix the pin or the patch in agentfest's flake.nix"
              sleep 60 &
              wait $! || true
              continue
            fi

            mkdir -p "$PASEO_HOME"
            rm -f "$PASEO_HOME/paseo.pid"

            node "$SERVER_ROOT/dist/scripts/supervisor-entrypoint.js" &
            child=$!
            # The first wait returns early when a trapped signal arrives; the
            # second reaps the child once it has finished shutting down.
            wait "$child" || true
            wait "$child" 2>/dev/null || true
            child=""

            [ "$stopping" = 0 ] || break
            log "Paseo exited; restarting in 5s"
            sleep 5 &
            wait $! || true
          done
        '';
      };

      entrypoint = pkgs.writeShellApplication {
        name = "agentfest-init";
        runtimeInputs = with pkgs; [
          coreutils
          bashInteractive
          nix
          nodejs
          gnugrep
          openssh

          # Floor for things the entrypoint needs before — or without — a
          # successful activation. git is used by claude-skills' clone during
          # activation itself, and tmux is what a long-lived Paseo terminal
          # should run inside; relying on ~/.nix-profile for either means one
          # failure cascades into three.
          git
          tmux

          # PID 1, see the exec at the end of this script.
          tini

          # Any npm package with a native addon and no linux-x64 prebuild falls
          # back to `node-gyp rebuild`. Paseo's own (node-pty, msgpackr) ship
          # prebuilds, but MCP servers installed through npm/npx often do not,
          # and gyp needs a full C++ toolchain and Python -- and its generated
          # Makefile shells out to sed and awk, which are not in coreutils.
          python3
          gnumake
          gcc
          binutils
          gnused
          gawk
          findutils
        ];
        text = ''
          HOME_DIR="''${HOME:-${homeDir}}"
          PASEO_VERSION="''${AGENTFEST_PASEO_VERSION:-${defaultPaseoVersion}}"
          CLAUDE_CODE_VERSION="''${AGENTFEST_CLAUDE_CODE_VERSION:-${defaultClaudeCodeVersion}}"
          ACTIVATION="''${AGENTFEST_HOME_ACTIVATION:-${homeActivation}}"

          log() { printf '[agentfest] %s\n' "$*"; }

          mkdir -p "$HOME_DIR"
          cd "$HOME_DIR"

          # --- 1. SSH material --------------------------------------------
          # The key is mounted read-only somewhere neutral and copied into
          # ~/.ssh rather than mounted there directly: ~/.ssh has to stay
          # writable, both because home-manager's ssh module writes
          # ~/.ssh/config into it and because known_hosts needs appending.
          # This runs before activation because activation is what clones
          # agent-smith over SSH.
          # Each secret is copied to the exact path dotfiles already expects,
          # rather than mounted there: a Secret volume is read-only, and both
          # destinations sit in directories that have to stay writable —
          # ~/.ssh for home-manager's ssh config and known_hosts, ~/.gnupg for
          # the imported keyring.
          SSH_SOURCE="''${AGENTFEST_SSH_DIR:-/run/secrets/agentfest}"
          if [ -d "$SSH_SOURCE" ]; then
            mkdir -p "$HOME_DIR/.ssh/keys" "$HOME_DIR/.secrets"
            chmod 700 "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/keys" "$HOME_DIR/.secrets"

            # configs/ssh points github.com and gitlab.com at this exact path.
            if [ -f "$SSH_SOURCE/personal.pem" ]; then
              install -m 600 "$SSH_SOURCE/personal.pem" "$HOME_DIR/.ssh/keys/personal.pem"
              log "installed ssh key at ~/.ssh/keys/personal.pem"

              # Also as a default identity, which fixes a first-boot-only
              # ordering trap: home-manager runs passwordStore (which fetches
              # the store from gitlab over ssh) BEFORE linkGeneration writes
              # ~/.ssh/config. On a fresh volume there is therefore no
              # IdentityFile directive yet, ssh falls back to default identity
              # paths, finds nothing, and the fetch fails — leaving an empty
              # password store and, downstream, no gopass and no GitHub PAT.
              # It self-heals on the second boot once the config persists,
              # which is exactly the kind of "works on restart" mystery worth
              # not shipping.
              install -m 600 "$SSH_SOURCE/personal.pem" "$HOME_DIR/.ssh/id_rsa"
            else
              log "no personal.pem — git over ssh and the agent-smith clone will fail"
            fi

            # configs/gnupg imports this during activation, which is what makes
            # pass/gopass — and therefore the pass-backed MCP servers — work.
            if [ -f "$SSH_SOURCE/private.key" ]; then
              install -m 600 "$SSH_SOURCE/private.key" "$HOME_DIR/.secrets/private.key"
              log "installed gpg key at ~/.secrets/private.key"
              # gpg refuses to be quiet about a group- or world-readable
              # homedir, and the PVC's fsGroup makes it exactly that.
              mkdir -p "$HOME_DIR/.gnupg"
              chmod 700 "$HOME_DIR/.gnupg"
            else
              log "no private.key — gpg keyring stays empty, so pass cannot decrypt"
            fi

            # Anything else in the mount lands in ~/.ssh as-is.
            for key in "$SSH_SOURCE"/*; do
              [ -f "$key" ] || continue
              case "$(basename "$key")" in
                personal.pem | private.key) continue ;;
              esac
              install -m 600 "$key" "$HOME_DIR/.ssh/$(basename "$key")"
            done
          else
            log "no secrets mounted at $SSH_SOURCE — ssh, gpg and pass will all be unconfigured"
          fi

          # Without this, a non-interactive `git clone git@github.com:...`
          # dies on host-key verification rather than prompting.
          #
          # gitlab.com matters as much as github.com here: configs/ssh names
          # both, and configs/pass syncs the password store from gitlab — which
          # in turn gates gopass, and therefore the GitHub PAT that
          # createTokenIncludedGitHubHttpsConfig writes for https remotes.
          # Omitting it breaks that whole chain at the first link.
          mkdir -p "$HOME_DIR/.ssh"
          chmod 700 "$HOME_DIR/.ssh"
          for host in github.com gitlab.com; do
            if ! grep -q "^$host " "$HOME_DIR/.ssh/known_hosts" 2>/dev/null; then
              log "seeding known_hosts for $host"
              ssh-keyscan -t rsa,ecdsa,ed25519 "$host" \
                >> "$HOME_DIR/.ssh/known_hosts" 2>/dev/null || \
                log "WARNING: ssh-keyscan failed for $host"
            fi
          done

          # --- 2. activate the festie home profile ------------------------
          # On a fresh volume this populates an empty /home/rounak; on every
          # later boot it reconciles the home against whatever the image now
          # carries, which is how an image bump reaches the running computer.
          log "activating festie home profile"
          mkdir -p "$HOME_DIR/.local/state/nix/profiles"

          # home-manager refuses to overwrite a file it does not own, and
          # several things here rewrite their own config at runtime: Claude
          # Code rewrites ~/.claude/settings.json when it installs plugins, and
          # `doom install` rewrites ~/.doom.d/*. Each of those replaces an HM
          # symlink with a real file, after which checkLinkTargets — the second
          # activation step — aborts the whole run before anything is applied.
          # The machine then silently stops converging: no skills sync, no
          # pass setup, no new packages, on every subsequent boot.
          #
          # Backing up rather than deleting keeps one generation of whatever
          # the runtime wrote, which is occasionally worth reading. The stale
          # backup has to go first, because HM equally refuses to clobber that.
          export HOME_MANAGER_BACKUP_EXT="hm-backup"
          find "$HOME_DIR" -maxdepth 4 -name '*.hm-backup' -delete 2>/dev/null || true

          if ! "$ACTIVATION/activate"; then
            log "WARNING: home-manager activation FAILED."
            log "WARNING: starting Paseo anyway so a terminal stays reachable"
            log "WARNING: and you can debug from the very app you'd otherwise lose."
            log "WARNING: the usual cause is claude-skills' agent-smith clone"
            log "WARNING: having no SSH key — see the chart's ssh.existingSecret."
          fi

          # --- 3. pick up the activated session environment ----------------
          # Standalone home-manager puts the profile under
          # $XDG_STATE_HOME/nix/profiles, and ~/.nix-profile is the legacy
          # location that may not exist at all. Looking only at the latter is
          # how the whole festie toolchain silently failed to reach PATH.
          for prof in \
            "$HOME_DIR/.local/state/nix/profiles/home-manager/home-path" \
            "$HOME_DIR/.nix-profile"
          do
            if [ -d "$prof/bin" ]; then
              export PATH="$prof/bin:$PATH"
            fi
            if [ -f "$prof/etc/profile.d/hm-session-vars.sh" ]; then
              # hm-session-vars.sh probes $__HM_SESS_VARS_SOURCED before
              # setting it, which is fatal under writeShellApplication's
              # `set -u`. Drop nounset just for the source — the alternative
              # is the entrypoint dying here and Paseo never starting.
              set +u
              # shellcheck disable=SC1090,SC1091
              . "$prof/etc/profile.d/hm-session-vars.sh"
              set -u
            fi
          done

          # The npm prefix is NOT prepended here, although it used to be. The
          # image's PATH (basePath) already carries it, deliberately after the
          # home-manager profile, and prepending it undid exactly that: under
          # Codeman every session resolved `claude` to the npm binary and ran
          # without dotfiles' wrapper, so the hierarchical skills never loaded.
          # Paseo launches whatever `claude` this PATH finds first.

          # Paseo's terminals start $SHELL. It names fish, which only exists
          # once activation has populated the profile; fall back to the passwd
          # shell rather than have every terminal fail to spawn.
          if [ ! -x "''${SHELL:-}" ]; then
            log "WARNING: ''${SHELL:-SHELL} is missing (activation?); terminals will use bash"
            export SHELL="${pkgs.bashInteractive}/bin/bash"
          fi

          # home-manager runs importGpgKey — which auto-starts gpg-agent —
          # before linkGeneration writes ~/.gnupg/gpg-agent.conf. The agent
          # therefore comes up with default settings, no pinentry-program, and
          # never reloads config, so every decryption for the life of the pod
          # fails with "No pinentry" even though the conf and the binary are
          # both correct. Killing it here means the next gpg call starts an
          # agent that has actually read the file.
          if command -v gpgconf >/dev/null 2>&1; then
            gpgconf --kill gpg-agent >/dev/null 2>&1 || true
            log "restarted gpg-agent so it picks up pinentry-curses"
          fi

          # --- 4. install/refresh the npm-managed agents -------------------
          export NPM_CONFIG_PREFIX="$HOME_DIR/.npm-global"
          mkdir -p "$NPM_CONFIG_PREFIX"

          # Point node-gyp at the headers already in the image instead of
          # letting it fetch them from nodejs.org — one less network
          # dependency on a boot that is already doing a lot.
          export npm_config_nodedir="${pkgs.nodejs}"

          # Install a package unless the version actually installed already
          # matches the pin.
          #
          # "Installed" means the package's own package.json, not a marker file
          # this script wrote. A marker only records what this script last did:
          # when claude-code was upgraded out of band on festie, its marker
          # still said the pinned 2.1.233 while 2.1.278 ran, so every boot
          # skipped the install and the pin silently stopped meaning anything.
          # Reading the real version makes a drifted install converge back.
          #
          # A spec of "latest" resolves against the registry on every boot, so
          # the machine tracks upstream by restarting rather than by editing a
          # pin. A registry lookup failure is deliberately not fatal: keeping
          # the version already on the volume is always better than refusing to
          # boot because npmjs.org was briefly unreachable.
          #
          # Usage: ensure_npm_pkg <package> <spec> <its package.json once
          # installed> <npm install args that place it>...
          ensure_npm_pkg() {
            pkg="$1"; spec="$2"; manifest="$3"; shift 3

            current=""
            if [ -f "$manifest" ]; then
              current="$(node -p 'require(process.argv[1]).version' "$manifest" 2>/dev/null || true)"
            fi

            if [ "$spec" = "latest" ]; then
              target="$(npm view "$pkg" version 2>/dev/null || true)"
              if [ -z "$target" ]; then
                log "WARNING: could not resolve $pkg@latest; keeping ''${current:-nothing}"
                return 0
              fi
              log "$pkg tracks latest -> $target"
            else
              target="$spec"
            fi

            if [ "$current" = "$target" ]; then
              log "$pkg@$target already installed"
              return 0
            fi

            log "installing $pkg@$target (was ''${current:-not installed})"
            if ! npm install --no-audit --no-fund "$@" "$pkg@$target"; then
              log "WARNING: installing $pkg@$target FAILED; leaving ''${current:-nothing} in place"
            fi
          }

          ensure_npm_pkg @anthropic-ai/claude-code "$CLAUDE_CODE_VERSION" \
            "$NPM_CONFIG_PREFIX/lib/node_modules/@anthropic-ai/claude-code/package.json" -g

          # --- 4a. Paseo ----------------------------------------------------
          # Into its own prefix, not the global one; basePath explains why.
          # Only the CLI is linked onto PATH: the prefix's node_modules/.bin
          # also carries esbuild, node-which and friends, which have no
          # business shadowing anything.
          PASEO_PREFIX="${paseoPrefix}"
          PASEO_SERVER_ROOT="$PASEO_PREFIX/node_modules/@getpaseo/server"
          mkdir -p "$PASEO_PREFIX/bin"
          ensure_npm_pkg @getpaseo/cli "$PASEO_VERSION" \
            "$PASEO_PREFIX/node_modules/@getpaseo/cli/package.json" --prefix "$PASEO_PREFIX"
          ln -sfn "$PASEO_PREFIX/node_modules/@getpaseo/cli/bin/paseo" "${paseoBin}/paseo"

          # --- 4b. Homebrew -------------------------------------------------
          # Installed into the persistent volume rather than baked into the
          # image, for the same reason as Paseo and Claude Code: it is a
          # self-updating thing that would otherwise be frozen at image-build
          # time, and a read-only Nix store cannot host a package manager that
          # writes to its own prefix.
          #
          # ~/.homebrew is an *unsupported* prefix on Linux — Homebrew only
          # blesses /home/linuxbrew/.linuxbrew — which means no bottles: every
          # formula would build from source. That is a deliberate trade. The
          # supported prefix lives outside $HOME, so it would sit in the image
          # layer and be discarded on every pod restart, re-downloading brew
          # each boot. And it cannot be created at runtime anyway: /home is
          # root-owned and this container runs as ${toString uid}.
          #
          # Nothing here needs bottles today. mic's formula has no dependencies
          # and its install is "download a tarball, drop one static binary in
          # bin" — zero compilation. Reconsider if that stops being true.
          BREW_PREFIX="$HOME_DIR/.homebrew"
          if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
            log "installing Homebrew into $BREW_PREFIX (first boot only)"
            # A full clone, not --depth=1: brew reports "shallow or no git
            # repository" on a shallow one and refuses to update itself.
            if git clone --quiet https://github.com/Homebrew/brew "$BREW_PREFIX"; then
              log "Homebrew installed"
            else
              log "WARNING: Homebrew clone failed — brew will be unavailable."
              log "WARNING: nothing else depends on it; mic comes from dotfiles."
            fi
          fi
          if [ -x "$BREW_PREFIX/bin/brew" ]; then
            # Appended, not prepended: dotfiles installs mic into
            # ~/.local/bin and that copy should win (see basePath).
            # Homebrew 6 refuses to write its tap-trust store when the prefix
            # is group- or world-writable:
            #
            #   Error: Refusing to write insecure trust store: trust store
            #   directory /home/rounak/.homebrew is group or world writable.
            #
            # The PVC's fsGroup makes every directory under $HOME exactly that,
            # so a freshly cloned prefix is always 0775 and every `brew install`
            # of a third-party tap fails. Same root cause as the ~/.gnupg chmod
            # earlier in this script, and the same fix. Run on every boot rather
            # than only after the clone, because the mode is a property of the
            # volume, not of the clone.
            chmod g-w,o-w "$BREW_PREFIX" || true

            export PATH="$PATH:$BREW_PREFIX/bin"
          fi

          # --- 5. hand over to Paseo ---------------------------------------
          # The daemon is reached through Paseo's end-to-end encrypted relay:
          # it dials out, so nothing has to listen on a public address. Its
          # password is what stops the pairing link from being a login on its
          # own (see paseoHarden), so its absence is worth shouting about.
          if [ -z "''${PASEO_PASSWORD:-}" ]; then
            log "WARNING: PASEO_PASSWORD is unset — whoever holds the pairing"
            log "WARNING: link controls this machine, as this user, with its keys."
          fi

          log "starting Paseo on ''${PASEO_LISTEN:-127.0.0.1:6767} (relay ''${PASEO_RELAY_ENABLED:-per config})"

          # Through tini, so that PID 1 reaps. Exec'ing a server directly makes
          # it PID 1, and no Node server is an init: it never reaps the orphans
          # that a long agent session leaves behind, so they accumulate as
          # zombies for the life of the pod. Two costs, both seen for real:
          #
          #   - they hold PIDs. A handful of Chrome launches left 434 of them.
          #   - `kill -0` SUCCEEDS on a zombie, so any wait loop that probes a
          #     pid with a signal waits forever. That silently turned finished
          #     provider logins into "still-waiting" timeouts in the
          #     automate-mic-doctor-refresh skill until it was taught to read
          #     /proc/<pid>/stat instead.
          #
          # -g so signals reach the whole process group: terminationGracePeriod
          # is 60s precisely so a long build is not truncated, and that only
          # works if the children are actually signalled.
          exec tini -g -- ${paseoRun}/bin/agentfest-paseo "$PASEO_SERVER_ROOT"
        '';
      };

      rootEnv = pkgs.buildEnv {
        name = "agentfest-root";
        paths = [
          entrypoint
          nssFiles
          fhsLoader
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.nix
          pkgs.cacert
          pkgs.dockerTools.binSh
          pkgs.dockerTools.usrBinEnv
          pkgs.dockerTools.caCertificates

          # An FHS-shaped /bin, for tools that assume one. Homebrew is the
          # reason this exists: bin/brew hardcodes
          # PATH="/usr/bin:/bin:/usr/sbin:/sbin" unconditionally, discarding
          # whatever we set, so nothing in a Nix profile is visible to it. On
          # this image that left it with /usr/bin containing exactly `env` and
          # /bin holding coreutils, bash and nix — no grep. Its CPU-feature
          # probe greps /proc/cpuinfo, so the failure surfaced as the
          # spectacularly misleading:
          #
          #   Error: Homebrew's x86_64 support on Linux requires a CPU with
          #          SSSE3 support!
          #
          # on a CPU that has SSSE3. Same class of problem as fhsLoader above,
          # and the same kind of fix: put the expected things where a non-Nix
          # program looks, rather than trying to teach it about Nix.
          #
          # gh earns its place for a specific reason: mic's Homebrew formula
          # downloads through gh (the repo is private), and the download
          # strategy resolves it off PATH — brew's sanitized PATH. Without gh
          # in /bin, `brew install mic` fails with "gh CLI not found" while gh
          # sits in the home-manager profile.
          #
          # Cheap in practice: git and gh are already in this image's closure
          # (the entrypoint and festie's home profile pull them in), so these
          # are mostly symlinks rather than new store paths.
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.curl
          pkgs.gnutar
          pkgs.gzip
          pkgs.git
          pkgs.gh
          # openssh is not optional for the tap. The lyric-tech/mic tap is a
          # private repo, and the only credential this container has for it is
          # the mounted SSH key — there is no git credential helper here — so
          # the tap uses the git@github.com clone target, exactly as the laptop
          # does. git then forks `ssh`, off the sanitized PATH, and without it
          # `brew tap` dies on "cannot run ssh: No such file or directory".
          pkgs.openssh
        ];
        # "/usr" is not decorative: dockerTools.usrBinEnv installs to
        # $out/usr/bin/env, so omitting it silently drops /usr/bin/env and
        # every `#!/usr/bin/env` script in the image fails with
        # "bad interpreter" — which is exactly how doom-emacs' installer died.
        pathsToLink = [ "/bin" "/usr" "/etc" "/share" "/lib" "/lib64" ];
      };
    in
    {
      packages.${system} = {
        default = self.packages.${system}.image;

        # Exposed on their own so CI (and a human) can build/inspect the
        # environment without producing a whole image.
        inherit entrypoint homeActivation paseoRun;

        # includeNixDB (via the *WithNixDb variant) is load-bearing, not a
        # nicety: home-manager's activate shells out to nix-env to set the
        # profile generation, which needs a registered store database.
        image = pkgs.dockerTools.buildLayeredImageWithNixDb {
          name = "ghcr.io/rounakdatta/agentfest";
          tag = "latest";
          # `contents`, not `copyToRoot`: buildLayeredImage forwards straight
          # to streamLayeredImage, which never took the newer argument name.
          # includeNixDB also keys off `contents` when registering the store DB.
          contents = [ rootEnv ];
          maxLayers = 100;

          config = {
            Cmd = [ "${entrypoint}/bin/agentfest-init" ];
            User = "${toString uid}:${toString gid}";
            WorkingDir = homeDir;
            ExposedPorts = { "6767/tcp" = { }; };
            Env = [
              "HOME=${homeDir}"
              "USER=${user}"
              "PATH=${basePath}"

              # Paseo's terminals start $SHELL as-is, so this is the shell every
              # terminal in the app gets. The entrypoint falls back to bash when
              # activation has not produced fish.
              "SHELL=${hmProfileBin}/fish"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "AGENTFEST_HOME_ACTIVATION=${homeActivation}"
              "AGENTFEST_PASEO_VERSION=${defaultPaseoVersion}"
              "AGENTFEST_CLAUDE_CODE_VERSION=${defaultClaudeCodeVersion}"

              # Loopback unless the chart says otherwise: the relay dials out,
              # so the daemon needs no reachable listener to be usable.
              "PASEO_LISTEN=127.0.0.1:6767"
              # dotfiles' claude wrapper resolves the real binary through this.
              # Points at the npm install rather than the nixpkgs one so the
              # client is current enough to know Opus 5 exists.
              "CLAUDE_REAL_BINARY=${npmBin}/claude"
              "LANG=C.UTF-8"
              "TERM=xterm-256color"

              # Homebrew, for the prefix bootstrapped into the volume at boot.
              # NO_AUTO_UPDATE matters most: without it every `brew` invocation
              # fetches upstream first, which on a cold container turns a
              # one-second install into minutes. NO_ENV_HINTS silences the
              # "add brew shellenv to your profile" nag, already handled via
              # basePath.
              #
              # Deliberately NOT setting HOMEBREW_PREFIX: brew derives it from
              # the path of its own executable (bin/brew, near the top) and
              # overwrites whatever we pass, so declaring it here would read as
              # authoritative while being ignored. LANG and LC_ALL are likewise
              # on brew's own sanitize list, which is why it still warns about
              # en_US.UTF-8 no matter what the image sets.
              "HOMEBREW_NO_ANALYTICS=1"
              "HOMEBREW_NO_AUTO_UPDATE=1"
              "HOMEBREW_NO_ENV_HINTS=1"
            ];
          };

          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp

            # /var/tmp, 1777 like /tmp above. FHS-standard and generally
            # expected, but the concrete forcing function is Homebrew: on a
            # Landlock-capable kernel (this one reports ABI 6) every
            # `brew install` runs the build in its sandbox, and
            # Sandbox::LinuxBackend#prepare_writable_path mkdir_p's the
            # sandbox's writable paths — /tmp, several /dev entries, and
            # /var/tmp. Every one of those exists in a container except
            # /var/tmp, and /var is root-owned so an unprivileged brew cannot
            # create it, giving:
            #
            #   Error: Permission denied @ dir_s_mkdir - /var/tmp
            #
            # It fails after the download and formula resolution, so it looks
            # like a formula problem rather than a missing directory. There is
            # no env-var escape — HOMEBREW_TEMP and
            # HOMEBREW_AVOID_NESTED_SANDBOXING both leave the path preparation
            # in place. It also broke binutils' post-install step for the same
            # reason.
            mkdir -p var/tmp
            chmod 1777 var/tmp

            mkdir -p home/${user}
          '';

          # The Nix database that includeNixDB bakes in is written as root,
          # but the container runs as ${toString uid}. home-manager's activate
          # shells out to nix-env, which takes a write lock on the DB, so
          # without this it dies on `opening lock file
          # '/nix/var/nix/db/big-lock': Permission denied` and no dotfiles
          # ever reach the home directory.
          #
          # fakeRootCommands rather than extraCommands: only the former runs
          # under fakeroot, where chown is actually recorded into the layer.
          fakeRootCommands = ''
            mkdir -p nix/var/nix home/${user}
            chown -R ${toString uid}:${toString gid} nix/var
            chown ${toString uid}:${toString gid} home/${user}

            # installPackages runs `nix-env -i`, which takes a lock by creating
            # <manifest>.lock *inside* /nix/store — so it needs write
            # permission on the store directory itself, not on its contents.
            # Deliberately not recursive: chowning the whole store would rewrite
            # ownership metadata for every path in a multi-gigabyte closure and
            # balloon the layer, to fix a problem that is only about creating
            # one file in one directory.
            chown ${toString uid}:${toString gid} nix/store
          '';
        };
      };

      checks.${system} = {
        image = self.packages.${system}.image;
        entrypoint = self.packages.${system}.entrypoint;
      };
    };
}
