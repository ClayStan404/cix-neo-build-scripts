#!/usr/bin/env python3
"""Tests for the Sky1 PM firmware compatibility verifier."""

from __future__ import annotations

import unittest
from unittest import mock

import verify_pm_firmware


class PmFirmwareVerifierTests(unittest.TestCase):
    def test_accepts_revision_and_expected_digest(self) -> None:
        data = b"prefix" + verify_pm_firmware.PM_FIRMWARE_SOURCE_REVISION.encode()
        with mock.patch.object(
            verify_pm_firmware.hashlib,
            "sha256",
            return_value=mock.Mock(
                hexdigest=lambda: verify_pm_firmware.EXPECTED_SHA256["debug"]
            ),
        ):
            result = verify_pm_firmware.verify(data, "debug")
        self.assertIn("config ABI v3.4", result)
        self.assertIn("schema v3.0", result)

    def test_rejects_unknown_source_revision(self) -> None:
        with self.assertRaisesRegex(
            verify_pm_firmware.VerificationError, "does not contain source revision"
        ):
            verify_pm_firmware.verify(b"unknown firmware", "release")

    def test_rejects_changed_binary(self) -> None:
        data = verify_pm_firmware.PM_FIRMWARE_SOURCE_REVISION.encode()
        with self.assertRaisesRegex(
            verify_pm_firmware.VerificationError, "unexpected debug PM firmware SHA-256"
        ):
            verify_pm_firmware.verify(data, "debug")


if __name__ == "__main__":
    unittest.main()
