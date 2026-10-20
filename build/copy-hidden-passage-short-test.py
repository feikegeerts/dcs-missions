"""Create a separate ~3 NM voice-test copy; preserve embedded scripts and audio.

Unlike the shipping packager this never regenerates scripts from src/. Only the
mission's pickup coordinates and title/travel briefing are changed. Input is
read-only; existing outputs are refused rather than overwritten.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]


def build(source, output):
    source, output = source.resolve(), output.resolve()
    if source == output or output.exists():
        raise ValueError("Choose a separate, non-existing output; nothing will be overwritten")
    original = source.read_bytes()
    members = {}
    with ZipFile(io.BytesIO(original)) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            if entry.filename in members:
                raise ValueError(f"Duplicate archive member: {entry.filename}")
            members[entry.filename] = archive.read(entry)
    required = {"mission", "options", "warehouses", "l10n/DEFAULT/dictionary",
                "l10n/DEFAULT/mapResource", "l10n/DEFAULT/OHP-main.lua", "l10n/DEFAULT/OHP-Moose_.lua"}
    if not required <= members.keys():
        raise ValueError("Expected a self-contained Hidden Passage archive")
    payload = members["l10n/DEFAULT/OHP-main.lua"].decode("utf-8")
    sounds = set(re.findall(r'["\'](Sounds/OHP/[^"\']+\.ogg)["\']', payload))
    if not sounds or not sounds <= members.keys():
        raise ValueError(f"Missing referenced voice assets: {sounds - members.keys()}")
    lua = shutil.which("lua5.1.exe") or shutil.which("lua5.1")
    if not lua:
        raise RuntimeError("Lua 5.1 not found on PATH")
    outdir = ROOT / "out"
    outdir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ohp-voice-test-", dir=outdir) as temp:
        temp = Path(temp)
        before, after = temp / "before", temp / "after"
        # Only these two trusted table filenames are extracted; all other archive
        # members are copied in memory, never resolved as filesystem paths.
        for folder in (before, after):
            for name in ("mission", "l10n/DEFAULT/dictionary"):
                path = folder / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(members[name])
        subprocess.run([lua, str(ROOT / "build/prepare-hidden-passage-short-test.lua"),
                        str(before), str(after)], cwd=ROOT, check=True)
        candidate = dict(members)
        for name in ("mission", "l10n/DEFAULT/dictionary"):
            candidate[name] = (after / name).read_bytes()
        generated = temp / "short-test.miz"
        with ZipFile(generated, "w", ZIP_DEFLATED) as archive:
            for name, data in candidate.items():
                archive.writestr(name, data)
        with ZipFile(generated) as archive:
            if archive.testzip() is not None or set(archive.namelist()) != set(members):
                raise RuntimeError("Archive CRC/member mismatch")
            changed = {name for name, data in members.items() if archive.read(name) != data}
            if changed != {"mission", "l10n/DEFAULT/dictionary"}:
                raise RuntimeError(f"Unexpected archive changes: {changed}")
        # Run the existing behavioral/voice tests against the preserved payload.
        script = temp / "OHP-main.lua"
        script.write_bytes(members["l10n/DEFAULT/OHP-main.lua"])
        subprocess.run([lua, str(ROOT / "tests/lua/run-hidden-passage-adapter.lua"), str(script), str(after / "mission")],
                       cwd=ROOT, check=True)
        if source.read_bytes() != original:
            raise RuntimeError("Source changed during build; no copy deployed")
        output.parent.mkdir(parents=True, exist_ok=True)
        data = generated.read_bytes()
        with output.open("xb") as file:
            file.write(data)
        if output.read_bytes() != data or source.read_bytes() != original:
            raise RuntimeError("Final output/source verification failed")
    evidence = {
        "input": str(source), "inputSha256": hashlib.sha256(original).hexdigest(),
        "output": str(output), "outputSha256": hashlib.sha256(data).hexdigest(),
        "changedMembers": sorted(changed), "preservedVoiceAssets": sorted(sounds),
        "verified": "Lua 5.1 table preservation, behavioral mocks, ZIP CRC; NOT live DCS terrain/audio acceptance",
    }
    (outdir / "operation-hidden-passage-voice-test-evidence.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.input, args.output)
