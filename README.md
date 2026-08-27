# Build System

This directory contains the CIX Neo build command and its small set of shared
build engines. It does not use the legacy build-system CLI, per-module script
naming, or framework contract.

Build one complete CIX kernel stack at a time:

```bash
./build-scripts/cix-build all-6.6
./build-scripts/cix-build all-7.0
./build-scripts/cix-build firmware-sky1
./build-scripts/cix-build uefi-development
./build-scripts/cix-build secure-firmware
./build-scripts/cix-build firmware-engineering
```

Build an individual target with the same command:

```bash
./build-scripts/cix-build kernel
./build-scripts/cix-build stable-kernel
./build-scripts/cix-build audio-sof
./build-scripts/cix-build radxa-o6-firmware
./build-scripts/cix-build radxa-o6n-firmware
./build-scripts/cix-build sky1-merak-firmware
./build-scripts/cix-build sky1-edge-firmware
./build-scripts/cix-build sky1p-evb-uefi
./build-scripts/cix-build star1-merak-uefi
./build-scripts/cix-build radxa-o6-firmware-engineering
./build-scripts/cix-build pmtool
./build-scripts/cix-build gpu-dkms
./build-scripts/cix-build bt-dkms
./build-scripts/cix-build vpu-dkms
./build-scripts/cix-build vpu-firmware
./build-scripts/cix-build npu-dkms
./build-scripts/cix-build grub-config
./build-scripts/cix-build alsa-conf
./build-scripts/cix-build cix-env
./build-scripts/cix-build cix-firmware
./build-scripts/cix-build audio-dsp
./build-scripts/cix-build dpu-ddk
./build-scripts/cix-build gpu-umd
./build-scripts/cix-build isp-umd
./build-scripts/cix-build libdrm
./build-scripts/cix-build libglvnd
./build-scripts/cix-build mesa
./build-scripts/cix-build libva
./build-scripts/cix-build ffmpeg
./build-scripts/cix-build libcme
./build-scripts/cix-build cix-vaapi
./build-scripts/cix-build isp-v4l2-dkms
./build-scripts/cix-build isp-dkms
./build-scripts/cix-build noe-umd
./build-scripts/cix-build npu-umd
./build-scripts/cix-build ai-engine
./build-scripts/cix-build mnn
./build-scripts/cix-build gstreamer-6.6
./build-scripts/cix-build gstreamer-base-7.0
./build-scripts/cix-build gstreamer-good-7.0
./build-scripts/cix-build nnstreamer
./build-scripts/cix-build wlan-dkms
```

`all-6.6` builds the CIX Linux 6.6 kernel and the complete driver, firmware,
userspace, multimedia, AI, and board-firmware target set. `all-7.0` builds the
CIX-patched stable 7.0 kernel, VPU DKMS and firmware packages,
`cix-grub-config`, and the Debian Salsa-based GStreamer 7.0 packages. VPU and
GRUB targets are intentionally shared by both sets. A bare `all` is rejected
because it would mix the two kernel stacks.

Each set is built in the dependency order calculated from Debian
`Build-Depends`. The default Debian package backend is `sbuild`. Select direct
host builds for conventional Debian packages in either set with:

```bash
./build-scripts/cix-build all-6.6 --backend local
./build-scripts/cix-build all-7.0 --backend local
```

The local backend uses APT to install exact, already-built internal
`Build-Depends` packages and their internal runtime dependencies on the host
before invoking `dpkg-buildpackage`; it therefore requires passwordless `sudo`
and intentionally changes the host's installed CIX packages. The required
`.deb` files are supplied directly from their mapped `output` directories, so
unrelated binary packages from the same source are not required or installed.
APT installs the exact workspace-built versions, including a downgrade when
the host already has a newer version of the same CIX package. The sbuild
backend keeps these packages inside its disposable build environment.

The backend selection does not change `direct` targets such as `kernel`,
`stable-kernel`, `audio-sof`, or the Sky1 firmware targets; those always
execute their target-owned native build flow.
A build set stops at the first failed target. `cix-build all-6.6 clean` and
`cix-build all-7.0 clean` clean their targets in reverse dependency order.
Clean every target registered in `build-map.yaml`, including targets outside
the two product sets, with:

```bash
./build-scripts/cix-build clean-all
```

`clean-all` removes empty registered target directories after their target-owned
cleaners finish. Directories that still contain reusable source downloads,
generated toolchains, or other target caches remain. The shared compiler cache
and sbuild APT archive cache are also retained. Use the stronger cleanup only
when those caches must be discarded:

```bash
./build-scripts/cix-build distclean
```

`distclean` first runs every target-owned cleaner, then removes all registered
target directories and empties the persistent ccache and sbuild APT archive
cache. It preserves the provisioned sbuild chroot and any unregistered entries
under `output/`; each preserved entry is reported explicitly. Both global
operations derive the complete target list from `build-map.yaml` rather than a
duplicated shell list.

Every target reports its elapsed time as `HH:MM:SS`, and a successful set
reports the total elapsed time. On failure, the command reports the failed
target's elapsed time and the total time before stopping.

The supported build host baseline is native ARM64 Debian 13. Other Debian and
Ubuntu host releases are intentionally outside the current scope.

There are two independent native kernel targets. `kernel` builds the CIX 6.6
development kernel using its kernel-owned configuration fragments and the
external temporary fix in `debian/kernel/patches/`. `stable-kernel` downloads
the upstream release pinned in `build-map.yaml`, then applies the patch set and
defconfig from the manifest-managed `cix-linux-main` checkout. Both use the
`direct` builder and `make bindeb-pkg`; neither uses the Debian package backend.
The stable target emits a `-cix` kernel release (for example, `7.0.13-cix`). The
new system does not retain the legacy fixed `7.0.0-generic` package name.

`audio-sof` builds on the native ARM64 host without using an x86 build
machine. SOF firmware itself runs on the Sky1 Xtensa DSP, so the direct flow
first builds an ARM64-hosted `xtensa-sky1-elf` compiler from the
manifest-pinned crosstool-NG, Newlib, and Xtensa overlay sources. The toolchain
is cached under `output/audio-sof/toolchain` and is rebuilt when any of those
inputs changes. It then builds the Sky1/Sky1P firmware and topology files and
packages them as `cix-audio-sof`.

`firmware-sky1` builds every currently supported Sky1 product firmware target:
Radxa Orion O6 and O6N, the CIX Merak EVB, and CIX Edge. They share the
manifest-pinned Sky1 EDK2, ACPICA, native AArch64 PackageTool, and CIX internal
payload repositories. The builder selects the board-owned DSC and package
configuration for each target; it never applies O6 board tuning to Merak or
Edge. Until the corresponding internal changes are merged, O6N source and
packaging changes are carried under `build-scripts/patches/radxa-o6n`.
The shared flow creates isolated Git worktrees under `output/TARGET/work`, so
repo checkouts remain clean. It publishes ten images per board under
`output/TARGET/images`: Full and OTA layouts for PR release, PR debug, PR2
debug, prototype release, and prototype debug. The five Full images are also
collected under `images/ocb`; the unsuffixed board image is the PR release
variant. It does not create Debian packages and is not affected by
`--backend`.

`uefi-development` builds the manifest-available validation-platform matrix
from the private development EDK2 sources: Sky1 Emu, FPGA, and Merak; Sky1P
Emu, FPGA, EVB, CRB1, and CRB2; and Star1 Emu, FPGA, and Merak. Every target
uses a native Debian 13 toolchain, an isolated worktree, and the canonical
RELEASE Debian/optee/nvme profile, then publishes `SKY1_BL33_UEFI.fd` and its
build report under `output/TARGET`. These are UEFI firmware volumes, not
signed full-flash images. Sky1P and Star1 full-image packaging remains blocked
where the only manifest-pinned `cix_cbff` executable is x86-64. Development
UEFI targets are direct builds and are not affected by `--backend`. Native
Sky1P and Star1 signing requires the CBFF 1.4 source maintained in the
restricted `cix_security/tool` repository. The release trees, including the
2026-08-26 release, contain only an x86-64 `cix_cbff`; the older source-available
Sky1 tool implements a different format and is not a safe substitute.

`uefi-stmm` builds the Sky1 Standalone MM firmware from the dedicated
`cix_master_stmm` EDK2 branches and publishes `BL32_AP_EFI_STMM.fd` with its
build report. It does not reuse the normal UEFI source branch, and it does not
require the old x86-hosted ARM64 cross-toolchain.

The native secure-firmware targets are:

- `sky1-tf-a`, which publishes `tf-a.bin` and `bl31.elf`;
- `sky1-pbl`, which publishes `pbl_fw.bin` and `bl2.elf`;
- `sky1-optee`, which publishes `tee.bin` and `tee.elf`;
- `sky1-se-firmware`, which publishes the RELEASE `se_fw` binary, ELF, HEX,
  and disassembly;
- `uefi-stmm`, which remains an independent Standalone MM artifact.

Run `cix-build sky1-trusted-firmware` for PBL and TF-A, or
`cix-build secure-firmware` for all implemented components. Each target builds
in an isolated Git worktree, uses Debian 13 ARM64 host tools, publishes a
`SHA256SUMS` file, and leaves every manifest source checkout clean. OP-TEE is
built as the standalone secure-world firmware used by the legacy flow when no
prebuilt Standalone MM path is supplied; `uefi-stmm` is deliberately kept as a
separate output rather than making the OP-TEE target depend on previous output
state.

PM firmware is not claimed as native: its available flow requires the licensed
Cadence Xtensa RI-2022.10 toolchain. BootROM is also not claimed: the legacy
manifest declares `cix_security/bootrom` and `cix_security/tool` in the `brom`
group, but the current checkout does not include that group and the current SSH
account cannot read either repository. These blockers remain recorded in the
migration ledger.

The remaining legacy firmware platforms and their native-build blockers are
tracked in [`docs/legacy-build-coverage.md`](docs/legacy-build-coverage.md).
The machine-readable [`legacy-build-map.yaml`](legacy-build-map.yaml) pins all
167 legacy `build-*.sh` entry points and records the replacement or migration
state of each one. Validate it, and optionally compare it with the legacy
checkout, with:

```bash
python3 ./build-scripts/ci/check_legacy_coverage.py \
    --legacy-root /home/claystan/cix-repo/build-scripts
```

The dated, exhaustive progress report is
[`docs/migration-status.md`](docs/migration-status.md). It lists every legacy
entry point under its effective status and explains the current product,
firmware, and infrastructure coverage.

`radxa-o6-firmware-engineering` produces one locally signed
`engineering_debug` full-flash image. Its BIOS exposes only Vendor/Automatic
and Custom. The profiles are in
the O6 UEFI setup menu under
`Device Manager -> Platform Configuration -> Advanced Configuration -> Power
Management`. Vendor/Automatic disables the external OPP table so PM firmware
can use its native OPN/Vmin/guardband path.
Custom enables a complete external CPU table with the Debug PM firmware and
permits edits to the non-boot OPPs of GB0, GB1, GM0, and GM1
within 800-3200 MHz and 550-1250 mV base voltage in steps of 10. Each editable
OPP can use a fixed voltage or Vmin profile 1-3. The effective 1500 MHz / 790 mV
boot OPP, DSU, and non-CPU domains remain locked. CPU power entries use the
measured-power table and interpolation from the exact pinned PM firmware
source, then conservatively scale upward with voltage squared above the source
voltage curve. Vmin modes reserve power at the source PM firmware's 980 mV
ceiling. The NVRAM settings carry a revision, exact size, and signature so an
incompatible layout cannot be consumed silently.
The build verifies the Debug PM binary against source revision `a2327331813f`,
its SHA-256 digest, PM config ABI v3.4, and the generated v3.0 schema. On the
following boot, a DXE driver validates, writes, reads back, and compares the
complete dedicated PM entry before performing one additional cold reset.
This target is not part of a product build set and the ordinary O6 firmware
target remains unchanged.

The same recovery-gated image repairs the existing `Advanced Configuration ->
Memory Configuration -> Memory Data Rate` update path. `Auto` and every
explicit menu value from 1600 through 6400 MT/s are validated and written only
to the BSET request. The per-population CONF limits remain exactly as supplied
by the vendor: normally 5500 MT/s, 4800 MT/s for the low-speed variants, and
6000 MT/s for the 32 GB Hynix variant. The updater validates the current image
and BSET checksum, writes the dedicated memory configuration entry, and
verifies the complete entry by reading it back. Rates above a board's qualified
limit remain experiments: the DDR implementation may reject them, the SoC
fuse limit may cap them, and an accepted rate can still fail training before
UEFI setup. Use such rates only with the tested USB recovery path.

For this tuning image, the Sky1 SE/DDR firmware and its `bootloader1` container
are built from the manifest-pinned sources on the ARM64 host. The build uses
Debian 13's `gcc-arm-none-eabi`, newlib, native GCC, OpenSSL, and libxml2; it
does not execute an x86 cross-toolchain. DDR training is limited to three
attempts. If an explicit rate fails, firmware writes `Auto` back to the
dedicated memory configuration entry, verifies the flash update, and resets.
Failure while already using `Auto` stops initialization instead of entering an
unbounded reset loop. Local signing is restricted to the documented prototype
key, and the tuning target publishes only the explicitly named
`engineering_debug` full-flash image. It never labels the repository's example
release keys as production keys. It intentionally does not publish tuning OTA
images because that payload does not carry the Debug PM firmware required by
the complete custom table. Product `pr` and `pr2` bootloaders
remain the manifest-pinned binaries: regenerating them requires RKMS, while the
available `cix_kms` frontend is x86-only and its source is not present. It is
therefore not executed by the ARM64-native build. PM and PBL target payloads
also remain version-matched manifest binaries because their source build needs
the licensed Xtensa toolchain, which Debian does not provide.

The `firmware-engineering` set also publishes the manifest-pinned ARM64 CIX
`pmtool` binary at
`output/pmtool/pmtool`. On the O6 test board, capture a checksummed read-only PM,
cpufreq, thermal, firmware, and kernel snapshot before and after flashing with:

```bash
sudo ./build-scripts/tests/collect-o6-pm-state.sh \
  ./output/pmtool/pmtool ./o6-pm-before
```

Use a new output directory for each capture. The collector needs privileged
hardware access and is never executed automatically by the build system.
The full recovery-gated board procedure is documented in
[`docs/o6-engineering-firmware.md`](docs/o6-engineering-firmware.md).

GPU, Bluetooth, WLAN, VPU, NPU, graphics, multimedia, firmware, boot
configuration, ALSA configuration, and system environment targets create
standard Debian source trees with the shared `debian` builder. Its default
backend is `sbuild`; pass `--backend local` to run `dpkg-buildpackage` directly
on the host instead. All targets use the single `cix-build` entry point. Files
under `builders/` implement reusable build models and source-assembly flows,
not package lists or independent commands. `cix-grub-config`,
`cix-alsa-conf`, and `cix-env` are native packages owned entirely by the
Debian metadata repository.

```bash
./build-scripts/cix-build gpu-dkms                 # isolated sbuild
./build-scripts/cix-build gpu-dkms --backend local # host dpkg-buildpackage
```

The local backend requires the package's `Build-Depends` to already be
installed on the host. This also applies to a build set using
`--backend local`: the command builds in dependency order but does not install
private build dependencies into the host. The sbuild backend resolves
dependencies inside its clean build environment. It also exposes previously
built packages from `output/*` through sbuild's temporary package archive. An
internal package named by the target's transitive `Build-Depends` closure
selects the output set that supplied it. The non-debug binary packages from
those source builds are
published together so APT can resolve their package-level `Depends`; output
sets from unrelated targets remain excluded. A Lintian policy violation fails
the sbuild invocation, even when package compilation itself succeeded.
Internal package matching is scoped by build-set membership. For example, the
6.6 targets obtain the standard GStreamer base development package from
Debian, while the 7.0 GStreamer target consumes the patched base package built
by `gstreamer-base-7.0`. A private `cix-*` dependency whose provider does not
share a build set is rejected as a configuration error.
`--backend` is rejected for individual `direct` targets because those flows
already define their own host build commands.

`build-map.yaml` is the single target and build-set registry. It declares each
set's target membership and each target's builder, source preparation flow,
source checkout, Debian metadata directory, and repository/path impact rules.
The only builders are `direct` and `debian`.
Direct flows run project-specific tools on the native host; the current flows
are `kernel-worktree`, `kernel-stable-tarball`, `sof-firmware`,
`sky1-firmware`, `sky1-firmware-engineering`, and `pmtool`.
Debian source flows are `quilt`,
`debian-git`, `native`, and `payload`, independently of the selected
sbuild/local backend. `cix-build`
resolves its target from this file, and the CI planner reads the same data.
Package names and source paths are therefore not duplicated in Shell dispatch
tables.

The planner normally discovers produced package names from Debian `control`
files used by the standard Debian builder. A direct target is outside that
source-package parser, so it may declare only the package identities needed by
the dependency graph with `build_packages` and `build_provides`. The kernel
uses these fields for its generated private `cix-linux-libc-dev` package, and
the SOF flow declares `cix-audio-sof`. A consuming package still expresses the
dependency only in its own `Build-Depends`.

All build paths use the host's full `nproc` value, including native kernel
`make bindeb-pkg`, its nested `dpkg-buildpackage` invocation, Debian package
backends, and DKMS compatibility tests.
Target outputs are written to `output/TARGET`.
Each build removes that target's previous top-level artifact files before
starting, so a persistent Jenkins workspace cannot publish stale packages.

Direct kernel flows, local `dpkg-buildpackage`, and sbuild use compiler wrappers
and share the host cache at
`~/.cache/cix-neo-sbuild/ccache`, with a shared 20 GB size limit.
Isolated sbuild sessions also share downloaded Debian archives at
`~/.cache/cix-neo-sbuild/apt-archives`. Each disposable chroot keeps its own
APT working directory and exchanges only real downloaded archives with this
cache; sbuild's temporary dependency packages and APT state are never shared.
Unchanged dependencies therefore do not need to be downloaded again.

The VPU DKMS package retains its runtime dependency on `cix-vpu-firmware`.
Its `cix-vpu-driver-dev` binary package provides the userspace V4L2 controls
header. CIX FFmpeg declares build dependencies on that package,
`cix-libva-dev`, and the CIX kernel UAPI package; the planner therefore
schedules kernel, VPU, and VA-API changes before rebuilding FFmpeg. Those three
output sets are the only internal package sets published to FFmpeg's temporary
sbuild archive.
Payload targets package selected files and directories from the
manifest-managed `cix_proprietary/cix_proprietary` repository. They fetch only
the mapped paths' Git LFS objects when `repo sync` leaves pointer files in the
checkout; they do not materialize every LFS object in the proprietary repo.
An explicitly configured `lfs.url` is respected, while hosts without one use
the central CIX artifact service for downloads instead of the Gitolite mirror.
The AI engine and MNN targets install their Python modules through Debian's
package build, so installing their debs never invokes `pip` from a maintainer
script. The MNN package is built for Debian 13's CPython 3.13 ABI and removes
the upstream wheel's build-machine RPATH before packaging it.
The `gstreamer-6.6` overlay retains the product's FDK-AAC plugin, so the canonical
host dependency list and sbuild chroot enable Debian's `non-free` component in
addition to `main`. Its private video development interface is shipped in
`cix-gstreamer-dev`; NNStreamer consumes that interface, NOE, and libcme
through normal `Build-Depends` and keeps its runtime plugins under
`/usr/share/cix`.

The Linux 7.0 media stack is independent. `gstreamer-base-7.0` and
`gstreamer-good-7.0` start from revision-pinned Debian Salsa packaging, retain
the Debian 13 stable/security patch level, and append the CIX AFBC and V4L2
patch series in an isolated work directory. They rebuild Debian's standard
binary package names and install to standard system paths; they do not include
the private `cixsr`/NOE integration from the Linux 6.6 overlay. The build map
derives the good-to-base ordering from the Salsa `debian/control` files.

## Adding a package

For a conventional native or quilt source package, add its packaging metadata
under `debian/` and add one target plus the relevant project/path rule to
`build-map.yaml`. Select the `debian` builder and its `native` or `quilt` flow,
then set the fields required by that flow. DKMS packages may add
`validate: dkms` to check the source name and version against `dkms.conf`.
Quilt targets may declare `source_excludes` for repository paths that are not
part of the source build or binary packages. NNStreamer uses this to omit its
large demo-model and disabled test-data directories from the repacked source
archive.

For a source repository that already contains maintained Debian packaging,
use the `debian-git` flow. Keep only the downstream changelog entries and
additional quilt patches under the target's `debian/` overlay directory.
Small packaging additions such as documented Lintian overrides may mirror
their paths below that directory. The flow preserves the source repository's
`debian/control`, package split, and build rules rather than copying them into
this project.

When one Debian source package genuinely combines multiple manifest projects,
the same quilt flow may declare `source_overlays` entries as
`WORKSPACE_SOURCE=SOURCE_SUBDIRECTORY`. Changes in every contributing project
still map to the one target; the package dependency graph remains in
`debian/control`.

The `wlan-dkms` target uses that overlay mechanism to combine the QCA FC6XE
and Realtek RTL8852B repositories into one DKMS source package. A change in
either repository selects the same target. Its firmware relationship remains
the runtime `Depends` field in `debian/wlan-dkms/control`, not a build-script
dependency.

No Shell function or per-package script is needed for another conventional
package. A project that cannot use standard Debian packaging uses the `direct`
builder and a focused flow implementation, such as the kernel or SOF firmware
flows. Package build dependencies remain exclusively in `debian/control`.

## Build host dependencies

On a newly installed native ARM64 Debian 13 host, install the complete project
toolchain as a regular user with sudo access:

```bash
./build-scripts/setup-host
```

This is the canonical host-package list for repository synchronization, direct
builds, local and sbuild Debian package builds, DKMS compatibility tests, and CI
planning/static validation. The command is idempotent: it installs only missing
packages. Use `--check` for a read-only readiness check,
`--list-packages` to print the maintained Debian package list, or `--dry-run`
to show installation commands without executing them.

## sbuild environment

After cloning or syncing the workspace, create the unprivileged sbuild
environment:

```bash
./build-scripts/setup-sbuild
```

The script invokes `setup-host`, validates native ARM64 user namespace support,
provisions dedicated temporary and ccache directories, and creates an sbuild
unshare tarball with `mmdebstrap`. It also provisions the persistent APT archive
cache used by the project-owned sbuild configuration. Therefore, running
`setup-sbuild` alone on a
new host installs the same complete dependency set before creating the chroot.
Both setup and package builds validate that an existing chroot enables the
required `trixie` archive components. If a previously created chroot is no
longer compatible, rebuild it with `setup-sbuild --force`.

Use `--help` to see mirror, tarball, and rebuild overrides.

## DKMS compatibility tests

The drivers depend on CIX-specific kernel interfaces and do not support a
generic upstream kernel. After building the packages, compile each module
against the headers produced by the CIX kernel build:

```bash
./build-scripts/tests/dkms.sh gpu-dkms
./build-scripts/tests/dkms.sh bt-dkms
./build-scripts/tests/dkms.sh vpu-dkms
./build-scripts/tests/dkms.sh npu-dkms
./build-scripts/tests/dkms.sh isp-v4l2-dkms
./build-scripts/tests/dkms.sh isp-dkms
./build-scripts/tests/dkms.sh wlan-dkms
```

The test command derives the binary package name from the target's Debian
control file. It extracts both debs into a disposable directory and gives DKMS
isolated source, state, and module trees. It does not install packages or write
to the host `/usr/src`, `/var/lib/dkms`, or `/lib/modules` trees. Jenkins may
pass exact artifacts with `--kernel-headers` and `--package`.

## CI build planning

`build-map.yaml` maps manifest projects and changed paths to build targets and
also supplies their build recipes. It contains no package dependency
relationships. `ci/plan.py` parses the Debian control files referenced by the
targets and derives internal build edges from `Build-Depends`,
`Build-Depends-Arch`, and `Build-Depends-Indep`.

Validate the complete mapping and dependency graph:

```bash
./build-scripts/ci/plan.py --check
```

Generate a plan from a changed project or path:

```bash
./build-scripts/ci/plan.py cix_opensource/linux
./build-scripts/ci/plan.py cix-linux-main
./build-scripts/ci/plan.py \
  cix_proprietary/cix_proprietary:cix_proprietary-debs/cix-vpu-umd/usr/lib/firmware/h264dec.fwb
./build-scripts/ci/plan.py \
  cix_opensource/gpu_kernel:drivers/gpu/arm/midgard/mali_kbase_core_linux.c
```

For Jenkins execution, print the topologically ordered commands:

```bash
changed_projects | ./build-scripts/ci/plan.py --format text --mode commands
```

Unmapped non-ignored paths, a missing executor or controls, duplicate package
providers, and dependency cycles are fatal validation errors.

The eventual CI deployment is company-internal Jenkins. This repository does
not define a GitHub-hosted build workflow.
