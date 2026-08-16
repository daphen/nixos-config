{ pkgs, upstream }:
let
  inherit (pkgs) lib;
  contents = pkgs.appimageTools.extractType2 {
    inherit (upstream) pname version src;
  };
  libraries = with pkgs; [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    fontconfig
    glib
    gtk3
    libdrm
    libglvnd
    libgbm
    libxkbcommon
    mesa
    nspr
    nss
    pango
    systemd
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
  ];
in
pkgs.stdenvNoCC.mkDerivation {
  inherit (upstream) pname version;
  src = contents;
  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/helium $out/bin $out/share/applications $out/share/icons
    cp -a . $out/libexec/helium/
    makeWrapper $out/libexec/helium/AppRun $out/bin/helium \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath libraries} \
      --set FONTCONFIG_FILE ${pkgs.fontconfig.out}/etc/fonts/fonts.conf \
      --set FONTCONFIG_PATH ${pkgs.fontconfig.out}/etc/fonts
    install -m 444 helium.desktop $out/share/applications/helium.desktop
    cp -a usr/share/icons/. $out/share/icons/
    runHook postInstall
  '';

  passthru = { inherit (upstream) src; };
  meta = upstream.meta // { mainProgram = "helium"; };
}
