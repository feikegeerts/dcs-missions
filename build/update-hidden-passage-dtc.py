"""Add native, preloaded CAP threat cartridges without rewriting editor data.

Reads the installed DCS DTC definitions. Changes only the two CAP units' DTC
assignments and DTC/OHP-CAP-*.dtc archive members. No gameplay/script/audio edits.
"""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
DCS = Path(r"C:\Program Files (x86)\Steam\steamapps\common\DCSWorld")
TARGETS = {
    "CAP-Hornet": ("FA-18C_hornet", "OHP-CAP-HORNET"),
    "CAP-Viper": ("F-16C_50", "OHP-CAP-VIPER"),
}
RADARS = {
    "Kub 1S91 str": "SAM SA-6 'Gainful'",
    "Osa 9A33 ln": "SAM SA-8 'Gecko'",
    "S-300PS 40B6M tr": "SAM SA-10 'Grumble'",
}


def lua_data(path, root):
    lua = shutil.which("lua5.1") or shutil.which("lua5.1.exe")
    if not lua:
        raise RuntimeError("Lua 5.1 is required")
    with tempfile.TemporaryDirectory(prefix="ohp-dtc-read-", dir=ROOT / "out") as folder:
        output = Path(folder) / "data.json"
        result = subprocess.run([lua, str(ROOT / "build/read-lua-table-json.lua"), str(path), root, str(output)],
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise ValueError(f"Cannot read Lua data {path}: {result.stderr.strip()}")
        return json.loads(output.read_text(encoding="utf-8"))


def mission_data(data):
    with tempfile.TemporaryDirectory(prefix="ohp-dtc-mission-", dir=ROOT / "out") as folder:
        path = Path(folder) / "mission"
        path.write_bytes(data)
        return lua_data(path, "mission")


def values(table):
    return table.values() if isinstance(table, dict) else table


def groups(mission, side, category):
    for country in values(mission["coalition"][side].get("country", {})):
        yield from values(country.get(category, {}).get("group", {}))


def profiles(install):
    base = install / "CoreMods/aircraft"
    hornet = lua_data(base / "FA-18C/DTC/SA/MEZ_THRTS_defs.lua", "MEZ_THRTS_defs")
    viper = lua_data(base / "F-16C/DTC/MPD/THREAT_PTS_defs.lua", "THREAT_PTS_defs")
    settings = lua_data(base / "FA-18C/DTC/SA/SETTINGS_defs.lua", "SA_SETTINGS")
    return ({entry["name"]: entry for entry in hornet},
            {entry["name"]: (i, entry) for i, entry in enumerate(viper, 1)}, settings)


def threat_sites(mission):
    sites = []
    for group in sorted(groups(mission, "red", "vehicle"), key=lambda g: g["name"]):
        if group.get("hidden") or group.get("hiddenOnMFD"):
            continue
        for unit in values(group["units"]):
            if unit["type"] in RADARS:
                route = list(values(group.get("route", {}).get("points", {})))
                start = route[0] if route else {}
                elevation = unit.get("alt", start.get("alt"))
                if not isinstance(elevation, (int, float)):
                    raise ValueError("Missing authored ground-route elevation for " + group["name"])
                sites.append({"group": group["name"], "unit": unit["name"], "kind": RADARS[unit["type"]],
                              "x": unit["x"], "y": unit["y"], "elevation": elevation})
    if not any(site["group"] == "Ground-9" and site["kind"] == RADARS["Kub 1S91 str"] for site in sites):
        raise ValueError("Expected the visible Ground-9 Kub radar; refusing guessed threat intel")
    if len(sites) > 15:
        raise ValueError("Viper supports at most 15 threat points; refusing to drop existing threats")
    return sites


def cartridges(mission, definitions):
    hornet, viper, settings = definitions
    sites = threat_sites(mission)
    mez, points = [], []
    for number, site in enumerate(sites, 1):
        h = hornet[site["kind"]]
        index, v = viper[site["kind"]]
        mez.append({"id": f"MEZ_THRTS_{number}", "num": number, "x": site["x"], "y": site["y"],
                    "text": h["default_text"], "threat_type": h["name"],
                    "threat_ring_radius": h["detectionRange"] / 1852, "threat_level": 1})
        # Use the authored ground-route elevation, never the aircraft waypoint
        # height. This is planning data, not a new terrain-height measurement.
        points.append({"number": number, "id": f"THREAT_PTS{55 + number}",
                       "x": site["x"], "y": site["y"], "threatName": v["name"],
                       "radius": v["detectionRange"], "alt": v["altitude"], "elev": site["elevation"],
                       "text": v["default_text"], "ring": True, "def_num": index})
    # Only threat data is supplied. Omitted navigation/radio/CMDS partitions are
    # not replaced; explicit mirror flags preserve the Viper's other MPD tabs.
    common = {"terrain": mission["theatre"]}
    result = {
        "OHP-CAP-HORNET": {"name": "OHP-CAP-HORNET", "type": "FA-18C_hornet", "data": {
            **common, "type": "FA-18C_hornet", "name": "OHP-CAP-HORNET",
            "SA": {"mirror_MEZ_THRTS": False, "Default_MEZ_THRTS_Level": 1,
                             "MEZ_THRTS": mez, "SETTINGS": deepcopy(settings)}}},
        "OHP-CAP-VIPER": {"name": "OHP-CAP-VIPER", "type": "F-16C_50", "data": {
            **common, "type": "F-16C_50", "name": "OHP-CAP-VIPER",
            "MPD": {"terrain": mission["theatre"], "mirror_NAV_PTS": True,
                              "mirror_DEST": True, "mirror_GEO_LINES": True,
                              "mirror_THREAT_PTS": False, "THREAT_PTS": points}}},
    }
    return result, sites


def tokens(text):
    """Lex enough Lua to locate unit tables; never regex-match inside strings/comments."""
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        start = i
        if text.startswith("--", i):
            long = re.match(r"\[(=*)\[", text[i + 2:])
            if long:
                end = text.find("]" + long[1] + "]", i + 2 + len(long[0]))
                if end < 0: raise ValueError("Unterminated Lua comment")
                i = end + len(long[1]) + 2
            else:
                end = text.find("\n", i)
                i = len(text) if end < 0 else end + 1
            continue
        if text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < len(text) and text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            if i >= len(text): raise ValueError("Unterminated Lua string")
            i += 1
        elif (long := re.match(r"\[(=*)\[", text[i:])):
            end = text.find("]" + long[1] + "]", i + len(long[0]))
            if end < 0: raise ValueError("Unterminated Lua long string")
            i = end + len(long[1]) + 2
        elif (word := re.match(r"[A-Za-z_]\w*|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", text[i:])):
            i += len(word[0])
        else:
            i += 1
        yield text[start:i], start, i


def patch_assignments(raw, assignments):
    text = raw.decode("utf-8")
    ts = list(tokens(text))
    stack, units, closes = [], {}, {}
    for i, (token, start, end) in enumerate(ts):
        if token == "{":
            stack.append({"start": start, "fields": {}})
        elif token == "}":
            table = stack.pop()
            closes[table["start"]] = end
            if "unitId" in table:
                if table["unitId"] in units: raise ValueError("Duplicate unitId")
                table["close"] = start
                table["trailing"] = ts[i - 1][0]
                units[table["unitId"]] = table
        elif stack and token == "[" and i + 4 < len(ts) and ts[i + 2][0] == "]" and ts[i + 3][0] == "=":
            key = ts[i + 1][0]
            if key in ('"unitId"', "'unitId'"):
                stack[-1]["unitId"] = int(ts[i + 4][0])
            if key in ('"DTC"', "'DTC'"):
                if "DTC" in stack[-1]["fields"]: raise ValueError("Duplicate DTC field")
                stack[-1]["fields"]["DTC"] = ts[i + 4]
    if stack: raise ValueError("Unbalanced Lua tables")
    edits = []
    for unit_id, assignment in assignments.items():
        table = units[unit_id]
        rendered = '{["AutoLoad"]=true,["Cartridges"]={{["name"]=' + json.dumps(assignment) + ',["default"]=true}}}'
        if "DTC" in table["fields"]:
            token, start, end = table["fields"]["DTC"]
            if token != "{": raise ValueError("Expected DTC data table")
            edits.append((start, closes[start], rendered))
        else:
            comma = "" if table["trailing"] in ("{", ",", ";") else ","
            edits.append((table["close"], table["close"], comma + '["DTC"]=' + rendered + ","))
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text.encode("utf-8")


def prepare(members, definitions):
    before = mission_data(members["mission"])
    if before.get("theatre") != "Syria": raise ValueError("Expected Hidden Passage Syria mission")
    generated, sites = cartridges(before, definitions)
    expected = deepcopy(before)
    assignments, found = {}, set()
    for group in groups(expected, "blue", "plane"):
        if group["name"] not in TARGETS: continue
        if group["name"] in found: raise ValueError("Duplicate CAP group")
        found.add(group["name"])
        kind, name = TARGETS[group["name"]]
        if len(group["units"]) != 1: raise ValueError("Review multi-unit CAP DTC assignment")
        unit = group["units"][0]
        if unit["type"] != kind or unit["skill"] not in ("Client", "Player"):
            raise ValueError("Unexpected CAP aircraft")
        desired = {"AutoLoad": True, "Cartridges": [{"name": name, "default": True}]}
        if unit.get("DTC") not in (None, {}, desired):
            raise ValueError("Existing custom aircraft DTC requires review; refusing overwrite")
        unit["DTC"] = desired
        assignments[unit["unitId"]] = name
    if found != set(TARGETS): raise ValueError("Both CAP aircraft are required")
    candidate = dict(members)
    if before != expected:
        candidate["mission"] = patch_assignments(members["mission"], assignments)
    if mission_data(candidate["mission"]) != expected:
        raise ValueError("Mission preservation failure: changes beyond the two unit DTC fields")
    for name, cartridge in generated.items():
        member = f"DTC/{name}.dtc"
        if member in members:
            old = json.loads(members[member])
            if old != cartridge:
                raise ValueError("Existing cartridge differs; review before replacing threat data")
        else:
            candidate[member] = (json.dumps(cartridge, indent=2) + "\n").encode()
    return candidate, sites


def update(source, deploy=False, install=DCS, definitions=None):
    source = Path(source).resolve()
    out = ROOT / "out"
    out.mkdir(exist_ok=True)
    output = out / "operation-hidden-passage.miz"
    if source == output.resolve(): raise ValueError("Input cannot be generated output")
    original = source.read_bytes()
    with ZipFile(io.BytesIO(original)) as archive:
        infos = archive.infolist()
        members = {info.filename: archive.read(info) for info in infos}
        if len(members) != len(infos): raise ValueError("Duplicate archive members")
        if archive.testzip() is not None: raise ValueError("Input ZIP CRC failure")
    candidate, sites = prepare(members, definitions or profiles(Path(install)))
    changed = sorted(name for name in members if members[name] != candidate[name])
    added = sorted(set(candidate) - set(members))
    if set(changed) - {"mission"}: raise ValueError("Unexpected archive change")
    if candidate == members:
        data = original
    else:
        buffer = io.BytesIO()
        with ZipFile(buffer, "w") as archive:
            for info in infos: archive.writestr(info, candidate[info.filename])
            for name in added: archive.writestr(name, candidate[name])
        data = buffer.getvalue()
    with ZipFile(io.BytesIO(data)) as archive:
        if archive.testzip() is not None: raise ValueError("Candidate ZIP CRC failure")
        if {name: archive.read(name) for name in archive.namelist()} != candidate:
            raise ValueError("Candidate archive verification failure")
    sha = lambda value: hashlib.sha256(value).hexdigest()
    evidence = {"input": str(source), "inputSha256": sha(original), "output": str(output),
                "outputSha256": sha(data), "changedMembers": changed, "addedMembers": added,
                "aircraft": list(TARGETS), "threatSites": sites,
                "verified": "native installed DTC schema; exact two-field mission semantic diff; other archive members preserved; ZIP CRC; NOT live cockpit acceptance"}
    if definitions is None:
        paths = ["CoreMods/aircraft/FA-18C/DTC/SA/MEZ_THRTS_defs.lua",
                 "CoreMods/aircraft/FA-18C/DTC/SA/SETTINGS_defs.lua",
                 "CoreMods/aircraft/FA-18C/DTC/FA-18C_hornet_DTC.lua",
                 "CoreMods/aircraft/F-16C/DTC/MPD/THREAT_PTS_defs.lua",
                 "CoreMods/aircraft/F-16C/DTC/F-16C_50_DTC.lua",
                 "MissionEditor/modules/me_DTC.lua", "MissionEditor/modules/me_managerDTC.lua"]
        evidence["nativeSchemaHashes"] = {path: sha((Path(install) / path).read_bytes()) for path in paths}
    if source.read_bytes() != original: raise RuntimeError("Input changed during build")
    output.write_bytes(data)
    if deploy:
        backup_dir = source.parent.parent / "Backups/Operation-Hidden-Passage"
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / (source.stem + "-before-dtc-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".miz")
        with backup.open("xb") as file: file.write(original)
        if backup.read_bytes() != original: raise RuntimeError("Backup verification failure")
        if source.read_bytes() != original: raise RuntimeError("Input changed before deployment")
        temporary = source.with_name(source.name + ".ohp-dtc-tmp")
        try:
            with temporary.open("xb") as file: file.write(data)
            if source.read_bytes() != original: raise RuntimeError("Input changed before replacement")
            temporary.replace(source)
        finally:
            temporary.unlink(missing_ok=True)
        if source.read_bytes() != data: raise RuntimeError("Installed archive verification failure")
        evidence.update(backup=str(backup), deployed=str(source))
    (out / "operation-hidden-passage-dtc-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--deploy", action="store_true")
    parser.add_argument("--dcs-install", type=Path, default=DCS)
    args = parser.parse_args()
    update(args.input, args.deploy, args.dcs_install)
