{ config, pkgs, inputs, ... }:

{
  # Import secrets if file exists (gitignored)
  imports = if builtins.pathExists ../secrets.nix then [ ../secrets.nix ] else [];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # zram swap (compressed in-memory swap to prevent OOM freezes)
  zramSwap.enable = true;
  zramSwap.memoryPercent = 50;

  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;
  hardware.graphics.enable = true;

  # Enable networking
  networking.networkmanager.enable = true;

  # Time zone
  time.timeZone = "Europe/Stockholm";

  # Internationalisation
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Console keymap
  console.keyMap = "us";

  # Users
  users.users.daphen = {
    isNormalUser = true;
    description = "daphen";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "video"
      "audio"
    ];
    shell = pkgs.fish;
  };

  # Enable Fish shell system-wide
  programs.fish.enable = true;

  # Make /bin/bash available (NixOS doesn't have it by default, needed by scripts)
  environment.binsh = "${pkgs.bash}/bin/bash";
  system.activationScripts.binbash = ''
    ln -sf ${pkgs.bash}/bin/bash /bin/bash
  '';

  # Allow wheel group to use sudo without password
  security.sudo.wheelNeedsPassword = false;

  # Enable swaylock PAM authentication (for screen locking)
  security.pam.services.swaylock = {};

  # System Packages
  environment.systemPackages = with pkgs; [
    # Core utilities
    vim
    neovim
    wget
    curl
    git
    htop
    less
    nano
    stow

    # Development
    devenv
    gcc
    gnumake
    automake
    autoconf
    pkg-config
    binutils

    # Shells & Terminal Tools
    fish
    fzf
    zoxide
    ripgrep
    fd
    jq
    direnv
    glow

    # File Management
    yazi

    # Version Control
    git
    github-cli
    lazygit

    # Terminal Emulators
    alacritty
    kitty
    ghostty
    wezterm

    # Browsers
    chromium
    qutebrowser

    # Wayland Tools
    grim
    slurp
    wl-clipboard
    wl-clip-persist
    wtype
    ydotool
    cliphist
    hyprpicker
    dragon-drop

    # Screenshot & Screen Sharing
    imv
    chafa

    # Clipboard Managers
    copyq
    clipse

    # Audio/Video
    pavucontrol
    brightnessctl
    playerctl

    # Image Tools
    imagemagick

    # Notifications
    mako

    # Background & Idle
    swaybg
    swayidle
    swaylock-effects

    # Launchers & Menus
    rofi
    rofi-bluetooth
    rofimoji
    eww

    # GTK / System Theme
    dconf-editor
    adwaita-icon-theme

    # Display Management
    waypaper

    # Fonts
    noto-fonts-color-emoji

    # Communication
    (pkgs.slack.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.makeWrapper ];
      postInstall = (old.postInstall or "") + ''
        wrapProgram $out/bin/slack \
          --add-flags "--ozone-platform=wayland --render-node-override=/dev/dri/renderD129"
      '';
    }))
    vesktop

    # Media
    spotify
    spotify-player

    # Office
    libreoffice-fresh

    # Container Tools
    docker
    docker-compose

    # Cloud Tools
    # azure-cli  # TODO: broken on unstable, re-enable later

    # Security
    mkcert

    # Qt/Kvantum theming
    libsForQt5.qtstyleplugin-kvantum
    kdePackages.qtstyleplugin-kvantum

    # Keyboard Tools
    kanata
    vial

    # Text Expansion
    espanso

    # Network Tools
    openssh
    dnsmasq
    iwd
    wirelesstools
    wpa_supplicant

    # System Monitoring
    fastfetch
    smartmontools

    # Gaming
    steam

    # GPU diagnostics
    libva-utils

    # Misc Tools
    bun
    opencode
    claude-code
    electron

    # System Tools
    efibootmgr
    iptables
    xset

    # Development Languages/Tools
    nodejs
    python3
    python3Packages.pip
    python3Packages.mdformat
    cargo
    rustc
    go
  ];

  # Fonts
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    font-awesome
    nerd-fonts.geist-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    nerd-fonts.symbols-only
  ];

  # Enable Docker
  virtualisation.docker.enable = true;

  # XDG Desktop Portal for Wayland
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
  };

  # dconf (needed for gsettings / GTK dark mode preference)
  programs.dconf.enable = true;

  # 1Password with polkit integration
  programs._1password.enable = true;
  programs._1password-gui.enable = true;
  programs._1password-gui.polkitPolicyOwners = [ "daphen" ];

  # Keyboard firmware (udev rules for Vial/QMK)
  hardware.keyboard.qmk.enable = true;

  # OpenSSH
  services.openssh.enable = true;

  # Enable CUPS for printing
  services.printing.enable = true;

  # Enable firmware updates
  services.fwupd.enable = true;

  # Enable TTY2 for emergency access
  systemd.services."getty@tty2".enable = true;

  # Nix settings
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;

      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    # Garbage collection
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # System state version
  system.stateVersion = "24.11";
}
