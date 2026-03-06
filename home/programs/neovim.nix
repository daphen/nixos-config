{ config, pkgs, ... }:

{
  # Neovim - install package + dependencies, config lives in dotfiles
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
    ];
  };

  # Neovim config from the shared dotfiles repo
  xdg.configFile."nvim" = {
    source = ../../dotfiles-source/nvim/.config/nvim;
    recursive = true;
  };
}
