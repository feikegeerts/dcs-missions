"""Read-only inventory of scripts and bootstrap references inside DCS archives."""

import argparse
import hashlib
import re
import subprocess
import shutil
import zipfile
from pathlib import Path


def inspect(path, templates=False):
    print(f"\n{path.name}")
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = entry.filename.replace("\\", "/")
            if name == "mission" or name.lower().endswith(".lua"):
                data = archive.read(entry)
                print(f"  {name}: {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()}")
                if "moose" in name.lower():
                    continue
                text = data.decode("utf-8", errors="replace")
                if name == "mission" and templates:
                    result = subprocess.run(
                        [shutil.which("lua5.1") or "lua5.1", str(Path(__file__).with_name("inspect-mission-templates.lua"))],
                        input=text, text=True, encoding="utf-8", capture_output=True, check=True,
                    )
                    print(result.stdout)
                for line in text.splitlines():
                    if re.search(r"bootstrap\.lua|mission_name\s*=|mission_version\s*=|local (PLAYER_GROUP_NAMES|BANDIT_GROUP_NAMES)", line):
                        print("    " + line.strip()[:500])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--templates", action="store_true")
    args = parser.parse_args()
    for mission in sorted(args.directory.glob("*.miz")):
        inspect(mission, args.templates)
