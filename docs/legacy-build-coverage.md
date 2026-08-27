# Legacy Build Coverage

This ledger records the migration from `/home/claystan/cix-repo` to the native
ARM64 Debian 13 build system. Complete coverage means that every legacy build
entry point is represented by one of the following outcomes:

- a native `cix-build` target;
- a declarative build set that replaces an orchestration wrapper;
- a partial replacement that records both the implemented output and the
  remaining variants;
- an explicit retired entry with a recorded replacement or reason;
- an explicit blocked entry with the missing source, tool, or product decision.

Legacy command names and their configuration interface are not compatibility
requirements. Multiple legacy wrappers may map to one new target or build set.

The active firmware milestone covers board UEFI, full-flash packaging,
Standalone MM, and their signing/delivery variants. The wider ledger remains a
historical migration inventory; its non-firmware entries do not expand the
scope of the current firmware work.

The authoritative entry-point snapshot is
[`legacy-build-map.yaml`](../legacy-build-map.yaml). It records all 167
top-level legacy `build-*.sh` files at revision
`7ebd44310b8dcb5351033722cbba94127c2ee26a`, with a status override where a
replacement, blocker, or retirement has been confirmed. Run
`ci/check_legacy_coverage.py` to validate replacements against `build-map.yaml`;
pass `--legacy-root` to detect entry points added to or removed from a local
legacy checkout.

The exhaustive dated status, including every entry point in every category, is
published in [`migration-status.md`](migration-status.md).

## Current Product Coverage

| Legacy area | New target or set | Status |
| --- | --- | --- |
| Debian 13 Sky1 Linux 6.6 product | `all-6.6` | Implemented |
| CIX-patched stable Linux 7.0 product | `all-7.0` | Implemented |
| Radxa Orion O6 firmware | `radxa-o6-firmware` | Implemented, complete 10-image signing/layout matrix |
| Radxa Orion O6N firmware | `radxa-o6n-firmware` | Implemented with isolated patches and complete 10-image matrix |
| Sky1 Merak internal EVB firmware | `sky1-merak-firmware` | Implemented, complete 10-image signing/layout matrix |
| Sky1 Edge firmware | `sky1-edge-firmware` | Implemented, complete 10-image signing/layout matrix |
| All implemented Sky1 product boards | `firmware-sky1` | Implemented |
| Private development UEFI platforms | `uefi-development` | Canonical native RELEASE profile implemented |
| Sky1 Standalone MM | `uefi-stmm` | Native RELEASE firmware implemented |
| Sky1 TF-A and PBL | `sky1-trusted-firmware` | Native Debian GCC build implemented |
| Sky1 OP-TEE | `sky1-optee` | Native Debian GCC build implemented |
| Sky1 SE firmware | `sky1-se-firmware` | Native RELEASE ARM Embedded build implemented |
| All implemented secure components | `secure-firmware` | Implemented; PM and BootROM remain explicit blockers |
| O6 engineering firmware and inspection tool | `firmware-engineering` | Implemented, recovery-gated |

## Firmware Platform Backlog

| SoC | Board or environment | Native UEFI `.fd` | Full-image status |
| --- | --- | --- | --- |
| Sky1 | Emu | Implemented | No product image target; legacy packaging path still needs a native audit |
| Sky1 | FPGA | Implemented | No product image target; legacy packaging path still needs a native audit |
| Sky1 | Merak | Implemented | Implemented by `sky1-merak-firmware` |
| Sky1P | EVB | Implemented | Blocked by restricted CBFF 1.4 source and x86-only release binary |
| Sky1P | CRB1 | Implemented | Blocked by the native CBFF prerequisite and missing board package configuration |
| Sky1P | CRB2 | Implemented | Blocked; matching full-image payload/configuration is absent in the legacy checkout |
| Sky1P | Emu | Implemented | No product image target; packaging inputs remain unaudited |
| Sky1P | FPGA | Implemented | No product image target; packaging inputs remain unaudited |
| Star1 | Merak | Implemented | Blocked by restricted CBFF 1.4 source and x86-only release binary |
| Star1 | Emu | Implemented | No product image target; packaging inputs remain unaudited |
| Star1 | FPGA | Implemented | No product image target; packaging inputs remain unaudited |

The native matrix currently implements the canonical RELEASE Debian/optee/nvme
profile used by the regular legacy update path. DEBUG, Android capsule,
alternate TEE/loader, and other legacy flag combinations remain explicit
migration work. The legacy Star1 wrapper also names Megrez, CloudBook, and
Batura, but their DSC trees are absent from the pinned `cix_master` sources;
those board variants are not claimed as supported.

`pr`, `pr2`, and `proto`, and `release` or `debug`, are signing/build variants;
they are not additional boards. Full/OTA and SPI/UFS are delivery layouts.

## Remaining Legacy Areas

The legacy repository also contains independent build families that are not
all part of the current Debian 13 product sets. They remain migration work and
must not be reported as supported merely because a similarly named package is
available:

- PM firmware, BootROM, secure product packaging/signing, and firmware QA
  targets that still require restricted source access, licensed tools, or RKMS;
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

The Sky1P/Star1 blocker was rechecked against Gerrit and the 2026-08-26 release
tree. `cix_security/tool` is restricted to the Security group, while the
release repository still publishes an x86-64 `cix_cbff` only. Internal change
72680 identifies its build source as `repo_brom/tool/cix_cbff`. The
source-available Sky1 `cix_mkimage` implements the older configuration and CBFF
format, so substituting it would create unvalidated boot containers.

BootROM was rechecked separately. The legacy manifest declares
`cix_security/bootrom` at `security/bootrom` and `cix_security/tool` at `tool`,
both in the `brom` group. The active legacy checkout was initialized with
`cix,notdefault,platform-linux`, so neither project is present. The Gitolite
mirror rejects the current account with HTTP-equivalent permission code 403,
and Gerrit exposes the project metadata but no readable refs. This is a source
access blocker, not evidence that the source repository does not exist.
