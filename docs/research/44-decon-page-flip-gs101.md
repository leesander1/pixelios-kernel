# 44 - Page flipping on the Pixel 6 display (gs101 DECON/DPP) instead of the per-frame CPU copy

Status: DESIGN, 2026-10-27; 2026-10-28: the reversible flip test (xnu 0161) ran and the panel showed the buffer: design A (section 2). Read-only research plus one hardware attempt (run 7, which hung, see 0.3).
Tags: **[src file:line]** read from source, **[obs run]** observed on hardware, **[guess]**.

Sources (outside git, `~/pixelios-artifacts/refs/`): `gs-display` = Google `kernel/google-modules/display` @ `android-gs-raviole-5.10-android13-qpr3`
3373c1b8 (`samsung/cal_9845` = gs101); `gs-dts` = sparse `kernel/gs` @ the same branch 6e771b23 (`arch/arm64/boot/dts/google/gs101-drm-dpu.dtsi`,
`gs101-sysmmu.dtsi`, `drivers/iommu/samsung-iommu.[ch]`).

## 0. Why

- CoreAnimation renders on the Mali-G78 in ~2 ms per frame [obs eagl3-6, `pixos-eagl: ... flush+GPU wait 1.6-2.1 ms per frame`].
- The kernel then copies each frame (layer 0, 1125x2436 IOSurface) into the boot framebuffer with the CPU: `SWEET FB: panel copy 1080x2400 avg 11189 us
  max 24311 us (300 copies)` [obs eagl5, xnu 0145 timing]. That is most of a 16.7 ms frame and the reason the UI still feels laggy.
- Page flip = point the display controller at the buffer CoreAnimation just drew; no copy.

### 0.1 Registers (all [src])

| Block | Base | Registers used |
|---|---|---|
| DPU_DMA RDMA L0-L5 | `0x1C0B0000 + 0x1000*n` (regs-dpp.h:20-28; dtsi drmdpp0-5 reg) | `RDMA_ENABLE` 0x0, `IN_CTRL_0` 0x8, `SRC_SIZE` 0x10, `SRC_OFFSET` 0x14, `IMG_SIZE` 0x18, `BASEADDR_Y8` 0x40, `SRC_STRIDE_1` 0x54 (stride 0 = bits 15:0, dpp_reg.c:696-698), shadow = +0x400 (`DMA_SHD_OFFSET`, regs-dpp.h:31) |
| DECON0_MAIN | `0x1C300000` (dtsi drmdecon0 reg "main") | `GLOBAL_CON` 0x20 (bit 8 = command mode, regs-decon.h:83-95), `TRIG_CON` 0x30 (regs-decon.h:97-116; the shim writes 0x3061), `SHD_REG_UP_REQ` 0x50 (bit per window, `SHD_REG_UP_REQ_WIN`, decon_reg.c:2045-2051), shadow +0x800 |
| DECON_WIN / WINCON | `0x1C310000` / `0x1C330000` (dtsi reg "win" / "wincon") | per window 0x1000; WINCON word 0 = enable bit 0, channel map bits 6:4 (regs-decon.h:516-525) |
| DPU SysMMU v8 x3 | `0x1C100000 / 0x1C110000 / 0x1C120000` (gs101-sysmmu.dtsi:185-223; all three are `iommus` of every DPP) | `CTRL` 0x0 bit 0, `CFG` 0x4, `STATUS` 0x8, `VERSION` 0x34; VM 0: `CTRL_VM` 0x8000 bit 0, `FLPT_BASE` 0x800C (samsung-iommu.c:37-70, samsung-iommu.h:186-209) |

Boot framebuffer: `0xFAC00000`, 1080x2400, stride 4320, a8r8g8b8 [obs, board.json fb]. `BASEADDR_Y8` is 32 bits wide.

### 0.2 How a flip is latched (from the driver, [src])

`dpp_reg_configure_params` writes the RDMA registers (they land in the shadow set), then `decon_reg_update_req_window(id, win)` sets the window's bit in
`SHD_REG_UP_REQ`; the hardware copies shadow to active at the next frame start. In command mode (TRIG_CON HW trigger from the panel TE) the next
frame is the next TE pulse. A flip is therefore: write `BASEADDR_Y8` (+ stride if it differs), set the window bit, and do not reuse the old buffer
until the bit clears (the driver polls it: `decon_reg_wait_update_done*` [guess on the exact name; verify]).

### 0.3 Run 7 (0146 dump) hung the phone

The 0146 dump at AppleCLCD start stalled the bus [obs eagl7: no USB log, sweetrestart never fired]. 0147 dumps only at swap 600 with a log line and
100 ms before each block, masked: 1 DECON / 2 windows / 4 RDMA / 8 SysMMU global / 16 SysMMU VM. First run `sweetdpudump=7`.

## 0.4 Dump results (run dpu2, 2026-10-27, xnu 0147 mask 0x27) [obs]

DECON0 `GLOBAL_CON` 0x133 (command mode), `TRIG_CON` 0x3061, `SHD_REG_UP_REQ` 0. Only **window 5** is enabled, channel map 0 = **DPP L0**.
RDMA L0: `RDMA_ENABLE` 0x40000000, `IN_CTRL_0` 0xff400000, `SRC_SIZE` = `IMG_SIZE` 0x09600438 (2400 x 1080), `SRC_OFFSET` 0,
`BASEADDR_Y8` = shadow = **0xFAC00000** (the boot framebuffer's physical address), `SRC_STRIDE_1` 0 (stride field 0; how the RDMA derives
4320 then is to be read from dpp_reg.c). L1-L5 unused. U2 closed. U1 (SysMMU) still open: mask 8/16 not read; after this run the SysMMU
read is the main suspect for run 7's hang, so it gets its own run, or is replaced by the reversible flip test (a base address outside the
splash: picture = bypass, fault/garbage = translated; restore 0xFAC00000 right after).

## 1. The decision the dump makes

| Dump shows | Meaning | Design |
|---|---|---|
| SysMMU `CTRL` bit 0 = 0 (or `CTRL_VM` 0 with no page table), and the scanning RDMA's `BASEADDR_Y8` = 0xFAC00000 | the DPP reads physical addresses (bypass) | **A: contiguous buffers below 4 GB** |
| SysMMU enabled, `FLPT_BASE` set, `BASEADDR_Y8` != 0xFAC00000 | the bootloader set up a page table; the DPP reads device virtual addresses | **B: map our buffers into that table** (or take over the SysMMU) |

Also read: which window is enabled and which channel (DPP layer) feeds it; that layer's `SRC_SIZE`, `IMG_SIZE`, stride (4320 expected), format in `IN_CTRL_0`.

## 2. Design A (bypass): contiguous scanout buffers

1. Display size: keep CoreAnimation at 1125x2436 and let the DPP crop. `sweetfb_native=1` (panel size) was tried with 0060 and UIKit has no
   status bar / layout data for a 360x800-point screen (0060 header comment), so native size is not an option. The RDMA crops by itself:
   `SRC_SIZE` = the buffer's width (stride / 4) and height, `SRC_OFFSET` = (x 22, y 18) = present()'s `fOffX/fOffY` for 1125x2436 on
   1080x2400, `IMG_SIZE` = 1080x2400 (regs-dpp.h:143-160: IDMA_SRC_WIDTH/HEIGHT, IDMA_SRC_OFFSET_X/Y, IDMA_IMG_WIDTH/HEIGHT) [src; offset
   arithmetic from 0060's centring]. The dump shows the live SRC_SIZE / SRC_OFFSET / IMG_SIZE the bootloader set for 0xFAC00000.
2. Contiguous memory: the IOSurfaces CoreAnimation creates for scanout are ordinary SweetSurface allocations (IOBufferMemoryDescriptor,
   `0046`), not contiguous. Two ways:
   - a. SweetSurface allocates surfaces that look like scanout buffers (size = panel size, format 'b3a8'/'BGRA', created by backboardd)
     with `kIOMemoryPhysicallyContiguous` and a 32-bit physical mask (`IOBufferMemoryDescriptor::inTaskWithPhysicalMask`, mask 0xFFFFF000 below 4 GB).
     ~10.4 MB each, 3 buffers; may fail late in boot when memory is fragmented -> fall back to the copy.
   - b. Reserve a carve-out at boot (e.g. after the 0xFAC00000 splash region, if free; must be verified from the memory map) and hand
     slices of it to those surfaces.
3. `present()`: when layer 0's surface is contiguous and below 4 GB, write its physical address to the scanning RDMA's `BASEADDR_Y8`, the
   row bytes to `SRC_STRIDE_1` bits 15:0 if different, set the window bit in `SHD_REG_UP_REQ`; skip the memcpy. Otherwise copy as today.
4. Ordering: the GPU must be done with the frame before the flip (eagl already waits in glFlush and cache-syncs the surface); the old
   buffer may be reused only after `SHD_REG_UP_REQ` clears (CoreAnimation's swap-complete notification should be held until then).
5. First test, reversible: one flip from 0xFAC00000 to a second, CPU-filled contiguous buffer and back after 2 s, from a boot-arg-gated
   kernel test (no CoreAnimation involvement), with the readback of the active and shadow `BASEADDR_Y8` logged before and after.

## 3. Design B (SysMMU on)

Map each scanout buffer into the bootloader's DPU page table (format: samsung-iommu v8 two-level table, FLPT/SLPT, 4 KiB pages,
`samsung-iommu.c`), or build our own table and switch `FLPT_BASE` + TLB invalidate (`IDX_ALL_INV` 0x8010 in VM mode). Non-contiguous buffers
then work. Larger job; only if the dump shows the SysMMU on.

## 4. Unknowns

- U1: SysMMU state at handoff (dump bit 8/16).
- U2: closed: window 5 / DPP L0 / base 0xFAC00000 (0.4).
- U3: closed: no native size (UIKit); the DPP crops 1125x2436 -> 1080x2400 with SRC_OFFSET (22, 18).
- U4: memory for design A. XNU owns only the high bank (board.json `xnu_ram` 0x880000000 + 4 GB; `gPhysBase=0x880000000` in the SweetMali
  log), so ordinary contiguous IOSurfaces are above 4 GB and a 32-bit `BASEADDR_Y8` in bypass mode cannot reach them: design A needs a
  carve-out in the low bank 0x80000000-0xFFFFFFFF. Live FDT reserved regions on oriole [obs logs/probe/20261027T122610Z-wlan-oriole1_/usb.txt, "SECTION FDT memory and reserved"]:
  ect 0x90000000, gsa 0x90200000+4M, tpu 0x93000000+16M, aoc 0x94000000+48M, **sec_dram 0xB7200000-0xC0000000**, **sec_pt
  0xE0000000-0xE2500000**, cp (modem) 0xE8000000-0xF0800000 (static dtsi), abl 0xF8800000+16M, splash 0xFAC00000+0x9E3400, logs 0xFD3F0000+.
  Candidate: 0xC0000000-0xE0000000 (512 MB, unused by XNU and by every reserved node), e.g. 3 x 10.5 MB at 0xC8000000. Still to rule out:
  ABL's staging of the boot image, ramdisk and DTB (research 01: load addresses unknown); the shim prints `INITRD lo= hi=` (loader.c:78) on
  every XNU boot, read it in the next run; and XNU must map the carve-out (ml_io_map or a reserved IOMemoryDescriptor::withPhysicalAddress,
  as the framebuffer surface already does) without the VM ever owning it.
- U5: the exact "update done" poll (decon_reg.c) and whether the HW trigger must be re-armed after a shadow update in command mode.
- U6: which DPU block stalled the bus in run 7 (0147 answers it).

## 5. Result of the flip test (2026-10-28, xnu 0161, runs flip1-oriole2/3, device/google/oriole/hardware/flip-2026-10-28.txt)

- RDMA L0 `BASEADDR_Y8` := 0xC8000000 + `SHD_REG_UP_REQ` window 5 latches in one TE frame (1-15 ms; shadow 0x440 follows, the request bit
  clears) and back to 0xFAC00000 the same way, six times, no panic [obs].
- The panel showed the colour bars written at 0xC8000000 [obs, the user's photo]: the DPP reads physical addresses. **U1 closed: design A.**
- U4: ABL stages the ramdisk at 0x86000000-0x88E1F671 [obs, shim INITRD line on the panel]; 0xC8000000.. was free in practice (the buffer
  held its pattern and nothing faulted). The buffer must be mapped through IOMemoryDescriptor::withPhysicalAddress, not ml_io_map (10 MB
  exhausts the device-mapping VA, run flip1-oriole1 panic).
- Next (implementation): a carve-out allocator of panel-sized scanout surfaces at 0xC8000000+, SweetSurface backing for the surfaces
  backboardd presents, present() flipping instead of copying, and swap completion held until the update request clears.
