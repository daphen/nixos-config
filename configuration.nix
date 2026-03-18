{ config, pkgs, inputs, ... }:

{
  # System Configuration
  # ====================
  
  # Import secrets if file exists (gitignored)
  imports = if builtins.pathExists ./secrets.nix then [ ./secrets.nix ] else [];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ "i915.enable_psr=0" "i915.enable_dc=0" "i915.enable_guc=0" ];
  # zram swap (compressed in-memory swap to prevent OOM freezes)
  zramSwap.enable = true;
  zramSwap.memoryPercent = 50;

  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
  ];

  # Hostname
  networking.hostName = "nixos";

  # Enable networking
  networking.networkmanager.enable = true;

  # Time zone
  time.timeZone = "Europe/Stockholm";  # Adjust to your timezone

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
    shell = pkgs.fish;  # Fish works perfectly in QEMU!
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
  # ===============
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
    stow  # Keep for reference, but won't use in Nix

    # Development
    # base-devel  # Note: Not a package in Nix, using individual build tools below instead
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
    # zen-browser # May need to package separately
    
    # Wayland Tools
    grim
    slurp
    wl-clipboard
    wl-clip-persist
    wtype
    ydotool
    cliphist
    hyprpicker
    
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
    # Need to add custom fonts like BerkeleyMono
    
    # Communication
    slack
    vesktop  # Discord
    # teams-for-linux
    
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
    _1password-gui
    _1password-cli
    mkcert
    
    # Keyboard Tools
    kanata
    vial
    # keyd
    
    # Text Expansion
    espanso
    
    # Network Tools
    openssh
    dnsmasq
    iwd
    wirelesstools  # Note: Changed from wireless-tools (correct package name)
    wpa_supplicant
    
    # System Monitoring
    fastfetch
    smartmontools
    
    # Package Management (Nix equivalents)
    # yay - not needed in NixOS
    
    # Gaming
    steam
    
    # AMD GPU
    libva-utils
    
    # Misc Tools
    bun
    opencode
    claude-code
    electron
    
    # System Tools
    efibootmgr
    iptables  # Note: Changed from iptables-nft (nixpkgs uses 'iptables')
    xset  # Needed by kanata for key repeat rate
    
    # Development Languages/Tools
    nodejs
    python3
    python3Packages.pip
    python3Packages.mdformat  # Markdown formatter
    cargo
    rustc
    go
  ];

  # Fonts
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans  # Renamed from noto-fonts-cjk
    noto-fonts-color-emoji
    font-awesome
    nerd-fonts.geist-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    nerd-fonts.symbols-only
    # Add custom fonts here (e.g. BerkeleyMono)
  ];

  # Enable sound with pipewire
  # (Configured in modules/audio.nix)
  
  # Enable bluetooth
  # (Configured in modules/bluetooth.nix)

  # Enable Docker
  virtualisation.docker.enable = true;

  # XDG Desktop Portal for Wayland
  # Note: niri-flake module already sets up xdg.portal with xdg-desktop-portal-gnome
  # Only add extra portals here if needed
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
  };

  # dconf (needed for gsettings / GTK dark mode preference)
  programs.dconf.enable = true;

  # Keyboard firmware (udev rules for Vial/QMK)
  hardware.keyboard.qmk.enable = true;

  # OpenSSH
  services.openssh.enable = true;

  # Enable CUPS for printing
  services.printing.enable = true;

  # Enable firmware updates
  services.fwupd.enable = true;

  # Enable TTY2 for emergency access (if swaylock locks you out)
  # Try Ctrl+Alt+F2 to switch (may not work in Wayland, use hard reboot if needed)
  systemd.services."getty@tty2".enable = true;

  # Nix settings
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      
      # Substituters for faster builds
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
  # DO NOT CHANGE unless you know what you're doing
  system.stateVersion = "24.11";
}
