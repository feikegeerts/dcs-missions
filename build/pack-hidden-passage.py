"""Build the explicit, self-contained Hidden Passage transport probe.

No changes to the wave packager, selector, hooks, or DCS installation.
--deploy replaces the seed archive; --deploy-to backs up and replaces a separate
existing mission while keeping the original seed/backup intact.
Use --update-existing for an editor-authored version of this scripted mission;
without that flag only an original Chinook-only seed/backup is accepted.
--update-existing delegates to the current layout-preserving operational updater.
For Testing or filename changes, use update-hidden-passage.py directly.
"""

import argparse
import hashlib
import json
import runpy
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
MISSION = ROOT / "src/missions/operation-hidden-passage"


def lua(*args):
    executable = shutil.which("lua5.1.exe") or shutil.which("lua5.1")
    if not executable:
        raise RuntimeError("Lua 5.1 executable not found on PATH")
    subprocess.run([executable, *map(str, args)], cwd=ROOT, check=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def shipping_payload():
    entry = (MISSION / "main.lua").read_text(encoding="utf-8")
    replacements = {
        'local ROOT = assert(_G.MY_SCRIPTS_ROOT, "bootstrap must supply the source root")': "",
        'dofile(ROOT .. "missions/operation-hidden-passage/config.lua")': "Config()",
        'dofile(ROOT .. "missions/operation-hidden-passage/operation.lua")': "OperationModule()",
        'dofile(ROOT .. "missions/operation-hidden-passage/voice.lua")': "VoiceModule()",
        'assert(loadfile(ROOT .. "missions/operation-hidden-passage/transport-test.lua"))(config, Operation, Voice)': "RunTransportTest(config, Operation, Voice)",
    }
    for source, replacement in replacements.items():
        if entry.count(source) != 1:
            raise ValueError(f"Expected one supported entry expression: {source}")
        entry = entry.replace(source, replacement)
    pieces = []
    for function, file, args in [
        ("Config", "config.lua", ""),
        ("OperationModule", "operation.lua", ""),
        ("VoiceModule", "voice.lua", ""),
        ("RunTransportTest", "transport-test.lua", "..."),
    ]:
        pieces.append(f"local function {function}({args})\n{(MISSION / file).read_text(encoding='utf-8')}\nend\n")
    payload = "\n".join(pieces) + entry
    for forbidden in ["dofile(", "loadfile(", "io.", "lfs.", "os.", "require(", "TraceOn("]:
        if forbidden in payload:
            raise ValueError(f"Forbidden shipping dependency: {forbidden}")
    return payload.encode("utf-8")


def build(source, deploy=False, deploy_to=None, update_existing=False):
    if update_existing:
        updater = runpy.run_path(str(ROOT / "build/update-hidden-passage.py"))
        updater["update"](source, deploy=deploy, layout="operational", deploy_to=deploy_to)
        return
    source = source.resolve()
    seed = source.read_bytes()
    out = ROOT / "out"
    out.mkdir(exist_ok=True)
    staging = out / "operation-hidden-passage-build"
    artifact = out / "operation-hidden-passage.miz"
    if source == artifact.resolve():
        raise ValueError("Seed cannot be the generated output")
    target = source if deploy else deploy_to.resolve() if deploy_to else None
    previous = target.read_bytes() if target else None
    if target == artifact.resolve():
        raise ValueError("Deployment target cannot be the generated output")
    members = {}
    with ZipFile(source) as archive:
        for entry in archive.infolist():
            name = entry.filename
            path = PurePosixPath(name)
            if entry.is_dir():
                continue
            if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name or name in members:
                raise ValueError(f"Unsafe/duplicate archive member: {name}")
            members[name] = archive.read(entry)
    for required in ["mission", "options", "warehouses", "l10n/DEFAULT/dictionary", "l10n/DEFAULT/mapResource"]:
        if required not in members:
            raise ValueError(f"Missing {required}")
    with tempfile.TemporaryDirectory(prefix="ohp-", dir=out) as temporary:
        temporary = Path(temporary)
        original, result = temporary / "source", temporary / "result"
        for name, data in members.items():
            for folder in (original, result):
                dest = folder / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
        lua(ROOT / "build/prepare-hidden-passage.lua", original, result, MISSION / "config.lua",
            *(["--update-existing"] if update_existing else []))
        (result / "l10n/DEFAULT/OHP-main.lua").write_bytes(shipping_payload())
        shutil.copyfile(ROOT / "src/lib/Moose_.lua", result / "l10n/DEFAULT/OHP-Moose_.lua")
        sounds = MISSION / "sounds"
        if not sounds.is_dir():
            raise ValueError("Missing mission sounds directory")
        sound_files = sorted(sounds.glob("*.ogg"))
        if not sound_files:
            raise ValueError("No Ogg voice assets found")
        shutil.copytree(sounds, result / "Sounds/OHP", dirs_exist_ok=True)
        lua(ROOT / "tests/lua/run-hidden-passage-artifact.lua", original, result,
            *(["--update-existing"] if update_existing else []))
        lua(ROOT / "tests/lua/run-hidden-passage-adapter.lua", result / "l10n/DEFAULT/OHP-main.lua")
        generated = temporary / "mission.miz"
        with ZipFile(generated, "w", ZIP_DEFLATED) as archive:
            for path in sorted(result.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(result).as_posix())
        with ZipFile(generated) as archive:
            assert archive.testzip() is None, "Archive CRC failure"
            assert all("\\" not in name for name in archive.namelist())
        if staging.exists():
            # This directory is owned only by this recipe, never by a caller.
            shutil.rmtree(staging)
        shutil.copytree(result, staging)
        shutil.copyfile(generated, artifact)

    evidence = {
        "input": str(source),
        "inputSha256": digest(seed),
        "mode": "update-existing" if update_existing else "original-seed",
        "output": str(artifact),
        "outputSha256": digest(artifact.read_bytes()),
        "verified": "Lua 5.1 tables, preservation/structure, mocked adapter, ZIP CRC; NOT live DCS acceptance",
    }
    if target:
        if source.read_bytes() != seed:
            raise RuntimeError("Source changed during build; refusing replacement")
        if target.read_bytes() != previous:
            raise RuntimeError("Deployment target changed during build; refusing replacement")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        # Keep backups outside Missions so DCS does not list them as playables.
        backup_dir = target.parent.parent / "Backups/Operation-Hidden-Passage"
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / f"{target.stem}-before-transport-{stamp}.miz"
        with backup.open("xb") as file:
            file.write(previous)
        assert backup.read_bytes() == previous
        # Recheck after backup as well; never silently discard an editor save.
        if source.read_bytes() != seed or target.read_bytes() != previous:
            raise RuntimeError("Source changed before deployment; original left intact")
        replacement = target.with_name(target.name + ".ohp-tmp")
        try:
            with replacement.open("xb") as file:
                file.write(artifact.read_bytes())
            replacement.replace(target)
        finally:
            if replacement.exists():
                replacement.unlink()
        evidence["backup"] = str(backup)
        evidence["replacedSha256"] = digest(previous)
        evidence["deployed"] = str(target)
    (out / "operation-hidden-passage-build-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Original seed, or edited scripted .miz with --update-existing")
    parser.add_argument("--update-existing", action="store_true", help="Preserve editor layout; update Chinook scripts, briefing and pickup/return waypoints")
    deployment = parser.add_mutually_exclusive_group()
    deployment.add_argument("--deploy", action="store_true", help="Back up and replace the explicitly supplied input .miz")
    deployment.add_argument("--deploy-to", type=Path, help="Back up and replace this existing mission; preserve the input seed")
    args = parser.parse_args()
    build(args.input, args.deploy, args.deploy_to, args.update_existing)
