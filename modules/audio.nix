{ config, pkgs, ... }:

{
  # Audio Configuration with PipeWire
  # ==================================
  
  # Disable PulseAudio (PipeWire replaces it)
  hardware.pulseaudio.enable = false;
  
  # Enable ALSA support
  sound.enable = true;
  
  # Enable PipeWire
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
