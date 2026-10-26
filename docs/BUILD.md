# Local shim build setup

The shim needs an AArch64 bare-metal compiler, GNU binutils, Python 3, and the
Android boot-image tools. No root access is required.

## Toolchain

Download Arm GNU Toolchain's `aarch64-none-elf` Linux x86_64 archive from
<https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads>, then
extract it under `~/.local/opt`. `shim/build.sh` uses
`aarch64-linux-gnu-` from `PATH` when available; otherwise it recognizes the
Arm toolchain path used in this setup. To select another installation, set
`CROSS_PREFIX`, or set `CROSS_CC`, `CROSS_OBJCOPY`, `CROSS_READELF`, and
`CROSS_NM` individually.

Fetch the AOSP scripts into the ignored `tools/third_party/` directory:

```sh
tools/fetch-android-tools.sh
```

The fetch script downloads `mkbootimg.py`, its GKI certificate helper, and
`avbtool.py` from AOSP Gitiles. `MKBOOTIMG`, `AVBTOOL`, and `PYTHON` can
override their defaults.

## Build

```sh
shim/build.sh --board bluejay
shim/build.sh --board bluejay --avb
shim/build.sh --board sweet
```

Bluejay outputs are `shim/out/shim-boot.img` and
`shim/out/shim-boot-avb.img`. The AVB test key is generated at
`shim/out/bluejay-testkey.pem`, which is ignored by git. Increase
`AVB_PARTITION_SIZE` if the target boot partition is larger than the 64 MiB
default.

The sweet v2 image uses the ignored stock DTB at
`dtb/boot_unpacked/dtb`; set `SWEET_DTB` to another copy. The board table,
generated C header, tool downloads, images, and private test key are not
committed.

## macOS host (Apple silicon)

The shim, its host tests, the boot-safety audit and the phone tools also run on a Mac (*observed* 2026-10-26: shim builds for bluejay
and oriole, `tools/check-all.sh` passes except the pre-existing patch-number gap; phone tools checked with stubs and with no phone
attached, not yet with a phone). One-time setup:

```sh
brew install coreutils flock shellcheck
brew install --cask android-platform-tools
python3 -m venv .venv && .venv/bin/pip install lz4 cryptography
# Arm GNU Toolchain 15.2.rel1, darwin-arm64, aarch64-none-elf, extracted under ~/.local/opt (check the published sha256)
```

Then, in each shell, `. tools/macos/env.sh` before `shim/build.sh`, `tools/check-all.sh` or the phone tools. It selects:

- **GCC 15.2** for the shim. Homebrew's GCC 16 compiles it but fails the audit's self-tests (they pin GCC 15 code shapes).
- **x86_64 host tests under Rosetta** (`tools/macos/gcc`): on an AArch64 host the shim's `__aarch64__` paths would run real `smc`/`mrs`
  instructions and trap.
- **GNU coreutils** first on `PATH` (`timeout`, `stat -c`, `sha256sum`).

Host differences the phone tools handle themselves (`tools/hostcompat.sh`, `tools/usb-ids`): USB ids come from the IORegistry instead of
sysfs/`lsusb`, and `tools/usb-log.py` finds the shim's CDC-ACM log as `/dev/cu.usbmodem*` (read from Apple's IOSerialBSDClient keys,
*not yet observed* with the gadget). `xrun` is still Linux-only (sysfs, ESP camera, `ip`).
