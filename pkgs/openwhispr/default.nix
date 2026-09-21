{
  lib,
  appimageTools,
  asar,
  fetchurl,
  nodejs,
  patch,
  runCommand,
}:

let
  pname = "openwhispr";
  version = "1.10.2";
  src = fetchurl {
    url = "https://github.com/OpenWhispr/openwhispr/releases/download/v${version}/OpenWhispr-${version}-linux-x86_64.AppImage";
    hash = "sha256-DIHGn6K0xcFypMedDzmSqg6xoFG3JRnB3QRQhgvJgd4=";
  };
  appimageContents = appimageTools.extractType2 { inherit pname version src; };
  patchedContents = runCommand "${pname}-${version}-niri" {
    nativeBuildInputs = [ asar nodejs patch ];
  } ''
    cp -a ${appimageContents} $out
    chmod -R u+w $out
    asar_path=$out/resources/app.asar
    work=$(mktemp -d)
    for file in \
      src/helpers/hotkeyManager.js \
      src/helpers/ipcHandlers.js \
      src/helpers/windowManager.js
    do
      mkdir -p "$work/$(dirname "$file")"
      (cd "$work/$(dirname "$file")" && asar extract-file "$asar_path" "$file")
    done
    patch -d "$work" -p1 < ${./openwhispr-niri.patch}

    ASAR_PATH="$asar_path" WORK="$work" node <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const disk = require("${asar}/lib/node_modules/@electron/asar/lib/disk.js");

const archive = process.env.ASAR_PATH;
const work = process.env.WORK;
const filesystem = disk.readFilesystemSync(archive);
const header = disk.readArchiveHeaderSync(archive);
const fd = fs.openSync(archive, "r+");
const dataStart = 8 + header.headerSize;

for (const name of [
  "src/helpers/hotkeyManager.js",
  "src/helpers/ipcHandlers.js",
  "src/helpers/windowManager.js",
]) {
  const info = filesystem.getFile(name, false);
  const changed = fs.readFileSync(path.join(work, name));
  const archiveSize = fs.fstatSync(fd).size;
  const digest = crypto.createHash("sha256").update(changed).digest("hex");
  fs.writeSync(fd, changed, 0, changed.length, archiveSize);
  info.offset = String(archiveSize - dataStart);
  info.size = changed.length;
  info.integrity.hash = digest;
  info.integrity.blocks = [digest];
}

const nextHeader = JSON.stringify(filesystem.header);
if (Buffer.byteLength(nextHeader) !== Buffer.byteLength(header.headerString)) {
  throw new Error("patched ASAR header changed size");
}
const headerBuffer = Buffer.alloc(dataStart);
fs.readSync(fd, headerBuffer, 0, headerBuffer.length, 0);
const headerOffset = headerBuffer.indexOf(header.headerString, 0, "utf8");
if (headerOffset < 0) throw new Error("ASAR header payload not found");
headerBuffer.write(nextHeader, headerOffset, Buffer.byteLength(nextHeader), "utf8");
fs.writeSync(fd, headerBuffer, 0, headerBuffer.length, 0);
fs.closeSync(fd);
NODE
  '';
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = patchedContents;

  extraPkgs = pkgs: with pkgs; [
    xdotool
    wtype
    ydotool
    wl-clipboard
    xclip
    xsel
    kdotool
    playerctl
    libsecret
    libnotify
    libpulseaudio
    pipewire
    stdenv.cc.cc.lib
  ];

  extraInstallCommands = ''
    install -Dm444 ${patchedContents}/open-whispr.desktop \
      $out/share/applications/${pname}.desktop
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-fail 'Exec=AppRun --no-sandbox' 'Exec=${pname} --no-sandbox'
    cp -r ${patchedContents}/usr/share/icons $out/share/icons
  '';

  meta = {
    description = "Privacy-first desktop voice dictation, meeting transcription and notes";
    homepage = "https://openwhispr.com/";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
}
