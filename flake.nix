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

    # Override niri-stable to v25.11 (matches Arch machine)
    niri-flake.inputs.niri-stable.url = "github:YaLTeR/niri/v25.11";

    # Pinned nixpkgs for iwd 3.12 (fixes repeated SIGSEGV in build_ciphers_common during roaming)
    nixpkgs-iwd.url = "github:nixos/nixpkgs/34c521aa2928ec0f0b376f60d33816fe768ea60d";

  };

  outputs = { self, nixpkgs, nixpkgs-iwd, home-manager, niri-flake, worktrunk, ... }@inputs:
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

      # Shared modules used by all machines
      commonModules = [
        # Apply overlays
        { nixpkgs.overlays = [ iwdOverlay widevineOverlay ]; }

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
        packages = with pkgs; [
          nixpkgs-fmt
          nil # Nix LSP
          home-manager
        ];
      };
    };
}
