# Build validation handoff

Date: 2026-09-09

The script review fixes are implemented in the `build-scripts` repository.
The initial fix pass ran tests and preflight only. The user subsequently
authorized sbuild provisioning and builds, then requested that building stop.
No build process remained when this status was checked; do not start additional
builds until requested.

The sbuild chroot was created successfully. The background `all-6.6 --resume`
run completed all 33 targets successfully, as recorded in
`output/build-reports/20260909T021910Z-2535140/build-result.json`.
The second resume run, full `all-7.0` and `secure-firmware` builds, and product
DKMS validation have not been performed in this validation pass.

## Implemented fixes

- Local dependency installation forces reinstallation of the exact workspace
  package, including when its version is already installed.
- Resume checks recursively compare dependency providers with their current
  inputs and hash the actual selected dependency `.deb` files. Missing,
  corrupt, stale, or unverifiable provider records prevent resume reuse.
- Fingerprints include planner/state/artifact code, build configuration, and
  explicit linked inputs. TF-A and PBL now include the manifest-linked
  `sources/radxa-o6/bootloader/library` repository.
- A shared artifact policy requires all declared Debian binary packages and
  each direct flow's deliverables before success is recorded or product
  artifacts pass validation.
- Installed-host DKMS checks match module, running kernel, architecture, and
  installed status together.
- Quilt preflight applies the complete patch series to disposable source
  copies assembled with the same exclusions and overlays as a real build.
- The CI executor rejects `--backend local --jobs N` when `N` is not 1.
- Previously uncovered owned paths now have CI impact or ignore rules.
  Shared Debian builder changes also select `audio-sof`.
- Artifact enumeration skips build/download/host-tool caches before traversing
  them. The existing kernel output now has 6 published inventory entries,
  excluding its intermediate build tree.

State format is now v3. Existing v2 records intentionally trigger a rebuild;
they were not deleted or rewritten. A standalone build using dependency
packages without valid provider records can complete, but is marked
non-resumable. Rebuild providers in dependency order, or run a complete build
set, to establish verified state.

## Completed validation

Run commands from the workspace root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s build-scripts/ci -p 'test_*.py'
./build-scripts/setup-host --check
./build-scripts/ci/plan.py --check
./build-scripts/cix-build all-6.6 --backend local --preflight-only
./build-scripts/cix-build all-7.0 --backend local --preflight-only
./build-scripts/cix-build secure-firmware --preflight-only
```

All commands passed. The test suite contains 106 tests, including isolated real
Git repositories, temporary Debian packages, APT simulation, and actual
`dpkg-source` patch application. Syntax checks passed for 26 Python files and
23 shell scripts. ShellCheck passed at warning/error severity across all shell
scripts and at all severity levels for the changed shell scripts, including
their sourced code. The unchanged UEFI scripts retain existing informational
SC2031 diagnostics when checking the entire shell tree at all levels.

The required-output policy also matched every target with existing outputs.
`stable-kernel-6.18` and `stable-kernel-7.1` had no output directories. This was
a file-presence check of previous outputs, not evidence of a new build.

Preflight reports:

- `output/build-reports/20260909T015926Z-2524818/build-result.json` (`all-6.6`)
- `output/build-reports/20260909T020210Z-2525345/build-result.json` (`all-7.0`)
- `output/build-reports/20260909T020301Z-2525761/build-result.json` (`secure-firmware`)

The Debian metadata repository is unchanged. Source checkouts were not edited.
The untracked `sources/audio-sof/sof/tools/rimage/tomlc99` symlink is an existing
manifest `linkfile`, not a generated change from this work.

## Remaining build checks (paused)

The host is native ARM64 Debian 13 and its declared dependencies are installed.
The sbuild chroot now exists at
`/home/claystan/.cache/sbuild/trixie-arm64-sbuild.tar.zst`.

When building is requested again, build each set and immediately repeat its
resume command. Committing previously dirty inputs can invalidate fingerprints
recorded before the commit, so the completed set may rebuild once:

```bash
./build-scripts/cix-build all-6.6 --resume
./build-scripts/cix-build all-6.6 --resume
./build-scripts/tests/product.py 6.6 --require-state --dkms

./build-scripts/cix-build all-7.0 --resume
./build-scripts/cix-build all-7.0 --resume
./build-scripts/tests/product.py 7.0 --require-state --dkms

./build-scripts/cix-build secure-firmware --resume
./build-scripts/cix-build secure-firmware --resume
```

The first run replaces obsolete state through successful builds; the second
should resume unchanged targets. For a local build, add `--backend local` to
both invocations of each product set. Local builds update the host's installed
internal packages and must be run serially.

Inspect the generated build reports, per-target logs, v3 dependency records,
and published artifact inventories. In particular, confirm same-version
internal dependencies are reinstalled in a real local build, and that an
unchanged second run resumes consumers after their providers have valid v3
records. Preserve existing caches; no global cleanup is needed for state
migration.

Product DKMS compilation is separate from installed-board validation. No
firmware flashing or SSH board checks are implied by the commands above.
