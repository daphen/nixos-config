{ pkgs }:

pkgs.buildGoModule {
  pname = "desktopctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];
  meta.mainProgram = "desktopctl";
}
