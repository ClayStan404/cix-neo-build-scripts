# Build System

This directory contains the CIX Neo build command and its small set of shared
build engines. It does not use the legacy build-system CLI, per-module script
naming, or framework contract.

Build the current CIX kernel, DKMS, and boot configuration packages:

```bash
./build-scripts/cix-build all
./build-scripts/cix-build kernel
./build-scripts/cix-build stable-kernel
./build-scripts/cix-build audio-sof
./build-scripts/cix-build radxa-o6-firmware
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
./build-scripts/cix-build gstreamer
./build-scripts/cix-build nnstreamer
./build-scripts/cix-build wlan-dkms
```

`all` builds every registered target in the dependency order calculated from
Debian `Build-Depends`. The default Debian package backend is `sbuild`. Select
direct host builds for all conventional Debian packages with:

```bash
./build-scripts/cix-build all --backend local
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
`stable-kernel`, `audio-sof`, and `radxa-o6-firmware`; those always execute
their target-owned native build flow.
The full build stops at the first failed target. `cix-build all clean` cleans
targets in reverse dependency order. Every target reports its elapsed time as
`HH:MM:SS`, and a successful full build reports the total elapsed time. On
failure, the command reports the failed target's elapsed time and the total
time before stopping.

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

`radxa-o6-firmware` builds the Radxa Orion O6 EDK2 firmware directly on the
ARM64 host. Repo supplies the three EDK2 trees, their pinned dependencies,
ACPICA, and the CIX internal firmware payload. The flow uses the upstream CIX
package scripts and publishes the flash and OCB images under
`output/radxa-o6-firmware/images`; it does not create a Debian package and is
not affected by `--backend`.

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
installed on the host. This also applies to `cix-build all --backend local`:
the command builds in dependency order but does not install private build
dependencies into the host. The sbuild backend resolves dependencies inside
its clean build environment. It also exposes previously built packages from
`output/*` through sbuild's temporary package archive. An internal package
named by the target's transitive `Build-Depends` closure selects the output set
that supplied it. The non-debug binary packages from those source builds are
published together so APT can resolve their package-level `Depends`; output
sets from unrelated targets remain excluded. A Lintian policy violation fails
the sbuild invocation, even when package compilation itself succeeded.
`--backend` is rejected for individual `direct` targets because those flows
already define their own host build commands.

`build-map.yaml` is the single target registry. It declares each target's
builder, source preparation flow, source checkout, Debian metadata directory,
and repository/path impact rules. The only builders are `direct` and `debian`.
Direct flows run project-specific tools on the native host; the current flows
are `kernel-worktree`, `kernel-stable-tarball`, `sof-firmware`, and
`radxa-o6-firmware`. Debian source flows are `quilt`, `native`, and `payload`,
independently of the selected sbuild/local backend. `cix-build` resolves its
target from this file, and the CI planner reads the same data. Package names
and source paths are therefore not duplicated in Shell dispatch tables.

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
The AI engine and MNN targets install their Python modules through Debian's
package build, so installing their debs never invokes `pip` from a maintainer
script. The MNN package is built for Debian 13's CPython 3.13 ABI and removes
the upstream wheel's build-machine RPATH before packaging it.
The GStreamer overlay retains the product's FDK-AAC plugin, so the canonical
host dependency list and sbuild chroot enable Debian's `non-free` component in
addition to `main`. Its private video development interface is shipped in
`cix-gstreamer-dev`; NNStreamer consumes that interface, NOE, and libcme
through normal `Build-Depends` and keeps its runtime plugins under
`/usr/share/cix`.

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
