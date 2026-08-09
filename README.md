# Build System

This directory contains the new configuration-driven build orchestration
and module implementations. It must not depend on the legacy build-system CLI
or framework contract.

The initial modules are the Linux kernel and GPU DKMS package:

```bash
./build-scripts/build-kernel.sh --nexus zj build
./build-scripts/build-gpu-dkms.sh --nexus zj build
```

The supported build host baseline is native ARM64 Debian 13. Other Debian and
Ubuntu host releases are intentionally outside the current scope.

The kernel module builds natively with the kernel-owned configuration fragments
and the `bindeb-pkg` make target. Before configuration it creates a temporary
Git worktree and applies the ordered patch series from
`debian/kernel/patches/series`; the manifest-managed kernel checkout remains
unchanged. The GPU module creates a standard Debian source package and builds
it with `sbuild`.

## sbuild Environment

Run the setup script on ARM64 Debian 13 as a regular user with sudo access:

```bash
./build-scripts/setup-sbuild.sh
```

The script installs missing host prerequisites, validates native ARM64 user
namespace support, provisions dedicated temporary and ccache directories, and
creates an sbuild unshare tarball with `mmdebstrap`.

Use `--help` to see distribution, mirror, tarball, and rebuild overrides.

## GPU DKMS compatibility test

The GPU driver depends on CIX-specific kernel interfaces and does not support a
generic upstream kernel. After building both packages, compile the modules
against the headers produced by the CIX kernel build:

```bash
./build-scripts/test-gpu-dkms.sh
```

The script extracts both debs into a disposable directory and gives DKMS
isolated source, state, and module trees. It does not install packages or write
to the host `/usr/src`, `/var/lib/dkms`, or `/lib/modules` trees. Jenkins may
pass exact artifacts with `--kernel-headers` and `--gpu-package`.

## CI build planning

`ci/build-map.yaml` maps manifest projects and changed paths to build targets.
It contains no package dependency relationships. `ci/plan.py` parses the
Debian control files referenced by the targets and derives internal build edges
from `Build-Depends`, `Build-Depends-Arch`, and `Build-Depends-Indep`.

Validate the complete mapping and dependency graph:

```bash
./build-scripts/ci/plan.py --check
```

Generate a plan from a changed project or path:

```bash
./build-scripts/ci/plan.py cix_opensource/linux
./build-scripts/ci/plan.py \
  cix_opensource/gpu_kernel:drivers/gpu/arm/midgard/mali_kbase_core_linux.c
```

For Jenkins execution, print the topologically ordered scripts:

```bash
changed_projects | ./build-scripts/ci/plan.py --format text --mode scripts
```

Unmapped non-ignored paths, missing scripts or controls, duplicate package
providers, and dependency cycles are fatal validation errors.

The eventual CI deployment is company-internal Jenkins. This repository does
not define a GitHub-hosted build workflow.
