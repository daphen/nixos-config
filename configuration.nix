{ config, pkgs, inputs, ... }:

{
  # System Configuration
  # ====================

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hostname
  networking.hostName = "nixos";

  # Enable networking
  networking.networkmanager.enable = true;

  # Time zone
  time.timeZone = "America/New_York";  # Adjust to your timezone

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
      "libvirtd"
      "video"
      "audio"
    ];
    shell = pkgs.fish;  # Fish works perfectly in QEMU!
  };

  # Enable Fish shell system-wide
  programs.fish.enable = true;

  # Allow wheel group to use sudo without password
  security.sudo.wheelNeedsPassword = false;

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
    
    # File Management
    yazi
    # dragon-drop  # TODO: Check correct package name in nixpkgs (might be 'dragon' or 'xdragon')
    
    # Version Control
    git
    github-cli
    lazygit
    
    # Terminal Emulators
    alacritty
    kitty
    unstable.ghostty  # Latest version from unstable
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
    
    # Screenshot & Screen Sharing
    imv
    chafa
    
    # Clipboard Managers
    copyq
    # clipse # May need to find in nixpkgs or package
    
    # Audio/Video
    pavucontrol
    brightnessctl
    
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
    # rofi-bluetooth  # Need to find equivalent
    # rofimoji
    eww
    
    # Display Management
    waypaper
    
    # Fonts
    noto-fonts-emoji
    # Need to add custom fonts like BerkeleyMono
    
    # Communication
    slack
    vesktop  # Discord
    # teams-for-linux
    
    # Media
    spotify
    # spotify-player  # Check if available
    
    # Office
    libreoffice-fresh
    
    # Virtualization
    qemu_full
    libvirt
    virt-manager
    
    # Container Tools
    docker
    docker-compose
    
    # Cloud Tools
    azure-cli
    
    # Security
    # 1password  # Needs special handling
    # 1password-cli
    mkcert
    
    # Keyboard Tools
    # kanata  # Available in nixpkgs
    # keyd
    
    # Text Expansion
    # espanso  # Check availability
    
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
    tmux
    bun
    # opencode  # Claude Code CLI
    
    # System Tools
    efibootmgr
    iptables  # Note: Changed from iptables-nft (nixpkgs uses 'iptables')
    
    # Development Languages/Tools
    nodejs
    python3
    python3Packages.pip
    cargo
    rustc
  ];

  # Fonts
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans  # Renamed from noto-fonts-cjk
    noto-fonts-emoji
    font-awesome
    # nerdfonts  # Temporarily disabled - download failing
    # Add custom fonts here
  ];

  # Enable sound with pipewire
  # (Configured in modules/audio.nix)
  
  # Enable bluetooth
  # (Configured in modules/bluetooth.nix)

  # Enable Docker
  virtualisation.docker.enable = true;
  
  # Enable libvirt
  virtualisation.libvirtd.enable = true;
  
  # Enable VirtualBox (if needed)
  # virtualisation.virtualbox.host.enable = true;
  # users.extraGroups.vboxusers.members = [ "daphen" ];

  # XDG Desktop Portal for Wayland
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      xdg-desktop-portal-wlr
    ];
  };

  # OpenSSH
  services.openssh.enable = true;

  # Enable CUPS for printing
  services.printing.enable = true;

  # Enable firmware updates
  services.fwupd.enable = true;

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
