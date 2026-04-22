# User programs - only installation and Nix integration
# All config files are handled by symlinks.nix
{ pkgs, ... }:
{
  # Shell
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # Editor — neovim installed directly rather than via programs.neovim, since HM's
  # module generates its own init.lua which conflicts with the dotfile-based config
  # symlinked through symlinks.nix.
  home.packages = with pkgs; [
    neovim-unwrapped
    # LSP/formatter tooling expected on PATH by the nvim config
    prettier
    black
    stylua
    eslint
    xclip
  ];
  home.sessionVariables.EDITOR = "nvim";
  programs.fish.shellAliases = {
    vi = "nvim";
    vim = "nvim";
  };

  # Git
  programs.git.enable = true;
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      editor = "nvim";
    };
  };
  programs.lazygit.enable = true;

  # Git worktree management
  programs.worktrunk = {
    enable = true;
    enableFishIntegration = true;
  };
}
