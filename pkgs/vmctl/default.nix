{ pkgs, worktrunk, neovim ? pkgs.neovim }:

pkgs.buildGoModule {
  pname = "vmctl";
  version = "0-unstable";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  subPackages = [ "." ];
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.git pkgs.openssh pkgs.rsync ];
  nativeCheckInputs = [ worktrunk ];
  postInstall = ''
    wrapProgram $out/bin/vmctl \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.openssh pkgs.rsync ]} \
      --set VMCTL_EDITOR_NVIM ${pkgs.lib.getExe neovim}
  '';
  meta.mainProgram = "vmctl";
}
