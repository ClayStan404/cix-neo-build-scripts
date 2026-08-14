# O6 PM Configuration Board Validation

## Scope

This procedure validates that the Sky1 PM firmware consumes the external v3.0
OPP table embedded by the EDK2 packaging flow. The first image deliberately
uses the unmodified CIX stock OPP tables. It is not an overclocking image.

The build system never installs `pmtool`, invokes privileged hardware access,
or flashes firmware automatically.

## Build Artifacts

Build the isolated validation set on the ARM64 Debian 13 build host:

```bash
./build-scripts/cix-build pm-validation
```

The required O6 artifacts are:

- `output/pmtool/pmtool`
- `output/radxa-o6-opp-validation/csu_pm_config_O6_stock-opp.bin`
- `output/radxa-o6-opp-validation/images/cix_flash_all_O6_pr_debug.bin`

`verify_pm_config.py` has already checked the PM config header, checksum,
custom PMIC section, every stock OPP entry, zero-filled unused entries, and the
unconfigured thirteenth domain before the image is published.

## Preconditions

Do not flash until all of the following are known for the exact test board:

1. The board is a Radxa Orion O6, not O6N or another Sky1 platform.
2. The current SPI image has been backed up and the backup checksum recorded.
3. A tested SPI recovery path is available independently of the installed OS.
4. Serial console output can be captured from power-on.
5. The validated board-specific flashing command and target device are known.

## Baseline Capture

Copy only the inspection tool to the board and verify it before use:

```bash
scp output/pmtool/pmtool TEST_BOARD:/tmp/pmtool
ssh TEST_BOARD 'sha256sum /tmp/pmtool'
```

The expected SHA-256 for the manifest-pinned tool is:

```text
4e49c2050759766716af7760de1daaf79ab7074dd56e907dea221000b96f8c71
```

Capture the effective table before flashing:

```bash
ssh -t TEST_BOARD 'sudo /tmp/pmtool cli opp_config'
```

Also record the current firmware version, Linux CPU frequency tables, kernel
version, and serial boot log. Preserve these results outside `/tmp`.

## Stock-Table Image Test

Flash only with the board's already validated recovery-aware procedure. This
document intentionally does not provide a generic SPI write command because a
wrong device or image can make the board unbootable.

After a cold boot, capture the same data again. Acceptance requires all of the
following:

- Serial output reports a valid v3.0 PM config and the external/configured OPP
  source rather than a checksum or version rejection.
- `pmtool cli opp_config` reports the same effective stock table values that
  were captured before flashing.
- Linux exposes the same CPU frequency maxima as the baseline.
- The board completes repeated cold boots without PM, thermal, or regulator
  errors.
- The backed-up image can be restored with the documented recovery path.

Only after this stock-equivalent test passes should a second experiment change
one OPP value. That later image must use a separate target and verifier profile
so it cannot be confused with product or stock-validation firmware.
