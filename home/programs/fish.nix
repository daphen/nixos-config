{ config, pkgs, ... }:

{
  # Fish Shell Configuration
  # =========================
  
  programs.fish = {
    enable = true;
    
    # Shell aliases
    shellAliases = {
      # Common shortcuts
      ls = "ls --color=auto";
      ll = "ls -lah";
      la = "ls -A";
      
      # Git shortcuts
      g = "git";
      gs = "git status";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git pull";
      
      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      
      # Neovim
      v = "nvim";
      vim = "nvim";
      
      # NixOS specific
      rebuild = "sudo nixos-rebuild switch --flake .#nixos";
      rebuild-home = "home-manager switch --flake .#daphen";
      update-flake = "nix flake update";
    };
    
    # Shell abbreviations (expand on space)
    shellAbbrs = {
      # Add your Fish abbreviations here
      # These will be ported from your dotfiles/fish config
    };
    
    # Fish plugins
    plugins = [
      # Fisher plugins will be added here
      # Or use programs.fish.plugins for Nix-managed plugins
    ];
    
    # Startup commands
    interactiveShellInit = ''
      # Set vi keybindings
      fish_vi_key_bindings
      
      # Initialize zoxide
      zoxide init fish | source
      
      # FZF configuration
      set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git'
      set -gx FZF_CTRL_T_COMMAND "$FZF_DEFAULT_COMMAND"
      
      # Theme mode (will be managed by theme system)
      set -gx THEME_MODE dark
      
      # Source theme if exists
      if test -f ~/.config/themes/generated/fish/dark.theme
        source ~/.config/themes/generated/fish/dark.theme
      end
      
      # Custom functions will be added via xdg.configFile
    '';
    
    # Functions directory
    # We'll copy your custom functions from dotfiles/fish/.config/fish/functions/
  };

  # FZF integration
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
    
    # FZF colors will be set by theme system
    # Placeholder default colors
    colors = {
      bg = "#0a0a0a";
      fg = "#ededed";
      hl = "#6a8be3";
      "bg+" = "#121212";
      "fg+" = "#ededed";
      "hl+" = "#a9b9ef";
      info = "#74baa8";
      prompt = "#e9b872";
      pointer = "#ff570d";
      marker = "#b85b53";
      spinner = "#74baa8";
      header = "#bcb6ec";
    };
  };

  # Zoxide (smart cd)
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # Copy Fish functions from dotfiles
  # These will be your custom functions from ~/dotfiles/fish/.config/fish/functions/
  # COMMENTED OUT: Requires dotfiles-source
  # xdg.configFile = {
  #   "fish/functions" = {
  #     source = ../../dotfiles-source/fish/functions;
  #     recursive = true;
  #   };
  # };
}
