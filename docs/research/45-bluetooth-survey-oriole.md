# 45 - Bluetooth on the Pixel 6 (BCM4389 BT over UART): what the hardware is and what iOS 16 expects (survey)

Status: SURVEY, 2026-10-27, read-only. Nothing built or run. Tags: **[src file:line]**, **[obs]** (read on this host), **[guess]**.

## 1. Hardware (gs101 / oriole)

- The Bluetooth radio is the BCM4389 combo chip that also does Wi-Fi (research 34, 39). Bluetooth uses its own host interface: HCI over a
  high-speed UART, not the PCIe link Wi-Fi uses [src gs-dts gs101-common-bluetooth.dtsi: `&serial_16 { status = "okay"; }`, `btbcm` node].
- UART: `serial_16: serial@175B0000`, `samsung,exynos-uart`, USI v2 (`samsung,usi-serial-v2`), 256-byte FIFO, RTS trigger level 1, RTS flow
  control by GPIO (`samsung,rts-gpio-control`), separate UART clock, pinctrl `uart16_bus` [src gs-dts gs101-usi.dtsi:952-964].
- Control pins (driver `goog,nitrous`, Google's BT power/low-power driver) [src gs101-common-bluetooth.dtsi]:
  - `shutdown-gpios` = BT_REG_ON = `gpp16-2` (output, 2.5 mA)
  - `device-wakeup-gpios` = BT_DEV_WAKE = `gpp14-3` (output; WLAN_EN of the Wi-Fi side is gpp14-2, the same bank)
  - `host-wakeup-gpios` = BT_HOST_WAKE = `gpa6-6` (function F = interrupt, pull-down)
  No oriole/raviole override of these nodes [obs: grep of gs101-oriole*.dts*, gs101-raviole*.dtsi in gs-dts].
- Firmware: the Bluetooth patch RAM file is a Broadcom `.hcd`; research 39 saw `BCM.hcd` and `BTFW_*.hcd` in `/firmware/brcm` of bluejay's
  vendor.img. For oriole it has not been extracted yet (`tools/extract-wlanfw.sh` only takes the Wi-Fi files; the factory zip is still in
  `~/Downloads`). [obs]

## 2. What iOS 16.7 expects (strings of the iOS root image, read-only; no Apple bytes copied)

- `bluetoothd` opens `/dev/uart.bluetooth` (UART transport) and runs `BlueTool` (`com.apple.BlueTool` launchd job) to boot the controller;
  it reads a device-tree `transport-encoding` and supports a PCIe transport (`AppleConvergedTransport`, `AppleConvergedIPCInterface`) used
  by newer Apple chips [obs: strings of `/usr/sbin/bluetoothd`, `/usr/sbin/BlueTool`].
- `BlueTool`: options `-d <device>` (UART device), `-b/-B` baud rate, `-w` download an `.hcd` file, `-S` take the baud rate from the device
  tree, `-D` PCIe transport; boot scripts `/etc/bluetool/%s.boot.script` (none ship in this root: `/private/etc` has no `bluetool`), and it
  power-cycles the chip through `/dev/btpoweroff`, `/dev/btreset`, `/dev/btwake` [obs]. It also references `AppleBluetoothModule` (the
  kernel side of the power/wake control on UART iPhones) [obs, guess on its role].
- Today `bluetoothd` and `bluetoothuserd` are removed from launchd (`tools/sweet-root-tweaks.py` DROPPED_JOBS): without a controller
  `bluetoothd` exits and respawns every 10 s (research 35).

## 3. What PixOS would need (staged, none started)

| Stage | Work | Where |
|---|---|---|
| B0 | DONE 2026-10-27: `tools/extract-wlanfw.sh` also dumps `/firmware/brcm/*.hcd`; oriole sd1a.210817.015.a4 has one file, `BCM.hcd` 385026 B (sha256 3585af85...), in `~/pixelios-artifacts/wlan-fw-oriole-*/bt/` | host |
| B1 | Shim read-only probe: USI16 UART registers + the three GPIO states (pins as above, from soc.json once added) | shim, like `--wlan-probe` |
| B2 | Shim writer: BT_REG_ON high, UART at 115200 8N1 with RTS/CTS, send HCI_Reset (`01 03 0C 00`), expect the Command Complete event; then BT_REG_ON low. Proves pins + UART + chip, no iOS | shim |
| B3 | XNU: an Exynos USI UART driver on IOSerialFamily that publishes `/dev/uart.bluetooth` (IOSerialBSDClient), plus a small service for `/dev/btpoweroff`/`btreset`/`btwake` on the three GPIOs; ADT `/arm-io/bluetooth` with `transport-encoding` (value from bluetoothd's code path: unknown) | xnu patches |
| B4 | Give `BlueTool` an `.hcd` to download (`-w` or a boot script for our device name), put `bluetoothd` back into launchd, see what it asks for next | userland overlay |

## 4. Unknowns

- U1: the `transport-encoding` value and the other `/arm-io/bluetooth` properties `bluetoothd`/`BlueTool` read (needs the disassembly of the
  two binaries, as research 33 did for QuartzCore).
- U2: which `.hcd` name BlueTool would look for and whether it accepts Google's BCM4389 patch file as is.
- U3: UART clock / USI mode setup for USI16 (the Wi-Fi and touch work have USI/clock code for USI11 that may generalise).
- U4: whether the chip needs Wi-Fi-side power (WLAN_EN / the shared PMU) up before BT_REG_ON on the 4389.
