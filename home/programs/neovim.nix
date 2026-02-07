{ config, pkgs, ... }:

{
  # Neovim Configuration
  # ====================
  
  # Enable Neovim
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    
    # Install Neovim from unstable for latest version
    package = pkgs.unstable.neovim-unwrapped;
    
    # Additional packages needed by Neovim plugins
    extraPackages = with pkgs; [
      # LSP servers (installed via Mason in Neovim, but good to have as fallback)
      nodejs  # For many LSP servers
      python3
      python3Packages.pip
      
      # Formatters
      nodePackages.prettier
      black
      stylua
      
      # Linters
      nodePackages.eslint
      
      # Build tools
      gcc
      gnumake
      
      # Clipboard support
      wl-clipboard
      xclip
      
      # Telescope dependencies
      ripgrep
      fd
      
      # Markdown preview
      # nodejs required above
    ];
  };

  # Copy entire Neovim config from dotfiles
  # This preserves your lazy.nvim setup and all custom configurations
  xdg.configFile."nvim" = {
    source = ../../dotfiles-source/nvim;
    recursive = true;
  };

  # Note: The actual Neovim configuration files from ~/dotfiles/nvim/.config/nvim/
  # will be symlinked here. This includes:
  # - init.lua
  # - lua/options.lua
  # - lua/keymaps.lua
  # - lua/plugins/
  # - lua/utils.lua
  # - etc.
}
