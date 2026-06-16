{
  description = "NixOS configuration - multi-machine flake";

  inputs = {
    # Use unstable nixpkgs for latest kernel/mesa (needed for new Intel GPU)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Fresher unstable pin for cherry-picked packages that must track
    # upstream (tailscale: LoL preview needs a current client) without
    # rebuilding the world off the main pin.
    nixpkgs-latest.url = "github:nixos/nixpkgs/nixos-unstable";

    # nvim wrapper builder (config lives in-repo at pkgs/neovim).
    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";

    # Home Manager - use master branch for unstable nixpkgs compatibility
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Worktrunk - git worktree management CLI
    worktrunk = {
      url = "github:max-sixty/worktrunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # palette-daemon — long-running WebKit command palette + browser
    # extension shim, replacing the per-tab iframe prewarm. Private
    # repo, hence git+ssh URL (the `github:` shorthand hits the public
    # GitHub API and 404s without an auth token).
    palette-daemon = {
      url = "git+ssh://git@github.com/daphen/palette-daemon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Niri flake - provides proper niri build with all dependencies.
    # We use niri-unstable from this flake (tracks master, includes v26.04+).
    niri-flake.url = "github:sodiboo/niri-flake";

    # Pinned nixpkgs for iwd 3.12 (fixes repeated SIGSEGV in build_ciphers_common during roaming)
    nixpkgs-iwd.url = "github:nixos/nixpkgs/34c521aa2928ec0f0b376f60d33816fe768ea60d";

    # Pinned nixpkgs for neovim 0.11.6 — nvim 0.12 broke too many plugins
    # (treesitter, markview, etc.); revisit when ecosystem catches up.
    nixpkgs-neovim.url = "github:nixos/nixpkgs/46db2e09e1d3f113a13c0d7b81e2f221c63b8ce9";

    # Fast-moving apps channel — bumped independently of the system nixpkgs
    # via: nix flake update nixpkgs-apps
    # Use nixos-unstable (Hydra-cached) rather than master to avoid mass source rebuilds
    nixpkgs-apps.url = "github:nixos/nixpkgs/nixos-unstable";

    # Helium browser — not in nixpkgs; this flake wraps the upstream AppImage with
    # appimageTools and auto-bumps via GitHub Actions on new releases.
    helium-nix = {
      url = "github:AlvaroParker/helium-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # endcord (Discord TUI, 1.4.2). Built from source via uv2nix because:
    #   - not in nixpkgs (upstream #73 closed not-planned)
    #   - the available NUR pins 1.4.1, missing hex theming, smart-paste,
    #     toggle_tree, and using a now-replaced voice dep (Snazzah/davey →
    #     DisnakeDev/dave.py).
    # Derivation lives at pkgs/endcord/default.nix.
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, nixpkgs-iwd, nixpkgs-apps, nixpkgs-neovim, home-manager, niri-flake, worktrunk, palette-daemon, uv2nix, pyproject-nix, pyproject-build-systems, ... }@inputs:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };

      endcord = pkgs.callPackage ./pkgs/endcord {
        inherit uv2nix pyproject-nix pyproject-build-systems;
      };

      nvimPkgs = import ./pkgs/neovim { inherit pkgs inputs; lib = nixpkgs.lib; };

      # Pin iwd to 3.12 to fix SIGSEGV crashes during WiFi roaming (build_ciphers_common)
      iwdOverlay = final: prev: {
        iwd = (import nixpkgs-iwd { inherit system; }).iwd;
      };

      # Pin neovim to 0.11.6 — nvim 0.12 broke nvim-treesitter master, markview,
      # and a chunk of plugins that haven't migrated. Re-evaluate when the
      # plugin ecosystem stabilises on 0.12.
      neovimOverlay = final: prev: {
        neovim-unwrapped = (import nixpkgs-neovim { inherit system; config.allowUnfree = true; }).neovim-unwrapped;
      };

      # Enable Widevine DRM on browsers that need it
      widevineOverlay = final: prev: {
        chromium = prev.chromium.override { enableWideVine = true; };
        qutebrowser = prev.qutebrowser.override { enableWideVine = true; };
      };

      # Add H7606WW (ProArt Studiobook 16) to asusctl's aura_support.ron.
      # The asusd binary reads this file from its own store path (hardcoded at
      # compile time), so we must recompile with the patched file.
      asusctlOverlay = final: prev: {
        asusctl = prev.asusctl.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            sed -i 's/\])$/    (\n        device_name: "H7606WW",\n        product_id: "19b6",\n        layout_name: "g634j-per-key",\n        basic_modes: [Static, Breathe, RainbowCycle, RainbowWave, Pulse],\n        basic_zones: [],\n        advanced_type: r#None,\n        power_zones: [Keyboard],\n    ),\n])/' \
              $out/share/asusd/aura_support.ron
          '';
        });
      };

      # Route fast-moving user-facing apps through the nixpkgs-apps channel so
      # they can be bumped independently of the system nixpkgs. Bump with:
      # nix flake update nixpkgs-apps && sudo nixos-rebuild switch --flake ~/nixos#<host>
      appsOverlay = final: prev:
        let
          apps = import nixpkgs-apps {
            inherit system;
            config.allowUnfree = true;
          };
        in {
          inherit (apps)
            # AI CLIs (ship daily)
            claude-code
            codex
            opencode
            pi-coding-agent
            # Compositor-adjacent
            # Browsers (security updates matter)
            chromium
            qutebrowser
            vivaldi
            google-chrome
            # Desktop apps
            slack
            vesktop
            spotify;
            # Note: _1password/_1password-gui intentionally left on system nixpkgs —
            # AgileBits rotates source URLs aggressively, so master/nixos-unstable
            # frequently point at versions whose download has already disappeared.
        };


      # Shared modules used by all machines
      commonModules = [
        # Apply overlays
        { nixpkgs.overlays = [ iwdOverlay widevineOverlay asusctlOverlay appsOverlay neovimOverlay ]; }

        # Niri flake module (sets up dbus, portals, polkit, etc.)
        niri-flake.nixosModules.niri

        # System modules
        ./common/niri.nix
        ./common/audio.nix
        ./common/bluetooth.nix
        ./common/networking.nix

        # Home Manager integration
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
            users.daphen = import ./common/home;
            extraSpecialArgs = {
              inherit inputs endcord;
              nvimLocal = nvimPkgs.neovimLocal;
              nvimBaked = nvimPkgs.neovim;
            };
          };
        }
      ];

      # Helper to build a machine configuration
      mkHost = machineModule: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = commonModules ++ [ machineModule ];
      };

      # Ephemeral dev-env (`nix run github:daphen/nixos#dev-env`) for remote
      # sandboxes. Built per-arch since lovbox sandboxes are aarch64 while
      # proart is x86_64. Sources the in-repo ./dotfiles + a baked neovim;
      # stays off the system's private/heavy inputs (palette-daemon, niri…).
      mkDevEnv = sys:
        let
          p = import nixpkgs {
            system = sys;
            config = { allowUnfree = true; allowUnfreePredicate = _: true; };
          };
          nv = import ./pkgs/neovim { pkgs = p; inherit inputs; lib = nixpkgs.lib; };
        in import ./pkgs/daphen-env {
          pkgs = p;
          dotfiles = ./dotfiles;
          neovim = nv.neovim;
        };

    in {
      nixosConfigurations = {
        thinkpad = mkHost ./machines/thinkpad;
        proart   = mkHost ./machines/proart;
        # zenbook  = mkHost ./machines/zenbook;
      };

      # Clean pkgs (no neovimOverlay) so neovim is 0.12, not the system's 0.11.6.
      packages = {
        x86_64-linux = {
          neovim = nvimPkgs.neovim;
          neovim-local = nvimPkgs.neovimLocal;
          dev-env = mkDevEnv "x86_64-linux";
          default = mkDevEnv "x86_64-linux";
        };
        aarch64-linux = {
          dev-env = mkDevEnv "aarch64-linux";
          default = mkDevEnv "aarch64-linux";
        };
      };

      # Development shell for testing configurations
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.nixpkgs-fmt
          pkgs.nil # Nix LSP
          home-manager.packages.${system}.home-manager
        ];
      };
    };
}
