{ pkgs }:

let
  release = tag: name: hash: pkgs.fetchurl {
    url = "https://github.com/itsdestin/swipe-keyboard/releases/download/${tag}/${name}";
    inherit hash;
  };
  engine = pkgs.fetchFromGitHub {
    owner = "itsdestin";
    repo = "swipe-keyboard";
    rev = "5d8eade530733f774133ec3802ebdd3f096f270f";
    sparseCheckout = [ "engine/src" "engine/include" ];
    hash = "sha256-ivZx0BF3nOvGxgva4RGKEyFTQaR5hpW7lhehw++MYBk=";
  };
  assets = pkgs.linkFarm "padswipe-assets" {
    "en.ngram" = release "language-files-2026-10-23-apostrophes" "en.ngram" "sha256-2gCRH+NkR95b6aliWJ8zC6EnbAqvl+YQK9vfB/mDQtA=";
    "en_swipe.combined" = release "language-files-2026-10-23-apostrophes" "en_swipe.combined" "sha256-cP9Fx2QS+43hqcR7IE1ZgjRKihu84jlFr319wn+ehLs=";
    "swipe-model.bin" = release "models-2026-10-23" "swipe-model.bin" "sha256-lBJypwFyKac+B9HAvXZnV+c5F02zpC+2IsJiVrjEYRA=";
  };
  decoder = pkgs.stdenv.mkDerivation {
    pname = "padswipe-decode";
    version = "0.1";
    src = ./decoder;
    nativeBuildInputs = [ pkgs.cmake pkgs.ninja ];
    buildInputs = [ pkgs.qt6.qtbase ];
    cmakeFlags = [ "-DENGINE=${engine}/engine" ];
    dontWrapQtApps = true;
    installPhase = "install -Dm755 padswipe-decode $out/bin/padswipe-decode";
  };
  ui = pkgs.linkFarm "padswipe-ui" {
    "padswipe.py" = ./padswipe.py;
    "shell.qml" = ./shell.qml;
  };
  # Loaded while the keyboard is open: the controller only feeds the keyboard, so pads and sticks stop moving the desktop.
  profile = pkgs.writeText "padswipe-profile.yaml" ''
    version: 1
    kind: DeviceProfile
    name: Pad Swipe
    target_devices: [ keyboard ]
    mapping: []
  '';
in
pkgs.writeShellScriptBin "padswipe" ''
  export PATH=${pkgs.lib.makeBinPath [ pkgs.python3 pkgs.wtype ]}:$PATH
  export PADSWIPE_DIR=${ui} PADSWIPE_DECODER=${decoder}/bin/padswipe-decode PADSWIPE_ASSETS=${assets} PADSWIPE_PROFILE=${profile}
  pkill -f 'padswipe-ui/shell.qml' && sleep 1
  qs -p ${ui}/shell.qml > "$XDG_RUNTIME_DIR/padswipe-qs.log" 2>&1
  inputplumber device 0 profile load /etc/inputplumber/profiles/hyprland-canvas.yaml
''
