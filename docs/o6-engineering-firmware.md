# O6 Engineering Firmware

## Scope

`radxa-o6-firmware-engineering` is the recovery-gated Radxa Orion O6 image for
BIOS-selectable CPU experiments. It is separate from the product
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

- `output/radxa-o6-firmware-engineering/images/cix_flash_all_O6_cpu_tuning_pr_debug.bin`
- `output/radxa-o6-firmware-engineering/bootloader1_pr_debug.img`
- `output/radxa-o6-firmware-engineering/csu_pm_config_O6_vendor-auto.bin`
- `output/pmtool/pmtool`

The full-flash image reuses the manifest-pinned `pr_debug` bootloader1 and
bootloader2 artifacts. It does not rebuild or locally sign either early-boot
component. The build does not publish a tuning OTA image because that payload
would not carry the Debug PM firmware required by the complete custom table.

The build verifies the PM configuration schema, CPU table policy, generated
UEFI form, exact manifest bootloader1 reuse, and the BL1, PM-config, and BL3
segments in the final full-flash image. This is provenance validation, not
proof that a newly synced firmware revision boots on a retail board.

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

## USB Firmware A/B Baseline

The initial USB comparison on 2026-08-31 established the following baseline
on test host `172.20.64.113`. The Linux 7.0 test environment and attached USB
input devices were otherwise unchanged.

| Firmware | USB keyboard and mouse | Status |
| --- | --- | --- |
| Radxa release 1.3.1 | Working | Baseline established |
| Retired source-bootloader Engineering Debug | No UEFI or OS | Failed before UEFI; SPI recovery required |
| CPU-tuning PR-debug replacement | Not tested | Requires serial-assisted boot validation |

The Radxa 1.3.1 baseline was captured over SSH before replacing the firmware:

- Kernel: `7.0.13-cix #1 SMP PREEMPT Fri Aug 14 03:18:43 EDT 2026`.
- OS: Debian 13.6 (`trixie`), ARM64.
- Kernel command line: `BOOT_IMAGE=/boot/vmlinuz-7.0.13-cix
  root=UUID=a7894d3f-8eb4-48fd-a77b-6a8d3fa1019f ro quiet acpi=force
  clk_ignore_unused`.
- SMBIOS firmware: Radxa Computer (Shenzhen) Co., Ltd. version `1.3.1`, dated
  `2026-07-16T11:55:04+00:00`.
- Board: `Radxa Orion O6`, board and product version `1.0`.
- USB topology: twelve xHCI root hubs, consisting of eight USB 2.0 hubs and
  four USB 3.0 10 Gbit/s hubs.
- Input receiver: Xiaomi Wireless Keyboard and Mouse Combo 2,
  `2717:5055`, attached to bus 1 at 12 Mbit/s. Both HID interfaces use
  `usbhid`; mouse, keyboard, consumer-control, and system-control input
  devices are present.
- Physical controller path for the receiver:
  `CIXH2030:06/CIXH2031:06/xhci-hcd.5.auto`.
- All ten `CIXH2030` wrappers bind to `cdnsp-sky1`; all ten `CIXH2031`
  controllers bind to `cdns-usbssp`.
- All ten `CIXH2032` USB 2.0 PHY devices bind to `cix,sky1-usb2-phy`, all four
  `CIXH2033` USB/DP PHY devices bind to `cix-usbdp-phy`, and `CIXH2034:00`
  binds to `cix-usb3-phy`.
- All ten `PNP0D10` ACPI devices have no physical platform node, confirming
  that the 7.0 CIX ACPI scan handler blocked the generic xHCI path as intended.
- `hid`, `hid_generic`, `usbhid`, and `evdev` are loaded and active.

The unprivileged SSH account cannot read the raw DSDT, MCFG, FACP, deferred
device list, or system kernel journal. Capture their checksums and logs through
the approved privileged read-only procedure during the controlled comparison.

This observation narrows the regression to a firmware-dependent interface,
including ACPI USB enumeration, controller/PHY description, or early hardware
initialization. It does not by itself identify which firmware component is at
fault. Do not attribute the failure solely to the Linux 7.0 USB or HID
configuration unless the engineering image reproduces it and the controller
and input-layer logs have been compared.

### 2026-08-31 Early-Boot Incident

The retired image
`cix_flash_all_O6_engineering_debug.bin`, SHA-256
`e6b6e574e690777724839cd3e826657389547378a13f76e1c5f8234faa0d659d`,
did not reach UEFI on the retail O6 test board after a source sync. No blue
BIOS-ready indication was observed and neither BIOS nor Linux was reachable.
The board was recovered with the known-good Radxa 1.3.1 SPI image; Linux
7.0.13 and the USB keyboard/mouse then worked again.

That retired image combined a locally prototype-signed, source-built
bootloader1 with patched SE/DDR firmware and CPU/memory tuning UEFI. Build-time
signature and layout checks did not establish runtime compatibility. The
source-built bootloader1 and memory-tuning path are therefore quarantined and
must not be republished by `radxa-o6-firmware-engineering`. The replacement
target changes only the CPU-tuning UEFI/PM path and reuses the manifest
`pr_debug` early boot chain. It remains unvalidated on hardware until a serial
log confirms each boot stage.

Before replacing the 1.3.1 baseline in a future controlled test, record the
exact kernel release, command line, USB topology, ACPI controller state,
driver bindings, and boot log. Run the same commands after flashing the
CPU-tuning PR-debug image:

```bash
uname -a
cat /proc/cmdline
lsusb
lsusb -t
find /sys/bus/acpi/devices -maxdepth 1 \
  \( -name 'CIXH203*' -o -name 'PNP0D10*' \) -print | sort
find /sys/bus/platform/devices -maxdepth 1 \
  \( -name 'CIXH203*' -o -name 'PNP0D10*' \) -print | sort
lsmod | grep -E 'hid|usbhid|evdev|xhci|cdnsp'
sudo dmesg | grep -Ei \
  'Sky1 USB|CIXH203|PNP0D10|cdnsp|xhci|usb|phy|defer|reset|clock'
sudo cat /sys/kernel/debug/devices_deferred
```

Also retain the full serial log from power-on. The comparison is valid only
when the kernel, root filesystem, kernel command line, physical USB ports,
devices, and cabling remain unchanged.

## BIOS Profiles

The CPU-tuning PR-debug image exposes two CPU modes under `Device Manager ->
Platform Configuration -> Advanced Configuration -> Power Management`:

- `Vendor/Automatic (PM firmware native OPPs)` disables the external OPP table
  and explicitly enables the fused Vmin curve so PM firmware uses its native
  per-part OPN/Vmin/guardband path.
- `Custom (complete CPU OPP table)` enables a CPU-only partial external table
  with the Debug PM firmware. Domains not present in that table continue to
  use the PM firmware's native per-chip values.

Custom exposes the non-boot OPPs of GB0, GB1, GM0, and GM1. Frequency inputs
are 800-3200 MHz and base-voltage inputs are 550-1250 mV in steps of 10.
Voltage policy is shown only for source OPPs with a Vmin checkpoint in the
pinned PM firmware. GB0/GB1 OPP4-6 map to Vmin3/Vmin2/Vmin1, GM0 OPP3-6 map to
Vmin3/Vmin3/Vmin2/Vmin1, and GM1 OPP4-5 map to Vmin1/Vmin1. Each such control
offers Fixed plus only its mapped tier. The mapped fused tier is the default;
Fixed remains an explicit expert override. A Vmin tier is a per-domain ATE
checkpoint floor, not a safe-voltage guarantee for an arbitrary edited
frequency. Frequencies must strictly increase and base voltages must not
decrease. The effective 1500 MHz / 790 mV
boot OPP is not editable. DSU and non-CPU domains are encoded as absent
(`0xffff`/`0xff`) rather than copied from a static board table.

These input boundaries are not safe-operating guarantees. Available internal
frequency and voltage data came from a K000086 EVB; a retail Radxa O6 may have
different power delivery, cooling, firmware payloads, board revisions, and
silicon population.

Saving a changed profile is followed by one additional cold reset after the
DXE driver validates, writes, reads back, and compares the dedicated PM entry.
Do not interrupt power during that update. Unknown settings layouts, invalid
PM data, disabled fused Vmin, modified protected OPPs, configured non-CPU data,
unsupported per-OPP voltage modes, out-of-range input, and non-monotonic CPU
tables are rejected.

Settings revision 3 resets every older layout to Vendor/Automatic. This avoids
silently reusing the revision-2 Fixed voltage defaults after an upgrade.

## Hardware Validation Findings

On 2026-09-02, a retail Radxa O6 running the engineering image was compared
between Vendor/Automatic and a safe Custom marker. Vendor/Automatic restored
the fused table, including GB0 2500 MHz at 950 mV and GB1 2600 MHz at 950 mV;
USB HID remained functional on Linux 7.0.13. The earlier Custom image correctly
applied a 2490 MHz GB0 marker, but also replaced DSU and other non-CPU tables
and defaulted mapped CPU OPPs to Fixed voltage. Revision 3 addresses both
findings. It still requires a new on-board A/B validation after flashing.

## Quarantined Memory Path

The CPU-tuning image does not apply the experimental memory-menu patch and
does not build or package patched SE/DDR firmware. The source patches are kept
only for post-incident analysis. A future memory experiment requires a
separate target, a known-good signed bootloader base, UART2 and UART5 capture,
an SPI backup, and explicit board validation before it can publish a flashable
artifact.

## Acceptance

After flashing and cold booting, repeat the PM and Linux snapshot with a new
output directory. Confirm both directions:

1. Custom produces the requested valid external table and survives repeated
   cold boots without PM, thermal, or regulator errors.
2. Vendor/Automatic disables the external table and returns to the board's
   PM-firmware-generated baseline.
3. The backed-up SPI image can be restored through the tested recovery path.

Custom remains a development interface, not a qualified performance profile.
Stability testing and board qualification are separate acceptance work.
