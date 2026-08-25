# Build System

This directory contains the CIX Neo build command and its small set of shared
build engines. It does not use the legacy build-system CLI, per-module script
naming, or framework contract.

Build one complete CIX kernel stack at a time:

```bash
./build-scripts/cix-build all-6.6
./build-scripts/cix-build all-7.0
./build-scripts/cix-build pm-validation
./build-scripts/cix-build pm-gb1-2700
./build-scripts/cix-build pm-tuning
```

Build an individual target with the same command:

```bash
./build-scripts/cix-build kernel
./build-scripts/cix-build stable-kernel
./build-scripts/cix-build audio-sof
./build-scripts/cix-build radxa-o6-firmware
./build-scripts/cix-build radxa-o6n-firmware
./build-scripts/cix-build radxa-o6-pm-validation
./build-scripts/cix-build radxa-o6-opp-validation
./build-scripts/cix-build radxa-o6-gb1-2700-experiment
./build-scripts/cix-build radxa-o6-pm-tuning
./build-scripts/cix-build radxa-o6n-pm-validation
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
`stable-kernel`, `audio-sof`, `radxa-o6-firmware`, and `radxa-o6n-firmware`;
those always execute
their target-owned native build flow.
A build set stops at the first failed target. `cix-build all-6.6 clean` and
`cix-build all-7.0 clean` clean their targets in reverse dependency order.
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

`radxa-o6-firmware` and `radxa-o6n-firmware` build the Radxa Orion O6 and O6N
EDK2 firmware directly on the ARM64 host. Both targets use the O6 and O6N board
support based on the manifest-pinned CIX EDK2 source. Until the corresponding
internal changes are merged, the O6N source and packaging changes are carried
under `build-scripts/patches/radxa-o6n`. The shared flow creates isolated Git
worktrees under `output/TARGET/work` and applies the patches there, so repo
checkouts remain clean. If the changes are later present upstream, the flow
detects that and skips the patches. Repo also supplies the pinned EDK2
dependencies, ACPICA, and the CIX internal firmware payload. The flow publishes
each board's flash and OCB images under its own `output/TARGET/images`
directory; it does not create Debian packages and is not affected by
`--backend`.

`radxa-o6-pm-validation`, `radxa-o6-opp-validation`, and
`radxa-o6n-pm-validation` are deliberately kept
outside the `all-6.6` and `all-7.0` product sets and are grouped only by the
explicit `pm-validation` set. The PMIC targets build the same firmware from isolated
worktrees, but enable the existing v3.0 custom PMIC section with the board's
documented stock limits and voltage offsets. The flow verifies the PM config
signature, checksum, limits, and rail fields before publishing
`csu_pm_config_BOARD_pmic.bin`. The O6 OPP target additionally enables the
12 source-stock OPP tables already shipped by CIX PackageTool and verifies
every table entry before publishing `csu_pm_config_O6_stock-opp.bin`. It does
not increase a frequency or change a voltage relative to that source profile.
The source-stock profile is not claimed to match an installed vendor firmware
release. The normal firmware targets remain unaffected by these experiments.
A successful build proves that the config block is well formed, not that PM
firmware consumed it; that conclusion requires a board boot test.

`radxa-o6-gb1-2700-experiment` is isolated in the explicit `pm-gb1-2700`
set. It layers one controlled change over the source-stock profile: the final
GB1 OPP changes from 2600 MHz at 920 mV to 2700 MHz at 950 mV. The verifier
rejects any other OPP-table difference. This experiment is never included in
a product build set and must be used only on a recoverable O6 test board.

`radxa-o6-pm-tuning` provides Vendor/Automatic, Experimental, and
Expert/Custom profiles in
the O6 UEFI setup menu under `Device Manager -> Platform Configuration ->
Advanced Configuration -> Power Management`. Vendor/Automatic disables the
external OPP table so PM firmware can use its native OPN/Vmin/guardband path.
Experimental and Expert/Custom enable a complete external table. The fixed
2.7 GHz profile is experimental rather than validated for a retail Radxa O6;
the available K000086 results came from a different internal EVB.
Expert/Custom permits edits to the non-startup OPPs of GB0, GB1, GM0, and GM1
within 800-3200 MHz and 550-1250 mV in steps of 10. These are input boundaries,
not safe operating guarantees. It enforces increasing frequencies and
non-decreasing voltages. Changed OPP power costs are conservatively scaled with
frequency and voltage squared. Startup OPPs, DSU, and non-CPU domains remain
locked. All profiles remove the legacy CPU cap so it cannot mask PM firmware's
selected table. On the following boot, a DXE driver validates the submitted
settings and complete current v3.0 PM block, updates the external-table state,
recalculates the checksum, writes the dedicated PM flash entry, reads back and
compares the complete entry, then performs one additional cold reset.
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
unbounded reset loop. Product (`pr`) and prototype images are source-built and
verified. The `pr2` image remains the manifest-pinned binary because its
private signing key is available only through RKMS. PM and PBL target payloads
also remain version-matched manifest binaries because their source build needs
the licensed Xtensa toolchain, which Debian does not provide.

The same set publishes the manifest-pinned ARM64 CIX `pmtool` binary at
`output/pmtool/pmtool`. On the O6 test board, capture the effective PM firmware
table before and after flashing a validation image with:

```bash
sudo ./pmtool cli opp_config
```

Run it from the copied artifact's directory. The command needs privileged
hardware access and is never executed automatically by the build system.
The full recovery-gated board procedure is documented in
[`docs/pm-validation.md`](docs/pm-validation.md).

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
`radxa-firmware`, `radxa-pm-validation`, `radxa-opp-validation`,
`radxa-opp-experiment`, `radxa-pm-tuning`, and `pmtool`.
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
