#!/usr/bin/env python3
"""Tests for the host-side O6 BIOS PM tuning reference model."""

from __future__ import annotations

import unittest

import pm_tuning_model as model


class PmTuningModelTests(unittest.TestCase):
    def test_partial_profile_requires_a_domain(self) -> None:
        settings = model.default_settings(model.PROFILE_PARTIAL)
        with self.assertRaisesRegex(ValueError, "no enabled CPU domain"):
            model.validate_settings(settings, engineering=False)

    def test_partial_profile_overrides_only_enabled_domains(self) -> None:
        settings = model.default_settings(model.PROFILE_PARTIAL)
        settings.enabled_domains[1] = 1
        model.validate_settings(settings, engineering=False)
        headers = model.partial_headers(settings.enabled_domains)
        self.assertEqual(headers[4], (7, 3))
        self.assertEqual(headers[3], model.DOMAIN_DISABLED)
        self.assertTrue(all(header == model.DOMAIN_DISABLED for header in headers[7:]))

    def test_release_rejects_and_migrates_engineering_profiles(self) -> None:
        for profile in (model.PROFILE_GB1_2700, model.PROFILE_CUSTOM):
            with self.subTest(profile=profile):
                settings = model.default_settings(profile)
                with self.assertRaisesRegex(
                    ValueError, "engineering profile is disabled"
                ):
                    model.validate_settings(settings, engineering=False)
                self.assertEqual(
                    model.migrate_profile(
                        profile,
                        model.SETTINGS_V1_SIZE,
                        engineering=False,
                    ),
                    model.PROFILE_VENDOR,
                )

    def test_engineering_accepts_complete_custom_profile(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        model.validate_settings(settings, engineering=True)

    def test_boot_opp_cannot_be_modified(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        settings.frequencies[2] = 1510
        with self.assertRaisesRegex(ValueError, "protected boot OPP changed"):
            model.validate_settings(settings, engineering=True)

    def test_settings_header_is_versioned(self) -> None:
        settings = model.default_settings()
        settings.revision = 1
        with self.assertRaisesRegex(ValueError, "invalid settings header"):
            model.validate_settings(settings, engineering=False)

    def test_unknown_settings_layout_is_not_migrated(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown settings size"):
            model.migrate_profile(
                model.PROFILE_VENDOR,
                model.SETTINGS_CURRENT_SIZE + 1,
                engineering=False,
            )

    def test_invalid_partial_domain_state_is_rejected(self) -> None:
        settings = model.default_settings(model.PROFILE_PARTIAL)
        settings.enabled_domains[0] = 2
        with self.assertRaisesRegex(ValueError, "invalid partial-domain state"):
            model.validate_settings(settings, engineering=False)

    def test_non_monotonic_custom_table_is_rejected(self) -> None:
        settings = model.default_settings(model.PROFILE_CUSTOM)
        settings.frequencies[1] = settings.frequencies[0]
        with self.assertRaisesRegex(ValueError, "frequencies are not increasing"):
            model.validate_settings(settings, engineering=True)


if __name__ == "__main__":
    unittest.main()
