# Pixel 6 (oriole)

SoC: `soc/google/gs101`. Status: shim probe observed on hardware 2026-10-26 (`device/google/oriole/hardware/probe-log-2026-10-26-run3.txt`); iOS 16.7.16 boots
to the lock screen 2026-10-27 (`hardware/ios-boot-2026-10-27-boot5.txt`), and touch unlocks it to the Home Screen
(`hardware/ios-boot-2026-10-27-boot6-touch.txt`, photos in `hardware/`). Slow UI (no GPU); no Wi-Fi, clock or Bluetooth.

Captures from this device go in `hardware/`.

## Targeting this phone

Every device tool picks ONE phone from `PIXOS_DEVICE` (default `bluejay`) and refuses any attached phone that reports another
codename (`tools/phone-target.sh`, allowlist `tools/phone-targets.txt`). `fboot.sh` also refuses an image built for another board.

```
PIXOS_DEVICE=oriole tools/phone-state                      # must say product=oriole
PIXOS_DEVICE=oriole tools/probe-run --build-args "..." --expect REGEX   # read-only shim probe (fastboot boot, writes nothing)
```

`fflash-userdata.sh` (the only tool that writes the phone's storage) follows `PIXOS_DEVICE` too; on a macOS host pass `--sparse`
(fastboot cannot send a raw image larger than RAM).

## Measured (2026-10-26, bootloader slider-17.0-15199431)

- 8 GiB in four 2 GiB banks; the high 6 GiB (0x880000000..0xA00000000) holds no reserved range: `xnu_ram`.
- `usb_dma_range` abl@f8800000 16 MiB (event buffer inside), `userdata_mib` 112914: both identical to bluejay.
- UFS cold re-init reaches HS-G4; all 8 CPUs report; the console draws on the panel at 0xfac00000.

Still from source only: key pins and touch (see `notes` in `board.json`).

## XNU image

`mkadt.py --board oriole`, `mkpayload.py --board oriole` and `build-xnu-image.sh --board oriole --adt A` build it; the ADT is bluejay's
except `model-number` and the About > Model Name text. The first boot hands XNU the same 4 GiB as bluejay (`xnu_ram`); 6 GiB is
measured free.

## iOS boot (2026-10-27)

Kernel from the `xnu.yml` CI, the iOS root in `userdata`, then
`PIXOS_DEVICE=oriole tools/xrun --board oriole --no-camera --gui --touch --cpus 8 --duration 900 --restart 960,bootloader`.
On a macOS host the Mac needs 192.168.7.1 on the phone's USB Ethernet port for the log; set it once and macOS keeps it:
`sudo networksetup -setmanual "Sweet iOS (USB Ethernet)" 192.168.7.1 255.255.255.0` (the service exists after the first boot).

- SpringBoard needs `/product` in the ADT: `mkadt.py` copies it from `research/ipsw-x/d22ap.adt` (unwrap the IPSW's
  `DeviceTree.d22ap.im4p` with `tools/adt.py unwrap`; it only warns when the file is missing). Without it SpringBoard aborts in a loop on
  "Failed to load bounding path bitmap data". A boot without `/product` leaves the root unusable: reflash the pristine image.
- The first boot of a fresh root runs DataMigration (about 6 min at 8 CPUs) before SpringBoard.
- Touch: the bootloader leaves USI11 out of SPI mode, the touch pads unconfigured and TS_SPI_SEL undriven, so touch needs
  `--touch` (the 6a recipe: rails on in the shim, `sweettouchmux=1`, the ABL transfer and the oscillator clock). Observed working
  2026-10-27: multi-touch, unlock swipe, Home Screen paging, keyboard.
