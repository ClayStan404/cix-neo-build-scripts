#!/usr/bin/env python3
"""Tests for the O6 memory configuration verifier."""

from __future__ import annotations

import unittest

import verify_memory_config


class MemoryConfigVerifierTests(unittest.TestCase):
    def test_accepts_auto(self) -> None:
        self.assertEqual(
            verify_memory_config.validate_requested_frequency(
                verify_memory_config.MEMORY_FREQUENCY_AUTO
            ),
            verify_memory_config.MEMORY_FREQUENCY_AUTO,
        )

    def test_accepts_every_explicit_rate(self) -> None:
        for frequency in verify_memory_config.EXPLICIT_FREQUENCIES:
            with self.subTest(frequency=frequency):
                self.assertEqual(
                    verify_memory_config.validate_requested_frequency(frequency),
                    frequency,
                )

    def test_rejects_unknown_frequency(self) -> None:
        with self.assertRaisesRegex(
            verify_memory_config.VerificationError,
            "unsupported memory frequency",
        ):
            verify_memory_config.validate_requested_frequency(3100)


if __name__ == "__main__":
    unittest.main()
