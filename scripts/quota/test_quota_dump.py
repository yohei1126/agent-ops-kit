"""Golden-fixture schema tests. Run: python3 -m unittest scripts/quota/test_quota_dump.py"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SCRIPT = HERE / "quota_dump.py"
FIELDS = {"agent_id", "pool_id", "kind", "status", "remaining_fraction", "used_fraction",
          "reset_time", "captured_at", "plan_tier", "source"}

FAKE_AGY = '''#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

record = Path("__RECORD__")
argv = sys.argv[1:]
i = argv.index("--settings")
settings = json.loads(Path(argv[i + 1]).read_text())
record.write_text(json.dumps({"argv": sys.argv, "settings": settings}))
payload = '{"quota": {"gemini-weekly": {"remaining_fraction": 0.5, "reset_time": "2026-11-10T00:00:00Z"}}}'
subprocess.run([settings["statusLine"]["command"]], input=payload, text=True)
'''


def run(*args, env=None):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True,
                          text=True, env=env)


class QuotaSchema(unittest.TestCase):
    def test_golden_agy_fixture(self):
        r = run("--agy-payload", str(HERE / "fixtures/agy-payload.mock.json"), "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        doc = json.loads(r.stdout)
        self.assertEqual(doc["schema_version"], 1)
        agy = {x["pool_id"]: x for x in doc["records"] if x["agent_id"] == "agy"}
        self.assertEqual(set(agy), {"gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h",
                                    "gemini-argon-wtu-weekly"})
        for rec in doc["records"]:
            self.assertEqual(set(rec) - {"note"}, FIELDS)
        self.assertEqual(agy["gemini-weekly"]["remaining_fraction"], 0.62)
        self.assertEqual(agy["3p-weekly"]["remaining_fraction"], 0.6)
        self.assertEqual(agy["gemini-argon-wtu-weekly"]["used_fraction"], 0.75)
        self.assertEqual(agy["gemini-weekly"]["reset_time"], "2026-11-10T00:00:00Z")
        self.assertEqual(agy["gemini-weekly"]["plan_tier"], "ai-pro")

    def test_real_agy_payload_shape(self):
        r = run("--agy-payload", str(HERE / "fixtures/agy-payload.real.json"), "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        agy = {x["pool_id"]: x for x in json.loads(r.stdout)["records"] if x["agent_id"] == "agy"}
        self.assertEqual({k: v["status"] for k, v in agy.items()}, {k: "ok" for k in agy})
        self.assertEqual(len(agy), 5)
        self.assertEqual(agy["3p-weekly"]["remaining_fraction"], 0.204)

    def test_fireworks_and_goat_never_invent_numbers(self):
        doc = json.loads(run("--json").stdout)
        by = {r["agent_id"]: r for r in doc["records"]}
        for key in ("opencode-fireworks", "box-goat"):
            self.assertEqual(by[key]["status"], "unknown")
            self.assertIsNone(by[key]["remaining_fraction"])
        self.assertEqual(by["opencode-fireworks"]["kind"], "carry")
        self.assertEqual(by["box-goat"]["kind"], "flat")

    def test_missing_pool_marked_unknown(self):
        p = HERE / "fixtures/agy-partial.tmp.json"
        p.write_text('{"quota": {"gemini-weekly": {"remaining_fraction": 0.5, "reset_time": "2026-11-10T00:00:00Z"}}}')
        try:
            doc = json.loads(run("--agy-payload", str(p), "--json").stdout)
        finally:
            p.unlink()
        by = {r["pool_id"]: r for r in doc["records"] if r["agent_id"] == "agy"}
        self.assertEqual(by["3p-weekly"]["status"], "unknown")

    def test_ok_weekly_without_reset_fails_schema(self):
        p = HERE / "fixtures/agy-noreset.tmp.json"
        p.write_text('{"quota": {"gemini-weekly": {"remaining_fraction": 0.5}}}')
        try:
            r = run("--agy-payload", str(p), "--json")
        finally:
            p.unlink()
        self.assertEqual(r.returncode, 2)
        self.assertIn("reset_time missing", r.stderr)

    def test_capture_leaves_global_settings_byte_identical(self):
        with tempfile.TemporaryDirectory() as home:
            cfg = Path(home) / ".gemini/antigravity-cli/settings.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text('{"model": "x"}\n')
            before = cfg.read_bytes()
            r = run("--agy-capture", "--agy-cmd", "true", "--timeout", "1",
                    env={**os.environ, "HOME": home})
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(cfg.read_bytes(), before)
            self.assertNotIn("statusLine", cfg.read_text())

    def test_capture_does_not_create_global_settings(self):
        with tempfile.TemporaryDirectory() as home:
            cfg = Path(home) / ".gemini/antigravity-cli/settings.json"
            r = run("--agy-capture", "--agy-cmd", "true", "--timeout", "1",
                    env={**os.environ, "HOME": home})
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(cfg.exists())

    def test_capture_uses_session_only_settings(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as tmp:
            cfg = Path(home) / ".gemini/antigravity-cli/settings.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text('{"model": "x"}\n')
            before = cfg.read_bytes()
            record = Path(tmp) / "record.json"
            fake = Path(tmp) / "fake-agy"
            fake.write_text(FAKE_AGY.replace("__RECORD__", str(record)))
            fake.chmod(0o700)
            r = run("--agy-capture", "--agy-cmd", f"{fake} -p ok", "--json", "--timeout", "10",
                    env={**os.environ, "HOME": home})
            self.assertEqual(r.returncode, 0, r.stderr)
            agy = {x["pool_id"]: x for x in json.loads(r.stdout)["records"]
                   if x["agent_id"] == "agy"}
            self.assertEqual(agy["gemini-weekly"]["remaining_fraction"], 0.5)
            rec = json.loads(record.read_text())
            argv = rec["argv"]
            i = argv.index("--settings")
            settings_path = Path(argv[i + 1])
            self.assertEqual(settings_path.name, "session-settings.json")
            self.assertEqual(set(rec["settings"]), {"statusLine"})
            self.assertFalse(settings_path.parent.exists())
            self.assertEqual(cfg.read_bytes(), before)

    def test_capture_none_prints_session_settings_command(self):
        with tempfile.TemporaryDirectory() as home:
            cfg = Path(home) / ".gemini/antigravity-cli/settings.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text('{"model": "x"}\n')
            before = cfg.read_bytes()
            r = run("--agy-capture", "--agy-cmd", "none", "--timeout", "1",
                    env={**os.environ, "HOME": home})
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("--settings", r.stderr)
            self.assertEqual(cfg.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
