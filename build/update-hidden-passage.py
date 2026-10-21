"""Preserve an existing Hidden Passage layout while updating its script, briefing and audio.

Mission/editor tables are preserved. Operational briefing replacement is guarded
by its recognized prior text; existing recordings require explicit --replace-audio permission.
Default layout is testing; --layout operational explicitly enables the approved
long-range port. --enable-firefight adds the staged enemy template to either
layout; --enable-test-firefight remains a Testing-only compatibility alias.
--deploy replaces --input; --deploy-to writes a new named copy.
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
OPERATIONAL_STORY_BRIEFING = (
    "OPERATION HIDDEN PASSAGE\n\n"
    "Three local sources have been compromised south of Hatay. They know enemy positions and movements in the area. "
    "Hostile troops are closing on their hideout; if captured, both the intelligence and the network behind it could be lost.\n\n"
    "Mule One is tasked to extract all three to Hatay for debrief. Raven One can cover the pickup or fly the extraction.\n\n"
    "On final, use F10 to request green smoke. Land clear of the personnel and remain landed until all three are aboard. "
    "Return to Hatay and unload."
)
OPERATIONAL_BRIEFING_KEYS = ("DictKey_descriptionText_1", "DictKey_descriptionBlueTask_3")
OPERATIONAL_LEGACY_BRIEFING_SHA256S = frozenset(
    {"a9c7a07d7a598013be397b8f8565f236c3897b58b19290f4776dd90f12e34b01"}
)
OPERATIONAL_BRIEFING_MARKERS = (
    "Mule One (CH-47F) and Raven One (UH-60L) are available at Hatay.",
    "The pickup is approximately 33.1 NM south of Hatay",
    "OHP-Pickup is the LANDING area.",
    "1. F10 > Operation Hidden Passage > Mark landing area (green smoke).",
    "There is no automatic mission end.",
)


def _lua_string_field(data, key):
    pattern = re.compile(rb'(\["' + re.escape(key.encode("ascii")) + rb'"\]\s*=\s*)"')
    matches = list(pattern.finditer(data))
    if len(matches) != 1:
        raise ValueError(f"Expected one Lua dictionary field {key}; found {len(matches)}")
    match = matches[0]
    start = match.end()
    cursor = start
    while cursor < len(data):
        if data[cursor] == 0x5C:  # Lua escape, including DCS's backslash-newline format.
            cursor += 2
        elif data[cursor] == 0x22:
            raw = data[start:cursor]
            normalized = raw.replace(b"\\\r\n", b"\\n").replace(b"\\\n", b"\\n")
            try:
                value = normalized.decode("unicode_escape")
            except UnicodeDecodeError as error:
                raise ValueError(f"Cannot decode Lua dictionary field {key}") from error
            return match.start(1), start, cursor, cursor + 1, value
        else:
            cursor += 1
    raise ValueError(f"Unterminated Lua dictionary field {key}")


def _rewrite_operational_briefing(dictionary):
    fields = [_lua_string_field(dictionary, key) for key in OPERATIONAL_BRIEFING_KEYS]
    values = [field[4] for field in fields]
    if values[0] != values[1]:
        raise ValueError("Operational description and Blue task differ; review before replacing the briefing")
    current = values[0]
    if current == OPERATIONAL_STORY_BRIEFING:
        return dictionary
    fingerprint = hashlib.sha256(current.encode("utf-8")).hexdigest()
    if fingerprint not in OPERATIONAL_LEGACY_BRIEFING_SHA256S or not all(
        marker in current for marker in OPERATIONAL_BRIEFING_MARKERS
    ):
        raise ValueError("Unknown operational briefing; review before replacing editor-authored text")
    replacement = json.dumps(OPERATIONAL_STORY_BRIEFING, ensure_ascii=True)[1:-1].encode("ascii")
    for key, field in reversed(list(zip(OPERATIONAL_BRIEFING_KEYS, fields))):
        _, start, end, _, _ = field
        dictionary = dictionary[:start] + replacement + dictionary[end:]
    return dictionary


def _has_current_operational_briefing(dictionary):
    try:
        values = [_lua_string_field(dictionary, key)[4] for key in OPERATIONAL_BRIEFING_KEYS]
    except ValueError:
        return False
    return values[0] == OPERATIONAL_STORY_BRIEFING and values[1] == OPERATIONAL_STORY_BRIEFING


def update(
    source,
    deploy=False,
    replace_audio=(),
    layout="testing",
    deploy_to=None,
    retire_source=False,
    enable_test_firefight=False,
    enable_firefight=False,
):
    if layout not in {"testing", "operational"}:
        raise ValueError("Unknown Hidden Passage layout")
    if deploy and deploy_to:
        raise ValueError("Choose --deploy or --deploy-to, not both")
    if retire_source and not deploy_to:
        raise ValueError("--retire-source requires --deploy-to")
    if enable_test_firefight and layout != "testing":
        raise ValueError("The firefight prototype can only be added to the Testing layout")
    enable_firefight = enable_firefight or enable_test_firefight
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
    current_story = layout == "operational" and _has_current_operational_briefing(candidate[dictionary])
    old_instruction = b"3. F10 > Operation Hidden Passage > Extract waiting personnel."
    new_instruction = b"3. Remain stopped for 2 seconds; boarding starts automatically. F10 > Operation Hidden Passage > Extract waiting personnel is a fallback."
    if not current_story:
        if candidate[dictionary].count(old_instruction) == 2:
            candidate[dictionary] = candidate[dictionary].replace(old_instruction, new_instruction)
        elif candidate[dictionary].count(new_instruction) != 2:
            raise ValueError("Unknown boarding briefing; review before modifying editor-authored text")
    no_firefight_briefing = b"The other helicopter remains in support. No adaptive enemies or SAMs are scripted yet."
    testing_firefight_briefing = (
        b"Testing only: six killable riflemen stage about 400 m from the HVTs. They move in at outbound halfway and open fire inside 300 m. "
        b"The HVTs return fire for 5 seconds, then hold while remaining protected until the exchange ends. The exchange ends when the HVTs are aboard, "
        b"the enemy force is eliminated, or after 10 minutes; the operational mission is unchanged."
    )
    operational_firefight_briefing = (
        b"About 3 NM before pickup, the primary rifle group moves in and opens fire inside 300 m. "
        b"A second concealed infantry group moves toward the HVTs when boarding begins. "
        b"The HVTs return fire for 5 seconds, then hold while remaining protected until the exchange ends. "
        b"Engage the enemy, but avoid the HVT party; your aircraft remain vulnerable."
    )
    previous_operational_firefight_briefing = (
        b"About 3 NM before pickup, six killable riflemen move in on the HVTs and open fire inside 300 m. "
        b"The HVTs return fire for 5 seconds, then hold while remaining protected until the exchange ends. "
        b"Engage the enemy, but avoid the HVT party; your aircraft remain vulnerable."
    )
    legacy_test_firefight = (
        b"Testing only: killable hostile riflemen open fire inside 1.5 NM. The exchange stops when they are eliminated, "
        b"the party is aboard, or after 10 minutes; the operational mission is unchanged."
    )
    # Update only the known aircraft instructions in the two standard briefings.
    briefing_changes = [
        (b"Blue CH-47F Mule-1 starts hot at Hatay. Fly to PICKUP (waypoint 4), collect",
         b"Mule One (CH-47F) and Raven One (UH-60L) are available at Hatay. Fly to PICKUP (waypoint 4), collect"),
        (b"The added UH-60L Client slot is preserved but NOT connected to this objective.",
         b"Both helicopters can extract the package; the first to start boarding becomes its carrier."),
        (b"Use the Chinook for extraction. No adaptive enemies or SAMs are scripted yet.", no_firefight_briefing),
    ]
    if not current_story:
        for old, new in briefing_changes:
            if candidate[dictionary].count(old) == 2:
                candidate[dictionary] = candidate[dictionary].replace(old, new)
            elif candidate[dictionary].count(new) != 2:
                already_has_firefight = old == briefing_changes[2][0] and any(
                    candidate[dictionary].count(briefing) == 2
                    for briefing in (
                        testing_firefight_briefing,
                        operational_firefight_briefing,
                        previous_operational_firefight_briefing,
                        legacy_test_firefight,
                    )
                )
                if not already_has_firefight:
                    raise ValueError("Unknown aircraft briefing; review before modifying editor-authored text")
        if candidate[dictionary].count(previous_operational_firefight_briefing) == 2:
            candidate[dictionary] = candidate[dictionary].replace(
                previous_operational_firefight_briefing, operational_firefight_briefing
            )
    if enable_firefight and not current_story:
        target_briefing = testing_firefight_briefing if layout == "testing" else operational_firefight_briefing
        if candidate[dictionary].count(target_briefing) != 2:
            known = (
                no_firefight_briefing,
                testing_firefight_briefing,
                operational_firefight_briefing,
                previous_operational_firefight_briefing,
                legacy_test_firefight,
            )
            matches = [briefing for briefing in known if candidate[dictionary].count(briefing) == 2]
            if len(matches) != 1:
                raise ValueError("Unknown firefight briefing; review before modifying editor-authored text")
            candidate[dictionary] = candidate[dictionary].replace(matches[0], target_briefing)
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
        # Reject the wrong archive/layout before transforming any of its briefing.
        PACK["lua"](ROOT / "tests/lua/run-hidden-passage-layout-artifact.lua", mission, layout)
        if enable_firefight:
            firefight_mission = temp / "mission-with-firefight-template"
            PACK["lua"](ROOT / "build/prepare-hidden-passage-firefight.lua", mission, firefight_mission, layout)
            PACK["lua"](
                ROOT / "tests/lua/run-hidden-passage-firefight-artifact.lua", mission, firefight_mission, layout
            )
            candidate["mission"] = firefight_mission.read_bytes()
            mission.write_bytes(candidate["mission"])
        if layout == "operational":
            candidate[dictionary] = _rewrite_operational_briefing(candidate[dictionary])
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
            if enable_firefight:
                permitted.add("mission")
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
        "verified": "explicit layout, tested MOOSE pin, targeted briefing/audio edits, editor preservation, optional constrained killable-infantry template, adapter mocks, ZIP CRC; NOT live DCS acceptance",
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
    parser.add_argument(
        "--enable-firefight",
        action="store_true",
        help="Add the approved late-activated killable-infantry template to the selected layout",
    )
    parser.add_argument(
        "--enable-test-firefight",
        action="store_true",
        help="Testing-only compatibility alias for --enable-firefight",
    )
    parser.add_argument("--replace-audio", action="append", default=[], metavar="NAME.ogg",
                        help="Explicitly allow replacing this source recording; all others remain protected")
    args = parser.parse_args()
    update(
        args.input,
        args.deploy,
        args.replace_audio,
        args.layout,
        args.deploy_to,
        args.retire_source,
        enable_test_firefight=args.enable_test_firefight,
        enable_firefight=args.enable_firefight,
    )
