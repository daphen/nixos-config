{ pkgs, inputs, ... }:
let
  canvas = inputs.hyprland-canvas.packages.${pkgs.system}.default;
  lockFiles = pkgs.runCommand "canvas-lock-qml" { } ''
    app=$out/share/quickshell-login
    mkdir -p $out/share
    cp -R ${../../dotfiles/quickshell-login/.config/quickshell-login} "$app"
    chmod -R u+w "$app"
    rm "$app/lock/Modules" "$app/lock/QsLib"
    mkdir -p "$app/lock/Modules" "$app/lock/QsLib/icons"
    cp ${../../dotfiles/quickshell/.config/quickshell/modules/Theme.qml} "$app/lock/Modules/Theme.qml"
    printf 'singleton Theme 1.0 Theme.qml\n' > "$app/lock/Modules/qmldir"
    cp ${../../dotfiles/qslib/.local/share/qml/QsLib}/{Icon.qml,PrimaryButton.qml,ButtonSurface.qml,Theme.qml} "$app/lock/QsLib/"
    printf 'module QsLib\nsingleton Theme Theme.qml\nIcon Icon.qml\nPrimaryButton PrimaryButton.qml\nButtonSurface ButtonSurface.qml\n' > "$app/lock/QsLib/qmldir"
    cp ${../../dotfiles/qslib/.local/share/qml/QsLib/icons}/{lock.svg,arrow-door-in.svg} "$app/lock/QsLib/icons/"
  '';
  lock = pkgs.writeShellScriptBin "canvas-lock" ''
    export HYPR_CANVAS_NATIVE_LOCK=1
    export QUICKSHELL_LOGIN_ROOT=${lockFiles}/share/quickshell-login
    export QS_BIN=${pkgs.quickshell}/bin/qs
    export QUICKSHELL_BIN=${pkgs.quickshell}/bin/quickshell
    export TIMEOUT_BIN=${pkgs.coreutils}/bin/timeout
    exec ${pkgs.bash}/bin/bash ${lockFiles}/share/quickshell-login/launch-lock
  '';
  session = pkgs.writeShellScriptBin "hypr-session" ''
    export HYPRLAND_CANVAS_SYSTEM_PACKAGE=${canvas}
    export HYPR_CANVAS_LOCK=${lock}/bin/canvas-lock
    exec /home/daphen/nixos/experiments/hyprland-canvas/run-login --real --system "$@"
  '';
in
{
  home.packages = [ canvas lock session ];
  home.file.".local/bin/hypr-session".source = "${session}/bin/hypr-session";
}
