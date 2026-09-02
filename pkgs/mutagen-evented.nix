{ pkgs }:

pkgs.mutagen.overrideAttrs (old: {
  pname = "mutagen-evented";
  patches = (old.patches or [ ]) ++ [ ./mutagen-evented.patch ];
  postInstall = (old.postInstall or "") + ''
    bundle="$TMPDIR/mutagen-agents"
    mkdir -p "$bundle"
    tar xzf "$out/libexec/mutagen-agents.tar.gz" -C "$bundle"
    install -m 0755 "$out/bin/mutagen-agent" "$bundle/linux_amd64"
    rm "$out/libexec/mutagen-agents.tar.gz"
    (cd "$bundle" && tar czf "$out/libexec/mutagen-agents.tar.gz" *)
  '';
})
