# Helium browser — local pin of 0.12.2.1 (pre-release) while waiting for the
# helium-nix flake (github:AlvaroParker/helium-nix) to auto-bump. Its updater
# appears to skip pre-release tags, so it's still on 0.12.1.1 even though
# upstream cut 0.12.2 on 2026-05-12 (packaging tag 0.12.2.1 the same day).
#
# We want 0.12.2 for: custom keyboard shortcuts, floating vertical-tab sidebar,
# hardened canvas/audio fingerprinting noise, and light-mode contrast fixes.
#
# When the flake catches up: delete this directory and restore the original
# `inputs.helium-nix.packages.${pkgs.system}.default` reference in
# common/home/programs.nix.
#
# Build logic mirrors the upstream flake — appimageTools.wrapType2 around the
# released AppImage, plus a .desktop entry rewritten to call `helium` instead
# of `AppRun`.
{ appimageTools, fetchurl }:

appimageTools.wrapType2 rec {
  pname = "helium";
  version = "0.12.2.1";

  src = fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${version}/${pname}-${version}-x86_64.AppImage";
    hash = "sha256-6bQuymGyoyusl4t9/z9K2udXH6hL8XNaqvUSlb0XxV0=";
  };

  extraInstallCommands =
    let
      contents = appimageTools.extract { inherit pname version src; };
    in
    ''
      install -m 444 -D ${contents}/${pname}.desktop -t $out/share/applications
      substituteInPlace $out/share/applications/${pname}.desktop \
        --replace 'Exec=AppRun' 'Exec=${pname}'
      cp -r ${contents}/usr/share/icons $out/share
    '';
}
