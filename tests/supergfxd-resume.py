import os
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="supergfxd-resume-test-") as directory:
    root = Path(directory)
    log = root / "calls"
    (root / "supergfxctl").write_text("""#!/bin/sh
case "$1" in
  --get) [ "$FAIL_QUERY" != mode ] || exit 1; printf '%s\n' "$MODE" ;;
  --pend-mode) [ "$FAIL_QUERY" != pending ] || exit 1; printf '%s\n' "$PENDING" ;;
  --status) [ "$FAIL_QUERY" != power ] || exit 1; printf '%s\n' "$POWER" ;;
  *) exit 2 ;;
esac
""")
    (root / "systemctl").write_text("""#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
[ "$FAIL_RESTART" != yes ] || [ "$1" != try-restart ]
""")
    for name in ("supergfxctl", "systemctl"):
        (root / name).chmod(0o755)
    cases = [
        ("Integrated", "active", "Unknown", "", "no", True, True),
        ("Integrated", "off", "Unknown", "", "no", False, True),
        ("Hybrid", "active", "Unknown", "", "no", False, True),
        ("Vfio", "active", "Unknown", "", "no", False, True),
        ("Integrated", "active", "Hybrid", "", "no", False, True),
        ("Integrated", "active", "Unknown", "mode", "no", False, False),
        ("Integrated", "active", "Unknown", "pending", "no", False, False),
        ("Integrated", "active", "Unknown", "power", "no", False, False),
        ("Integrated", "active", "Unknown", "", "yes", True, False),
    ]
    for mode, power, pending, fail_query, fail_restart, restart, success in cases:
        log.unlink(missing_ok=True)
        env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CALLS=str(log),
                   MODE=mode, POWER=power, PENDING=pending, FAIL_QUERY=fail_query,
                   FAIL_RESTART=fail_restart)
        result = subprocess.run([str(script)], env=env, capture_output=True, text=True)
        calls = log.read_text().splitlines() if log.exists() else []
        expected = ["reset-failed supergfxd.service", "try-restart supergfxd.service"] if restart else []
        assert calls == expected, (mode, power, pending, fail_query, calls)
        assert (result.returncode == 0) == success, (mode, power, result.returncode, result.stderr)
    print(f"PASS: {len(cases)} resume cases through {script}")
