# O6 Engineering Firmware

## Scope

`radxa-o6-firmware-engineering` is the recovery-gated Radxa Orion O6 image for
BIOS-selectable CPU and memory experiments. It is separate from the product
firmware targets and is not included in `all-6.6`, `all-7.0`, or
`firmware-sky1`.

The build system never installs `pmtool`, invokes privileged hardware access,
or flashes firmware automatically.

## Build Artifacts

Build the engineering image and the manifest-pinned ARM64 inspection tool on
the Debian 13 ARM64 host:

```bash
./build-scripts/cix-build firmware-engineering
```

The published artifacts are:

- `output/radxa-o6-firmware-engineering/images/cix_flash_all_O6_engineering_debug.bin`
- `output/radxa-o6-firmware-engineering/csu_pm_config_O6_vendor-auto.bin`
- `output/pmtool/pmtool`

The locally signed full-flash image is for blank or prototype development
boards. It is not a product-signed image. The build does not publish a tuning
image named `pr` or `pr2`, because those trust states require RKMS. It also
does not publish a tuning OTA image, because that payload would not contain the
Debug PM firmware required by the complete custom table.

The build verifies the pinned Debug PM firmware identity, PM configuration
schema, CPU table policy, memory update policy, generated UEFI form, source-
built bootloader1, prototype signing boundary, and final full-flash image.

## Preconditions

Do not flash until all of the following are known for the exact test board:

1. The board is a Radxa Orion O6.
2. The current SPI image has been backed up and its checksum recorded.
3. A tested SPI recovery path is available independently of the installed OS.
4. Serial console output can be captured from power-on.
5. The validated board-specific flashing procedure is known.

## Baseline Capture

Copy the inspection tool and read-only collector to the board:

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
checksums. Record the serial boot log separately.

## BIOS Profiles

The Engineering Debug image exposes two CPU modes under `Device Manager ->
Platform Configuration -> Advanced Configuration -> Power Management`:

- `Vendor/Automatic (PM firmware native OPPs)` disables the external OPP table
  so PM firmware uses its native per-part OPN/Vmin/guardband path.
- `Custom (complete CPU OPP table)` enables the complete external CPU table
  with the Debug PM firmware.

Custom exposes the non-boot OPPs of GB0, GB1, GM0, and GM1. Frequency inputs
are 800-3200 MHz and base-voltage inputs are 550-1250 mV in steps of 10. Each
OPP can use a fixed voltage or Vmin profile 1-3. Frequencies must strictly
increase and base voltages must not decrease. The effective 1500 MHz / 790 mV
boot OPP, DSU, and non-CPU domains are not editable.

These input boundaries are not safe-operating guarantees. Available internal
frequency and voltage data came from a K000086 EVB; a retail Radxa O6 may have
different power delivery, cooling, firmware payloads, board revisions, and
silicon population.

Saving a changed profile is followed by one additional cold reset after the
DXE driver validates, writes, reads back, and compares the dedicated PM entry.
Do not interrupt power during that update. Unknown settings layouts, invalid
PM data, modified protected OPPs, changed DSU data, out-of-range input, and
non-monotonic CPU tables are rejected.

## Memory Data Rate

The same image repairs `Advanced Configuration -> Memory Configuration ->
Memory Data Rate`. `Auto` and every explicit value from 1600 through 6400 MT/s
update only the BSET request. The updater does not change the vendor CONF
maximum or the board's DRAM topology data.

Memory training runs before UEFI setup. Source-built SE/DDR firmware makes no
more than three training attempts. If an explicit request fails, firmware
writes `Auto` to the dedicated memory entry, verifies it, and resets. Failure
while already using `Auto` stops initialization rather than entering an
unbounded reset loop. Keep the tested USB recovery image available.

After a successful boot, inspect the controller PLL with:

```bash
sudo ./pmtool cli pllst | grep ddrc_pll
sudo dmidecode --type memory
```

Approximately 2748 MHz corresponds to 5500 MT/s, 3000 MHz to 6000 MT/s, and
3200 MHz to 6400 MT/s. A successful boot is not memory-stability qualification.

## Acceptance

After flashing and cold booting, repeat the PM and Linux snapshot with a new
output directory. Confirm both directions:

1. Custom produces the requested valid external table and survives repeated
   cold boots without PM, thermal, regulator, or memory-training errors.
2. Vendor/Automatic disables the external table and returns to the board's
   PM-firmware-generated baseline.
3. The backed-up SPI image can be restored through the tested recovery path.

Custom remains a development interface, not a qualified performance profile.
Stability testing and board qualification are separate acceptance work.
