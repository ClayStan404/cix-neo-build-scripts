#!/usr/bin/env python3
"""Tests for resumable build state and artifact verification."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_state


class BuildStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temporary.name)
        self.output = self.workspace / "output" / "demo"
        self.output.mkdir(parents=True)
        self.state_path = self.workspace / "output" / ".cix-state" / "targets" / "demo.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_collect_artifacts_excludes_work_and_tests(self) -> None:
        (self.output / "demo.bin").write_bytes(b"artifact")
        (self.output / "images").mkdir()
        (self.output / "images" / "firmware.bin").write_bytes(b"firmware")
        (self.output / "work").mkdir()
        (self.output / "work" / "scratch").write_bytes(b"scratch")
        (self.output / "tests").mkdir()
        (self.output / "tests" / "result.log").write_bytes(b"test")

        artifacts = build_state.collect_artifacts(self.output, self.workspace)

        self.assertEqual(
            [entry["path"] for entry in artifacts],
            ["output/demo/demo.bin", "output/demo/images/firmware.bin"],
        )

    def test_state_detects_changed_artifact(self) -> None:
        artifact = self.output / "demo.bin"
        artifact.write_bytes(b"first")
        state = {
            "version": build_state.STATE_VERSION,
            "target": "demo",
            "fingerprint": "expected",
            "artifacts": build_state.collect_artifacts(self.output, self.workspace),
        }
        self.state_path.parent.mkdir(parents=True)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")

        valid, _ = build_state.state_is_valid(
            self.state_path, "expected", self.workspace
        )
        self.assertTrue(valid)

        artifact.write_bytes(b"changed")
        valid, reason = build_state.state_is_valid(
            self.state_path, "expected", self.workspace
        )
        self.assertFalse(valid)
        self.assertIn("changed", reason)

    def test_state_detects_added_artifact(self) -> None:
        (self.output / "demo.bin").write_bytes(b"first")
        state = {
            "version": build_state.STATE_VERSION,
            "target": "demo",
            "fingerprint": "expected",
            "artifacts": build_state.collect_artifacts(self.output, self.workspace),
        }
        self.state_path.parent.mkdir(parents=True)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        (self.output / "stale.deb").write_bytes(b"stale")

        valid, reason = build_state.state_is_valid(
            self.state_path, "expected", self.workspace
        )

        self.assertFalse(valid)
        self.assertIn("added", reason)

    def test_state_detects_changed_symlink_target(self) -> None:
        (self.output / "first").write_bytes(b"same")
        (self.output / "second").write_bytes(b"same")
        link = self.output / "current"
        link.symlink_to("first")
        state = {
            "version": build_state.STATE_VERSION,
            "target": "demo",
            "fingerprint": "expected",
            "artifacts": build_state.collect_artifacts(self.output, self.workspace),
        }
        self.state_path.parent.mkdir(parents=True)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        link.unlink()
        link.symlink_to("second")

        valid, reason = build_state.state_is_valid(
            self.state_path, "expected", self.workspace
        )

        self.assertFalse(valid)
        self.assertIn("changed", reason)

    def test_run_report_records_target_and_result(self) -> None:
        relative = build_state.init_run(
            "all-6.6",
            "build",
            "sbuild",
            ["one", "two"],
            self.workspace,
            self.workspace / "output" / "build-reports",
        )
        report = self.workspace / relative
        build_state.update_run(
            report,
            "one",
            "preflight",
            "preflight",
            1,
            None,
            None,
            self.workspace,
            self.workspace / "output" / ".cix-state",
        )
        build_state.finish_run(report, "success", 2)

        value = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(value["status"], "success")
        self.assertEqual(value["targets"][0]["target"], "one")

    def test_repository_signature_is_scoped_to_input_paths(self) -> None:
        repository = self.workspace / "source"
        (repository / "used").mkdir(parents=True)
        (repository / "unused").mkdir()
        (repository / "used" / "input").write_text("one\n", encoding="utf-8")
        (repository / "unused" / "input").write_text("one\n", encoding="utf-8")
        subprocess.run(("git", "init", "-q", str(repository)), check=True)
        subprocess.run(("git", "-C", str(repository), "add", "."), check=True)
        subprocess.run(
            (
                "git",
                "-C",
                str(repository),
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "initial",
            ),
            check=True,
        )
        before = build_state._repository_signature(
            repository, self.workspace, (PurePosixPath("used"),)
        )

        (repository / "unused" / "input").write_text("two\n", encoding="utf-8")
        subprocess.run(("git", "-C", str(repository), "add", "."), check=True)
        subprocess.run(
            (
                "git",
                "-C",
                str(repository),
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "unrelated",
            ),
            check=True,
        )
        after = build_state._repository_signature(
            repository, self.workspace, (PurePosixPath("used"),)
        )

        self.assertEqual(before["digest"], after["digest"])


if __name__ == "__main__":
    unittest.main()
