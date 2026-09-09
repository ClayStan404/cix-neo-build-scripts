"""Required published outputs for Debian packages and native build flows."""

from __future__ import annotations

from pathlib import Path

import plan


class ArtifactError(RuntimeError):
    """A target is missing a required published output."""


def required_outputs(target: plan.Target) -> tuple[str, ...]:
    if target.builder == "debian":
        return ("*.deb",)
    if target.flow == "sky1-firmware":
        variants = ("", "_pr_debug", "_pr2_debug", "_proto", "_proto_debug")
        return tuple(
            f"images/{directory}cix_flash_{delivery}_{target.board}{variant}.bin"
            for variant in variants
            for directory, delivery in (("", "all"), ("", "ota"), ("ocb/", "all"))
        )
    if target.flow == "sky1-firmware-engineering":
        return (
            f"images/cix_flash_all_{target.board}_cpu_tuning_pr_debug.bin",
            "bootloader1_pr_debug.img",
            "bootloader3_cpu_tuning_pr_debug.img",
            f"csu_pm_config_{target.board}_vendor-auto.bin",
        )
    outputs = {
        "kernel-worktree": (
            "linux-image-*-generic_*_arm64.deb",
            "linux-headers-*-generic_*_arm64.deb",
            "cix-linux-libc-dev_*_arm64.deb",
        ),
        "kernel-stable-tarball": (
            "linux-image-*-cix_*_arm64.deb",
            "linux-headers-*-cix_*_arm64.deb",
        ),
        "sof-firmware": ("cix-audio-sof_*_all.deb",),
        "uefi-development": ("SKY1_BL33_UEFI.fd",),
        "uefi-stmm": ("BL32_AP_EFI_STMM.fd",),
        "sky1-tf-a": ("tf-a.bin", "bl31.elf", "SHA256SUMS"),
        "sky1-pbl": ("pbl_fw.bin", "bl2.elf", "SHA256SUMS"),
        "sky1-optee": ("tee.bin", "tee.elf", "SHA256SUMS"),
        "sky1-se-firmware": (
            "se_fw.bin", "se_fw.elf", "se_fw.hex", "se_fw.disass", "SHA256SUMS",
        ),
        "pmtool": ("pmtool",),
        "ramparser": (
            "ramparser/crash", "ramparser/ramlog", "ramparser/rdr", "SHA256SUMS",
        ),
        "cix-test-tools": (
            "tools/lt7911_download", "tools/i3ctransfer", "tools/spidev_fdx",
            "tools/uart_test", "tools/uart_transceiver", "tools/phytool",
            "tools/mv6tool", "SHA256SUMS",
        ),
        "ltp-testsuite": (
            "ltp/runltp", "ltp/testcases/bin/getpid01", "ltp/testcases/bin/uname01",
            "ltp/testcases/bin/gettimeofday01", "SHA256SUMS",
        ),
    }
    try:
        return outputs[target.flow]
    except KeyError as exc:
        raise ArtifactError(f"no artifact policy for {target.name}: {target.flow}") from exc


def validate_outputs(target: plan.Target, workspace: Path) -> None:
    output = workspace / "output" / target.name
    patterns = required_outputs(target)
    if target.control:
        # Every declared binary must be present, not just an arbitrary .deb.
        packages, _, _, _ = plan._parse_control(workspace / target.control)
        patterns = tuple(f"{package}_*.deb" for package in sorted(packages))
    for pattern in patterns:
        matches = list(output.glob(pattern))
        if len(matches) != 1 or not matches[0].is_file() or matches[0].stat().st_size == 0:
            raise ArtifactError(
                f"{target.name} requires exactly one nonempty artifact matching {pattern}; "
                f"found {len(matches)}"
            )
