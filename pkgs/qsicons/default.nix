{
  stdenvNoCC,
  fontforge,
  python3Packages,
}:

stdenvNoCC.mkDerivation {
  pname = "qsicons";
  version = "1.0.0";

  src = ../../dotfiles/qslib/.local/share/qml/QsLib/icons;
  dontUnpack = true;

  nativeBuildInputs = [
    fontforge
    python3Packages.fonttools
  ];

  installPhase = ''
    runHook preInstall

    fontDir="$out/share/fonts/truetype"
    mkdir -p "$fontDir"
    fontforge -lang=py -script ${./build.py} "$src" "$fontDir"

    python - "$fontDir" <<'PY'
    import json
    import sys
    from pathlib import Path
    from fontTools.ttLib import TTFont

    output = Path(sys.argv[1])
    mapping = json.loads((output / "qsicons-map.json").read_text())
    cmap = TTFont(output / "QsIcons.ttf").getBestCmap()
    expected = {codepoint: name for name, codepoint in mapping.items()}
    if cmap != expected:
        raise SystemExit("generated font cmap does not match qsicons-map.json")
    PY

    runHook postInstall
  '';
}
