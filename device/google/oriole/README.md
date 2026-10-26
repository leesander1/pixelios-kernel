# Pixel 6 (oriole)

SoC: `soc/google/gs101`. Status: shim probe observed on hardware 2026-10-26 (`hardware/probe-log-2026-10-26-run3.txt`); no XNU boot yet.

Captures from this device go in `hardware/`.

## Targeting this phone

Every device tool picks ONE phone from `PIXOS_DEVICE` (default `bluejay`) and refuses any attached phone that reports another
codename (`tools/phone-target.sh`, allowlist `tools/phone-targets.txt`). `fboot.sh` also refuses an image built for another board.

```
PIXOS_DEVICE=oriole tools/phone-state                      # must say product=oriole
PIXOS_DEVICE=oriole tools/probe-run --build-args "..." --expect REGEX   # read-only shim probe (fastboot boot, writes nothing)
```

`xrun` (XNU boot) and `fflash-userdata.sh` stay bluejay-only until oriole has a measured board definition.

## Measured (2026-10-26, bootloader slider-17.0-15199431)

- 8 GiB in four 2 GiB banks; the high 6 GiB (0x880000000..0xA00000000) holds no reserved range: `xnu_ram`.
- `usb_dma_range` abl@f8800000 16 MiB (event buffer inside), `userdata_mib` 112914: both identical to bluejay.
- UFS cold re-init reaches HS-G4; all 8 CPUs report; the console draws on the panel at 0xfac00000.

Still from source only: key pins and touch (see `notes` in `board.json`). `xrun`, `build-xnu-image.sh` and `mkpayload.py` are
bluejay-only, so no XNU image is built for oriole yet.
