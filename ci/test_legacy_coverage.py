#!/usr/bin/env python3
"""Tests for the legacy build coverage ledger."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

import check_legacy_coverage as coverage


class LegacyCoverageTest(unittest.TestCase):
    def test_repository_ledger_is_valid(self) -> None:
        counts = coverage.validate_ledger()

        self.assertEqual(sum(counts.values()), 167)
        self.assertGreater(counts["implemented"], 0)
        self.assertGreater(counts["partial"], 0)
        self.assertGreater(counts["pending"], 0)

    def test_duplicate_snapshot_entry_is_rejected(self) -> None:
        ledger = yaml.safe_load(coverage.DEFAULT_LEDGER.read_text(encoding="utf-8"))
        ledger["snapshot"]["entrypoints"].append(
            ledger["snapshot"]["entrypoints"][-1]
        )
        ledger["snapshot"]["entrypoint_count"] += 1

        with tempfile.TemporaryDirectory() as temporary_directory:
            ledger_path = Path(temporary_directory) / "ledger.yaml"
            ledger_path.write_text(yaml.safe_dump(ledger), encoding="utf-8")
            with self.assertRaisesRegex(coverage.CoverageError, "duplicates"):
                coverage.validate_ledger(ledger_path)

    def test_partial_entry_requires_a_reason(self) -> None:
        ledger = yaml.safe_load(coverage.DEFAULT_LEDGER.read_text(encoding="utf-8"))
        ledger["overrides"]["build-uefi.sh"].pop("reason")

        with tempfile.TemporaryDirectory() as temporary_directory:
            ledger_path = Path(temporary_directory) / "ledger.yaml"
            ledger_path.write_text(yaml.safe_dump(ledger), encoding="utf-8")
            with self.assertRaisesRegex(coverage.CoverageError, "must have a reason"):
                coverage.validate_ledger(ledger_path)


if __name__ == "__main__":
    unittest.main()
