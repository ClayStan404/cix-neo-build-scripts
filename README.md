# Build System

This directory contains the CIX Neo build command and its small set of shared
build engines. It does not use the legacy build-system CLI, per-module script
naming, or framework contract.

Build the current CIX kernel, DKMS, and boot configuration packages:

```bash
./build-scripts/cix-build kernel --nexus zj
./build-scripts/cix-build stable-kernel --nexus zj
./build-scripts/cix-build gpu-dkms --nexus zj
./build-scripts/cix-build vpu-dkms --nexus zj
./build-scripts/cix-build vpu-firmware --nexus zj
./build-scripts/cix-build npu-dkms --nexus zj
./build-scripts/cix-build grub-config --nexus zj
```

The supported build host baseline is native ARM64 Debian 13. Other Debian and
Ubuntu host releases are intentionally outside the current scope.

There are two independent native kernel targets. `kernel` builds the CIX 6.6
development kernel using its kernel-owned configuration fragments and the
external temporary fix in `debian/kernel/patches/`. `stable-kernel` uses the
`cix-linux-kernel` harness to build its currently supported upstream stable
release (7.0.13 at the time of writing) with the patch set and defconfig from
the separately manifest-managed `cix-linux-main` checkout. Both use
`make bindeb-pkg`; neither uses `sbuild`.
The stable harness owns the selected kernel version and currently emits a
`-cix` kernel release (for example, `7.0.13-cix`). The new system does not
retain the legacy fixed `7.0.0-generic` package name.

GPU, VPU, and NPU create standard Debian source packages and build them with
`sbuild`. All targets use the single `cix-build` entry point. Files under
`builders/` implement reusable build types, not package lists or independent
commands. `cix-grub-config` is a native package owned entirely by the Debian
metadata repository.

`build-map.yaml` is the single target registry. It declares each target's
builder, source checkout, Debian metadata directory, and repository/path impact
rules. `cix-build` resolves its target from this file, and the CI planner reads
the same data. Package names and source paths are therefore not duplicated in
Shell dispatch tables.

Defaults live in `cix-build.conf`. Environment variables can override the
file, and command-line options override both. Pass an alternate file as the
first option with `cix-build --config FILE TARGET`.

The Nexus selector chooses an internal download endpoint for non-sbuild build
flows that fetch private inputs. It is not an APT or sbuild setting and is not
propagated into standard sbuild package builds.

The VPU DKMS package retains its runtime dependency on `cix-vpu-firmware`.
The firmware target packages the 16 proprietary `.fwb` files from the
manifest-managed `cix_proprietary/cix_proprietary` repository. It fetches only
that path's Git LFS objects when `repo sync` leaves pointer files in the
checkout; it does not materialize every LFS object in the proprietary repo.

## Adding a package

For a conventional native or quilt source package, add its packaging metadata
under `debian/` and add one target plus the relevant project/path rule to
`build-map.yaml`. Select the generic `sbuild` builder, set `source_git` and
`debian`, and set `source` for a quilt source package. DKMS packages may add
`validate: dkms` to check the source name and version against `dkms.conf`.

No Shell function or per-package script is needed for another conventional
package. A new engine is justified only when a package cannot be represented by
an existing build type. Package build dependencies remain exclusively in
`debian/control`.

## sbuild Environment

Run the setup script on ARM64 Debian 13 as a regular user with sudo access:

```bash
./build-scripts/setup-sbuild
```

The script installs missing host prerequisites, validates native ARM64 user
namespace support, provisions dedicated temporary and ccache directories, and
creates an sbuild unshare tarball with `mmdebstrap`.

Use `--help` to see distribution, mirror, tarball, and rebuild overrides.

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
./build-scripts/ci/plan.py cix-linux-kernel
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
