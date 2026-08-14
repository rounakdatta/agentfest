{
  description = "agentfest — a persistent remote computer whose primary UI is Claude Code";

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

      # The profile deliberately precedes the npm prefix: dotfiles' `claude` is
      # a wrapper that layers hierarchical skills on, and the npm package
      # installs a bin of the same name. The wrapper has to win the PATH lookup
      # and reach the real binary through CLAUDE_REAL_BINARY instead.
      basePath = "${hmProfileBin}:${npmBin}:${homeDir}/.nix-profile/bin:/bin:/usr/bin";

      # The whole point of the exercise: the image's environment IS the
      # laptop's environment, evaluated for Linux.
      homeActivation = dotfiles.homeConfigurations.festie.activationPackage;

      # Codeman ships several releases a week, so it is pinned by the *chart*
      # rather than baked into the image: bumping it is a values.yaml edit and
      # a pod restart, not an image rebuild. It installs into the persistent
      # volume, so it survives restarts and is only fetched when the pin moves.
      defaultCodemanVersion = "latest";

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
      '';

      # dockerTools.fakeNss only knows root and nobody. Codeman, tmux and
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
          # activation itself, and tmux is what Codeman drives; relying on
          # ~/.nix-profile for either means one failure cascades into three.
          git
          tmux

          # aicodeman depends on node-pty, which ships no linux-x64 prebuild
          # and falls back to `node-gyp rebuild`. That needs a full C++
          # toolchain and Python at npm-install time — and gyp's generated
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
          CODEMAN_VERSION="''${AGENTFEST_CODEMAN_VERSION:-${defaultCodemanVersion}}"
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
            else
              log "no personal.pem — git over ssh and the agent-smith clone will fail"
            fi

            # configs/gnupg imports this during activation, which is what makes
            # pass/gopass — and therefore the pass-backed MCP servers — work.
            if [ -f "$SSH_SOURCE/private.key" ]; then
              install -m 600 "$SSH_SOURCE/private.key" "$HOME_DIR/.secrets/private.key"
              log "installed gpg key at ~/.secrets/private.key"
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
            log "WARNING: starting Codeman anyway so the terminal stays reachable"
            log "WARNING: and you can debug from the very UI you'd otherwise lose."
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
              # is the entrypoint dying here and Codeman never starting.
              set +u
              # shellcheck disable=SC1090,SC1091
              . "$prof/etc/profile.d/hm-session-vars.sh"
              set -u
            fi
          done

          export PATH="$HOME_DIR/.npm-global/bin:$PATH"

          # --- 4. install/refresh the npm-managed agents -------------------
          export NPM_CONFIG_PREFIX="$HOME_DIR/.npm-global"
          mkdir -p "$NPM_CONFIG_PREFIX"

          # Point node-gyp at the headers already in the image instead of
          # letting it fetch them from nodejs.org — one less network
          # dependency on a boot that is already doing a lot.
          export npm_config_nodedir="${pkgs.nodejs}"

          # Install a package unless the recorded version already matches.
          #
          # A spec of "latest" resolves against the registry on every boot, so
          # the machine tracks upstream by restarting rather than by editing a
          # pin. The marker still guards the install itself: reinstalling is
          # not free — aicodeman compiles node-pty from source — so we pay only
          # when upstream has actually moved.
          #
          # A registry lookup failure is deliberately not fatal. Keeping the
          # version already on the volume is always better than refusing to
          # boot because npmjs.org was briefly unreachable.
          ensure_npm_pkg() {
            pkg="$1"; spec="$2"; marker="$NPM_CONFIG_PREFIX/.agentfest-$3-version"

            if [ "$spec" = "latest" ]; then
              target="$(npm view "$pkg" version 2>/dev/null || true)"
              if [ -z "$target" ]; then
                log "WARNING: could not resolve $pkg@latest; keeping $(cat "$marker" 2>/dev/null || echo none)"
                return 0
              fi
              log "$pkg tracks latest -> $target"
            else
              target="$spec"
            fi

            if [ "$(cat "$marker" 2>/dev/null || true)" = "$target" ]; then
              log "$pkg@$target already present"
              return 0
            fi

            log "installing $pkg@$target"
            if npm install -g "$pkg@$target"; then
              printf '%s\n' "$target" > "$marker"
            else
              log "WARNING: installing $pkg@$target FAILED; leaving previous install in place"
            fi
          }

          # The npm package is `aicodeman`; `codeman` on npm is an unrelated
          # 0.0.1 squat.
          ensure_npm_pkg aicodeman "$CODEMAN_VERSION" codeman
          ensure_npm_pkg @anthropic-ai/claude-code "$CLAUDE_CODE_VERSION" claude-code

          # --- 5. hand over to Codeman -------------------------------------
          # -H binds beyond loopback, which Codeman refuses to do quietly
          # without CODEMAN_PASSWORD. Tinyauth sits in front of it as well.
          if [ -z "''${CODEMAN_PASSWORD:-}" ]; then
            log "WARNING: CODEMAN_PASSWORD is unset — Codeman is an RCE surface"
            log "WARNING: by design, so it should never be the only thing between"
            log "WARNING: the network and this pod."
          fi

          log "starting codeman on ''${CODEMAN_BIND_HOST:-0.0.0.0}:''${CODEMAN_PORT:-3000}"
          exec codeman web -H "''${CODEMAN_BIND_HOST:-0.0.0.0}"
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
        inherit entrypoint homeActivation;

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
            ExposedPorts = { "3000/tcp" = { }; };
            Env = [
              "HOME=${homeDir}"
              "USER=${user}"
              "PATH=${basePath}"

              # Codeman resolves a pane's shell as $SHELL -> passwd -> /bin/bash,
              # and only accepts a candidate that exists and is executable — so
              # naming fish here yields fish when activation has populated the
              # profile, and falls back to the passwd entry's bash when it has
              # not. fish is on Codeman's own login-flag allowlist, so it still
              # gets spawned as `-i -l` and reads /etc/profile like the rest.
              "SHELL=${hmProfileBin}/fish"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "AGENTFEST_HOME_ACTIVATION=${homeActivation}"
              "AGENTFEST_CODEMAN_VERSION=${defaultCodemanVersion}"
              "AGENTFEST_CLAUDE_CODE_VERSION=${defaultClaudeCodeVersion}"
              # dotfiles' claude wrapper resolves the real binary through this.
              # Points at the npm install rather than the nixpkgs one so the
              # client is current enough to know Opus 5 exists.
              "CLAUDE_REAL_BINARY=${npmBin}/claude"
              "LANG=C.UTF-8"
              "TERM=xterm-256color"
            ];
          };

          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp
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
