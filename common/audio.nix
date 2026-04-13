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
