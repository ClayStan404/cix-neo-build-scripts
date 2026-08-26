# Legacy Build Coverage

This ledger records the migration from `/home/claystan/cix-repo` to the native
ARM64 Debian 13 build system. Complete coverage means that every legacy build
entry point is represented by one of the following outcomes:

- a native `cix-build` target;
- a declarative build set that replaces an orchestration wrapper;
- an explicit retired entry with a recorded replacement or reason;
- an explicit blocked entry with the missing source, tool, or product decision.

Legacy command names and their configuration interface are not compatibility
requirements. Multiple legacy wrappers may map to one new target or build set.

The authoritative entry-point snapshot is
[`legacy-build-map.yaml`](../legacy-build-map.yaml). It records all 167
top-level legacy `build-*.sh` files at revision
`7ebd44310b8dcb5351033722cbba94127c2ee26a`, with a status override where a
replacement, blocker, or retirement has been confirmed. Run
`ci/check_legacy_coverage.py` to validate replacements against `build-map.yaml`;
pass `--legacy-root` to detect entry points added to or removed from a local
legacy checkout.

## Current Product Coverage

| Legacy area | New target or set | Status |
| --- | --- | --- |
| Debian 13 Sky1 Linux 6.6 product | `all-6.6` | Implemented |
| CIX-patched stable Linux 7.0 product | `all-7.0` | Implemented |
| Radxa Orion O6 firmware | `radxa-o6-firmware` | Implemented |
| Radxa Orion O6N firmware | `radxa-o6n-firmware` | Implemented with isolated patches |
| Sky1 Merak internal EVB firmware | `sky1-merak-firmware` | Implemented |
| Sky1 Edge firmware | `sky1-edge-firmware` | Implemented |
| All implemented Sky1 product boards | `firmware-sky1` | Implemented |
| O6/O6N PM validation | `pm-validation` | Implemented, recovery-gated |
| O6 PM and memory tuning | `pm-tuning` | Implemented, recovery-gated |

## Firmware Platform Backlog

| SoC | Board or environment | Legacy source | Migration status |
| --- | --- | --- | --- |
| Sky1 | Emu | private development EDK2 | Pending UEFI port; legacy full-image packaging uses x86-only tools and needs a native path |
| Sky1 | FPGA | private development EDK2 | Pending UEFI port; legacy full-image packaging uses x86-only tools and needs a native path |
| Sky1P | EVB | release and development EDK2 | Blocked by x86-only `cix_cbff` and missing manifest TF-A/TEE inputs |
| Sky1P | CRB1 | private development EDK2 | Blocked by the Sky1P native packaging prerequisites |
| Sky1P | CRB2 | private development EDK2 | Blocked; matching firmware payload/configuration is absent in the legacy checkout |
| Sky1P | Emu | private development EDK2 | Pending after native Sky1P packaging |
| Sky1P | FPGA | private development EDK2 | Pending after native Sky1P packaging |
| Star1 | Merak | private development EDK2 | Blocked by missing curated sources and x86-only `cix_cbff` full-image packaging |
| Star1 | Emu | private development EDK2 | Blocked by missing curated sources and x86-only `cix_cbff` full-image packaging |
| Star1 | FPGA | private development EDK2 | Blocked by missing curated sources and x86-only `cix_cbff` full-image packaging |

`pr`, `pr2`, and `proto`, and `release` or `debug`, are signing/build variants;
they are not additional boards. Full/OTA and SPI/UFS are delivery layouts.

## Remaining Legacy Areas

The legacy repository also contains independent build families that are not
all part of the current Debian 13 product sets. They remain migration work and
must not be reported as supported merely because a similarly named package is
available:

- source-built TF-A, TEE, PM, PBL, security, and firmware QA targets;
- Android platform, Android bootloader, and Android XPU targets;
- Buildroot, Yocto, Debian installer/rootfs, and full-disk image targets;
- Sky1P and Star1 kernel, firmware, NPU, and platform variants;
- Chromium, GNOME Shell, Mutter, Xwayland, BlueZ, MPV, OpenCV, TVM, ArmNN,
  LTP, unit-test, QA, factory, flash, dump, and recovery utilities;
- private AI, media, ISP, security, and customer deliverable bundles;
- orchestration-only wrappers such as legacy `build-all*`, `build-full*`,
  timestamp, Docker, and parallel dispatch scripts.

New repositories are added to the manifest only when their first target is
implemented. Each migration must first confirm that every required executable
is either native AArch64 or buildable from source on Debian 13. The build map
then becomes the authoritative target, source-impact, and build-set registry.
