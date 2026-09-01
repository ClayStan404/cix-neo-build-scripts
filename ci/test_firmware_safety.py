#!/usr/bin/env python3
"""Regression tests for the O6 CPU-tuning firmware publication boundary."""

from __future__ import annotations

import unittest
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci"))
import plan  # noqa: E402


class O6FirmwareSafetyTests(unittest.TestCase):
    def test_engineering_flow_reuses_pr_debug_early_boot(self) -> None:
        flow = (ROOT / "builders/direct/firmware-sky1.sh").read_text()

        self.assertIn("CIX_INTERNAL_VARIANT=pr-debug", flow)
        self.assertIn("bootloader1_pr_debug.img", flow)
        self.assertIn("cix_flash_all_${platform}_cpu_tuning_pr_debug.bin", flow)
        self.assertNotIn("cix_bootloader1_build \\", flow)
        self.assertNotIn("builders/direct/bootloader1.sh", flow)
        self.assertNotIn("CIX_INTERNAL_VARIANT=proto-debug", flow)
        self.assertNotIn("radxa-memory-tuning", flow)

    def test_final_image_segments_are_checked(self) -> None:
        flow = (ROOT / "builders/direct/firmware-sky1.sh").read_text()

        self.assertIn('bootloader1_flash_offset="$((0x188000))"', flow)
        self.assertIn('pm_config_flash_offset="$((0x504000))"', flow)
        self.assertIn('bootloader3_flash_offset="$((0x506000))"', flow)
        self.assertIn("full-flash image does not embed the manifest", flow)
        self.assertIn("full-flash image does not embed the validated", flow)
        self.assertIn("full-flash image does not embed the CPU-tuning UEFI", flow)

    def test_internal_packager_supports_pr_debug_selection(self) -> None:
        patch = (
            ROOT
            / "patches/radxa-pm-tuning"
            / "0002-PackageTool-select-internal-flash-variant.patch"
        ).read_text()

        self.assertIn("+    pr-debug)", patch)
        self.assertIn("+        exec_cix_mkimage pr debug", patch)

    def test_quarantined_sources_cannot_trigger_a_flashable_target(self) -> None:
        build_map = plan.load_build_map(
            ROOT / "build-map.yaml", ROOT.parent, check_paths=False
        )
        changes = (
            "cix_security/ddr:src/example.c",
            "cix_security/firmware:src/example.c",
            "cix_security/library:src/example.c",
            "cix_private/sw_tools_private:src/example.c",
            "cix_proprietary/cix_firmware:sky1/example.bin",
            "cix-neo-build-scripts:builders/direct/bootloader1.sh",
            "cix-neo-build-scripts:patches/radxa-bootloader/example.patch",
            "cix-neo-build-scripts:patches/radxa-memory-tuning/example.patch",
        )

        targets, _, _ = plan.map_changes(changes, build_map)

        self.assertNotIn("radxa-o6-firmware-engineering", targets)
        self.assertIn("sky1-se-firmware", targets)


if __name__ == "__main__":
    unittest.main()
