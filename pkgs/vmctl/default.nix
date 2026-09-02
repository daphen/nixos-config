{ pkgs }:

pkgs.buildGoModule {
  pname = "vmctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];
  meta.mainProgram = "vmctl";
}
