{
  description = "NixOS configuration - multi-machine flake";

  inputs = {
    # Use unstable nixpkgs for latest kernel/mesa (needed for new Intel GPU)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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

    # Niri flake - provides proper niri build with all dependencies
    niri-flake.url = "github:sodiboo/niri-flake";

    # Override niri-stable to v26.04 (niri moved orgs from YaLTeR to niri-wm)
    niri-flake.inputs.niri-stable.url = "github:niri-wm/niri/v26.04";

    # Pinned nixpkgs for iwd 3.12 (fixes repeated SIGSEGV in build_ciphers_common during roaming)
    nixpkgs-iwd.url = "github:nixos/nixpkgs/34c521aa2928ec0f0b376f60d33816fe768ea60d";

    # Fast-moving apps channel — bumped independently of the system nixpkgs
    # via: nix flake update nixpkgs-apps
    # Use nixos-unstable (Hydra-cached) rather than master to avoid mass source rebuilds
    nixpkgs-apps.url = "github:nixos/nixpkgs/nixos-unstable";

  };

  outputs = { self, nixpkgs, nixpkgs-iwd, nixpkgs-apps, home-manager, niri-flake, worktrunk, ... }@inputs:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };

      # Pin iwd to 3.12 to fix SIGSEGV crashes during WiFi roaming (build_ciphers_common)
      iwdOverlay = final: prev: {
        iwd = (import nixpkgs-iwd { inherit system; }).iwd;
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
            waybar
            mako
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
        { nixpkgs.overlays = [ iwdOverlay widevineOverlay asusctlOverlay appsOverlay ]; }

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
              inherit inputs;
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

    in {
      nixosConfigurations = {
        thinkpad = mkHost ./machines/thinkpad;
        proart   = mkHost ./machines/proart;
        # zenbook  = mkHost ./machines/zenbook;
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
