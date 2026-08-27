#!/usr/bin/env python3
"""Tests for CI dependency bootstrap planning."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import execute


class ExecuteTests(unittest.TestCase):
    def test_dependency_closure_adds_transitive_prerequisites(self) -> None:
        forward = {
            "application": frozenset({"library"}),
            "library": frozenset({"headers"}),
            "headers": frozenset(),
            "unrelated": frozenset(),
        }
        self.assertEqual(
            execute.dependency_closure({"application"}, forward),
            {"application", "library", "headers"},
        )

    def test_package_targets_ignores_non_debian_artifacts(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            (workspace / "output" / "kernel").mkdir(parents=True)
            (workspace / "output" / "kernel" / "linux.deb").write_bytes(b"deb")
            (workspace / "output" / "ramparser").mkdir(parents=True)
            (workspace / "output" / "ramparser" / "crash").write_bytes(b"elf")

            self.assertEqual(
                execute.package_targets(workspace, ["ramparser", "kernel"]),
                ["kernel"],
            )

    def test_preflight_plan_stops_before_later_targets(self) -> None:
        targets = {
            name: mock.Mock(name=name) for name in ("first", "broken", "later")
        }
        build_map = mock.Mock(targets=targets)
        with mock.patch.object(
            execute, "preflight_target", side_effect=(0, 1, 0)
        ) as preflight:
            results = execute.preflight_plan(
                Path("/workspace"),
                build_map,
                ("first", "broken", "later"),
                "sbuild",
            )

        self.assertEqual(results, {"first": 0, "broken": 1})
        self.assertEqual(preflight.call_count, 2)


if __name__ == "__main__":
    unittest.main()
