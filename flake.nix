{
  description = "NixOS configuration - migrated from Arch Linux";

  inputs = {
    # Use unstable nixpkgs for latest kernel/mesa (needed for new Intel GPU)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Home Manager - use master branch for unstable nixpkgs compatibility
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Niri flake - provides proper niri build with all dependencies
    niri-flake.url = "github:sodiboo/niri-flake";

    # Override niri-stable to v25.11 (matches Arch machine)
    niri-flake.inputs.niri-stable.url = "github:YaLTeR/niri/v25.11";

  };

  outputs = { self, nixpkgs, home-manager, niri-flake, ... }@inputs:
    let
      system = "x86_64-linux";
      
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };

      };

    in {
      nixosConfigurations = {
        nixos = nixpkgs.lib.nixosSystem {
          inherit system;
          
          specialArgs = { 
            inherit inputs;
          };
          
          modules = [
            # Core system configuration
            ./configuration.nix
            
            # Hardware configuration (auto-generated)
            ./hardware-configuration.nix
            
            # Niri flake module (sets up dbus, portals, polkit, etc.)
            niri-flake.nixosModules.niri

            # System modules
            ./modules/niri.nix
            ./modules/audio.nix
            ./modules/bluetooth.nix
            ./modules/networking.nix
            
            # Home Manager integration
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                
                # Backup existing files that conflict
                backupFileExtension = "backup";
                
                # Main user configuration
                users.daphen = import ./modules/home;
                
                # Pass extra arguments to home-manager
                extraSpecialArgs = { 
                  inherit inputs;
                };
              };
            }
          ];
        };
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
