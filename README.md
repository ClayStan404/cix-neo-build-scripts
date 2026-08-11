# Build System

This directory contains the CIX Neo build command and its small set of shared
build engines. It does not use the legacy build-system CLI, per-module script
naming, or framework contract.

Build the current CIX kernel, DKMS, and boot configuration packages:

```bash
./build-scripts/cix-build kernel
./build-scripts/cix-build stable-kernel
./build-scripts/cix-build gpu-dkms
./build-scripts/cix-build vpu-dkms
./build-scripts/cix-build vpu-firmware
./build-scripts/cix-build npu-dkms
./build-scripts/cix-build grub-config
```

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

GPU, VPU, NPU, firmware, and boot configuration targets create standard Debian
source trees with the shared `debian` builder. Its default backend is `sbuild`;
pass `--backend local` to run `dpkg-buildpackage` directly on the host instead.
All targets use the single `cix-build` entry point. Files under `builders/`
implement reusable build models and source-assembly flows, not package lists or
independent commands. `cix-grub-config` is a native package owned entirely by
the Debian metadata repository.

```bash
./build-scripts/cix-build gpu-dkms                 # isolated sbuild
./build-scripts/cix-build gpu-dkms --backend local # host dpkg-buildpackage
```

The local backend requires the package's `Build-Depends` to already be
installed on the host. The sbuild backend resolves them inside its clean build
environment. `--backend` is rejected for `direct` targets because those flows
already define their own host build commands.

`build-map.yaml` is the single target registry. It declares each target's
builder, source preparation flow, source checkout, Debian metadata directory,
and repository/path impact rules. The only builders are `direct` and `debian`.
Direct flows run project-specific tools on the native host; the current kernel
flows are `kernel-worktree` and `kernel-stable-tarball`. Debian source flows are
`quilt`, `native`, and `firmware`, independently of the selected sbuild/local
backend. `cix-build` resolves its target from this file, and the CI planner
reads the same data. Package names and source paths are therefore not duplicated
in Shell dispatch tables.

All build paths use the host's full `nproc` value, including native kernel
`make bindeb-pkg`, its nested `dpkg-buildpackage` invocation, Debian package
backends, and DKMS compatibility tests.
Target outputs are written to `output/TARGET`.
Each build removes that target's previous top-level artifact files before
starting, so a persistent Jenkins workspace cannot publish stale packages.

Direct kernel flows, local `dpkg-buildpackage`, and sbuild use compiler wrappers
and share the host cache at
`~/.cache/cix-neo-sbuild/ccache`.

The VPU DKMS package retains its runtime dependency on `cix-vpu-firmware`.
The firmware target packages the 16 proprietary `.fwb` files from the
manifest-managed `cix_proprietary/cix_proprietary` repository. It fetches only
that path's Git LFS objects when `repo sync` leaves pointer files in the
checkout; it does not materialize every LFS object in the proprietary repo.

## Adding a package

For a conventional native or quilt source package, add its packaging metadata
under `debian/` and add one target plus the relevant project/path rule to
`build-map.yaml`. Select the `debian` builder and its `native` or `quilt` flow,
then set the fields required by that flow. DKMS packages may add
`validate: dkms` to check the source name and version against `dkms.conf`.

No Shell function or per-package script is needed for another conventional
package. A project that cannot use standard Debian packaging uses the `direct`
builder and a focused flow implementation, such as the current kernel flow or a
future board-firmware flow. Package build dependencies remain exclusively in
`debian/control`.

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
unshare tarball with `mmdebstrap`. Therefore, running `setup-sbuild` alone on a
new host installs the same complete dependency set before creating the chroot.

Use `--help` to see mirror, tarball, and rebuild overrides.

## DKMS compatibility tests

The drivers depend on CIX-specific kernel interfaces and do not support a
generic upstream kernel. After building the packages, compile each module
against the headers produced by the CIX kernel build:

```bash
./build-scripts/tests/dkms.sh gpu-dkms
./build-scripts/tests/dkms.sh vpu-dkms
./build-scripts/tests/dkms.sh npu-dkms
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
