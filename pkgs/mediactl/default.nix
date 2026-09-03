{ pkgs }:

pkgs.buildGoModule {
  pname = "mediactl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];
  meta.mainProgram = "mediactl";
}
