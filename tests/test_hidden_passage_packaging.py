"""Archive/deployment safety tests; gameplay is covered by the Lua adapter suite."""

import contextlib
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
LUA = shutil.which("lua5.1.exe") or shutil.which("lua5.1")


def lua_table(value):
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, (int, float)):
        return repr(value)
    items = enumerate(value, 1) if isinstance(value, list) else value.items()
    return "{" + ",".join(f"[{lua_table(k)}]={lua_table(v)}" for k, v in items) + "}"


@unittest.skipUnless(LUA, "Lua 5.1 is required")
class PackagingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "out").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ohp-packaging-test-", dir=ROOT / "out")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.root = self.folder / "repo"
        sounds = self.root / "src/missions/operation-hidden-passage/sounds"
        sounds.mkdir(parents=True)
        (sounds / "example.ogg").write_bytes(b"OggSnew-recording")
        (self.root / "src/lib").mkdir()
        (self.root / "src/lib/Moose_.lua").write_bytes(b"tested-pin")
        self.payload = b'local file = "Sounds/OHP/example.ogg"\nreturn true\n'
        module = runpy.run_path(str(ROOT / "build/update-hidden-passage.py"))
        self.update = module["update"]
        self.update.__globals__["ROOT"] = self.root
        self.update.__globals__["PACK"] = {"shipping_payload": lambda: self.payload, "lua": self.check_lua}

    def check_lua(self, path, *args):
        if path.name in {
            "prepare-hidden-passage-firefight.lua",
            "run-hidden-passage-firefight-artifact.lua",
            "run-hidden-passage-layout-artifact.lua",
        }:
            folder = "build" if path.name.startswith("prepare-") else "tests/lua"
            subprocess.run([LUA, str(ROOT / folder / path.name), *map(str, args)],
                           cwd=ROOT, check=True, capture_output=True)
        else:
            self.assertEqual(path.name, "run-hidden-passage-adapter.lua")
            self.assertEqual(Path(args[0]).read_bytes(), self.payload)

    def fixture(self, layout="testing", audio=None, firefight_offset=None):
        pickup = (151595.453125, 42823.1015625) if layout == "testing" else (86422.487668525, 41545.335676019)
        hvt = (pickup[0] - 42, pickup[1] - 72)
        mission = {
            "theatre": "Syria", "sortie": "DictKey_sortie_5", "descriptionText": "general",
            "descriptionBlueTask": "blue", "triggers": {"zones": [
                {"name": "OHP-Pickup", "x": pickup[0], "y": pickup[1], "radius": 35},
                {"name": "OHP-Hatay-Return", "x": 147592.73464202, "y": 38819.890889083, "radius": 180},
                {"name": "OHP-HVTs", "x": hvt[0], "y": hvt[1], "radius": 25},
            ]},
            "coalition": {"red": {"country": []}, "blue": {"country": [{"helicopter": {"group": [
                {"units": [{"name": "Mule-1-1", "type": "CH-47Fbl1"}]},
                {"units": [{"name": "Raven-1-1", "type": "UH-60L"}]},
            ]}}]}},
        }
        briefing = (
            "Blue CH-47F Mule-1 starts hot at Hatay. Fly to PICKUP (waypoint 4), collect\n"
            "3. F10 > Operation Hidden Passage > Extract waiting personnel.\n"
            "The added UH-60L Client slot is preserved but NOT connected to this objective.\n"
            "Use the Chinook for extraction. No adaptive enemies or SAMs are scripted yet."
        )
        if firefight_offset is not None:
            briefing = briefing.replace(
                "Use the Chinook for extraction. No adaptive enemies or SAMs are scripted yet.",
                "Testing only: killable hostile riflemen open fire inside 1.5 NM. The exchange stops when they are eliminated, "
                "the party is aboard, or after 10 minutes; the operational mission is unchanged.",
            )
        title = "Operation Hidden Passage - Voice Test" if layout == "testing" else "Operation Hidden Passage"
        dictionary = {"DictKey_sortie_5": title, "general": briefing, "blue": briefing, "custom": "Keep this."}
        members = {
            "mission": ("mission=" + lua_table(mission)).encode(),
            "l10n/DEFAULT/dictionary": ("dictionary=" + lua_table(dictionary)).encode(),
            "l10n/DEFAULT/mapResource": b"editor-owned resources",
            "l10n/DEFAULT/OHP-main.lua": b"old payload",
            "l10n/DEFAULT/OHP-Moose_.lua": b"tested-pin",
            "options": b"editor-owned options", "warehouses": b"editor-owned warehouses",
            "custom-asset.txt": b"preserve arbitrary assets",
        }
        if firefight_offset is not None:
            x, y = hvt[0] + firefight_offset, hvt[1] - firefight_offset
            units = []
            for index in range(1, 7):
                column, row = (index - 1) % 3, (index - 1) // 3
                units.append({
                    "unitId": 800 + index, "name": f"OHP-TestOpposition-{index}",
                    "type": "Infantry AK", "x": x + (column - 1) * 9,
                    "y": y + (row - 0.5) * 10,
                })
            mission["coalition"]["red"]["country"].append({
                "id": 0, "name": "RUSSIA", "vehicle": {"group": [{
                    "groupId": 800, "name": "OHP-TestOpposition", "x": x, "y": y,
                    "lateActivation": True,
                    "route": {"points": [{"x": x, "y": y}]}, "units": units,
                }]},
            })
        if audio is not None:
            members["Sounds/OHP/example.ogg"] = audio
        source = self.folder / "Missions" / (layout + ".miz")
        source.parent.mkdir(exist_ok=True)
        with ZipFile(source, "w", ZIP_DEFLATED) as archive:
            for name, data in members.items():
                archive.writestr(name, data)
        return source, members

    def run_update(self, source, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            self.update(source, **kwargs)

    def test_testing_update_preserves_editor_members_and_source(self):
        source, before = self.fixture()
        original = source.read_bytes()
        self.run_update(source)
        self.assertEqual(source.read_bytes(), original)
        with ZipFile(self.root / "out/operation-hidden-passage-testing.miz") as archive:
            self.assertIsNone(archive.testzip())
            for name, data in before.items():
                if name not in {"l10n/DEFAULT/dictionary", "l10n/DEFAULT/OHP-main.lua"}:
                    self.assertEqual(archive.read(name), data)
            self.assertIn(b"Operation Hidden Passage - Testing", archive.read("l10n/DEFAULT/dictionary"))

    def test_operational_requires_explicit_correct_layout(self):
        source, _ = self.fixture("operational")
        original = source.read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_update(source)
        self.assertEqual(source.read_bytes(), original)
        self.run_update(source, layout="operational")
        self.assertTrue((self.root / "out/operation-hidden-passage.miz").is_file())

    def test_testing_rejects_operational_mode(self):
        source, _ = self.fixture()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_update(source, layout="operational")

    def test_test_firefight_adds_only_the_constrained_testing_template(self):
        source, before = self.fixture()
        self.run_update(source, enable_test_firefight=True)
        output = self.root / "out/operation-hidden-passage-testing.miz"
        with ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            mission = archive.read("mission")
            self.assertIn(b"OHP-TestOpposition", mission)
            self.assertEqual(mission.count(b'"Infantry AK"'), 6)
            self.assertIn(b"Testing only: six killable riflemen stage", archive.read("l10n/DEFAULT/dictionary"))
            for name, data in before.items():
                if name not in {"mission", "l10n/DEFAULT/dictionary", "l10n/DEFAULT/OHP-main.lua"}:
                    self.assertEqual(archive.read(name), data)

    def test_test_firefight_migrates_legacy_template_to_testing_staging_position(self):
        source, _ = self.fixture(firefight_offset=180)
        self.run_update(source, enable_test_firefight=True)
        with ZipFile(self.root / "out/operation-hidden-passage-testing.miz") as archive:
            mission = archive.read("mission")
            self.assertIn(b"OHP-TestOpposition", mission)
            self.assertIn(b"Testing only: six killable riflemen stage about 400 m", archive.read("l10n/DEFAULT/dictionary"))

    def test_test_firefight_is_rejected_for_operational_layout(self):
        source, _ = self.fixture("operational")
        with self.assertRaisesRegex(ValueError, "only be added to the Testing"):
            self.run_update(source, layout="operational", enable_test_firefight=True)

    def test_operational_firefight_adds_template_and_updates_briefing(self):
        source, before = self.fixture("operational")
        self.run_update(source, layout="operational", enable_firefight=True)
        with ZipFile(self.root / "out/operation-hidden-passage.miz") as archive:
            self.assertIsNone(archive.testzip())
            mission = archive.read("mission")
            briefing = archive.read("l10n/DEFAULT/dictionary")
            self.assertIn(b"OHP-TestOpposition", mission)
            self.assertEqual(mission.count(b'"Infantry AK"'), 6)
            self.assertEqual(briefing.count(b"About 3 NM before pickup"), 2)
            self.assertNotIn(b"Testing only", briefing)
            for name, data in before.items():
                if name not in {"mission", "l10n/DEFAULT/dictionary", "l10n/DEFAULT/OHP-main.lua"}:
                    self.assertEqual(archive.read(name), data)

    def test_audio_replacement_requires_opt_in(self):
        source, _ = self.fixture(audio=b"OggSold-recording")
        with self.assertRaisesRegex(ValueError, "Existing recording differs"):
            self.run_update(source)
        self.run_update(source, replace_audio=["example.ogg"])

    def test_new_filename_is_verified_backed_up_and_old_name_retired(self):
        source, _ = self.fixture()
        original = source.read_bytes()
        target = source.with_name("Operation Hidden Passage - Testing.miz")
        self.run_update(source, deploy_to=target, retire_source=True)
        self.assertFalse(source.exists())
        self.assertTrue(target.is_file())
        evidence = json.loads((self.root / "out/operation-hidden-passage-testing-evidence.json").read_text())
        self.assertEqual(Path(evidence["backup"]).read_bytes(), original)
        self.assertEqual(evidence["renamedFrom"], str(source.resolve()))

    def test_existing_destination_is_never_overwritten(self):
        source, _ = self.fixture()
        target = source.with_name("already-exists.miz")
        target.write_bytes(b"keep me")
        with self.assertRaises(ValueError):
            self.run_update(source, deploy_to=target, retire_source=True)
        self.assertEqual(target.read_bytes(), b"keep me")
        self.assertTrue(source.exists())

    def test_retirement_needs_a_new_destination(self):
        source, _ = self.fixture()
        with self.assertRaises(ValueError):
            self.run_update(source, retire_source=True)

    def test_repeated_deployment_is_content_idempotent(self):
        source, _ = self.fixture()
        self.run_update(source, deploy=True)
        with ZipFile(source) as archive:
            first = {name: archive.read(name) for name in archive.namelist()}
        self.run_update(source, deploy=True)
        with ZipFile(source) as archive:
            self.assertEqual(first, {name: archive.read(name) for name in archive.namelist()})

    def test_firefight_deployment_is_idempotent(self):
        source, _ = self.fixture()
        self.run_update(source, deploy=True, enable_test_firefight=True)
        first = source.read_bytes()
        self.run_update(source, deploy=True)
        self.assertEqual(source.read_bytes(), first)


if __name__ == "__main__":
    unittest.main()
