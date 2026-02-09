{ config, pkgs, ... }:

let
  # Create a derivation for each Niri script
  # This ensures they're properly packaged with dependencies
  
  niri-scripts = pkgs.stdenv.mkDerivation {
    name = "niri-scripts";
    src = ../../dotfiles/niri/.config/niri/scripts;
    
    buildInputs = with pkgs; [
      bash
      coreutils
      jq
      grim
      slurp
      wl-clipboard
      ghostty
      yazi
      zoxide
      fzf
    ];
    
    installPhase = ''
      mkdir -p $out/bin
      
      # Copy all scripts
      cp -r $src/* $out/bin/
      
      # Make all scripts executable
      chmod +x $out/bin/*
      
      # Patch shebangs
      patchShebangs $out/bin
    '';
  };

in {
  # Add niri-scripts to user packages
  home.packages = [ niri-scripts ];
  
  # Copy Niri configuration
  xdg.configFile."niri/config.kdl" = {
    source = ../../dotfiles/niri/.config/niri/config.kdl;
  };
  
  # Individual script descriptions:
  # - niri-focus-tracker: Window focus history tracker
  # - niri-jump-or-exec: Jump to or execute applications  
  # - focus-workspace-down-or-monitor: Smart workspace navigation
  # - focus-workspace-up-or-monitor: Smart workspace navigation
  # - move-window-down-or-monitor: Move windows across workspaces
  # - move-window-up-or-monitor: Move windows across workspaces
  # - spawn-terminal-with-claude: Open terminal with Claude Code
  # - spawn-terminal-with-yazi: Open terminal with Yazi
  # - spawn-terminal-with-zoxide-picker: Directory picker
  # - screenshot-to-clipboard: Screenshot selection
  # - toggle-camera: Camera toggle
  # - toggle-mic: Microphone toggle
  # - toggle-notes: Notes toggle
  # - spawn-notes: Spawn notes
  # - spawn-new-note: Create new note
  # - notes-sync-notify: Notes sync notification
  # - force-kill-focused: Force kill focused window
  # - clipboard-history.sh: Clipboard history
}
