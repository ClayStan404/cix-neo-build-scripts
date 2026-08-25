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

## Controlled GB1 2.7 GHz Experiment

Build the separately gated experiment set:

```bash
./build-scripts/cix-build pm-gb1-2700
```

The experiment artifacts are:

- `output/radxa-o6-gb1-2700-experiment/csu_pm_config_O6_gb1-2700.bin`
- `output/radxa-o6-gb1-2700-experiment/images/cix_flash_all_O6_pr_debug.bin`

The `gb1-2700` verifier profile requires the source-stock table except for one
entry: the GB1 top OPP changes from 2600 MHz at 920 mV to 2700 MHz at 950 mV.
The sustained OPP, DSU table, all other domains, PMIC rails, and OPP limits
remain unchanged. Its power cost is conservatively increased from 2292 mW to
2538 mW using the frequency-times-voltage-squared model. The higher voltage
follows the previously observed vendor table ceiling and is not a stability
guarantee.

Use the same recovery-aware full-image flashing procedure and perform a cold
boot. Before applying CPU load, capture:

```bash
sudo /tmp/pmtool cli opp_config
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
```

Acceptance for this stage requires `pmtool` to report the GB1 top OPP as
2700 MHz at 950 mV, Linux policy 0 to expose the intended maximum, normal idle
temperatures, and no new PM, regulator, thermal, or SCMI errors. Do not start a
stress test until these checks pass. Restore the known-good full image if the
board cannot complete a cold boot.

## BIOS-Selectable Profiles

Build the separate tuning image after the controlled 2.7 GHz profile has
passed the board checks above:

```bash
./build-scripts/cix-build pm-tuning
```

Flash only this recovery-gated O6 artifact:

- `output/radxa-o6-pm-tuning/images/cix_flash_all_O6_pr_debug.bin`

In UEFI setup, open `Device Manager -> Platform Configuration -> Advanced
Configuration -> Power Management` and select a profile:

- `Vendor/Automatic (PM firmware native OPPs)`
- `Experimental: GB1 up to 2700 MHz at 950 mV`
- `Expert/Custom CPU OPPs`

Vendor/Automatic sets the external OPP table invalid and leaves its contents
unused, allowing PM firmware to use its native per-part OPN/Vmin/guardband
path. Experimental and Expert/Custom set the external complete table valid.
Expert/Custom opens a separate form for the non-startup OPPs of GB0, GB1, GM0,
and GM1. Each frequency must be 800-3200 MHz and each voltage must be 550-1250
mV, in steps of 10. These are input boundaries, not safe operating guarantees.
The voltage boundary reflects the documented Big/Mid CPU rail range; it does
not establish a safe voltage for the SoC or the retail board. Frequencies must
strictly increase and voltages must not decrease within a domain. Startup OPP 3
remains fixed at 1800 MHz / 790 mV and is not shown. DSU and non-CPU domains are
not exposed.

The available frequency/voltage test data for K000086 was collected on an
internal EVB. The publicly sold Radxa O6 may differ in board revision, power
delivery, cooling, firmware payload, and silicon population. The 2.7 GHz fixed
profile and all Expert/Custom settings therefore remain experiments on the
retail O6 until they pass board-specific validation.

When an editable OPP changes, its power cost is rounded up from
`stock_power * new_frequency * new_voltage^2 /
(stock_frequency * stock_voltage^2)`. The result is never allowed below the
stock power cost. This keeps the closed PM firmware's power model conservative
for undervolting and avoids retaining an underestimated stock cost when
overclocking.

Save and exit. The normal setup reset is followed by one additional cold reset
after the firmware has updated and read back the dedicated PM configuration.
Do not interrupt power during that update. The updater rejects an unknown PM
version, invalid checksum, unexpected OPP layout, modified startup OPP, changed
DSU table, out-of-range value, or non-monotonic CPU table. It validates the
complete generated block before writing and compares the complete flash entry
afterwards. The setup-save path removes the legacy CPU limit for every profile
so it cannot mask PM firmware's native or externally selected table.

The tuning image also repairs the existing Memory Data Rate selector. Open
`Device Manager -> Platform Configuration -> Advanced Configuration -> Memory
Configuration`. `Auto` and every explicit data rate from 1600 through 6400
MT/s update only the validated BSET request. The updater never changes the
per-board CONF maximum, so all vendor limits and DRAM topology data remain
intact. It updates the BSET checksum, writes the memory configuration entry,
and verifies it by reading the complete entry back.

Memory training happens before UEFI setup. Closed DDR firmware may cap or
reject a request above the detected board's qualified limit; if it accepts an
unstable rate, training may fail before the profile selector is available.
Recover by flashing the known-good image over USB. After a successful boot,
verify the controller PLL with:

```bash
sudo ./pmtool cli pllst | grep ddrc_pll
```

Approximately 2748 MHz corresponds to 5500 MT/s, 3000 MHz to 6000 MT/s, and
3200 MHz to 6400 MT/s. Also confirm `Configured Memory Speed` with
`sudo dmidecode --type memory`. A successful boot is not memory-stability
qualification.

After the automatic cold reset, repeat the `pmtool` and Linux cpufreq captures
from the controlled experiment. Then select Vendor/Automatic, save, allow the
same additional reset, and confirm that the external OPP table is disabled and
the effective table returns to the board's PM-firmware-generated baseline. Do
not require that baseline to equal the PackageTool source table or a fixed
2600 MHz / 920 mV entry. This bidirectional board test is the acceptance gate;
a successful build alone does not approve the tuning image for product use.

Expert/Custom is a development interface, not a validated performance profile.
Use it only after Vendor/Automatic recovery has been confirmed on a board with
a tested SPI recovery path. Stability testing and board qualification remain
separate acceptance work.
