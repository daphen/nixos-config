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

  # remove_observers fires on InterfacesRemoved without checking WHICH interface
  # went away, so a phone merely disconnecting (BlueZ drops its GATT interfaces)
  # tears down the device watcher. On reconnect the device is still bonded, so
  # Device1 is never re-added and process_object — which only attaches when
  # Device1 appears — never restores it. The observer goes permanently deaf,
  # silently, until the service restarts. Make the teardown symmetric with the
  # setup: forget a device only when the device object itself disappears.
  removeAnchor = "        if path in self.property_observers:";
  removeFixed = "        if BluezDeviceAPI.interface in services and path in self.property_observers:";

  # The advertisement carried no Service Solicitation, so iOS saw a generic
  # connectable peripheral with no stated interest in ANCS and never initiated a
  # reconnect — it knew it was disconnected (tapping the row showed a connect
  # spinner) but had no reason to come back. Soliciting the ANCS service is how a
  # smartwatch gets iOS to connect to IT; without it the link only ever comes up
  # by tapping the device in Settings.
  solicitAnchor = "    @property\n    def IncludeTxPower(self) -> Bool:";
  solicit =
    "    @property\n"
    + "    def SolicitUUIDs(self) -> List[Str]:\n"
    + "        return [\"7905F431-B5CE-4E99-A40F-4B1E122D00D0\"]  # ANCS\n"
    + "\n"
    + "    @SolicitUUIDs.setter\n"
    + "    def SolicitUUIDs(self, value: List[Str]) -> None:\n"
    + "        pass\n"
    + "\n"
    + solicitAnchor;
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
    substituteInPlace ancs4linux/observer/scanner.py \
      --replace-fail ${pkgs.lib.escapeShellArg removeAnchor} ${pkgs.lib.escapeShellArg removeFixed}
    substituteInPlace ancs4linux/advertising/advertisement.py \
      --replace-fail ${pkgs.lib.escapeShellArg solicitAnchor} ${pkgs.lib.escapeShellArg solicit}
    ${pkgs.python3}/bin/python3 -m compileall -q \
      ancs4linux/desktop_integration/main.py ancs4linux/observer/scanner.py ancs4linux/advertising/advertisement.py
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
  pythonImportsCheck = [
    "ancs4linux"
    "ancs4linux.desktop_integration.main"
    "ancs4linux.observer.scanner"
    "ancs4linux.advertising.advertisement"
  ];

  meta = {
    description = "Receive iOS notifications on Linux over Bluetooth LE (ANCS)";
    homepage = "https://github.com/pzmarzly/ancs4linux";
    license = pkgs.lib.licenses.gpl2Plus;
  };
}
