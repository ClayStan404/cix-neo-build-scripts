# O6 PM Configuration Board Validation

## Scope

This procedure validates that the Sky1 PM firmware consumes the external v3.0
OPP table embedded by the EDK2 packaging flow. The first image deliberately
uses the unmodified source-stock OPP tables shipped by the manifest-pinned CIX
PackageTool. It is not an overclocking image. These source tables are not
assumed to be identical to the effective tables in a separately released
vendor firmware image.

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

Copy the inspection tool and read-only collector to the board, then verify the
tool before use:

```bash
scp output/pmtool/pmtool TEST_BOARD:/tmp/pmtool
scp build-scripts/tests/collect-o6-pm-state.sh TEST_BOARD:/tmp/
ssh TEST_BOARD 'sha256sum /tmp/pmtool'
```

The expected SHA-256 for the manifest-pinned tool is:

```text
4e49c2050759766716af7760de1daaf79ab7074dd56e907dea221000b96f8c71
```

Capture a checksummed snapshot before flashing:

```bash
ssh -t TEST_BOARD \
  'sudo /tmp/collect-o6-pm-state.sh /tmp/pmtool /var/tmp/o6-pm-before'
scp -r TEST_BOARD:/var/tmp/o6-pm-before ./
```

The snapshot includes the effective OPP table, firmware identity, Linux CPU
frequency policy, thermal zones, kernel version, relevant kernel messages, and
checksums. Record the serial boot log separately. Preserve the copied results
outside `/tmp` and `/var/tmp`.

## Stock-Table Image Test

Flash only with the board's already validated recovery-aware procedure. This
document intentionally does not provide a generic SPI write command because a
wrong device or image can make the board unbootable.

After a cold boot, run the collector again with a new output directory (for
example, `/var/tmp/o6-pm-after`) and copy it off the board. Acceptance requires
all of the following:

- Serial output reports a valid v3.0 PM config and the external/configured OPP
  source rather than a checksum or version rejection.
- `pmtool cli opp_config` reports all source-stock entries encoded in the
  generated v3.0 config.
- Linux exposes the same CPU frequency maxima as the baseline.
- The board completes repeated cold boots without PM, thermal, or regulator
  errors.
- The backed-up image can be restored with the documented recovery path.

The initial O6 board test confirmed that the PM firmware consumed all 58 OPP
entries from this external v3.0 config. The effective table differed from the
previous vendor-firmware table, while Linux CPU frequency maxima remained
unchanged. This proves the external-table mechanism, not equivalence with the
vendor firmware.

## BIOS-Selectable Profiles

Build the separate tuning image:

```bash
./build-scripts/cix-build pm-tuning
```

Flash this recovery-gated O6 prototype artifact:

- `output/radxa-o6-pm-tuning/images/cix_flash_all_O6_engineering_debug.bin`

This locally signed image is for blank/prototype development boards. It is not
a product-signed image. The target does not publish a tuning image named
`pr` or `pr2`; those trust states require RKMS and retain their manifest-pinned
bootloaders until an ARM64-native RKMS packaging frontend is available. Tuning
OTA images are also not published because that payload does not carry the PM
firmware required by the complete custom table.

The Engineering Debug image exposes only:

- `Vendor/Automatic (PM firmware native OPPs)`
- `Custom (complete CPU OPP table)`

In UEFI setup, open `Device Manager -> Platform Configuration -> Advanced
Configuration -> Power Management` and select an available profile. The
firmware migrates a persisted fixed-frequency or partial profile from an older
tuning build to Vendor/Automatic rather than consuming it.

Vendor/Automatic sets the external OPP table invalid and leaves its contents
unused, allowing PM firmware to use its native per-part OPN/Vmin/guardband
path. Custom enables the complete external CPU table. The Engineering Debug
image contains both the UEFI controls and PM firmware needed to use that table
above retail OPN limits.
The custom form edits non-boot OPPs of GB0, GB1, GM0, and GM1. Frequency is
800-3200 MHz and base voltage is 550-1250 mV in steps of 10. Each OPP can use
Fixed voltage or per-chip Vmin profile 1-3; internally the profile is encoded in
the PM firmware's voltage field. These are input boundaries, not safe operating
guarantees. Frequencies must strictly increase and base voltages must not
decrease. The effective boot/sustained OPP at 1500 MHz / 790 mV is fixed and not
shown. DSU and non-CPU domains are not exposed.

The available frequency/voltage test data for K000086 was collected on an
internal EVB. The publicly sold Radxa O6 may differ in board revision, power
delivery, cooling, firmware payload, and silicon population. All Custom
settings remain experiments on the retail O6 until they pass board-specific
validation.

CPU OPP power starts with the same measured-power points and linear
interpolation as PM firmware source revision `a2327331813f`. It then scales
power upward with voltage squared when the requested voltage exceeds the
source curve; Vmin modes reserve power at the source firmware's 980 mV
ceiling. The build rejects the Debug PM firmware binary unless its embedded
revision and SHA-256 match the validated payload. This pins complete-table and
Vmin behavior to PM config ABI v3.4 while the board-owned
generator and DXE writer deliberately remain pinned to config schema v3.0.

Save and exit. The normal setup reset is followed by one additional cold reset
after the firmware has updated and read back the dedicated PM configuration.
Do not interrupt power during that update. The updater rejects an unknown PM
version, invalid checksum, unexpected OPP layout, modified boot OPP, changed
DSU table, out-of-range value, or non-monotonic CPU table. It validates the
complete generated block before writing and compares the complete flash entry
afterwards. The setup-save path removes the legacy CPU limit for every profile
so it cannot mask PM firmware's native or externally selected table.
The setup variable also carries a revision, exact data size, and signature;
known older layouts are migrated, while unknown layouts are rejected.

The tuning image also repairs the existing Memory Data Rate selector. Open
`Device Manager -> Platform Configuration -> Advanced Configuration -> Memory
Configuration`. `Auto` and every explicit data rate from 1600 through 6400
MT/s update only the validated BSET request. The updater never changes the
per-board CONF maximum, so all vendor limits and DRAM topology data remain
intact. It updates the BSET checksum, writes the memory configuration entry,
and verifies it by reading the complete entry back.

Memory training happens before UEFI setup. The source-built SE/DDR firmware
tries training no more than three times. If an explicit request fails, it
persists `Auto` to the dedicated memory configuration entry, verifies the
write, and resets. If training fails while already using `Auto`, initialization
stops rather than reset-looping. A request above the detected board's qualified
limit may also be capped by the SoC fuse limit. Keep the known-good USB recovery
image available even with automatic recovery. After a successful boot, verify
the controller PLL with:

```bash
sudo ./pmtool cli pllst | grep ddrc_pll
```

Approximately 2748 MHz corresponds to 5500 MT/s, 3000 MHz to 6000 MT/s, and
3200 MHz to 6400 MT/s. Also confirm `Configured Memory Speed` with
`sudo dmidecode --type memory`. A successful boot is not memory-stability
qualification.

After the automatic cold reset, repeat the `pmtool` and Linux cpufreq captures.
Then select Vendor/Automatic, save, allow the same additional reset, and confirm
that the external OPP table is disabled and the effective table returns to the
board's PM-firmware-generated baseline. Do not require that baseline to equal
the PackageTool source table or a fixed 2600 MHz / 920 mV entry. This
bidirectional board test is the acceptance gate; a successful build alone does
not approve the tuning image for product use.

Custom is a development interface, not a validated
performance profile. Use it only after Vendor/Automatic recovery has been
confirmed on a board with a tested SPI recovery path. Stability testing and
board qualification remain separate acceptance work.
