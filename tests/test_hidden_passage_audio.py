"""Validate shipped voice assets, queue lengths, and approved volume-only renders."""

from array import array
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MISSION = ROOT / "src/missions/operation-hidden-passage"
FFPROBE = shutil.which("ffprobe")
FFMPEG = shutil.which("ffmpeg")
RETAINED_ORIGINALS = {
    "boarding-start.ogg": "35a78666d3f72d7ab7299ebf59b14c036fc33eeb27913675c694e6cd41f135bf",
    "boarding-confirm.ogg": "84ff479a9e88d9198dd262b5d665a63d0df12f3e7bcac463b67da6f771890d8f",
    "uh60-boarding-complete.ogg": "7f71c7bb3966be48c23c09b98b2edbb88d8e6d7798782dfcc0e28c147a5e7a04",
    "hidden-passage-success.ogg": "7f678c9ec3dde7536f385e9e3a91c4400d5566592b5f36fbb6868ce2d2071aa2",
}


class AudioTests(unittest.TestCase):
    def setUp(self):
        text = (MISSION / "voice.lua").read_text(encoding="utf-8")
        self.lines = {}
        self.disabled = set()
        for key, body in re.findall(r"^  (\w+) = \{\n(.*?)^  \},", text, re.M | re.S):
            filename = re.search(r'file = "Sounds/OHP/([^"/]+\.ogg)"', body)
            duration = re.search(r"duration = ([\d.]+)", body)
            if filename and duration:
                self.lines[key] = (filename[1], float(duration[1]))
                if re.search(r"disabled\s*=\s*true", body):
                    self.disabled.add(key)

    def test_all_recordings_are_registered_once_and_listed_in_the_script(self):
        files = [name for name, duration in self.lines.values()]
        self.assertEqual(len(files), 27)
        self.assertEqual(len(set(files)), 27)
        self.assertEqual(self.disabled, {"cas_departure", "cap_departure"})
        self.assertEqual(len(self.lines) - len(self.disabled), 25)
        actual = {path.name for path in (MISSION / "sounds").glob("*.ogg")}
        self.assertEqual(set(files), actual)
        script = (ROOT / "docs/hidden-passage-voice-script.md").read_text(encoding="utf-8")
        entries = re.findall(r"^- \*\*File:\*\* `([^`]+\.ogg)`", script, re.M)
        self.assertEqual(len(entries), 27)
        self.assertEqual(set(entries), actual)

    def test_retained_recordings_use_only_the_approved_volume_render(self):
        gain = json.loads((MISSION / "voice-gain.json").read_text(encoding="utf-8"))
        for name, expected in RETAINED_ORIGINALS.items():
            with self.subTest(name=name):
                recording = gain["files"][name]
                self.assertEqual(recording["originalSha256"], expected)
                self.assertEqual(hashlib.sha256((MISSION / "sounds" / name).read_bytes()).hexdigest(),
                                 recording["renderedSha256"])
                self.assertGreater(recording["correlation"], 0.999)

    @unittest.skipUnless(FFMPEG, "FFmpeg is required")
    def test_all_27_recordings_have_the_approved_ten_percent_volume_reduction(self):
        gain = json.loads((MISSION / "voice-gain.json").read_text(encoding="utf-8"))
        self.assertEqual(gain["linearGain"], 0.9)
        self.assertEqual(set(gain["files"]), {name for name, _ in self.lines.values()})
        for name, recording in gain["files"].items():
            with self.subTest(name=name):
                path = MISSION / "sounds" / name
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), recording["renderedSha256"])
                result = subprocess.run([
                    FFMPEG, "-nostdin", "-v", "error", "-i", str(path), "-af", "asetpts=N/SR/TB",
                    "-f", "f32le", "-acodec", "pcm_f32le", "-",
                ], check=True, capture_output=True)
                self.assertEqual(result.stderr, b"")
                samples = array("f")
                samples.frombytes(result.stdout)
                if sys.byteorder != "little":
                    samples.byteswap()
                self.assertEqual(len(samples), recording["samples"])
                rms = math.sqrt(sum(x*x for x in samples) / len(samples))
                self.assertAlmostEqual(rms / recording["originalRms"], 0.9, delta=0.001)
                self.assertAlmostEqual(rms, recording["renderedRms"], places=6)
                self.assertGreater(recording["correlation"], 0.999)
                self.assertLess(recording["relativeErrorVsExactGain"], 0.02)

    @unittest.skipUnless(FFPROBE, "FFprobe is required")
    def test_all_assets_are_mono_vorbis_and_queue_lengths_cover_audio(self):
        for name, queued in self.lines.values():
            with self.subTest(name=name):
                result = json.loads(subprocess.check_output([
                    FFPROBE, "-v", "error", "-show_entries",
                    "stream=codec_name,sample_rate,channels:format=duration", "-of", "json",
                    str(MISSION / "sounds" / name),
                ], text=True))
                self.assertEqual(len(result["streams"]), 1)
                stream = result["streams"][0]
                self.assertEqual(stream["codec_name"], "vorbis")
                self.assertEqual(stream["channels"], 1)
                # Preserve original sample rates, including the 44.1 kHz clips.
                self.assertIn(stream["sample_rate"], {"44100", "48000"})
                duration = float(result["format"]["duration"])
                self.assertGreater(duration, 0.25)
                self.assertGreaterEqual(queued + 0.0001, duration)
                self.assertLess(queued - duration, 0.3)

    @unittest.skipUnless(FFMPEG, "FFmpeg is required")
    def test_all_assets_decode_without_errors(self):
        for name, duration in self.lines.values():
            with self.subTest(name=name):
                subprocess.run([
                    FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-i",
                    str(MISSION / "sounds" / name), "-f", "null", "-",
                ], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
