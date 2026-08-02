# ancs4linux — receives iOS notifications over Apple Notification Center
# Service (BLE GATT), the protocol smartwatches use. Not in nixpkgs.
#
# Upstream is unmaintained ("I am no longer using this project"), so this pins
# an explicit rev rather than tracking master.
{ pkgs }:

let
  # Double-quoted (not '') on purpose: Nix strips common indentation from ''
  # strings, which silently mangles injected Python into invalid blocks.
  helperAnchor = "log = logging.getLogger(__name__)";
  helper = helperAnchor + ''

    def _allowed(app_id: str) -> bool:
        import os

        allow = os.environ.get("ANCS_APP_ALLOWLIST", "").strip()
        if not allow:
            return True
        return app_id in [x.strip() for x in allow.split(",") if x.strip()]
  '';

  guardAnchor = "        self.device_handle = data.device_handle";
  guard =
    "        if not _allowed(data.app_id):\n"
    + "            log.debug(\"Filtered out \" + data.app_id)\n"
    + "            return\n"
    + guardAnchor;
in
pkgs.python3Packages.buildPythonApplication rec {
  pname = "ancs4linux";
  version = "1.0.0-unstable-2026-05-24";
  pyproject = true;

  src = pkgs.fetchFromGitHub {
    owner = "pzmarzly";
    repo = "ancs4linux";
    rev = "985b8d07681e41785fc589149fe520f8ba5d325c";
    hash = "sha256-Z998P9P7Yu055UwrRjA1uMTG/uJsH6MvlhzDURpG4dM=";
  };

  build-system = [ pkgs.python3Packages.hatchling ];

  # PyGObject resolves GLib/Gio typelibs at runtime; the gapps hook threads
  # GI_TYPELIB_PATH into the entry-point wrappers.
  nativeBuildInputs = [ pkgs.gobject-introspection pkgs.wrapGAppsNoGuiHook ];
  buildInputs = [ pkgs.glib ];

  dependencies = with pkgs.python3Packages; [ dasbus pygobject3 typer ];

  # Allowlist by iOS bundle id, driven by $ANCS_APP_ALLOWLIST (empty = allow
  # everything, i.e. upstream behaviour). Patched in rather than reimplemented
  # as our own listener so upstream keeps owning notification dismissal and
  # positive/negative action forwarding, which is the fiddly half.
  #
  # Filtering on bundle id, not ANCS category: Messages reports as category
  # Social, which would also let through Messenger, WhatsApp and Twitter.
  postPatch = ''
    substituteInPlace ancs4linux/desktop_integration/main.py \
      --replace-fail ${pkgs.lib.escapeShellArg helperAnchor} ${pkgs.lib.escapeShellArg helper} \
      --replace-fail ${pkgs.lib.escapeShellArg guardAnchor} ${pkgs.lib.escapeShellArg guard}
    ${pkgs.python3}/bin/python3 -m compileall -q ancs4linux/desktop_integration/main.py
  '';

  # Upstream ships these as install.sh copies into /etc; expose them where
  # services.dbus.packages looks instead. They grant the ancs4linux group
  # talk-access to the two root daemons on the system bus.
  postInstall = ''
    install -Dm644 autorun/ancs4linux-observer.xml \
      $out/share/dbus-1/system.d/ancs4linux-observer.conf
    install -Dm644 autorun/ancs4linux-advertising.xml \
      $out/share/dbus-1/system.d/ancs4linux-advertising.conf
  '';

  # No test suite upstream.
  doCheck = false;

  # The submodule matters: the allowlist patch edits it, and importing only the
  # top package would let a mangled block ship as a runtime crash.
  pythonImportsCheck = [ "ancs4linux" "ancs4linux.desktop_integration.main" ];

  meta = {
    description = "Receive iOS notifications on Linux over Bluetooth LE (ANCS)";
    homepage = "https://github.com/pzmarzly/ancs4linux";
    license = pkgs.lib.licenses.gpl2Plus;
  };
}
