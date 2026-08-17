#!/usr/bin/env python3
"""Tests for the O6 memory configuration verifier."""

from __future__ import annotations

import unittest

import verify_memory_config


class MemoryConfigVerifierTests(unittest.TestCase):
    def test_auto_restores_vendor_limits(self) -> None:
        self.assertEqual(
            verify_memory_config.requested_limits(
                verify_memory_config.MEMORY_FREQUENCY_AUTO
            ),
            verify_memory_config.VENDOR_LIMITS,
        )

    def test_every_explicit_rate_synchronizes_all_known_board_limits(self) -> None:
        for frequency in verify_memory_config.EXPLICIT_FREQUENCIES:
            with self.subTest(frequency=frequency):
                limits = verify_memory_config.requested_limits(frequency)
                self.assertEqual(
                    set(limits), set(verify_memory_config.VENDOR_LIMITS)
                )
                self.assertEqual(set(limits.values()), {frequency})

    def test_rejects_unknown_frequency(self) -> None:
        with self.assertRaisesRegex(
            verify_memory_config.VerificationError,
            "unsupported memory frequency",
        ):
            verify_memory_config.requested_limits(3100)


if __name__ == "__main__":
    unittest.main()
