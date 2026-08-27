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

    def run_cleanup(self, function: str, *targets: str) -> None:
        script = """
set -Eeuo pipefail
CIX_ROOT="$1"
cleanup_script="$2"
function_name="$3"
shift 3
source "${cleanup_script}"
cix_require_command() { :; }
cix_log() { :; }
"${function_name}" "$@"
"""
        subprocess.run(
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
            check=True,
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


if __name__ == "__main__":
    unittest.main()
