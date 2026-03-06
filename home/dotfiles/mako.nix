{ config, pkgs, ... }:

{
  # Mako notification daemon - enable service, config lives in dotfiles
  services.mako.enable = true;

  xdg.configFile."mako/config" = {
    source = ../../dotfiles-source/mako/.config/mako/config;
  };
}
