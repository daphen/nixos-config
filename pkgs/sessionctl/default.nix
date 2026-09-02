{ pkgs }:

pkgs.buildGoModule {
  pname = "sessionctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];
  meta.mainProgram = "sessionctl";
}
