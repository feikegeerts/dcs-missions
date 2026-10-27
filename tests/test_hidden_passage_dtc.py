"""Native cartridge structure, targeted Lua edits, and archive/deployment safety."""
import contextlib
from copy import deepcopy
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(ROOT / "build/update-hidden-passage-dtc.py"))
LUA_TABLE = runpy.run_path(str(ROOT / "tests/test_hidden_passage_packaging.py"))["lua_table"]


@unittest.skipUnless(shutil.which("lua5.1") or shutil.which("lua5.1.exe"), "Lua 5.1 is required")
class DtcTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "out").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ohp-dtc-test-", dir=ROOT / "out")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.prepare = MODULE["prepare"]
        names = [("SAM SA-6 'Gainful'", "6", 25000, 14000),
                 ("SAM SA-8 'Gecko'", "8", 10300, 5000),
                 ("SAM SA-10 'Grumble'", "10", 120000, 27000)]
        self.defs = ({name: {"name": name, "default_text": label, "detectionRange": radius, "lvl": 1}
                      for name, label, radius, alt in names},
                     {name: (i, {"name": name, "default_text": label, "detectionRange": radius, "altitude": alt})
                      for i, (name, label, radius, alt) in enumerate(names, 1)},
                     {"DCLTR_SETTINGS": {"MREJ1": {"MEZ_Names": True, "MEZ_Rings": True},
                                         "MREJ2": {"MEZ_Names": True, "MEZ_Rings": True}}})
        def aircraft(name, kind, ident):
            return {"name": name, "DTC": {}, "frequency": 305,
                    "route": {"points": [{"name": "PICKUP", "alt": 0, "alt_type": "RADIO", "x": 10, "y": 20}]},
                    "units": [{"name": name + "-1", "type": kind, "unitId": ident,
                               "skill": "Client", "payload": {"fuel": 6000}, "AddPropAircraft": {"STN_L16": "01025"}}]}
        def sam(name, radar, x, hidden=False):
            return {"name": name, "lateActivation": name == "Ground-9", "hiddenOnMFD": hidden,
                    "units": [{"name": name + "-radar", "type": radar, "unitId": 100 + x, "x": x, "y": 50}],
                    "route": {"points": [{"alt": 485, "x": x, "y": 50}]}}
        self.mission = {"theatre": "Syria", "description": '{["unitId"]=1,["DTC"]={}}',
                        "triggers": {"zones": [{"name": "OHP-Pickup", "x": 10, "y": 20}]},
                        "coalition": {"blue": {"country": [{"plane": {"group": [
                            aircraft("CAP-Hornet", "FA-18C_hornet", 1),
                            aircraft("CAP-Viper", "F-16C_50", 2),
                            aircraft("CAS-Hornet", "FA-18C_hornet", 3)]}}]},
                            "red": {"country": [{"vehicle": {"group": [
                                sam("Ground-9", "Kub 1S91 str", 10),
                                sam("Ground-1", "S-300PS 40B6M tr", 20),
                                sam("Ground-7", "Osa 9A33 ln", 30),
                                sam("Hidden", "Kub 1S91 str", 40, True)]}}]}}}

    def members(self, mission=None):
        return {"mission": ("-- decoy {[\"unitId\"]=1}\nmission=" + LUA_TABLE(mission or self.mission)).encode(),
                "l10n/DEFAULT/OHP-main.lua": b"keep gameplay", "Sounds/OHP/example.ogg": b"keep audio",
                "l10n/DEFAULT/dictionary": b"keep briefing", "warehouses": b"keep warehouses",
                "DTC/OTHER.dtc": b"keep unrelated cartridge"}

    def planes(self, mission):
        return mission["coalition"]["blue"]["country"][0]["plane"]["group"]

    def test_only_cap_unit_dtc_fields_change_and_other_members_are_identical(self):
        original = self.members()
        candidate, sites = self.prepare(original, self.defs)
        after = MODULE["mission_data"](candidate["mission"])
        for group in self.planes(after)[:2]:
            dtc = group["units"][0].pop("DTC")
            self.assertTrue(dtc["AutoLoad"])
            self.assertTrue(dtc["Cartridges"][0]["default"])
        self.assertEqual(after, self.mission)
        self.assertEqual({s["group"] for s in sites}, {"Ground-9", "Ground-1", "Ground-7"})
        for name, data in original.items():
            if name != "mission": self.assertEqual(candidate[name], data)

    def test_both_native_cartridges_contain_kub_and_existing_known_sites_in_correct_units(self):
        candidate, _ = self.prepare(self.members(), self.defs)
        h = json.loads(candidate["DTC/OHP-CAP-HORNET.dtc"])
        v = json.loads(candidate["DTC/OHP-CAP-VIPER.dtc"])
        for cartridge in (h, v):
            self.assertEqual(cartridge["type"], cartridge["data"]["type"])
            self.assertEqual(cartridge["data"]["terrain"], "Syria")
        self.assertFalse(h["data"]["SA"]["mirror_MEZ_THRTS"])
        self.assertEqual(h["data"]["SA"]["Default_MEZ_THRTS_Level"], 1)
        self.assertFalse(v["data"]["MPD"]["mirror_THREAT_PTS"])
        self.assertTrue(v["data"]["MPD"]["mirror_NAV_PTS"])
        self.assertNotIn("NAV_PTS", v["data"]["MPD"])
        self.assertNotIn("CMDS", v["data"]["MPD"])
        hp, vp = h["data"]["SA"]["MEZ_THRTS"], v["data"]["MPD"]["THREAT_PTS"]
        self.assertEqual(len(hp), 3)
        self.assertEqual(len(vp), 3)
        for first, second in zip(hp, vp):
            self.assertEqual((first["x"], first["y"]), (second["x"], second["y"]))
            self.assertAlmostEqual(first["threat_ring_radius"] * 1852, second["radius"])
            self.assertTrue(second["ring"])
            self.assertEqual(second["elev"], 485)

    def test_existing_empty_dtc_tables_can_be_replaced_without_touching_group_dtc(self):
        for group in self.planes(self.mission)[:2]: group["units"][0]["DTC"] = {}
        candidate, _ = self.prepare(self.members(), self.defs)
        after = MODULE["mission_data"](candidate["mission"])
        for group in self.planes(after)[:2]: self.assertEqual(group["DTC"], {})

    def test_idempotent_rebuild_keeps_mission_and_cartridge_bytes_identical(self):
        candidate, _ = self.prepare(self.members(), self.defs)
        again, _ = self.prepare(candidate, self.defs)
        self.assertEqual(candidate, again)

    def test_custom_assigned_cartridge_is_not_silently_overwritten(self):
        self.planes(self.mission)[0]["units"][0]["DTC"] = {"Cartridges": [{"name": "MY-CUSTOM", "default": True}]}
        with self.assertRaisesRegex(ValueError, "custom"):
            self.prepare(self.members(), self.defs)

    def test_existing_different_generated_cartridge_is_not_overwritten(self):
        members = self.members()
        members["DTC/OHP-CAP-HORNET.dtc"] = b'{"name":"OTHER"}'
        with self.assertRaisesRegex(ValueError, "cartridge differs"):
            self.prepare(members, self.defs)

    def test_wrong_or_missing_aircraft_fail_closed(self):
        for fault in ("missing", "type", "ai"):
            mission = deepcopy(self.mission)
            groups = self.planes(mission)
            if fault == "missing": groups.pop(1)
            elif fault == "type": groups[1]["units"][0]["type"] = "F-5E-3"
            else: groups[1]["units"][0]["skill"] = "High"
            with self.assertRaises(ValueError): self.prepare(self.members(mission), self.defs)

    def test_missing_or_hidden_objective_radar_cannot_produce_guessed_ring(self):
        group = self.mission["coalition"]["red"]["country"][0]["vehicle"]["group"][0]
        group["hiddenOnMFD"] = True
        with self.assertRaisesRegex(ValueError, "Ground-9"):
            self.prepare(self.members(), self.defs)

    def test_viper_threat_limit_never_silently_discards_sites(self):
        red = self.mission["coalition"]["red"]["country"][0]["vehicle"]["group"]
        for i in range(16):
            clone = deepcopy(red[0]); clone["name"] = f"Extra-{i}"; red.append(clone)
        with self.assertRaisesRegex(ValueError, "15 threat"):
            self.prepare(self.members(), self.defs)

    def test_missing_ground_elevation_is_not_replaced_with_aircraft_altitude(self):
        group = self.mission["coalition"]["red"]["country"][0]["vehicle"]["group"][0]
        group["route"] = {}
        with self.assertRaisesRegex(ValueError, "ground-route elevation"):
            self.prepare(self.members(), self.defs)

    def test_data_reader_handles_root_without_assert_message_becoming_depth(self):
        self.assertEqual(MODULE["mission_data"](b'mission={value="ok",nested={enabled=true}}'),
                         {"value": "ok", "nested": {"enabled": True}})

    def test_data_reader_reports_missing_cyclic_and_excessively_nested_data(self):
        for data, message in (
            (b'other={}', "Missing data root"),
            (b'mission={}; mission.self=mission', "Cyclic data table"),
            (b'mission=' + b'{nested=' * 101 + b'{}' + b'}' * 101, "Data nesting limit"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                MODULE["mission_data"](data)

    @unittest.skipUnless(MODULE["DCS"].exists(), "Installed DCS native importers are required")
    def test_installed_native_importers_accept_generated_cartridges(self):
        actual = MODULE["profiles"](MODULE["DCS"])
        candidate, _ = self.prepare(self.members(), actual)
        fixture = self.folder / "cartridges.lua"
        fixture.write_text("cartridges=" + LUA_TABLE({
            "hornet": json.loads(candidate["DTC/OHP-CAP-HORNET.dtc"]),
            "viper": json.loads(candidate["DTC/OHP-CAP-VIPER.dtc"]),
        }), encoding="utf-8")
        lua = shutil.which("lua5.1") or shutil.which("lua5.1.exe")
        result = subprocess.run([lua, str(ROOT / "tests/lua/run-hidden-passage-dtc-native.lua"),
                                 str(MODULE["DCS"]), str(fixture)], capture_output=True, text=True, check=True)
        self.assertIn("hornet installed native DTC importer: 3 threat points accepted", result.stdout)
        self.assertIn("viper installed native DTC importer: 3 threat points accepted", result.stdout)

    def test_lua_lexer_skips_long_strings_and_comments_containing_fake_units(self):
        members = self.members()
        members["mission"] = b'--[=[ {["unitId"]=1,["DTC"]={}} ]=]\n' + members["mission"]
        members["mission"] += b'\nmission.extra=[==[{["unitId"]=2,["DTC"]={}}]==]\n'
        candidate, _ = self.prepare(members, self.defs)
        self.assertIn(b'--[=[ {["unitId"]=1,["DTC"]={}} ]=]', candidate["mission"])
        self.assertTrue(candidate["mission"].endswith(b'mission.extra=[==[{["unitId"]=2,["DTC"]={}}]==]\n'))

    def test_deployment_creates_exact_backup_and_second_build_is_archive_noop(self):
        source = self.folder / "Missions/test.miz"
        source.parent.mkdir()
        with ZipFile(source, "w") as z:
            for name, value in self.members().items(): z.writestr(name, value)
        original = source.read_bytes()
        update = MODULE["update"]
        prior = update.__globals__["ROOT"]
        # Keep tool/helper paths real; generated output is local and restored below.
        output = ROOT / "out/operation-hidden-passage.miz"
        evidence = ROOT / "out/operation-hidden-passage-dtc-evidence.json"
        saved = {p: p.read_bytes() if p.exists() else None for p in (output, evidence)}
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                result = update(source, deploy=True, definitions=self.defs)
                self.assertEqual(Path(result["backup"]).read_bytes(), original)
                installed = source.read_bytes()
                again = update(source, definitions=self.defs)
            self.assertEqual(output.read_bytes(), installed)
            self.assertEqual(again["changedMembers"], [])
            self.assertEqual(again["addedMembers"], [])
        finally:
            update.__globals__["ROOT"] = prior
            for path, data in saved.items():
                if data is None: path.unlink(missing_ok=True)
                else: path.write_bytes(data)


if __name__ == "__main__":
    unittest.main()
