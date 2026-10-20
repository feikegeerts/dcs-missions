"""Preserve an existing Hidden Passage layout while updating scripts and audio.

Mission/editor tables are preserved, except the known boarding instruction in
the briefing. Existing recordings require explicit --replace-audio permission.
Default layout is testing; --layout operational explicitly enables the approved
long-range port. --deploy replaces --input; --deploy-to writes a new named copy.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import runpy
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
PACK = runpy.run_path(str(ROOT / "build/pack-hidden-passage.py"))


def update(source, deploy=False, replace_audio=(), layout="testing", deploy_to=None, retire_source=False):
    if layout not in {"testing", "operational"}:
        raise ValueError("Unknown Hidden Passage layout")
    if deploy and deploy_to:
        raise ValueError("Choose --deploy or --deploy-to, not both")
    if retire_source and not deploy_to:
        raise ValueError("--retire-source requires --deploy-to")
    source = source.resolve()
    target = source if deploy else Path(deploy_to).resolve() if deploy_to else None
    if deploy_to and (target == source or target.exists()):
        raise ValueError("--deploy-to requires a separate, non-existing destination")
    original = source.read_bytes()
    members = {}
    with ZipFile(io.BytesIO(original)) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            if entry.filename in members:
                raise ValueError("Duplicate archive member")
            members[entry.filename] = archive.read(entry)
    main = "l10n/DEFAULT/OHP-main.lua"
    required = {"mission", "options", "warehouses", "l10n/DEFAULT/dictionary",
                "l10n/DEFAULT/mapResource", main, "l10n/DEFAULT/OHP-Moose_.lua"}
    if not required <= members.keys():
        raise ValueError(f"Missing archive members: {sorted(required - members.keys())}")
    if members["l10n/DEFAULT/OHP-Moose_.lua"] != (ROOT / "src/lib/Moose_.lua").read_bytes():
        raise ValueError("Archive MOOSE differs from the tested pin; review before updating")
    candidate = dict(members)
    candidate[main] = PACK["shipping_payload"]()
    dictionary = "l10n/DEFAULT/dictionary"
    old_instruction = b"3. F10 > Operation Hidden Passage > Extract waiting personnel."
    new_instruction = b"3. Remain stopped for 2 seconds; boarding starts automatically. F10 > Operation Hidden Passage > Extract waiting personnel is a fallback."
    if candidate[dictionary].count(old_instruction) == 2:
        candidate[dictionary] = candidate[dictionary].replace(old_instruction, new_instruction)
    elif candidate[dictionary].count(new_instruction) != 2:
        raise ValueError("Unknown boarding briefing; review before modifying editor-authored text")
    # Update only the known aircraft instructions in the two standard briefings.
    briefing_changes = [
        (b"Blue CH-47F Mule-1 starts hot at Hatay. Fly to PICKUP (waypoint 4), collect",
         b"Mule One (CH-47F) and Raven One (UH-60L) are available at Hatay. Fly to PICKUP (waypoint 4), collect"),
        (b"The added UH-60L Client slot is preserved but NOT connected to this objective.",
         b"Both helicopters can extract the package; the first to start boarding becomes its carrier."),
        (b"Use the Chinook for extraction. No adaptive enemies or SAMs are scripted yet.",
         b"The other helicopter remains in support. No adaptive enemies or SAMs are scripted yet."),
    ]
    for old, new in briefing_changes:
        if candidate[dictionary].count(old) == 2:
            candidate[dictionary] = candidate[dictionary].replace(old, new)
        elif candidate[dictionary].count(new) != 2:
            raise ValueError("Unknown aircraft briefing; review before modifying editor-authored text")
    if layout == "testing":
        title = b'"Operation Hidden Passage - Testing"'
        if candidate[dictionary].count(title) != 1:
            for old in [b'"Operation Hidden Passage - Voice Test"', b'"Operation Hidden Passage"']:
                if candidate[dictionary].count(old) == 1:
                    candidate[dictionary] = candidate[dictionary].replace(old, title)
                    break
            else:
                raise ValueError("Unknown test mission title; review before renaming")
    replace_audio = set(replace_audio)
    available = {file.name for file in (ROOT / "src/missions/operation-hidden-passage/sounds").glob("*.ogg")}
    if not replace_audio <= available:
        raise ValueError("--replace-audio must name known source Ogg files by basename")
    for file in (ROOT / "src/missions/operation-hidden-passage/sounds").glob("*.ogg"):
        name, data = "Sounds/OHP/" + file.name, file.read_bytes()
        if name in members and members[name] != data and file.name not in replace_audio:
            raise ValueError(f"Existing recording differs from source; review before replacing: {name}")
        candidate[name] = data
    referenced = set(re.findall(rb'["\'](Sounds/OHP/[^"\']+\.ogg)["\']', candidate[main]))
    for name in referenced:
        if name.decode() not in candidate:
            raise ValueError(f"Missing referenced audio: {name!r}")
    out = ROOT / "out"
    out.mkdir(exist_ok=True)
    stem = "operation-hidden-passage-testing" if layout == "testing" else "operation-hidden-passage"
    artifact = out / (stem + ".miz")
    if source == artifact.resolve() or target == artifact.resolve():
        raise ValueError("Input/deployment target cannot be the generated output")
    with tempfile.TemporaryDirectory(prefix="ohp-short-update-", dir=out) as temp:
        temp = Path(temp)
        mission = temp / "mission"
        mission.write_bytes(members["mission"])
        briefing = temp / "dictionary"
        briefing.write_bytes(candidate[dictionary])
        PACK["lua"](ROOT / "tests/lua/run-hidden-passage-layout-artifact.lua", mission, briefing, layout)
        script = temp / "OHP-main.lua"
        script.write_bytes(candidate[main])
        PACK["lua"](ROOT / "tests/lua/run-hidden-passage-adapter.lua", script, mission)
        generated = temp / "candidate.miz"
        with ZipFile(generated, "w", ZIP_DEFLATED) as archive:
            for name, data in candidate.items():
                archive.writestr(name, data)
        with ZipFile(generated) as archive:
            assert archive.testzip() is None
            assert set(archive.namelist()) == set(candidate)
            changed = {name for name in members if archive.read(name) != members[name]}
            permitted = {main, dictionary} | {"Sounds/OHP/" + name for name in replace_audio}
            assert changed <= permitted, f"Unapproved archive changes: {changed}"
            for name, data in candidate.items():
                assert archive.read(name) == data
        data = generated.read_bytes()
        artifact.write_bytes(data)
    sha = lambda data: hashlib.sha256(data).hexdigest()
    evidence = {
        "input": str(source), "inputSha256": sha(original),
        "layout": layout,
        "output": str(artifact), "outputSha256": sha(data),
        "changedMembers": sorted(changed), "addedMembers": sorted(candidate.keys() - members.keys()),
        "replacedAudio": sorted(name for name in changed if name.startswith("Sounds/OHP/")),
        "verified": "explicit layout, tested MOOSE pin, targeted briefing/audio edits, editor preservation, adapter mocks, ZIP CRC; NOT long-route live acceptance",
    }
    if source.read_bytes() != original:
        raise RuntimeError("Input changed during build; refusing deployment")
    if target:
        backup_dir = source.parent.parent / "Backups/Operation-Hidden-Passage"
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = backup_dir / f"{source.stem}-before-voice-{stamp}.miz"
        with backup.open("xb") as file:
            file.write(original)
        assert backup.read_bytes() == original
        if source.read_bytes() != original:
            raise RuntimeError("Input changed before replacement; refusing deployment")
        replacement = source.with_name(source.name + ".ohp-voice-tmp")
        try:
            with replacement.open("xb") as file:
                file.write(data)
            if target == source:
                replacement.replace(target)
            else:
                # A new name must never overwrite an existing mission.
                with target.open("xb") as file:
                    file.write(data)
        finally:
            if replacement.exists():
                replacement.unlink()
        assert target.read_bytes() == data
        evidence.update(backup=str(backup), deployed=str(target))
        if target != source and retire_source:
            if source.read_bytes() != original:
                raise RuntimeError("Source changed before retirement; both missions retained")
            source.unlink()  # Explicit rename request; exact original is backed up.
            evidence["renamedFrom"] = str(source)
    (out / (stem + "-evidence.json")).write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--layout", choices=["testing", "operational"], default="testing")
    deployment = parser.add_mutually_exclusive_group()
    deployment.add_argument("--deploy", action="store_true")
    deployment.add_argument("--deploy-to", type=Path, help="Create a separate, non-existing named mission")
    parser.add_argument("--retire-source", action="store_true", help="With --deploy-to, retire the old filename after verified backup/deployment")
    parser.add_argument("--replace-audio", action="append", default=[], metavar="NAME.ogg",
                        help="Explicitly allow replacing this source recording; all others remain protected")
    args = parser.parse_args()
    update(args.input, args.deploy, args.replace_audio, args.layout, args.deploy_to, args.retire_source)
