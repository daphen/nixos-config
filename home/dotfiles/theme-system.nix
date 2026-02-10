{ config, pkgs, ... }:

let
  # Theme generator derivation
  theme-generator = pkgs.writeShellScriptBin "theme-manager" ''
    #!/usr/bin/env bash
    # Theme manager script
    # This will be populated from ~/.dotfiles/themes/theme-manager.sh
    
    THEMES_DIR="$HOME/.config/themes"
    
    # Source the actual theme-manager.sh logic here
    # For now, this is a placeholder
    
    echo "Theme manager - to be implemented"
  '';

in {
  # Add theme generator to packages
  home.packages = [ theme-generator pkgs.jq ];
  
  # Copy theme system files
  xdg.configFile."themes" = {
    source = ../../dotfiles/themes;
    recursive = true;
  };
  
  # Home activation script to generate themes on switch
  home.activation.generateThemes = config.lib.dag.entryAfter ["writeBoundary"] ''
    echo "Generating themes..."
    
    if [ -f "$HOME/.config/themes/theme-manager.sh" ]; then
      cd "$HOME/.config/themes"
      # Run theme generation for current mode
      ./theme-manager.sh generate dark || true
      ./theme-manager.sh apply dark || true
    fi
  '';
  
  # Theme system includes:
  # - colors.json: Single source of truth
  # - theme-manager.sh: Generator script
  # - templates/: Template files for each tool
  # - generated/: Auto-generated theme files
  #   - fish/
  #   - fzf/
  #   - ghostty/
  #   - nvim-custom/
  #   - nvim/
}
