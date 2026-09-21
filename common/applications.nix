{ config, lib, applicationPkgs, inputs, ... }:

let
  isDeck = config.networking.hostName == "steamdeck";
  pkgs = applicationPkgs;
in {
  environment.systemPackages = with pkgs; [
    kitty
    yazi
    nautilus
    (inputs.nixpkgs-latest.legacyPackages.${pkgs.system}.satty.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ../pkgs/satty-single-enter-crop.patch ];
    }))
    imv
    copyq
    clipse
    pavucontrol
    dconf-editor
    waypaper
    (slack.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ makeWrapper ];
      postInstall = (old.postInstall or "") + ''
        wrapProgram $out/bin/slack \
          --add-flags "--ozone-platform=wayland${lib.optionalString (!isDeck) " --render-node-override=/dev/dri/by-path/pci-0000:65:00.0-render"}"
      '';
    }))
    vesktop
    spotify
    spotify-player
    obsidian
    libreoffice-fresh
    libsForQt5.qtstyleplugin-kvantum
    kdePackages.qtstyleplugin-kvantum
    vial
    opencode
    claude-code
    codex
    pi-coding-agent
  ] ++ lib.optionals (!isDeck) (with pkgs; [ google-chrome chromium ]);

  fonts.packages = with pkgs; [
    (callPackage ../pkgs/qsicons { })
    geist-font
    inter
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    font-awesome
    nerd-fonts.geist-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    nerd-fonts.symbols-only
  ];

  programs._1password.enable = true;
  programs._1password.package = pkgs._1password-cli;
  programs._1password-gui.enable = true;
  programs._1password-gui.package = pkgs._1password-gui;
  programs._1password-gui.polkitPolicyOwners = [ "daphen" ];
  environment.etc."1password/custom_allowed_browsers" = {
    text = "helium\n";
    mode = "0755";
  };
}
