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

    def test_6400_raises_all_known_board_limits(self) -> None:
        limits = verify_memory_config.requested_limits(3200)
        self.assertEqual(set(limits), set(verify_memory_config.VENDOR_LIMITS))
        self.assertEqual(set(limits.values()), {3200})

    def test_lower_request_does_not_reduce_vendor_limit(self) -> None:
        limits = verify_memory_config.requested_limits(2400)
        self.assertEqual(limits, verify_memory_config.VENDOR_LIMITS)

    def test_rejects_unknown_frequency(self) -> None:
        with self.assertRaisesRegex(
            verify_memory_config.VerificationError,
            "unsupported memory frequency",
        ):
            verify_memory_config.requested_limits(3100)


if __name__ == "__main__":
    unittest.main()
