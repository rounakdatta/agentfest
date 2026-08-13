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

      # The whole point of the exercise: the image's environment IS the
      # laptop's environment, evaluated for Linux.
      homeActivation = dotfiles.homeConfigurations.festie.activationPackage;

      # Codeman ships several releases a week, so it is pinned by the *chart*
      # rather than baked into the image: bumping it is a values.yaml edit and
      # a pod restart, not an image rebuild. It installs into the persistent
      # volume, so it survives restarts and is only fetched when the pin moves.
      defaultCodemanVersion = "1.18.0";

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
        ];
        text = ''
          HOME_DIR="''${HOME:-${homeDir}}"
          CODEMAN_VERSION="''${AGENTFEST_CODEMAN_VERSION:-${defaultCodemanVersion}}"
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
          SSH_SOURCE="''${AGENTFEST_SSH_DIR:-/run/secrets/agentfest-ssh}"
          if [ -d "$SSH_SOURCE" ]; then
            log "installing SSH material from $SSH_SOURCE"
            mkdir -p "$HOME_DIR/.ssh"
            chmod 700 "$HOME_DIR/.ssh"
            for key in "$SSH_SOURCE"/*; do
              [ -f "$key" ] || continue
              install -m 600 "$key" "$HOME_DIR/.ssh/$(basename "$key")"
            done
          else
            log "no SSH material at $SSH_SOURCE — the agent-smith clone will fail"
          fi

          # Without this, a non-interactive `git clone git@github.com:...`
          # dies on host-key verification rather than prompting.
          if [ ! -s "$HOME_DIR/.ssh/known_hosts" ] || \
             ! grep -q 'github\.com' "$HOME_DIR/.ssh/known_hosts" 2>/dev/null; then
            log "seeding known_hosts for github.com"
            mkdir -p "$HOME_DIR/.ssh"
            chmod 700 "$HOME_DIR/.ssh"
            ssh-keyscan -t rsa,ecdsa,ed25519 github.com \
              >> "$HOME_DIR/.ssh/known_hosts" 2>/dev/null || \
              log "WARNING: ssh-keyscan failed; github.com may be unreachable"
          fi

          # --- 2. activate the festie home profile ------------------------
          # On a fresh volume this populates an empty /home/rounak; on every
          # later boot it reconciles the home against whatever the image now
          # carries, which is how an image bump reaches the running computer.
          log "activating festie home profile"
          mkdir -p "$HOME_DIR/.local/state/nix/profiles"

          if ! "$ACTIVATION/activate"; then
            log "WARNING: home-manager activation FAILED."
            log "WARNING: starting Codeman anyway so the terminal stays reachable"
            log "WARNING: and you can debug from the very UI you'd otherwise lose."
            log "WARNING: the usual cause is claude-skills' agent-smith clone"
            log "WARNING: having no SSH key — see the chart's ssh.existingSecret."
          fi

          # --- 3. pick up the activated session environment ----------------
          HM_VARS="$HOME_DIR/.nix-profile/etc/profile.d/hm-session-vars.sh"
          if [ -f "$HM_VARS" ]; then
            # shellcheck disable=SC1090
            . "$HM_VARS"
          fi

          export PATH="$HOME_DIR/.npm-global/bin:$HOME_DIR/.nix-profile/bin:$PATH"

          # --- 4. install/refresh Codeman ----------------------------------
          # The npm package is `aicodeman`; `codeman` on npm is an unrelated
          # 0.0.1 squat. Keyed on a marker file so a version bump in values.yaml
          # reinstalls on the next restart and an unchanged pin costs nothing.
          export NPM_CONFIG_PREFIX="$HOME_DIR/.npm-global"
          mkdir -p "$NPM_CONFIG_PREFIX"
          MARKER="$NPM_CONFIG_PREFIX/.agentfest-codeman-version"

          if [ "$(cat "$MARKER" 2>/dev/null || true)" != "$CODEMAN_VERSION" ]; then
            log "installing aicodeman@$CODEMAN_VERSION"
            npm install -g "aicodeman@$CODEMAN_VERSION"
            printf '%s\n' "$CODEMAN_VERSION" > "$MARKER"
          else
            log "aicodeman@$CODEMAN_VERSION already present"
          fi

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
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.nix
          pkgs.cacert
          pkgs.dockerTools.binSh
          pkgs.dockerTools.usrBinEnv
          pkgs.dockerTools.caCertificates
        ];
        pathsToLink = [ "/bin" "/etc" "/share" "/lib" ];
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
              "PATH=${homeDir}/.npm-global/bin:${homeDir}/.nix-profile/bin:/bin:/usr/bin"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "AGENTFEST_HOME_ACTIVATION=${homeActivation}"
              "AGENTFEST_CODEMAN_VERSION=${defaultCodemanVersion}"
              "LANG=C.UTF-8"
              "TERM=xterm-256color"
            ];
          };

          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp
            mkdir -p home/${user}
          '';
        };
      };

      checks.${system} = {
        image = self.packages.${system}.image;
        entrypoint = self.packages.${system}.entrypoint;
      };
    };
}
