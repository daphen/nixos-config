{ config, pkgs, lib, inputs, self, ... }:

{
  imports = [
    # Worktrunk provides its own home-manager module (programs.worktrunk)
    inputs.worktrunk.homeModules.default
  ];

  # ─────────────────────────────────────────────────────────────────────
  # Basic identity — hardcoded for now. Override via `home.username` arg
  # at homeManagerConfiguration time if deploying to a different user.
  # ─────────────────────────────────────────────────────────────────────
  home.username = lib.mkDefault "daphen";
  home.homeDirectory = lib.mkDefault "/home/${config.home.username}";
  home.stateVersion = "24.05";

  # ─────────────────────────────────────────────────────────────────────
  # Shell + prompt + fish-integrated tools
  # ─────────────────────────────────────────────────────────────────────
  programs.fish = {
    enable = true;
    # Note: no tokyonight-fish plugin — conf.d/fish_frozen_theme.fish (from
    # dotfiles) sets named colors; local kitty renders them with the custom
    # palette. On other terminals the colors fall back to that terminal's
    # palette — acceptable since this env is only used via SSH from local kitty.
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    # Config TOML comes from dotfiles if present; otherwise starship default.
    # User ports Tide → starship.toml manually in ~/dotfiles/starship/.config/starship.toml.
  };

  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.worktrunk = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.git.enable = true;

  # ─────────────────────────────────────────────────────────────────────
  # Package set — the portable CLI toolkit
  # ─────────────────────────────────────────────────────────────────────
  home.packages = [
    # Bundled neovim — plugins + LSPs + lua config baked into the Nix store
    self.packages.${pkgs.system}.neovim
  ] ++ (with pkgs; [
    # AI CLIs
    claude-code
    opencode

    # CLI toolkit
    ripgrep
    fd
    bat
    jq
    gh
    delta
    fastfetch

    # Auth
    _1password-cli
  ]);

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  # Ensure ~/.local/bin is on PATH (replaces the local fish_user_paths variable
  # which doesn't port across containers).
  home.sessionPath = [ "$HOME/.local/bin" ];

  # ─────────────────────────────────────────────────────────────────────
  # Dotfile content — baked into the Nix store via inputs.dotfiles.
  # Path resolution: `inputs.dotfiles` is a fetchGit-style store path, so
  # `inputs.dotfiles + "/x/y"` composes to a concrete store path that
  # home-manager copies into place.
  # ─────────────────────────────────────────────────────────────────────
  xdg.configFile = let
    df = inputs.dotfiles;
  in {
    # Fish shell config. programs.fish.enable generates its own config.fish
    # that sources conf.d/ files automatically, so conflicts if we also set
    # config.fish — use mkForce to override with the dotfile version.
    # Intentionally not shipping fish_variables (per note in symlinks.nix).
    "fish/config.fish".source    = lib.mkForce (df + "/fish/.config/fish/config.fish");
    "fish/conf.d".source         = df + "/fish/.config/fish/conf.d";
    "fish/functions".source      = df + "/fish/.config/fish/functions";
    "fish/completions".source    = df + "/fish/.config/fish/completions";
    "fish/fish_plugins".source   = df + "/fish/.config/fish/fish_plugins";

    # Git configs
    "git/personal".source        = df + "/git/.config/git/personal";
    "git/work".source            = df + "/git/.config/git/work";
    "git/ignore".source          = df + "/git/.config/git/ignore";

    # opencode tool config + themes
    "opencode/opencode.json".source = df + "/opencode/.config/opencode/opencode.json";
    "opencode/themes".source        = df + "/opencode/.config/opencode/themes";

    # Starship prompt — only wire if the user has committed starship.toml.
    # Comment this line in after porting Tide config over:
    # "starship.toml".source = df + "/starship/.config/starship/starship.toml";
  };

  # Home-level dotfiles
  home.file = let
    df = inputs.dotfiles;
  in {
    ".gitconfig".source         = df + "/git/.gitconfig";
    ".gitignore_global".source  = df + "/git/.gitignore_global";

    # Claude Code config — lives at ~/.claude (outside ~/.config)
    ".claude".source            = df + "/claude/.claude";
  };
}
