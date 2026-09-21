{ pkgs }:

pkgs.buildGoModule {
  pname = "desktopctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.util-linux ];
  postPatch = ''
    mkdir -p testdata
    cp ${../../dotfiles/hyprland/.config/hypr/scripts/desktop-launch} testdata/desktop-launch
  '';
  postInstall = ''
    install -Dm755 \
      ${../../dotfiles/hyprland/.config/hypr/scripts/desktop-launch} \
      $out/bin/desktop-launch
    patchShebangs $out/bin/desktop-launch
  '';
  postFixup = ''
    wrapProgram $out/bin/desktop-launch \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.systemd pkgs.util-linux ]}
    wrapProgram $out/bin/desktopctl --prefix PATH : $out/bin
  '';
  meta.mainProgram = "desktopctl";
}
