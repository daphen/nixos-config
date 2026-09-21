{ pkgs, ... }:

let
  osk = pkgs.writeShellApplication {
    name = "deck-osk-toggle";
    runtimeInputs = [ pkgs.jq pkgs.procps pkgs.steam pkgs.wvkbd ];
    text = builtins.readFile ./deck-osk-toggle;
  };
  oskEntry = pkgs.makeDesktopItem {
    name = "on-screen-keyboard";
    desktopName = "On-Screen Keyboard";
    exec = "${osk}/bin/deck-osk-toggle";
    icon = "input-keyboard";
    categories = [ "Utility" ];
  };
in
{
  programs.dconf.enable = true;
  environment.systemPackages = [ pkgs.wvkbd osk oskEntry ];
  home-manager.users.daphen = { config, lib, ... }: let
    theme = "${config.home.homeDirectory}/nixos/machines/steamdeck/split-keyboard";
    link = config.lib.file.mkOutOfStoreSymlink;
  in {
    home.activation.deckCssPreload = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      hook="${config.home.homeDirectory}/homebrew/plugins/SDH-CssLoader/css_browserhook.py"
      if test -f "$hook"; then
        if ! ${pkgs.patch}/bin/patch --reverse --forward --dry-run --silent --batch "$hook" ${./css-loader-shared-styles.patch} >/dev/null 2>&1; then
          ${pkgs.patch}/bin/patch --forward --batch "$hook" ${./css-loader-shared-styles.patch}
        fi
      fi
    '';
    home.file."homebrew/themes/Split Keyboard/theme.json".source = link "${theme}/theme.json";
    home.file."homebrew/themes/Split Keyboard/keyboard.css".source = link "${theme}/keyboard.css";
  };
}
