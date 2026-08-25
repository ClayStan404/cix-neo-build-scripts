#!/usr/bin/env python3
"""Tests for the host-side O6 BIOS PM tuning reference model."""

from __future__ import annotations

import unittest

import pm_tuning_model as model


class PmTuningModelTests(unittest.TestCase):
    def test_removed_profiles_migrate_to_vendor(self) -> None:
        for profile in (1, 3):
            with self.subTest(profile=profile):
                settings = model.default_settings(profile)
                with self.assertRaisesRegex(ValueError, "unknown profile"):
                    model.validate_settings(settings)
                self.assertEqual(
                    model.migrate_profile(
                        profile,
                        model.SETTINGS_V1_SIZE,
                    ),
                    model.PROFILE_VENDOR,
                )

    def test_accepts_complete_custom_profile(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        model.validate_settings(settings)

    def test_boot_opp_cannot_be_modified(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        settings.frequencies[2] = 1510
        with self.assertRaisesRegex(ValueError, "protected boot OPP changed"):
            model.validate_settings(settings)

    def test_settings_header_is_versioned(self) -> None:
        settings = model.default_settings()
        settings.revision = 1
        with self.assertRaisesRegex(ValueError, "invalid settings header"):
            model.validate_settings(settings)

    def test_unknown_settings_layout_is_not_migrated(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown settings size"):
            model.migrate_profile(
                model.PROFILE_VENDOR,
                model.SETTINGS_CURRENT_SIZE + 1,
            )

    def test_non_monotonic_custom_table_is_rejected(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        settings.frequencies[1] = settings.frequencies[0]
        with self.assertRaisesRegex(ValueError, "frequencies are not increasing"):
            model.validate_settings(settings)


if __name__ == "__main__":
    unittest.main()
