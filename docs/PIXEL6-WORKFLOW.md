# Working on PixOS for the Pixel 6 (oriole): the loop, the tools, the state

How to pick up this work as another agent (or person). The rules are in [AGENTS.md](../AGENTS.md) (hard rules: reversible only,
never write bootloader/modem/persist/efs/vbmeta/boot*/dtbo/GPT, userdata only after the user confirms, adb/fastboot only when the
attached device reports product `oriole`, no secrets/firmware/Apple binaries in git, cite every constant, push only when the user says so).
Each tool is documented on its own in [AUTOMATION.md](AUTOMATION.md); this page is the end-to-end loop and where every thread stands.

## 1. The pieces

| What | Where | Notes |
|---|---|---|
| Kernel: XNU patch series + shim (boot stub) + tools | `~/code/pixelios-kernel`, branch `wip/gcc16-build`, remote = the user's fork `leesander1/pixelios-kernel` | patches in `xnu/patches/NNNN-*.patch`, applied in order on Apple's xnu by CI |
| Userland: iOS root build + GPU stack | `~/code/pixelios-userland`, branch `wip/macos-build` (local commits only) | `gpu/` = Mesa Panfrost for iOS, libdrm-xnu, the GL frontend, the EAGL stand-in |
| Artifacts (never in git) | `~/pixelios-artifacts/` | CI kernels `xnu-<sha>/`, Mesa builds `gpu/`, Wi-Fi firmware `wlan-fw-oriole-*/`, iOS root image, IPSW dmgs |
| Phone | Pixel 6 **oriole** (not the 6a/bluejay some older notes describe; same BCM4389 Wi-Fi, same SoC) | `export PIXOS_DEVICE=oriole` for every tool |
| Run logs | `logs/runs/<UTC>-<label>/usbnet.log` (iOS boots), `logs/probe/<UTC>-<label>_/usb.txt` (shim probes) | recorded results go to `device/google/oriole/hardware/*.txt` |

The phone has userdata flashed with the iOS 16.7.16 root once (`~/pixelios-artifacts/flashed-userdata.txt`). Every test boot is
`fastboot boot` of a RAM image (kernel + payload): nothing is flashed per run. Files in the root are changed per boot with the dev overlay.

## 2. The hardware loop

1. **Phone in fastboot**, product oriole: `PIXOS_DEVICE=oriole tools/phone-state` must print `state=fastboot product=oriole`.
   After a shim run the phone comes back in *recovery* (minutes later); `tools/phone-lock run --owner NAME -- tools/to-fastboot.sh 600` moves it.
2. **Shim probe** (no iOS, seconds to minutes): `tools/probe-run --build-args "--pstore-fast <flags>" --expect "<line>" --label <name>`.
   Flags: `--wlan-probe`, `--wlan-link=N` (Wi-Fi power-up chain, needs `--timeout 1200` on oriole: its USB log is slow), `--gpu-probe`,
   `--gpu-rails`, `--touch-probe=...` (AUTOMATION.md).
3. **iOS boot**: `tools/xrun --kernel K --board oriole --gui --touch --dvfs 1803000,1836000,1826000 --gpu-handover --cpus 8 --duration 900
   --restart 960,bootloader --overlay DIR --args "..." --label <name>`. It builds the image, boots it, captures the USB network log
   (`usbnet.log`) and restarts the phone to the bootloader at the end. macOS: `. tools/macos/env.sh` first; the Mac's USB network address
   is set once with `sudo networksetup -setmanual "Sweet iOS (USB Ethernet)" 192.168.7.1 255.255.255.0` (already done).
4. **Batches**: put several runs in one script so one phone session tests many things (`device/google/oriole/batch-*.sh`, e.g.
   `batch-eagl1.sh`: `SKIP_A=1`, `RUNB_LABEL=`, `KERNEL=`, `EXTRA_ARGS=` env knobs). Queue the next batch to start when the previous one
   prints `saved:` rather than waiting by hand.
5. **Logs a process writes to /dev/null** reach `usbnet.log` only for names in boot-arg `sweetnull=a,b,c` (xnu patch 0048), prefixed `|name|`.
   The USB log replays only the last 64 KiB from before the link came up.
6. **Record** what each run showed (the facts, the log path, the next step) in `device/google/oriole/hardware/<topic>-<date>.txt`, commit.

Payload limit: keep image + overlay under ~32 MiB (30.4 MiB boots, 34.4 MiB returns to fastboot in 4 s). Big files ship gzipped and are
unpacked on the phone (`pixelios-userland gpu/common/gzunpack.c`; the phone has no clock, so "changed" = gzip trailer, never mtime).

## 3. Kernel changes (XNU patches)

- Add a **new** patch with the next free number (`ls xnu/patches | tail`; GPU/display work uses 0140+, 0145 is the latest). Do not edit
  old patches that already ran on hardware.
- To write a hunk against a file that many patches change, rebuild that file first: apply, in order, only the parts of every patch that
  touch it, into an empty dir (see the Python splitter used for 0145: split each patch on `--- a/` and feed the parts whose `+++ b/` is the
  file to `patch -p1`), edit a copy, `diff -u` the two, then re-apply the whole sequence again to prove the new patch applies.
- New boot-args go into `tools/bootargs-known.txt`. `python3 -I tools/validate-repo.py` currently fails on old findings (patch-number
  gaps 0121/0125/0133, README paths); a change must not add new ones.
- **Build** (CI, ~5-10 min): commit, `git push`, then `gh workflow run xnu.yml --repo leesander1/pixelios-kernel --ref wip/gcc16-build`
  (pushing to `main` also triggers it; workflows on the fork are enabled). Then
  `tools/ci-kernel --commit HEAD --expect-string "<a string your patch logs>"` downloads and verifies it to `~/pixelios-artifacts/xnu-<sha>/`.
  **Local build on this Mac** (no CI minutes, ~3 min incremental): `tools/xnu-mac-build [--compare CI_KERNEL]` -> kernel at
  `~/pixelios-artifacts/macbuild/out/kernel.development.sweet` (feed it to `tools/xrun --kernel`); see docs/LOCAL-BUILD.md "macOS".
  It builds the working tree's `xnu/patches`, committed or not. (`tools/xnu-local-build` is the Linux equivalent.)
- Kernel in use: the newest `~/pixelios-artifacts/xnu-<sha>` from `tools/ci-kernel` (as of 2026-10-27 evening: patches up to 0153 =
  backlight opt-in 0150 + console replay 0151-0153 (`sweetreplay=TEXT`, fires ~200 s after AppleCLCD start: use `--duration 480`)). Before that:
  `~/pixelios-artifacts/xnu-db4a387/kernel.development.sweet` (patches up to 0149: the backlight service, log-only unless
  `sweetbright=1`; up to 0148: surface row alignment + copy timing,
  the staged read-only DPU dump `sweetdpudump=MASK`, the per-board Wi-Fi pin). `xnu-6757417` = up to 0145 (the last kernel that ran on hardware).

## 4. Userland GPU stack (pixelios-userland `gpu/`)

- One-time builds: `gpu/build-mesa-host.sh` (host tools), `gpu/build-mesa-ios.sh` (Mesa 26.2.5 Panfrost for iOS arm64, patches in
  `gpu/patches`) into `~/pixelios-artifacts/gpu/`.
- **GPU self-tests** (one binary, three launchd jobs): `gpu/selftest/build-selftest.sh BASE_PLIST OUT_DIR`. All three pass on oriole.
- **CoreAnimation on the GPU**: `gpu/eagl/build-eagl.sh BASE_PLIST OUT_DIR` makes an overlay: `libpixosgl.dylib.gz` (Mesa + `eagl.m`),
  the loader `libpixosgl-load.dylib`, `pixos-gz-unpack` + root job `org.pixelios.gl-unpack`, `pixosgl.crash`. Boot it with
  `--overlay OUT_DIR --args "sweetmali=1 sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/local/lib/libpixosgl-load.dylib
  sweetnull=backboardd,SpringBoard,pixos-gz-unpack sweetfb_hz=60"` plus `--gpu-handover`. `BASE_PLIST` = the root's original
  `launchd.plist`: `~/pixelios-artifacts/overlays/launchd.orig.plist`. Built overlays are kept in `~/pixelios-artifacts/overlays/<name>/`
  (`eagl7` = gpu/eagl 235ae9f with the icon surface probe).
- Log lines: `pixos-eagl:` (stand-in), `pixos-gl:` / `pixos-drm:` / `MESA:` (Mesa side), `SWEET MALI:` (kernel GPU driver), `SWEET FB:`
  (kernel framebuffer). The stand-in prints frames, fps and "flush+GPU wait ms per frame" every 30 s.
- Crash backtraces: `build-eagl.sh` keeps an unstripped `libpixosgl.dylib.sym`; find the load base from the `CRASH backboardd bt` frames
  (each return address must follow a `bl`/`blr`) and look the offsets up with `nm -n`.
- Safety: the loader falls back to the CPU renderer after two backboardd starts without 2 minutes of GPU frames, so a bad build costs
  a few seconds of display, not the phone. `touch /usr/local/lib/pixosgl.off` in an overlay disables it.

## 5. Where each thread stands (2026-10-27)

**Next phone session:** `device/google/oriole/batch-next.sh` runs everything queued (the read-only DPU dump with the GPU overlay, then the
Wi-Fi link test and XNU attach). After run 7 the phone needs a Power+VolDown hold first.


| Thread | State | Next step |
|---|---|---|
| Boot, lock screen, touch, keyboard | working (boots 5-8) | - |
| GPU self-tests (clear, IOSurface, GLES 3.1 triangle) | pass | - |
| CoreAnimation on the GPU | **works**: the whole UI draws via Mesa on the Mali-G78, GPU time ~2 ms/frame, no crashes (runs eagl2-6, `hardware/wlan-eagl1-2026-10-27.txt`) | home screen app icons are blank. Established: with the CPU renderer (boot 6 photo) icons render; with the GPU renderer the icon surfaces (600x600, seed 1) are EMPTY when backboardd binds them (probe, run dpu1: nonzero 0/256 from the CPU's own view), so the producer never draws them: not a GPU/cache problem. SpringBoard's "IOServiceMatching failed for: AppleM2ScalerCSCDriver" appears in CPU-renderer runs too, so it is not the switch. Next: find what fills those surfaces in the CPU-renderer case (CA SW renderer offscreen pass vs a client-side image path chosen by the server's GPU capability) |
| Lag | the kernel copies every frame to the panel with the CPU: 11-25 ms per frame (patch 0145 timing) | **page flip proven possible** (xnu 0161, run flip1-oriole3: the display scanned a buffer at 0xC8000000, photo; physical addresses, no SysMMU): next = scanout surfaces in the 0xC0000000-0xE0000000 carve-out + present() flips (research 44 section 5) |
| Wi-Fi (BCM4389) | shim chain S00-S36 restore=ok; XNU attach level 2 (run wd2-oriole5) and level 5 (run wd5-oriole1: firmware, NVRAM, token and rTLV written into chip RAM and read back, every CRC matches, chip left halted) level 6 (run wd6-oriole1: reset vector at backplane 0) and level 7 (xnu 0154, run wd7-oriole1: the CA7 released, the firmware BOOTS and publishes pciedev_shared_t (version 7, no trap) at 0x00458d50 after 550 ms, CA7 put back into reset) pass on oriole; xnu 0155 prints the firmware's own boot log (run wd7-oriole4: RTE PCIE-MSGBUF 20.25.485.19 on BCM4389 r3, three slices attached, boot 519 ms); early lines via `sweetreplay=WLAN` + `--duration 480` (grep the log with `-a`) | the host side of msgbuf (rings, mailboxes, doorbells): XNU driver, design first |
| Bluetooth | surveyed (`docs/research/45-bluetooth-survey-oriole.md`): BCM4389 BT = HCI over USI16 UART `0x175B0000`, pins gpp16-2/gpp14-3/gpa6-6; iOS wants `/dev/uart.bluetooth` + `/dev/bt*` + BlueTool | `BCM.hcd` extracted (B0 done); next the shim UART/HCI_Reset probe (B1/B2) |
| Brightness | xnu 0149 service STALLS the UI when published (dpu1), opt-in since 0150 (`sweetbacklight=1`); DSIM path verified open (packet-go off). xnu 0149: the service iOS BrightnessControl looks for (`backlight-control`, `brightness-nits` 16.16) maps nits to panel DBV; log-only by default, `sweetbright=1` sends DCS 0x51 via DSIM0 (`docs/research/46`) | next run: see `SWEET BL:` requests + the DSIM dump (mask bit 32); then a run with `sweetbright=1` (user present) |
| Buttons | power and volume keys WORK (run dpu2 2026-10-27: SWEET KEYS key=1/key=2 down/up, iOS showed its volume HUD) | - |
| Battery | real on oriole: xnu 0156-0159 read the MAX77759 fuel gauge (percent, voltage, current, temperature) and its charger (plugged in / charging / done) and SweetBattery publishes them (`sweetbattery=2`, default in oriole images; runs fg3/fg4: 91 %, 4321 mV, USB plugged, charge done) | unplugged and charging states not yet observed; the 2x current/capacity scale; low-battery warnings untested |
| Vibration | not started (Cirrus haptics amp on I2C + its firmware from the factory image) | survey |
| Audio, sensors | not started; behind the AOC co-processor (aoc@0x94000000) and its firmware/IPC | large |
| Camera | not started (Google ISP stack) | last |
| Cellular | out of scope (modem firmware, carrier stack) | - |

### Page flip research so far (sources in `~/pixelios-artifacts/refs/`, outside git)

- Display driver: `gs-display` = `kernel/google-modules/display` @ `android-gs-raviole-5.10-android13-qpr3` (3373c1b8), gs101 = `samsung/cal_9845`.
  Device tree + SysMMU driver: `gs-dts` = sparse `kernel/gs` @ same branch (6e771b23): `gs101-drm-dpu.dtsi`, `gs101-sysmmu.dtsi`, `drivers/iommu/samsung-iommu.[ch]`.
- DPP input DMA (RDMA) L0-L5 at `0x1C0B0000 + 0x1000*n` (`regs-dpp.h`): `RDMA_ENABLE` 0x0, `IN_CTRL_0` 0x8, `SRC_SIZE` 0x10, `SRC_OFFSET`
  0x14, `IMG_SIZE` 0x18, `BASEADDR_Y8` 0x40 (32-bit device address), `SRC_STRIDE_1` 0x54 (stride 0 in bits 15:0, `dpp_reg.c`), shadow copies at +0x400.
- DECON0 `0x1C300000`: `GLOBAL_CON` 0x20, `TRIG_CON` 0x30 (the shim writes 0x3061 = HW trigger, command mode), `SHD_REG_UP_REQ` 0x50
  (bit per window; latches the shadow registers at the next frame), window registers at `0x1C310000`.
- DPU SysMMU v8 `sysmmu_dpu0/1/2` at `0x1C100000/0x1C110000/0x1C120000`: `CTRL` 0x0 (bit 0), `CFG` 0x4, `STATUS` 0x8, `VERSION` 0x34,
  per-VM `CTRL_VM` 0x8000 (bit 0), `FLPT_BASE` 0x800C. The DPU nodes list all three as `iommus`.
- Boot framebuffer `0xFAC00000`, 1080x2400, stride 4320 (below 4 GB, so the bootloader may scan out with the SysMMU bypassed: unmeasured).
- Run 7 hung the phone with the 0146 dump (a register read stalled the bus before the USB log was up; the watchdog is off, so it
  needs a Power+VolDown hold). 0147 stages it: dump only at the 600th swap, a `reading <block>` line + 100 ms before each block,
  `sweetdpudump` mask 1 DECON0 / 2 windows / 4 RDMA / 8 SysMMU global / 16 SysMMU VM 0. Run `sweetdpudump=7` first.
- Lesson for any new MMIO read: never read an unproven block before the USB log is up, and mark each block in the log first.
- Open: is the DPU SysMMU on at handoff (decides contiguous buffers vs page tables), which RDMA layer scans out, and whether a base-address
  write + `SHD_REG_UP_REQ` flips cleanly in command mode. The read-only dump answers the first two.

## 6. Habits that saved time

- Fix several things per hardware run, not one: build everything that can be tested, then one batch.
- Every new path logs what it decided (and caps its own log lines); the next run's log should answer the open question by itself.
- When something fails on the phone, rebuild the failing piece's symbols or source first and read the actual error (`MESA: error: ...`,
  `CRASH ... bt`) before changing code; most fixes here came from one log line.
- Commit after each verified step (no AI attribution lines, never commit `.claude/`); write results into `device/google/oriole/hardware/`.
