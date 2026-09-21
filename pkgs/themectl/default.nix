{ buildGoModule, lib, makeWrapper, python3, glib, dconf, gsettings-desktop-schemas, jq }:
let
  python = python3.withPackages (ps: [ ps.pygobject3 ]);
  runtimePath = lib.makeBinPath [ glib dconf jq python ];
  schemas = "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}";
in buildGoModule {
  pname = "themectl";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    install -Dm644 watch.py $out/libexec/themectl-watch.py
    wrapProgram $out/bin/themectl \
      --prefix PATH : ${runtimePath} \
      --prefix XDG_DATA_DIRS : ${schemas} \
      --prefix GIO_EXTRA_MODULES : ${dconf.lib}/lib/gio/modules
    makeWrapper ${python}/bin/python3 $out/bin/themectl-watch \
      --add-flags "$out/libexec/themectl-watch.py" \
      --prefix PATH : "$out/bin:${runtimePath}" \
      --prefix GI_TYPELIB_PATH : ${glib.out}/lib/girepository-1.0 \
      --prefix XDG_DATA_DIRS : ${schemas} \
      --prefix GIO_EXTRA_MODULES : ${dconf.lib}/lib/gio/modules
  '';
  meta.mainProgram = "themectl";
}
