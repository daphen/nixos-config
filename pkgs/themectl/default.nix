{ buildGoModule }:

buildGoModule {
  pname = "themectl";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  postInstall = ''
    mv $out/bin/themectl $out/bin/theme-manager
  '';
}
