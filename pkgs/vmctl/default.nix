{ pkgs }:

pkgs.buildGoModule {
  pname = "vmctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  subPackages = [ "." ];
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.git pkgs.git-lfs pkgs.openssh pkgs.rsync pkgs.worktrunk ];
  postInstall = ''
    wrapProgram $out/bin/vmctl --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.git-lfs pkgs.openssh pkgs.rsync pkgs.worktrunk ]}
  '';
  meta.mainProgram = "vmctl";
}
