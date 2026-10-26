# Pixel 6 (oriole)

SoC: `soc/google/gs101`. Status: scaffold, no hardware run yet.

Captures from this device go in `hardware/`.

## Targeting this phone

Every device tool picks ONE phone from `PIXOS_DEVICE` (default `bluejay`) and refuses any attached phone that reports another
codename (`tools/phone-target.sh`, allowlist `tools/phone-targets.txt`). `fboot.sh` also refuses an image built for another board.

```
PIXOS_DEVICE=oriole tools/phone-state                      # must say product=oriole
PIXOS_DEVICE=oriole tools/probe-run --build-args "..." --expect REGEX   # read-only shim probe (fastboot boot, writes nothing)
```

`xrun` (XNU boot) and `fflash-userdata.sh` stay bluejay-only until oriole has a measured board definition.

## What `board.json` still needs (measure, do not copy)

- `dram_banks` / `xnu_ram`: a conservative 4 GiB guess copied from bluejay (the Pixel 6 has 8 GiB). The probe log prints the live `/memory` banks.
- `usb_dma_range`: the bootloader's DWC3 event-buffer carve-out (`abl@...` in the live FDT); `tools/pix check oriole` fails until it is set.
- `userdata_mib`: from the GPT read; depends on the 128/256 GiB model.

Sourced (read from source, not yet observed on oriole): framebuffer, key pins, touch (see `notes` in `board.json`).
