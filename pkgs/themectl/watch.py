import sys
from pathlib import Path

from gi.repository import Gio, GLib


settings = Gio.Settings.new("org.gnome.desktop.interface")
loop = GLib.MainLoop()
mode_file = Path.home() / ".config/theme_mode"
applying = None
apply_again = False


def applied(process, result):
    global applying
    try:
        process.wait_check_finish(result)
    except GLib.Error as error:
        sys.exit(f"themectl-watch: {error}")
    applying = None
    if apply_again:
        follow()


def apply_theme():
    global applying, apply_again
    if applying is not None:
        apply_again = True
        return
    apply_again = False
    applying = Gio.Subprocess.new(["themectl", "auto"], Gio.SubprocessFlags.NONE)
    applying.wait_check_async(None, applied)


def follow(*_):
    try:
        mode = "dark" if settings.get_string("color-scheme") == "prefer-dark" else "light"
        value = mode + "\n"
        mode_file.parent.mkdir(parents=True, exist_ok=True)
        if not mode_file.exists() or mode_file.read_text() != value:
            mode_file.write_text(value)
        apply_theme()
    except (OSError, GLib.Error) as error:
        sys.exit(f"themectl-watch: {error}")


settings.connect("changed::color-scheme", follow)
settings.get_string("color-scheme")
follow()
loop.run()
