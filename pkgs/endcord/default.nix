# endcord — Discord TUI client. Pinned to a master commit because the latest
# tag (1.4.2, 2026-04-10) lacks hex-string theme color support — that landed
# 10 days later (af88aed5, 2026-04-20). When upstream tags 1.4.3+, switch
# `rev` back to a version string.
#
# Adapted from tcarrio/nixcfg's uv2nix-based derivation. We diverge from the
# hexadecimalDinosaur NUR (which pins 1.4.1, missing several features) and
# from the 1.4.2 tag because we need:
#   - Hex-string color support in themes (af88aed5)
#   - Smart-paste (`p` in vim mode / Ctrl+V) for clipboard images and text
#   - The `toggle_tree` keybinding (lowercase `t` in vim mode)
# The NUR also can't be `overrideAttrs`'d to a newer endcord because 1.4.2+
# swapped voice deps from Snazzah/davey to DisnakeDev/dave.py — which the
# NUR doesn't package, hence the full uv2nix rebuild here.
#
# `withMedia = false` builds the lite variant (no av/pillow/dave.py); set to
# true to get full media + voice. We default to media-on since the user uses
# image previews and the closure size delta is acceptable.
{
  lib,
  pkgs,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
  withMedia ? true,
}:

let
  python = pkgs.python313;

  src = pkgs.fetchFromGitHub {
    owner = "daphen";
    repo = "endcord";
    # Our fork, which now contains all our patches AND tracks upstream.
    # try-upstream-merge merges sparklost/endcord HEAD (f537896) into
    # our customisations. To pull more upstream changes:
    #   cd /tmp/endcord-fork
    #   git fetch upstream && git merge upstream/main
    #   git push origin <branch>
    # Then bump rev + hash here.
    rev = "88f12a412a4b2d03fe8d524c7ab89f95253b022d";
    hash = "sha256-7hIlqA5gRxBFyc0p6UI+AcpwBRhqGUXxBQR8Vnad57s=";
  };

  # Upstream's pyproject.toml omits a [build-system] table because the
  # official build path uses `uv` directly. uv2nix loads the workspace via
  # pyproject-nix, which expects the table — so we append it.
  patchedSrc = pkgs.runCommandLocal "endcord-source-patched" { inherit src; } ''
    cp -r $src $out
    chmod -R u+w $out
    cat >> $out/pyproject.toml << 'EOF'

    [build-system]
    requires = ["setuptools", "cython"]
    build-backend = "setuptools.build_meta"
    EOF
  '';

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = patchedSrc; };

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
      (lib.composeManyExtensions [
        pyproject-build-systems.overlays.default
        overlay
      ]);

  venv = pythonSet.mkVirtualEnv "endcord-env" (
    if withMedia then
      lib.mapAttrs (_name: _: [ "media" ]) workspace.deps.default
    else
      workspace.deps.default
  );

  pname = if withMedia then "endcord" else "endcord-lite";

  isLinux = pkgs.stdenv.isLinux;
  ldLibraryPath = lib.optionalString (withMedia && isLinux) (
    lib.makeLibraryPath [ pkgs.libpulseaudio ]
  );
  binPath = lib.makeBinPath (lib.optional (withMedia && isLinux) pkgs.pulseaudio);

in
pkgs.stdenv.mkDerivation {
  inherit pname;
  version = "1.4.2-unstable-2026-05-25";
  inherit src;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  buildInputs = [ python ] ++ lib.optional (withMedia && isLinux) pkgs.pulseaudio;

  # No patches needed — all of our changes live in the fork itself
  # (daphen/endcord). The ./patches/ dir is kept for reference but
  # not applied at build time.
  patches = [ ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/endcord
    cp -r endcord main.py themes $out/share/endcord/

    mkdir -p $out/bin
    makeWrapper ${python.interpreter} $out/bin/endcord \
      ${lib.optionalString (ldLibraryPath != "") "--prefix LD_LIBRARY_PATH : \"${ldLibraryPath}\""} \
      --prefix PYTHONPATH : "$out/share/endcord:${venv}/${python.sitePackages}" \
      ${lib.optionalString (binPath != "") "--prefix PATH : \"${binPath}\""} \
      --add-flags "$out/share/endcord/main.py"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Feature rich Discord TUI client${
      lib.optionalString (!withMedia) " (lite, no media support)"
    }";
    homepage = "https://github.com/sparklost/endcord";
    license = licenses.gpl3Only;
    mainProgram = "endcord";
    platforms = platforms.unix;
  };
}
