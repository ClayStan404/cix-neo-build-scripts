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
- Do not recreate the legacy `cix-debian13-k6.6.89-driver` metapackage. Package
  targets are selected and built directly through the new build map.
- Legacy implementation ideas may be studied and reused selectively, but no
  legacy behavior is retained by default.

### Build Architecture

- Replace the legacy x86-hosted ARM64 cross-compilation workflow.
- Run the new build system natively on ARM64 machines.
- Build CIX SOF on the ARM64 host by generating an ARM64-hosted Xtensa GCC
  toolchain from manifest-pinned sources. Xtensa remains the firmware target
  architecture because the firmware executes on the audio DSP; do not reuse
  the legacy x86-hosted prebuilt compiler.
- Build Radxa Orion O6 EDK2 firmware directly on the ARM64 host with the
  upstream CIX package scripts. Publish flash and OCB images rather than a
  Debian package.
- Support ARM64 Debian 13 as the build host baseline. Debian 12, Ubuntu, and
  other host distributions are outside the current scope.
- Build software as standard Debian packages using conventional Debian package
  build workflows.
- Support both `sbuild` and host-local `dpkg-buildpackage` as selectable
  backends for conventional Debian source packages. Keep `sbuild` as the
  default.
- Build the Linux kernel natively with its own `bindeb-pkg` make target rather
  than running the kernel build through `sbuild`.
- Maintain two independent kernel targets: the CIX 6.6 development kernel and
  a pinned upstream stable kernel release.
- Keep the stable-kernel download, patch application, configuration, and
  `bindeb-pkg` flow in `build-scripts`. Use the CIX defconfig and patch series
  from the manifest-managed `cix-linux-main` checkout; do not require a
  separate build-harness repository or fetch an untracked patch branch.
- Pin the stable kernel version declaratively in `build-map.yaml` and use the
  `-cix` kernel release identifier. Do not preserve the legacy fixed
  `7.0.0-generic` binary package name in the greenfield build system.
- Compose the kernel configuration from the configuration targets stored in
  the kernel source tree. Do not maintain copied kernel configuration files in
  the external Debian metadata repository.
- Make `cix-grub-config` recognize both development `vmlinuz-*-generic` and
  stable `vmlinuz-*-cix` kernels, exclude release-candidate and debug kernels,
  and select the highest eligible version for its CIX GRUB entry. Stable CIX
  kernels use `acpi=force clk_ignore_unused`; development
  `*-cix-build-generic` kernels use `acpi=force`.
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
- When the local `dpkg-buildpackage` backend is selected, install the exact
  internal packages named by `Build-Depends`, plus their internal runtime
  dependencies, from mapped build outputs before building a consumer. Do not
  require or install unrelated sibling binary packages.
- Enable Debian's `main` and `non-free` components in the sbuild chroot because
  the required CIX GStreamer feature set includes the FDK-AAC plugin.
- Use `trixie` as the fixed build distribution. Do not derive the build
  distribution from the host OS release or expose an unused suite selector.
- Keep compiler caches at the fixed user-scoped path
  `~/.cache/cix-neo-sbuild/ccache` with a 20 GB size limit shared by local and
  sbuild execution.
- Introduce a Nexus selector only when a direct-build project needs to fetch
  private inputs. It is not an APT mirror or a Debian package backend setting
  and must not be propagated into standard package builds.
- Validate GPU, VPU, and NPU DKMS packages by compiling their modules against
  the headers package produced by the CIX kernel build. Generic upstream
  kernel headers are not a supported test target.
- Use external `3.0 (quilt)` Debian metadata for upstream DKMS source projects
  and proprietary firmware payloads. Use `3.0 (native)` for packages whose
  source is owned by the Debian metadata repository.
- For Debian Salsa packaging repositories, preserve the repository-owned
  `debian/` metadata and append only CIX changelog entries and quilt patches
  in an isolated work directory. Do not copy the complete Salsa packaging into
  the CIX Debian metadata repository. Permit small, documented packaging
  additions such as Lintian overrides without duplicating upstream metadata.
- Maintain separate GStreamer products for the two kernel stacks. Linux 6.6
  uses the private vendor `cix-gstreamer` overlay. Linux 7.0 uses Debian 13's
  standard GStreamer packages rebuilt from Salsa with CIX AFBC and V4L2
  patches; it must not include `cixsr`, NOE, or other Linux 6.6 private-stack
  dependencies.

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
- Track `cixtech/cix-linux-main` at branch `main` under
  `sources/linux-main`.
- Track `cix_opensource/gpu_kernel` at branch `cix_r54p1-11eac0_dev` under
  `sources/gpu-kernel`.
- Track `cix_opensource/bt/rtl_bt_driver` at branch `cix_rtl8852b_dev` under
  `sources/rtl-bt-driver`.
- Track `cix_opensource/vpu_driver` at branch `cix_vpu_dev` under
  `sources/vpu-driver`.
- Track `cix_proprietary/cix_proprietary` at branch `cix_master_linux_lfs`
  under `sources/cix-proprietary` for the proprietary VPU firmware payload.
  Keep this source on the internal server; do not mirror its binaries to the
  temporary GitHub repositories. Respect a host-configured Git LFS download
  URL and otherwise use the central CIX artifact service rather than relying
  on the Gitolite mirror to implement the LFS authentication protocol.
- Track `cix_opensource/npu_driver` at branch `cix_x2_r2p1_dev` under
  `sources/npu-driver`.
- Track `cix_opensource/cix_ai_engine` at branch `cix_master` under
  `sources/cix-ai-engine`.
- Track `github_mirror/alibaba/MNN` at branch `cix_3.6.1_dev` under
  `sources/mnn`.
- Track `freedesktop_repo/gstreamer/gstreamer` at branch `cix_1.26.2_dev`
  under `sources/gstreamer` for the Linux 6.6 private media stack.
- Track Debian Salsa `gstreamer-team/gst-plugins-base1.0` and
  `gstreamer-team/gst-plugins-good1.0` under `sources/debian/` for the Linux
  7.0 standard media stack. Pin the peeled Debian 13 release-tag commits in
  the manifest instead of following Salsa `master`. Check Debian stable and
  security source versions separately because those updates may be published
  before an equivalent Salsa tag exists.
- Track `cix_opensource/nnstreamer` at branch `cix_2.4.2_dev` under
  `sources/nnstreamer`.
- Track `cix_opensource/wlan/fc6xe` at branch `cix_wlan_qcacld_dev` under
  `sources/wlan-qca` and `cix_opensource/wlan/rtl_wlan_driver` at branch
  `cix_rtl8852b_dev` under `sources/wlan-rtl` for the combined WLAN DKMS
  source package.
- Track the SOF firmware inputs under `sources/audio-sof`: crosstool-NG at
  `cix-sof-gcc10x-dev`, Newlib for Xtensa at `xtensa`, SOF at
  `cix-stable-v2.11-dev`, tomlc99 at `master`, and the Xtensa overlay at
  `cix-sof-gcc10.2-dev`.
- Track the Radxa Orion O6 and O6N firmware inputs under `sources/radxa-o6`:
  EDK2, EDK2 non-OSI, and EDK2 platforms at `cix_opensource_firmware`; ACPICA at
  `R2024_12_12`; and `cix_bsp_release` at `cix_master`. Sync the EDK2 gitlinks
  as revision-pinned manifest projects directly in the EDK2 tree, and do not
  include the x86-only AArch64 cross-toolchain on the native ARM64 host. Keep
  O6N as patches against the current CIX EDK2 source until the equivalent
  internal changes are merged. Apply those patches only to isolated build
  worktrees, and automatically skip them when they are already present
  upstream. The build system must not fetch or overlay a separate Radxa EDK2
  tree at build time.
- Reimplement useful performance controls from community firmware in the
  manifest-pinned current CIX EDK2 source; do not depend on or transplant the
  community EDK2 tree. Validate the current v3 PM configuration path before
  adding setup controls. Keep that validation outside the 6.6 and 7.0 product
  build sets, use the board-owned v3.0 generator, preserve its documented stock
  limits and voltage offsets, and reject the generated block unless its version,
  signature, checksum, PMIC scheme, limits, and rail configuration all match.
  First validate external OPP handling with the unmodified stock OPP tables
  shipped by the current CIX PackageTool. Keep this stock-table image separate
  from product builds and reject it unless all domain headers, entries, unused
  slots, and the unconfigured thirteenth domain match exactly. Do not introduce
  higher frequencies or new voltage points until the stock-table image has
  passed a recoverable board test.
- Provide a separate O6 firmware target with BIOS-selectable Vendor/Automatic,
  Experimental, and Expert/Custom PM profiles. Keep source checkouts clean by
  carrying the implementation as a build-time patch. Vendor/Automatic must
  disable the external OPP table so PM firmware can use its native per-part
  OPN/Vmin/guardband path. Experimental and Expert/Custom must enable a complete
  external OPP table. Do not treat frequency/voltage evidence from the internal
  K000086 EVB as qualification of the publicly sold Radxa O6 board.
  Expert/Custom may edit only the non-startup OPPs of GB0, GB1, GM0, and GM1,
  within 800-3200 MHz and 550-1250 mV in steps of 10. These are input boundaries,
  not safe operating guarantees; the voltage boundary reflects the documented
  Big/Mid CPU rail range. Require strictly increasing frequencies and
  non-decreasing voltages within each domain. Conservatively scale each
  changed OPP power cost with frequency and voltage squared, rounding up and
  never reducing the value below the source-stock cost. Do not expose startup
  OPPs, DSU, or non-CPU domains.
  Validate both the submitted settings and the complete existing v3 PM block
  before writing; recalculate the checksum; read back and compare the complete
  PM entry; and cold-reset only after a verified write. The setup-save path
  must also prevent the legacy CPU limit from masking any selected profile.
- Track internal `tools/cix_binary` at commit
  `cf4388565546e14ab4c566e55495cd6757edd92e` under `sources/cix-binary` for
  the ARM64 `pmtool` validation utility. Publish only the checked executable as
  a direct build artifact; verify its architecture and SHA-256, and never run
  its privileged hardware commands automatically.
- Track `freedesktop_repo/mesa/drm` at branch `cix_libdrm_2.4.109_dev` under
  `sources/libdrm`.
- Track `freedesktop_repo/mesa/libglvnd` at branch `cix_glvnd-v1.7.0_dev`
  under `sources/libglvnd`.
- Track `freedesktop_repo/mesa/mesa` at branch `cix_mesa-25.1.5_dev` under
  `sources/mesa`.
- Track `cix_opensource/libva` at branch `cix_2.22_dev` under
  `sources/libva`.
- Track `ffmpeg_repo/ffmpeg` at branch `cix_7.1.1_dev` under
  `sources/ffmpeg`.
- Track `cix_opensource/video_processing` at branch `cix_master` under
  `sources/video-processing` for the CIX Media Engine source.
- Track `cix_opensource/cix-vaapi` at branch `cix_master` under
  `sources/cix-vaapi`.
- Track `cix_opensource/isp_driver` at branch `cix_isp_dev` under
  `sources/isp-driver-v4l2`.
- Track the private GitHub repository `ClayStan404/cix-neo-build-scripts` at
  branch `master` under `build-scripts`.
- Track the private GitHub repository `ClayStan404/cix-neo-debian` at branch
  `master` under `debian`.
- The current manifest contains exactly forty-eight projects: forty-six source
  input repositories, the build scripts, and the Debian packaging metadata.
  Eleven revision-pinned dependency projects populate EDK2's twelve gitlink
  paths; Brotli is reused at two paths.

### Project Layout

- `.repo/manifests/`: the manifest repository checkout managed by `repo`.
- Workspace root: the `repo` client root containing `.repo/`.
- `sources/`: upstream source checkouts managed by the root repo client.
- `debian/`: repo-managed Debian packaging metadata, kept separate from
  upstream sources.
- `build-scripts/`: repo-managed single build command and its shared build
  engines.
- `build-scripts/builders/`: internal implementations for the `direct` and
  `debian` build models and their flows; adding a conventional package must not
  add a builder file.
- `build-scripts/tests/`: executable build-output compatibility tests. Keep a
  single parameterized DKMS test command rather than per-package wrappers, and
  do not place `test-*` scripts at the build-scripts root.

### Configuration

- Expose one public command: `build-scripts/cix-build TARGET|BUILD_SET`. Do not
  create legacy-style per-target `build-*.sh` entry points. Provide separate
  `all-6.6` and `all-7.0` product build sets, and reject the ambiguous bare
  `all` selector. Each set must build its declared targets in dependency order
  and stop on the first failure. Report elapsed time for every target and the
  total elapsed time after a successful set build. A failed build must report
  the failed target's elapsed time before exiting; a failed set build must also
  report its total elapsed time.
- Keep VPU DKMS, VPU firmware, and `cix-grub-config` in both product build
  sets. Keep the CIX Linux 6.6 kernel and legacy CIX GStreamer target in
  `all-6.6`. Keep the stable 7.0 kernel and the Debian Salsa-based GStreamer
  7.0 targets in `all-7.0`; do not include the legacy GPU DKMS target because
  Linux 7.0 uses Panthor.
- Keep `build-scripts/build-map.yaml` as the single registry for target names,
  product build-set membership, build types, source locations, Debian metadata
  locations, and CI repository impact rules. Local builds and CI planning must
  read the same registry.
- Expose only two build models: `direct` for project-specific commands running
  on the native host, and `debian` for standard Debian source-package builds.
  Kernel and future board-firmware builds are direct flows, not builder
  categories. Select source preparation explicitly with a target flow.
- Let the `debian` builder switch between `sbuild` and local
  `dpkg-buildpackage` from the public command. Keep source assembly identical
  between backends and reject the backend option for an individual direct
  target. For a product build set, apply the selected backend only to Debian
  targets and leave direct flows unchanged.
- Keep the backend default at `sbuild`. Select the host build explicitly with
  `cix-build TARGET --backend local`; local builds must check the package's
  `Build-Depends` and fail rather than installing dependencies implicitly.
- Implement reusable build types rather than package-specific Shell dispatch.
  Adding another conventional native or quilt source package must require only
  its Debian metadata and declarative mapping entries, not a new build script or
  Shell function.
- Let quilt targets declaratively exclude repository paths that are not build
  inputs or package outputs. Do not archive large demo models or disabled test
  data merely because they share an upstream repository with buildable source.
- Let a quilt target declaratively assemble multiple manifest repositories
  when they form one Debian source package. Keep this as source preparation in
  the shared quilt flow, and map every contributing repository to the target.
- Keep current defaults in `cix-build`: use all host CPUs and write under
  `output/TARGET`. Do not maintain a separate configuration file until a
  concrete target needs configuration-driven behavior.
- Replace a target's previous top-level artifact files when starting a build
  so persistent CI workspaces cannot publish stale packages.
- Always use the host's full `nproc` value for every nested build layer,
  including native kernel `bindeb-pkg`, `dpkg-buildpackage`, sbuild, and DKMS
  validation. Do not expose a build-job override. Pass the resolved value to
  native kernel packaging through `DPKG_FLAGS=--jobs=COUNT` so it overrides
  the upstream packaging rule's internal `dpkg-buildpackage -j1`.
- Always enable ccache by using Debian's `/usr/lib/ccache` compiler wrappers.
  Direct kernel builds, local `dpkg-buildpackage`, and sbuild share the fixed
  host cache at `~/.cache/cix-neo-sbuild/ccache` with a 20 GB size limit.
- Reuse downloaded Debian archives across disposable sbuild sessions through
  `~/.cache/cix-neo-sbuild/apt-archives`. Keep each chroot's APT working
  directory, package installation, and build state isolated. Exchange only
  real downloaded archives with the persistent cache; never cache sbuild's
  generated build-dependency packages.
- Validate existing sbuild chroots before reuse and before package builds.
  Require both the `main` and `non-free` components for Debian 13, and direct
  users to rebuild stale chroots explicitly with `setup-sbuild --force`.
- Do not declare configuration variables or CLI options until a concrete target
  consumes them.
- Derive one workspace-root path directly from the checked-out layout. Do not
  layer script-directory, workspace-directory, or exported path aliases.
- Group mapped target metadata in one structure and pass action, output, and
  job values to builders explicitly. Keep temporary build state local to the
  builder that owns it.
- Target implementations contain only build-type behavior; shared engines are
  not standalone targets and must not encode package dependency relationships.
- When the first Nexus-consuming target is introduced, support these site
  selector values:
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
- When either Debian backend consumes internal packages, inject the exact
  binary packages named by `Build-Depends` and recursively include their
  internal `Pre-Depends` and `Depends`. Never inject unrelated binaries merely
  because the same source package produces them.
- Scope internal package-provider matching to targets that share at least one
  product build set. A standard Debian package produced only by another
  product variant must remain an archive dependency; a private `cix-*`
  dependency without a provider in a shared set is a configuration error.
- For a product build set, order every target that provides one of those exact
  packages before its consumer so the build succeeds from an empty output
  directory. Reject a set that omits an internal build dependency required by
  one of its targets.
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
- Run Lintian for sbuild package builds and require a successful Lintian run.

### Current Implemented Scope

The current build system contains these build targets:

- Kernels: `kernel`, `stable-kernel`
- Kernel drivers and firmware: `gpu-dkms`, `bt-dkms`, `wlan-dkms`,
  `vpu-dkms`, `vpu-firmware`, `npu-dkms`, `isp-v4l2-dkms`, `isp-dkms`
- Graphics and media: `libdrm`, `libglvnd`, `mesa`, `libva`, `ffmpeg`,
  `libcme`, `cix-vaapi`, `gstreamer-6.6`, `gstreamer-base-7.0`,
  `gstreamer-good-7.0`, `nnstreamer`
- Proprietary userspace payloads: `gpu-umd`, `dpu-ddk`, `isp-umd`, `noe-umd`,
  `npu-umd`
- AI runtimes: `ai-engine`, `mnn`
- System integration and firmware: `grub-config`, `alsa-conf`, `audio-dsp`,
  `audio-sof`, `radxa-o6-firmware`, `radxa-o6n-firmware`, `cix-env`,
  `cix-firmware`

The VPU DKMS package must retain its runtime dependency on
`cix-vpu-firmware`. Its 16 proprietary `.fwb` files come from the
`cix-vpu-umd/usr/lib/firmware` staging directory in
`cix_proprietary/cix_proprietary`, not from the open-source VPU driver. Fetch
only those Git LFS objects when assembling the firmware source package.

The `audio-sof` direct flow builds the ARM64-hosted Xtensa compiler from source,
caches it by its manifest input revisions, builds Sky1 and Sky1P SOF firmware
and topology files, and creates the architecture-independent
`cix-audio-sof` Debian package.

The `radxa-o6-firmware` and `radxa-o6n-firmware` targets share one direct
firmware flow that invokes the manifest-pinned CIX EDK2 and internal packaging
scripts on ARM64 with board `O6` or `O6N`. Temporary O6N patches live in the
build-script repository and are applied to target-owned worktrees, leaving the
manifest source checkouts unchanged. It emits each board's flash and OCB images
under `output/TARGET/images` and has no Debian backend. O6N has no EC, so its
packaging must leave the EC flash region erased rather than include the default
platform EC firmware.

The `radxa-o6-pm-validation` and `radxa-o6n-pm-validation` targets exercise the
existing v3.0 custom PMIC path without changing the board's documented limits
or voltage offsets. They are experimental direct targets grouped by the
explicit `pm-validation` build set, are not members of either product build
set, and publish a separately verified PM configuration block with their
firmware images. Normal O6/O6N firmware builds do not apply the validation
patch. Treat a board boot test as the acceptance gate for closed-firmware
consumption; build-time binary validation alone is insufficient.

The `radxa-o6-opp-validation` target extends only the O6 experiment with the
stock 12-domain OPP tables supplied by CIX PackageTool. Its verifier compares
every generated table field and confirms that no additional domain is enabled.
The `pmtool` direct target publishes the exact manifest-pinned ARM64 inspection
binary used to capture the effective firmware OPP table on the board. Neither
target is included in a product build set, installs software, invokes `sudo`,
or flashes firmware.

The `radxa-o6-pm-tuning` direct target layers a BIOS profile selector and a v3
PM update driver over an image that contains a complete external OPP table.
The image marks that table disabled by default, and Vendor/Automatic keeps it
disabled so PM firmware can generate its native per-part table. Experimental
and Expert/Custom re-enable a complete external table; Expert/Custom exposes
only non-startup OPPs for GB0, GB1, GM0, and GM1 under bounded and monotonic
input rules. Startup OPPs, DSU, and non-CPU domains remain locked. The updater
validates the complete current and generated PM blocks and verifies the
dedicated PM flash entry after every update. It belongs only to the explicit
`pm-tuning` set. The normal O6 firmware target and both product build sets do
not apply this patch.

## Legacy Reference

- Legacy workspace: `/home/claystan/cix-repo`
- New build-system workspace: `/home/claystan/cix-neo-bs`
- The legacy system cross-compiles ARM64 software on x86 hosts and uses `repo`
  manifests to manage the full source workspace.

## Decisions Still To Be Made

- Artifact publishing, retention, and signing requirements.
- Container, CI, caching, signing, and publishing requirements.
- Nexus URL mapping, authentication, and access policy for each site selector.
