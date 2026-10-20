"""Compatibility entry point: update the testing layout, never the long mission.

For new work use update-hidden-passage.py with an explicit --layout.
"""

from pathlib import Path
import runpy
import sys

if __name__ == "__main__":
    if any(arg == "--layout" or arg.startswith("--layout=") for arg in sys.argv[1:]):
        raise SystemExit("Use update-hidden-passage.py for explicit layout selection")
    sys.argv.extend(["--layout", "testing"])
    runpy.run_path(str(Path(__file__).with_name("update-hidden-passage.py")), run_name="__main__")
