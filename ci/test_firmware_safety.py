#!/usr/bin/env python3
"""Regression tests for firmware patches and publication boundaries."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci"))
import plan  # noqa: E402


class SecureFirmwarePatchTests(unittest.TestCase):
    def test_native_toolchain_patch_preserves_upstream_bootperf(self) -> None:
        patch = (
            ROOT / "patches/radxa-bootloader"
            / "0002-se-firmware-support-debian-native-toolchain.patch"
        )
        with tempfile.TemporaryDirectory(prefix="cix-se-patch-test.") as temporary:
            worktree = Path(temporary)
            subprocess.run(["git", "init", "-q", str(worktree)], check=True)
            dap_path = worktree / "driver/dap/dap_rsp.c"
            dap_path.parent.mkdir(parents=True)
            # Keep upstream context independent of the patch and source checkout.
            dap_path.write_text(
                "static uint32_t dap_packet_size = 64; //usb2.0\n"
                "\nstatic int rtp_rom_pwron(uint32_t base_address)\n{\n"
                "\tuint val;\n\n"
                "\tSMN_WRITEL(ARM_CS_SYSPCR_ROM_TABLE_PR, "
                "base_address + ARM_CS_ROM_TABLE_SYSPCR);\n"
                "\tbperf_record_stage(BP_SE_DLY_ROM_PWRON, BPERF_RECORD_START);\n"
                "\thal_mdelay(10);\n"
                "/* Remaining function body omitted. */\n}\n\n"
                "static int rsp_query_cmd(char *data)\n{\n"
                "\tif (!strncmp(data, \"qSupported\", 10)) {\n"
                "\t\tlen = sprintf(data, \"PacketSize=%08x#1\", dap_buf.size);\n"
                "\t} else if (!strncmp(data, \"qSetPacketNum=\", 14)) {\n"
                "\t\tchar *buf = data + 14;\n"
                "\t\tuint num = strtoul(buf, NULL, 16);\n"
                "\t\tif (!num)\n\t\t\tnum = 1;\n"
                "\t\tdap_buf.size = num * dap_packet_size;\n"
                "\t}\n}\n"
            )
            result = subprocess.run(
                ["git", "-C", str(worktree), "apply",
                 "--include=driver/dap/dap_rsp.c", str(patch)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            dap = dap_path.read_text()
            self.assertIn("\tuint32_t val;", dap)
            self.assertIn(
                "bperf_record_stage(BP_SE_DLY_ROM_PWRON, BPERF_RECORD_START);\n"
                "\thal_mdelay(10);",
                dap,
            )


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

    def test_cpu_tuning_uses_partial_external_opp_tables(self) -> None:
        flow = (ROOT / "builders/direct/firmware-sky1.sh").read_text()
        patch = (
            ROOT
            / "patches/radxa-pm-tuning"
            / "0004-Platform-use-CPU-only-partial-OPPs.patch"
        ).read_text()

        self.assertIn("0004-Platform-use-CPU-only-partial-OPPs.patch", flow)
        self.assertIn("PM_CONFIG_OPP_EXTERNAL_PARTIAL", patch)
        self.assertIn("PmNonCpuDomainsAreUnused", patch)
        self.assertIn("PmDefaultVoltageMode", patch)
        self.assertIn("RADXA_PM_TUNING_REVISION     3", patch)

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
