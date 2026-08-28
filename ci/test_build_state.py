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

    def test_debian_cleanup_trap_survives_process_substitution(self) -> None:
        builder = Path(__file__).resolve().parents[1] / "builders/debian.sh"
        work_root = self.output / ".demo.failed-build"
        script = r'''
set -Eeuo pipefail
CIX_ROOT="$1"
builder="$2"
source "${builder}"
run_failure() (
    local work_root="$1"
    mkdir -p -- "${work_root}/source"
    cix_trap_debian_work_root "${work_root}"
    false
)
run_failure "$3" > >(tee /dev/null)
'''

        result = subprocess.run(
            (
                "bash",
                "-c",
                script,
                "cleanup-test",
                str(self.workspace),
                str(builder),
                str(work_root),
            ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unbound variable", result.stderr)
        self.assertFalse(work_root.exists())

    def test_stale_debian_work_roots_are_removed(self) -> None:
        builder = Path(__file__).resolve().parents[1] / "builders/debian.sh"
        stale = self.output / ".demo.stale-build"
        retained = self.output / "retained"
        (stale / "source").mkdir(parents=True)
        retained.mkdir()
        script = r'''
set -Eeuo pipefail
CIX_ROOT="$1"
builder="$2"
declare -A TARGET=([name]=demo)
cix_log() { :; }
source "${builder}"
cix_clean_debian_work_roots "$3"
'''

        subprocess.run(
            (
                "bash",
                "-c",
                script,
                "cleanup-test",
                str(self.workspace),
                str(builder),
                str(self.output),
            ),
            check=True,
        )

        self.assertFalse(stale.exists())
        self.assertTrue(retained.is_dir())

    def test_stable_kernel_interrupted_worktree_is_verified(self) -> None:
        builder = Path(__file__).resolve().parents[1] / "builders/direct/kernel.sh"
        kernel = self.workspace / "linux"
        patch = self.workspace / "0001-change.patch"
        config = self.workspace / "defconfig"
        kernel.mkdir()
        (kernel / "Makefile").write_text(
            "VERSION = 7\nPATCHLEVEL = 0\nSUBLEVEL = 13\n", encoding="utf-8"
        )
        (kernel / "value").write_text("before\n", encoding="utf-8")
        subprocess.run(("git", "init", "-q", str(kernel)), check=True)
        subprocess.run(("git", "-C", str(kernel), "add", "."), check=True)
        commit = (
            "git",
            "-C",
            str(kernel),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
        )
        subprocess.run((*commit, "-qm", "base"), check=True)
        (kernel / "value").write_text("after\n", encoding="utf-8")
        subprocess.run(("git", "-C", str(kernel), "add", "value"), check=True)
        subprocess.run((*commit, "-qm", "change"), check=True)
        patch.write_bytes(
            subprocess.run(
                ("git", "-C", str(kernel), "format-patch", "-1", "--stdout"),
                check=True,
                stdout=subprocess.PIPE,
            ).stdout
        )
        (kernel / ".config").write_text("CONFIG_DEMO=y\n", encoding="utf-8")
        config.write_text("CONFIG_DEMO=y\n", encoding="utf-8")

        script = r'''
set -Eeuo pipefail
source "$1"
cix_stable_kernel_worktree_matches "$2" 7.0.13 "$3" "$4"
'''
        command = (
            "bash",
            "-c",
            script,
            "kernel-resume-test",
            str(builder),
            str(kernel),
            str(config),
            str(patch),
        )

        subprocess.run(command, check=True)
        config.write_text("CONFIG_DEMO=n\n", encoding="utf-8")
        self.assertNotEqual(subprocess.run(command).returncode, 0)

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
