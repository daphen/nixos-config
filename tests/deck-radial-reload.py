import os
from pathlib import Path
import subprocess
import time

config = Path(os.environ["RADIAL_TEST_CONFIG"])
qs = os.environ["QS_BIN"]
log = config.parent / "reload.log"
module = config.parent / "modules/DeckRadialPalette.qml"

with log.open("w") as output:
    process = subprocess.Popen([qs, "--no-color", "-p", str(config)], stdout=output, stderr=subprocess.STDOUT)

    def wait_for(message, count):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if log.read_text().count(message) >= count:
                return
            time.sleep(.03)
        raise AssertionError(log.read_text())

    def check_ipc():
        response = subprocess.run([qs, "ipc", "--pid", str(process.pid), "show"], capture_output=True, text=True, timeout=2)
        text = response.stdout + response.stderr
        assert "target palette" in text and "Not ready" not in text, text + log.read_text()
        for action, value in [("open", "16"), ("cancel", "0")]:
            response = subprocess.run([qs, "ipc", "--pid", str(process.pid), "call", "--", "palette", "radial", action, value, ""],
                                      capture_output=True, text=True, timeout=2)
            assert response.returncode == 0 and "Not ready" not in response.stdout + response.stderr, response.stdout + response.stderr

    try:
        wait_for("Configuration Loaded", 1)
        check_ipc()
        original = module.read_text()
        module.write_text(original + "\n")
        wait_for("Configuration Loaded", 2)
        time.sleep(.1)
        check_ipc()
        module.write_text(original + "\nnot valid QML\n")
        wait_for("Failed to load configuration", 1)
        check_ipc()
        module.write_text(original)
        wait_for("Configuration Loaded", 3)
        time.sleep(.1)
        check_ipc()
        print("PASS canonical palette IPC survives successful reload, rejected reload, and recovery")
    finally:
        process.terminate()
        process.wait(timeout=3)
