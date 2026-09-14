"""Architecture regression checks; run from the repository root."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "src" / "lib" / "telemetry"


class TelemetryBoundaries(unittest.TestCase):
    def test_shared_modules_have_no_mission_source_or_roster_dependency(self):
        modules = list(LIBRARY.glob("*.lua"))
        self.assertGreaterEqual(len(modules), 14)
        for module in modules:
            with self.subTest(module=module.name):
                source = module.read_text(encoding="utf-8")
                self.assertNotIn("missions/", source)
                self.assertNotIn("MY_SCRIPTS_ROOT", source)
                self.assertNotRegex(source, r'"(?:Aerial|Bandit)-\d+')
                self.assertNotRegex(source, r'mission_name\s*=\s*"')

    def test_shared_modules_do_not_load_gameplay_or_dependencies_from_disk(self):
        for module in LIBRARY.glob("*.lua"):
            with self.subTest(module=module.name):
                source = module.read_text(encoding="utf-8")
                self.assertIsNone(re.search(r"\b(?:dofile|loadfile|require)\s*\(", source))

    def test_mission_uses_integration_not_transport_internals(self):
        source = (ROOT / "src/gameplay/package-waves.lua").read_text(encoding="utf-8")
        gameplay = source.split("-- Dev-only unattended test combat", 1)[0]
        self.assertNotIn("duel_telemetry_runtime", gameplay)
        self.assertNotIn("bridge.start", gameplay)
        self.assertNotIn("development.start", gameplay)
        self.assertEqual(gameplay.count("mission_name = MISSION_CONFIG.mission_name,"), 1)
        integration = (LIBRARY / "integration.lua").read_text(encoding="utf-8")
        self.assertIn('"combat"', integration)


if __name__ == "__main__":
    unittest.main()
