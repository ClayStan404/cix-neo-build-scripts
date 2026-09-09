#!/usr/bin/env python3
"""Tests for global output cleanup behavior."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


class GlobalCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cix-cleanup-test.")
        self.root = Path(self.temporary.name)
        self.output = self.root / "output"
        self.output.mkdir()
        self.cleanup_script = Path(__file__).resolve().parents[1] / "commands/cleanup.sh"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_cleanup(
        self, function: str, *targets: str, check: bool = True
    ) -> subprocess.CompletedProcess:
        script = """
set -Eeuo pipefail
CIX_ROOT="$1"
cleanup_script="$2"
function_name="$3"
shift 3
source "${cleanup_script}"
cix_require_command() { :; }
cix_log() { printf '%s\\n' "$*"; }
cix_die() { printf 'ERROR: %s\\n' "$*" >&2; exit 1; }
"${function_name}" "$@"
"""
        return subprocess.run(
            [
                "bash",
                "-c",
                script,
                "cleanup-test",
                str(self.root),
                str(self.cleanup_script),
                function,
                *targets,
            ],
            check=check,
            capture_output=True,
            text=True,
        )

    def test_clean_all_removes_empty_outputs_but_preserves_caches(self) -> None:
        (self.output / "empty" / "nested").mkdir(parents=True)
        (self.output / "retired" / "images").mkdir(parents=True)
        (self.output / "manual" / "artifact.bin").parent.mkdir(parents=True)
        (self.output / "manual" / "artifact.bin").write_text(
            "artifact\n", encoding="utf-8"
        )
        cache_leaf = self.output / "cached" / "toolchain" / "include" / "bits"
        cache_leaf.mkdir(parents=True)
        (self.output / "cached" / "toolchain" / ".cache-id").write_text(
            "cached\n", encoding="utf-8"
        )
        cache_leaf.chmod(0o555)
        cache_leaf.parent.chmod(0o555)

        self.run_cleanup(
            "cix_remove_empty_outputs", "empty", "cached"
        )

        self.assertFalse((self.output / "empty").exists())
        self.assertFalse((self.output / "retired").exists())
        self.assertTrue((self.output / "manual" / "artifact.bin").is_file())
        self.assertTrue(cache_leaf.is_dir())

    def test_distclean_removes_read_only_target_cache(self) -> None:
        cache_leaf = self.output / "cached" / "toolchain" / "include"
        cache_leaf.mkdir(parents=True)
        cache_file = cache_leaf / "header.h"
        cache_file.write_text("cached\n", encoding="utf-8")
        cache_file.chmod(0o444)
        cache_leaf.chmod(0o555)
        cache_leaf.parent.chmod(0o555)

        self.run_cleanup("cix_remove_registered_outputs", "cached")

        self.assertFalse((self.output / "cached").exists())

    def test_distclean_removes_shared_downloads_and_empty_output_root(self) -> None:
        downloads = self.output / ".downloads"
        downloads.mkdir()
        (downloads / "gdb-10.2.tar.gz").write_text("downloaded source")
        (self.output / "cached").mkdir()

        self.run_cleanup("cix_remove_registered_outputs", "cached")

        self.assertFalse(self.output.exists())
        self.run_cleanup("cix_remove_registered_outputs", "cached")

    def test_distclean_preserves_and_reports_unregistered_entries(self) -> None:
        for relative in ("build-reports/run.json", ".manual/note", "retired/pkg.deb"):
            path = self.output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("preserve")
        (self.output / ".downloads").mkdir()
        (self.output / ".downloads/cache").write_text("remove")

        result = self.run_cleanup("cix_remove_registered_outputs", "cached")

        self.assertFalse((self.output / ".downloads").exists())
        for name in ("build-reports", ".manual", "retired"):
            self.assertTrue((self.output / name).is_dir())
            self.assertIn(f"Preserve unregistered output entry {self.output / name}", result.stdout)

    def test_distclean_rejects_linked_shared_cache_before_deleting_targets(self) -> None:
        external = self.root / "external"
        external.mkdir()
        (external / "keep").write_text("preserve")
        (self.output / ".downloads").symlink_to(external, target_is_directory=True)
        (self.output / "cached").mkdir()
        (self.output / "cached/artifact").write_text("preserve on preflight failure")

        result = self.run_cleanup("cix_remove_registered_outputs", "cached", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)
        self.assertTrue((external / "keep").is_file())
        self.assertTrue((self.output / "cached/artifact").is_file())


if __name__ == "__main__":
    unittest.main()
