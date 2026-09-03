{ buildGoModule }:

buildGoModule {
  pname = "themectl";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  meta.mainProgram = "themectl";
}
