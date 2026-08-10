# CIX Neo Build System Requirements

This document is the living record of the requirements agreed during the
design of the new build system. Update it whenever a requirement or decision
is confirmed.

## Confirmed Requirements

### Project Direction

- This is a greenfield rewrite.
- Push completed commits to each repository's configured remote as part of the
  same workflow unless the user explicitly requests a local-only commit.
- Do not provide compatibility with the legacy build system, its CLI, its
  configuration files, or its internal module contract.
- Legacy implementation ideas may be studied and reused selectively, but no
  legacy behavior is retained by default.

### Build Architecture

- Replace the legacy x86-hosted ARM64 cross-compilation workflow.
- Run the new build system natively on ARM64 machines.
- Support ARM64 Debian 13 as the build host baseline. Debian 12, Ubuntu, and
  other host distributions are outside the current scope.
- Build software as standard Debian packages using conventional Debian package
  build workflows.
- Use `sbuild` as the Debian package build backend for conventional source
  packages.
- Build the Linux kernel natively with its own `bindeb-pkg` make target rather
  than running the kernel build through `sbuild`.
- Maintain two independent kernel targets: the CIX 6.6 development kernel and
  the newest stable kernel release supported by `cix-linux-kernel`.
- Build the stable kernel through the native flow owned by
  `cix-linux-kernel`, using the CIX defconfig and patch series from the
  manifest-managed `cix-linux-main` checkout. Do not fetch an untracked patch
  branch during the build.
- Follow the stable harness's currently supported kernel version and `-cix`
  kernel release identifier. Do not preserve the legacy fixed
  `7.0.0-generic` binary package name in the greenfield build system.
- Compose the kernel configuration from the configuration targets stored in
  the kernel source tree. Do not maintain copied kernel configuration files in
  the external Debian metadata repository.
- Keep temporary downstream kernel fixes under `debian/kernel/patches/` and
  apply them to a disposable Git worktree. Do not modify the manifest-managed
  kernel checkout during a build.
- Maintain the complete Debian 13 ARM64 host dependency list in the executable
  `build-scripts/setup-host`. A newly installed build machine must be able to
  install all repository, native kernel, sbuild, DKMS test, and CI validation
  tools by running that command once.
- Keep `build-scripts/setup-host` idempotent and make
  `build-scripts/setup-sbuild` reuse it rather than maintaining a second host
  package list.
- Provide a self-contained environment setup script at
  `build-scripts/setup-sbuild` so a new ARM64 Debian host can install the
  required host tools and provision a clean sbuild environment directly.
- Use an unprivileged `sbuild` unshare backend with a build chroot tarball
  created by `mmdebstrap`.
- Use `trixie` as the default build distribution. Never derive the build
  distribution from the host OS release.
- Keep compiler caches user-scoped under the user's XDG cache directory by
  default.
- Treat the Nexus selector as an internal download-endpoint choice for
  non-sbuild projects that fetch private inputs. It is not an APT mirror or an
  sbuild setting and must not be propagated into standard sbuild builds.
- Validate GPU, VPU, and NPU DKMS packages by compiling their modules against
  the headers package produced by the CIX kernel build. Generic upstream
  kernel headers are not a supported test target.
- Use external `3.0 (quilt)` Debian metadata for upstream DKMS source projects
  and proprietary firmware payloads. Use `3.0 (native)` for packages whose
  source is owned by the Debian metadata repository.

### Source Management

- Continue to support the Android `repo` tool and repo manifest format for
  managing the multi-repository source workspace.
- Use Debian's package-managed `/usr/bin/repo` launcher. Configure `REPO_URL`
  as `ssh://git@gitmirror.cixcomputing.com/android_repo/git-repo` and
  `REPO_REV` as `stable` so the upstream Repo implementation is fetched from
  the internal mirror without adding options to every `repo init` command.
- Do not use or vendor the legacy CIX launcher or the `cix-stable` Repo branch;
  their Nexus and smart-cache extensions are outside the rewritten system.
- Host the new minimal manifest in the private GitHub repository
  `https://github.com/ClayStan404/cix-neo-manifest.git` on branch `master`.
- Keep the existing internal Linux and GPU source repository URLs and source
  branches.
- Temporarily host new build-system repositories on private GitHub repositories
  until the build system is complete and matching internal repositories can be
  created. Then migrate the repositories and update their manifest entries.
- Use `default.xml` as the default manifest so a workspace needs only the
  manifest repository URL and branch during `repo init`.
- Initialize and synchronize a workspace with:

  ```bash
  repo init -u git@github.com:ClayStan404/cix-neo-manifest.git -b master
  repo sync
  ```

- Let `repo init` manage the manifest checkout under `.repo/manifests/`; do not
  maintain a duplicate manifest directory at the workspace root.
- Do not copy the complete manifest set from the legacy build system.
- Maintain a minimal, curated manifest for the new system.
- Add a source repository to the manifest only when its corresponding build
  module is introduced and needed.
- Keep upstream source checkouts in a dedicated source directory.
- Track `cix_opensource/linux` at branch `cix_6.6_master_dev` under
  `sources/linux`.
- Track `cix-oss/cix-linux-kernel` at branch `master` under
  `sources/linux-stable`.
- Track `cixtech/cix-linux-main` at branch `main` under
  `sources/linux-main`.
- Track `cix_opensource/gpu_kernel` at branch `cix_r54p1-11eac0_dev` under
  `sources/gpu-kernel`.
- Track `cix_opensource/vpu_driver` at branch `cix_vpu_dev` under
  `sources/vpu-driver`.
- Track `cix_proprietary/cix_proprietary` at branch `cix_master_linux_lfs`
  under `sources/cix-proprietary` for the proprietary VPU firmware payload.
  Keep this source on the internal server; do not mirror its binaries to the
  temporary GitHub repositories.
- Track `cix_opensource/npu_driver` at branch `cix_x2_r2p1_dev` under
  `sources/npu-driver`.
- Track the private GitHub repository `ClayStan404/cix-neo-build-scripts` at
  branch `master` under `build-scripts`.
- Track the private GitHub repository `ClayStan404/cix-neo-debian` at branch
  `master` under `debian`.
- The current manifest contains exactly nine projects: seven source and build
  input repositories, the build scripts, and the Debian packaging metadata.

### Project Layout

- `.repo/manifests/`: the manifest repository checkout managed by `repo`.
- Workspace root: the `repo` client root containing `.repo/`.
- `sources/`: upstream source checkouts managed by the root repo client.
- `debian/`: repo-managed Debian packaging metadata, kept separate from
  upstream sources.
- `build-scripts/`: repo-managed single build command and its shared build
  engines.
- `build-scripts/builders/`: internal, reusable build-type implementations;
  adding a conventional package must not add a builder file.
- `build-scripts/tests/`: executable build-output compatibility tests. Keep a
  single parameterized DKMS test command rather than per-package wrappers, and
  do not place `test-*` scripts at the build-scripts root.

### Configuration

- The build system must support explicit configuration.
- Target build logic must be able to select different execution paths based on
  the resolved configuration.
- Expose one public command: `build-scripts/cix-build TARGET`. Do not create
  legacy-style per-target `build-*.sh` entry points.
- Keep `build-scripts/build-map.yaml` as the single registry for target names,
  build types, source locations, Debian metadata locations, and CI repository
  impact rules. Local builds and CI planning must read the same registry.
- Implement reusable build types rather than package-specific Shell dispatch.
  Adding another conventional native or quilt source package must require only
  its Debian metadata and declarative mapping entries, not a new build script or
  Shell function.
- Keep defaults in the flat `build-scripts/cix-build.conf` file. Environment
  variables override that file and command-line options override both.
- Default build parallelism to the host's `nproc` value. A resolved
  `--jobs COUNT` must control every nested build layer, including native
  kernel `bindeb-pkg`, `dpkg-buildpackage`, sbuild, and DKMS validation. Pass
  native kernel jobs through `DPKG_FLAGS=--jobs=COUNT` so they override the
  upstream packaging rule's internal `dpkg-buildpackage -j1`.
- Declare and resolve common settings only once. Target implementations contain
  only build-type behavior; shared engines are not standalone targets and must
  not encode package dependency relationships.
- The baseline configuration includes a Nexus site selector with these values:
  - `sh`: Shanghai
  - `zj`: Zhangjiang
  - `wuh`: Wuhan
  - `szv`: Suzhou
  - `ksh`: Kunshan
  - `wux`: Wuxi
  - `release`: release service
  - `public`: customer-facing public service

### CI Change Impact and Dependencies

- Maintain a machine-readable mapping from each manifest project and relevant
  changed path to one or more targets executed through `cix-build`.
- Keep repository/path impact mapping separate from package dependency data.
- Derive internal package build edges from the source stanza fields
  `Build-Depends`, `Build-Depends-Arch`, and `Build-Depends-Indep` in each
  target's Debian control file.
- Do not declare dependencies in target implementations, and do not let one
  build target invoke another build target.
- When a changed target provides a package used by another target's build
  dependencies, include all transitive reverse build dependencies in the CI
  plan.
- Execute selected targets in deterministic topological order, with
  dependencies before dependents.
- Treat unmapped non-ignored paths, a missing build executor or control file,
  duplicate internal package providers, and dependency cycles as CI planning
  errors.
- Do not interpret binary package `Depends` as a rebuild edge. Express
  compatibility test triggers through Debian test metadata instead of fake
  build dependencies.
- The initial GPU DKMS source package has no build dependency on the kernel
  target: it ships module source, and DKMS compiles that source for installed
  compatible kernels on the target system.
- VPU and NPU follow the same DKMS source-package model. Their compatibility
  with the CIX kernel is validated separately and is not represented as a fake
  `Build-Depends` edge.
- Run CI in the company-internal Jenkins deployment. Do not add a GitHub-hosted
  build workflow.

### Current Implemented Scope

The current build system contains these build modules:

1. CIX 6.6 development Linux kernel
2. CIX-patched latest stable Linux kernel
3. GPU DKMS package
4. VPU DKMS package
5. VPU firmware package
6. NPU DKMS package
7. CIX GRUB configuration package

The VPU DKMS package must retain its runtime dependency on
`cix-vpu-firmware`. Its 16 proprietary `.fwb` files come from the
`cix-vpu-umd/usr/lib/firmware` staging directory in
`cix_proprietary/cix_proprietary`, not from the open-source VPU driver. Fetch
only those Git LFS objects when assembling the firmware source package.

## Legacy Reference

- Legacy workspace: `/home/claystan/cix-repo`
- New build-system workspace: `/home/claystan/cix-neo-bs`
- The legacy system cross-compiles ARM64 software on x86 hosts and uses `repo`
  manifests to manage the full source workspace.

## Decisions Still To Be Made

- Output repository/layout and artifact naming conventions.
- Container, CI, caching, signing, and publishing requirements.
- Nexus URL mapping, authentication, and access policy for each site selector.
