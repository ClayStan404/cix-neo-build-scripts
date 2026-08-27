# CIX Neo Build System Migration Status

Status date: 2026-08-27

This report records the current migration from the legacy CIX build system at
`/home/claystan/cix-repo` to the native ARM64 Debian 13 build system. It covers
the implemented infrastructure and product flows, then lists the effective
status of every one of the 167 legacy top-level `build-*.sh` entry points.

The authoritative machine-readable sources are:

- `build-map.yaml` for current targets, build sets, source mappings, and CI
  impact rules;
- `legacy-build-map.yaml` for the fixed legacy entry-point snapshot and each
  entry's migration status;
- `docs/legacy-build-coverage.md` for firmware-platform coverage and scope.

The legacy snapshot is pinned to build-scripts revision
`7ebd44310b8dcb5351033722cbba94127c2ee26a`. Status counts describe legacy
scripts, not equal-sized features. Several old wrappers can map to one new
target, and several new targets have no one-to-one legacy wrapper.

## Status Summary

| Status | Count | Meaning |
| --- | ---: | --- |
| Implemented | 39 | The required legacy output has a native replacement target or declarative build set. |
| Partial | 3 | A useful replacement exists, but explicitly named legacy variants or outputs remain. |
| Blocked | 6 | Work cannot complete without repository access, a licensed toolchain, or a scope change. |
| Pending | 118 | The entry has not yet been audited and migrated; it is not implicitly supported. |
| Retired | 1 | The wrapper adds no unique output and is replaced by built-in behavior. |
| Total | 167 | Every top-level legacy `build-*.sh` entry is represented exactly once. |

The ledger validation passes against the live legacy checkout, so there is no
entry-point drift at this snapshot.

## Implemented Build-System Foundation

- The supported host baseline is native ARM64 Debian 13. The new system does
  not preserve the x86 cross-build framework or its command-line interface.
- `cix-build` is the single user entry point. `build-map.yaml` is the single
  registry for targets, build sets, source locations, Debian metadata, and CI
  source-impact rules.
- There are two build models: `direct` for project-specific native flows and
  `debian` for Debian source packages.
- Debian targets use isolated `sbuild` by default and may use host
  `dpkg-buildpackage` with `--backend local`. Direct targets are unaffected by
  the Debian backend selection.
- Debian `Build-Depends` fields are the package-dependency source of truth.
  The build planner orders targets and propagates rebuild impact from those
  package relationships rather than shell-script dependency declarations.
- Direct builds, local Debian builds, and sbuild share a 20 GB ccache at
  `~/.cache/cix-neo-sbuild/ccache`. Sbuild also shares downloaded APT archives
  without sharing mutable APT state.
- Builds use the host CPU count by default, clean stale top-level artifacts,
  publish under `output/TARGET`, stop on the first failure, and report per-target
  and total elapsed time.
- `clean-all` cleans every registered target while retaining reusable caches.
  `distclean` additionally removes all registered target directories and
  empties the shared ccache and sbuild APT archive cache while preserving the
  sbuild chroot and explicitly reporting unregistered output entries.
- Setup scripts install the recorded Debian 13 host and sbuild prerequisites
  needed to reproduce a new build machine.
- The manifest, Debian metadata, and build scripts are maintained as separate
  manifest-managed repositories. Changes are selected by repository/path rules
  in the same build map consumed by local builds and CI planning.

The current build map contains 59 unique targets. The main build sets overlap
by design:

| Build set | Targets | Current coverage |
| --- | ---: | --- |
| `all-6.6` | 33 | CIX Linux 6.6 kernel, O6/O6N firmware, drivers, firmware packages, graphics, multimedia, AI, and system packages. |
| `all-7.0` | 6 | CIX-patched Linux 7.0.13, VPU DKMS and firmware, GRUB integration, and Debian Salsa-based GStreamer 7.0 packages. |
| `firmware-sky1` | 4 | O6, O6N, Sky1 Merak, and Sky1 Edge full product firmware. Each target publishes ten Full/OTA signing-layout variants. |
| `uefi-development` | 11 | Canonical native RELEASE UEFI volumes for available Sky1, Sky1P, and Star1 Emu/FPGA/EVB/CRB/Merak platforms. |
| `secure-firmware` | 5 | Standalone MM, OP-TEE, PBL, TF-A, and Sky1 SE firmware. |
| `sky1-trusted-firmware` | 2 | PBL and TF-A convenience set. |
| `pm-validation` | 4 | Recovery-gated O6/O6N PM configuration validation and the PM inspection tool. |
| `pm-tuning` | 2 | Recovery-gated O6 BIOS-selectable CPU and experimental memory tuning plus the PM inspection tool. |

The secure-firmware set has completed on the ARM64 host and its TF-A, PBL,
OP-TEE, SE firmware, and Standalone MM artifacts are present under `output/`.
Product and package targets were built and corrected during migration, but this
status report does not claim that all 59 targets were rerun from a fresh host
after every later firmware commit.

## Remaining Firmware-Critical Work

1. BootROM source access is the immediate blocker. The legacy manifest does
   contain `cix_security/bootrom` (`cix_bootrom_dev`) and
   `cix_security/tool` (`cix_master`) in the `brom` group. The active legacy
   checkout uses `cix,notdefault,platform-linux`, so those projects were not
   synced. The current SSH account is also denied access to their refs. Once
   both ACLs are granted, add the sources to the new manifest, audit the native
   toolchain, and implement the BootROM target.
2. Sky1P and Star1 UEFI volumes build natively, but their signed full-image
   flow needs the CBFF 1.4 source in `cix_security/tool`. The currently
   available release executable is x86-64 and is not usable on the ARM64 host.
3. PM firmware source is available, but the build requires the licensed
   Cadence Xtensa RI-2022.10 toolchain. No supported native Debian 13 ARM64
   installation is currently available.
4. The canonical development UEFI profile is implemented. DEBUG, Android
   capsule, alternate TEE/loader/boot profiles, and missing Star1 board DSCs
   remain explicit work rather than implied support.

## Implemented Legacy Entries (39)

| Legacy entry | Native replacement |
| --- | --- |
| `build-ai-engine.sh` | `ai-engine` |
| `build-audio_dsp.sh` | `audio-dsp` |
| `build-audio_sof.sh` | `audio-sof` |
| `build-bt.sh` | `bt-dkms` |
| `build-cix-cme.sh` | `libcme` |
| `build-cix-env.sh` | `cix-env` |
| `build-cix-firmware.sh` | `cix-firmware` |
| `build-cix-gpu-dkms-src.sh` | `gpu-dkms` |
| `build-cix-gpu-dkms.impl.sh` | `gpu-dkms` |
| `build-cix-gpu-dkms.sh` | `gpu-dkms` |
| `build-cix-grub-config.sh` | `grub-config` |
| `build-cix-grubcfg.sh` | `grub-config` |
| `build-cix-isp-dkms.impl.sh` | `isp-dkms` |
| `build-cix-isp-dkms.sh` | `isp-dkms` |
| `build-cix-isp-v4l2-dkms.sh` | `isp-v4l2-dkms` |
| `build-cix-npu-dkms.sh` | `npu-dkms` |
| `build-cix-vaapi.sh` | `cix-vaapi` |
| `build-cix-vpu-dkms.sh` | `vpu-dkms` |
| `build-dpu-ddk.sh` | `dpu-ddk` |
| `build-ffmpeg.sh` | `ffmpeg` |
| `build-firmware-radxa-O6.sh` | `radxa-o6-firmware` |
| `build-firmware-release-Edge.sh` | `sky1-edge-firmware` |
| `build-firmware.sh` | `sky1-se-firmware` |
| `build-gstreamer.sh` | `gstreamer-6.6` |
| `build-isp-driver-v4l2.sh` | `isp-v4l2-dkms` |
| `build-isp-driver.sh` | `isp-dkms` |
| `build-isp-umd.sh` | `isp-umd` |
| `build-kernel.sh` | `kernel` |
| `build-libva.sh` | `libva` |
| `build-mesa.sh` | `mesa` |
| `build-mnn.sh` | `mnn` |
| `build-nnstreamer.sh` | `nnstreamer` |
| `build-noe-umd.sh` | `noe-umd` |
| `build-npu-umd.sh` | `npu-umd` |
| `build-pbl.sh` | `sky1-pbl` |
| `build-tee.sh` | `sky1-optee` |
| `build-tf-a.sh` | `sky1-trusted-firmware` |
| `build-uefi-stmm.sh` | `uefi-stmm` |
| `build-wlan.sh` | `wlan-dkms` |

## Partially Implemented Legacy Entries (3)

| Legacy entry | Current replacement | Remaining work |
| --- | --- | --- |
| `build-all-sec.sh` | `secure-firmware` | TF-A, PBL, OP-TEE, Standalone MM, and Sky1 SE firmware build natively. PM firmware, BootROM, and product-signing flows remain blocked. |
| `build-uefi-star1.sh` | `uefi-development` | Emu, FPGA, and Merak canonical RELEASE profiles build natively. Megrez, CloudBook, and Batura DSC sources are absent, and full-image packaging remains separate. |
| `build-uefi.sh` | `uefi-development` | The canonical RELEASE Debian/optee/nvme profile is implemented for every manifest-available platform. DEBUG, Android capsule, alternate TEE, loader, and boot variants remain pending. |

## Blocked Legacy Entries (6)

| Legacy entry | Blocker | Required resolution |
| --- | --- | --- |
| `build-bootrom.sh` | `cix_security/bootrom` and `cix_security/tool` exist in the legacy `brom` group, but are absent from the checkout and unreadable by the current SSH account. | Grant both repository ACLs, sync both projects, then audit and implement the native ARM64 flow. |
| `build-ffmpeg-ubuntu24.sh` | Ubuntu 24.04 packaging is outside the Debian 13-only product baseline. | Make Ubuntu 24.04 an explicit supported product and define its separate package/test baseline. |
| `build-ffmpeg-ubuntu25.sh` | Ubuntu 25 packaging is outside the Debian 13-only product baseline. | Make Ubuntu 25 an explicit supported product and define its separate package/test baseline. |
| `build-mkimage-sky1p.sh` | The available CBFF 1.4 executable is x86-64; its source is in the restricted `cix_security/tool` repository. | Grant repository access, build CBFF 1.4 natively, and validate signed Sky1P images. |
| `build-mkimage-star1.sh` | The available CBFF 1.4 executable is x86-64; its source is in the restricted `cix_security/tool` repository. | Grant repository access, build CBFF 1.4 natively, and validate signed Star1 images. |
| `build-pm_fw.sh` | The PM firmware requires licensed Cadence Xtensa RI-2022.10 tooling not available for the current native host. | Provide a licensed, supported Debian 13 ARM64 toolchain or an approved native build service. |

## Pending Legacy Entries (118)

Pending means no output-equivalence decision has been completed. Some entries
may become native targets, some may collapse into declarative build sets, and
some may be retired after their orchestration-only behavior is confirmed. They
are listed explicitly so none can be mistaken for implemented coverage.

1. `build-ai-all.sh`
2. `build-ai-test.sh`
3. `build-all-fip.sh`
4. `build-all-nopackage.sh`
5. `build-all-private.sh`
6. `build-all-qa-firmware.sh`
7. `build-all-yocto.sh`
8. `build-all.sh`
9. `build-android-bootloader.sh`
10. `build-android-only.sh`
11. `build-android-xpu.sh`
12. `build-android.sh`
13. `build-armnn.sh`
14. `build-audio_dsp_android.sh`
15. `build-audio_dsp_unit_test.sh`
16. `build-audio_sof_clang.sh`
17. `build-bin_hex.sh`
18. `build-bluez.sh`
19. `build-bootloader.sh`
20. `build-buildroot.sh`
21. `build-cas-tas.sh`
22. `build-cc-uuu.sh`
23. `build-cc-uuu25.sh`
24. `build-cc.sh`
25. `build-chromium.sh`
26. `build-cix-bkup.sh`
27. `build-cix-cc.sh`
28. `build-cix-common-misc.sh`
29. `build-cix-go.sh`
30. `build-cix-isp.sh`
31. `build-cix-mkimage.sh`
32. `build-cix-mm.sh`
33. `build-cix-noe.sh`
34. `build-cix_pipe.sh`
35. `build-csidma-driver.sh`
36. `build-ddrdump.sh`
37. `build-debian.sh`
38. `build-debian12.sh`
39. `build-debian13.sh`
40. `build-edge-slm.sh`
41. `build-firmware-release-android.sh`
42. `build-firmware-release.sh`
43. `build-full-nopackage.sh`
44. `build-full.sh`
45. `build-fvp-tc2.sh`
46. `build-gnome-shell.sh`
47. `build-gpu-driver.sh`
48. `build-gpu.sh`
49. `build-graphics.sh`
50. `build-grub.sh`
51. `build-hdcp2.sh`
52. `build-img2hex.sh`
53. `build-imx_boot.sh`
54. `build-imx_vpu.sh`
55. `build-irqbalance.sh`
56. `build-isp-open-source.sh`
57. `build-jellyfin-ffmpeg.sh`
58. `build-kylin-ffmpeg.sh`
59. `build-lk.sh`
60. `build-llamacpp.sh`
61. `build-lt7911uxc.sh`
62. `build-ltp-opensource.sh`
63. `build-ltp.sh`
64. `build-make.sh`
65. `build-memory-config.sh`
66. `build-metapackages.sh`
67. `build-minimum-unittest.sh`
68. `build-minimum-without-debian.sh`
69. `build-minimum.sh`
70. `build-mkimage.sh`
71. `build-mpv.sh`
72. `build-mutter.sh`
73. `build-noe-compiler-sky1.sh`
74. `build-noe-compiler-sky1p.sh`
75. `build-noe-llm.sh`
76. `build-noe-serialization.sh`
77. `build-npu-kmd.sh`
78. `build-npu-runtime.sh`
79. `build-opencv.sh`
80. `build-openocd.sh`
81. `build-opensource-firmware.sh`
82. `build-opensource-linux-tag.sh`
83. `build-opensource.sh`
84. `build-optee-client.sh`
85. `build-parallel.sh`
86. `build-prideb.sh`
87. `build-qa-pm_fw.sh`
88. `build-qa-tfa.sh`
89. `build-qspi-flash.sh`
90. `build-ramparser.sh`
91. `build-rk-kernel.sh`
92. `build-rk3588.sh`
93. `build-se-config.sh`
94. `build-sec-package.sh`
95. `build-sec-release.sh`
96. `build-sensorfusion.sh`
97. `build-storage.sh`
98. `build-sysroot.sh`
99. `build-tee-sdk.sh`
100. `build-tool.sh`
101. `build-tvm.sh`
102. `build-uefi-ci-android.sh`
103. `build-uefi-ci-merge.sh`
104. `build-uefi-unit-test.sh`
105. `build-unit_test.sh`
106. `build-viplite-acuityllm.sh`
107. `build-viplite-dkms.sh`
108. `build-viplite-kmd.sh`
109. `build-viplite-umd.sh`
110. `build-vpu_driver.sh`
111. `build-vpu_test.sh`
112. `build-whispercpp.sh`
113. `build-xwayland.sh`
114. `build-yocto.sh`
115. `build-zhouyi-dkms.sh`
116. `build-zhouyi-kmd.sh`
117. `build-zhouyi-onnxruntime.sh`
118. `build-zhouyi-umd.sh`

## Retired Legacy Entry (1)

| Legacy entry | Replacement | Reason |
| --- | --- | --- |
| `build-with-timestamp.sh` | Built-in `cix-build` elapsed-time reporting | The wrapper adds no build output; every target and build set now reports elapsed time directly. |

## Updating This Report

Change `legacy-build-map.yaml` first when an entry is implemented, partially
implemented, blocked, or retired. Keep this report synchronized with that
authoritative ledger, then validate both the replacement names and the frozen
legacy snapshot with:

```bash
python3 ./build-scripts/ci/check_legacy_coverage.py \
    --legacy-root /home/claystan/cix-repo/build-scripts
```

An entry may move to `implemented` only when the required output is available
through the new system. A similarly named package or a successful build of one
variant is not sufficient evidence for output equivalence.
