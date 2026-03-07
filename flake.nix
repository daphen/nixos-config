{
  description = "NixOS configuration - migrated from Arch Linux";

  inputs = {
    # Use latest stable NixOS
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    
    # Use unstable for cutting-edge packages
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Home Manager for user configuration
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Niri flake - provides proper niri build with all dependencies
    niri-flake = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    # Override niri-stable to v25.11 (matches Arch machine)
    # This makes niri-flake build v25.11 instead of its default v25.08
    niri-flake.inputs.niri-stable.url = "github:YaLTeR/niri/v25.11";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, niri-flake, ... }@inputs:
    let
      system = "x86_64-linux";
      
      # Create a pkgs instance with unstable overlay
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
        overlays = [
          # Overlay to access unstable packages
          (final: prev: {
            unstable = import nixpkgs-unstable {
              inherit system;
              config.allowUnfree = true;
            };
          })
        ];
      };

    in {
      nixosConfigurations = {
        # Main system configuration
        # Change "nixos" to your desired hostname
        nixos = nixpkgs.lib.nixosSystem {
          inherit system;
          
          specialArgs = { 
            inherit inputs;
            inherit pkgs;
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
                  inherit pkgs;
                };
              };
            }
          ];
        };
      };

      # Standalone home-manager configuration (optional, for non-NixOS systems)
      homeConfigurations = {
        daphen = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          
          modules = [
            ./modules/home
          ];
          
          extraSpecialArgs = {
            inherit inputs;
          };
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
