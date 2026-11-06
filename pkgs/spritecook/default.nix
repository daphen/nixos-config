{ pkgs }:
let
  python = pkgs.python3.withPackages (p: [ p.pillow p.numpy ]);
  share = pkgs.linkFarm "spritecook-share" {
    "spritecook.py" = ./spritecook.py;
    "build.lua" = ./build.lua;
    "Lint.lua" = ./Lint.lua;
    "replace.lua" = ./replace.lua;
    "AGENTS.md" = ./AGENTS.md;
  };
  cli = pkgs.writeShellScriptBin "spritecook" ''
    # Aseprite launched from the desktop has no fish environment, so read the key the way daemons.nix does.
    if [ -z "''${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.config/fish/secrets.fish" ]; then
      export OPENAI_API_KEY="$(${pkgs.fish}/bin/fish -c 'source "$HOME/.config/fish/secrets.fish"; printf "%s" "$OPENAI_API_KEY"')"
    fi
    export SPRITECOOK_SHARE=${share} SPRITECOOK_ASEPRITE=${pkgs.aseprite}/bin/aseprite
    exec ${python}/bin/python3 ${share}/spritecook.py "$@"
  '';
  extension = pkgs.runCommand "spritecook-aseprite-extension" { } ''
    mkdir -p $out
    cp ${./Lint.lua} $out/Lint.lua
    substitute ${./plugin.lua} $out/plugin.lua --replace-fail @spritecook@ ${cli}/bin/spritecook
    cat > $out/package.json <<'EOF'
    { "name": "spritecook", "displayName": "Spritecook", "version": "1.0.0",
      "contributes": { "scripts": [ { "path": "./plugin.lua" } ] } }
    EOF
  '';
in
cli.overrideAttrs (old: { passthru = (old.passthru or { }) // { inherit extension python; }; })
