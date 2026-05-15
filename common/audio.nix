{ config, pkgs, ... }:

{
  # Audio Configuration with PipeWire
  # ==================================
  
  # Disable PulseAudio (PipeWire replaces it)
  services.pulseaudio.enable = false;
  
  # Enable PipeWire (ALSA support is configured below)
  services.pipewire = {
    enable = true;
    
    # Audio server
    audio.enable = true;
    
    # ALSA support
    alsa = {
      enable = true;
      support32Bit = true;
    };
    
    # PulseAudio compatibility
    pulse.enable = true;
    
    # JACK support
    jack.enable = true;
    
    # WirePlumber (session manager)
    wireplumber.enable = true;

    # Increase quantum to avoid buffer underruns on AMD ACP audio chain.
    # Default 1024 (~21ms) starves on this hardware; 2048 (~42ms) is stable.
    extraConfig.pipewire."92-quantum" = {
      "context.properties" = {
        "default.clock.quantum"     = 2048;
        "default.clock.min-quantum" = 1024;
        "default.clock.max-quantum" = 8192;
      };
    };

    # Bump every Bluetooth A2DP sink above analog/HDMI so whichever pair of
    # headphones is currently connected becomes the default automatically.
    # With no configured-default sink saved, ties break in favor of the
    # most recently added node — i.e. last-connected-wins.
    wireplumber.extraConfig."51-bluetooth-priority" = {
      "monitor.bluez.rules" = [
        {
          matches = [{ "node.name" = "~bluez_output\\..*"; }];
          actions.update-props = {
            "priority.session" = 4000;
            "priority.driver"  = 4000;
          };
        }
      ];
    };
  };

  # Additional audio packages
  environment.systemPackages = with pkgs; [
    alsa-utils
    pipewire
    wireplumber
  ];

  # Real-time audio
  security.rtkit.enable = true;
}
