# 44 - Page flipping on the Pixel 6 display (gs101 DECON/DPP) instead of the per-frame CPU copy

Status: DESIGN, 2026-10-27. Nothing here has run. Read-only research plus one hardware attempt (run 7, which hung, see 0.3).
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

## 1. The decision the dump makes

| Dump shows | Meaning | Design |
|---|---|---|
| SysMMU `CTRL` bit 0 = 0 (or `CTRL_VM` 0 with no page table), and the scanning RDMA's `BASEADDR_Y8` = 0xFAC00000 | the DPP reads physical addresses (bypass) | **A: contiguous buffers below 4 GB** |
| SysMMU enabled, `FLPT_BASE` set, `BASEADDR_Y8` != 0xFAC00000 | the bootloader set up a page table; the DPP reads device virtual addresses | **B: map our buffers into that table** (or take over the SysMMU) |

Also read: which window is enabled and which channel (DPP layer) feeds it; that layer's `SRC_SIZE`, `IMG_SIZE`, stride (4320 expected), format in `IN_CTRL_0`.

## 2. Design A (bypass): contiguous scanout buffers

1. Display size: render at the panel's 1080x2400 so no crop is needed. Today `xnu 0060` makes the logical display iPhone X sized (1125x2436) and
   `present()` crops it (`fOffX/fOffY`). Option: boot-arg `sweetfb_native=1` already exists (presented size = panel size); CoreAnimation then
   allocates 1080x2400 scanout surfaces. Check that SpringBoard lays out (it did at 1125x2436 because that is a known iPhone geometry) [guess risk].
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
- U2: which RDMA layer and window scan out (dump bits 2/4).
- U3: whether 1080x2400 (`sweetfb_native=1`) lays out correctly in SpringBoard.
- U4: free physical memory below 4 GB for 3 x ~10.4 MB contiguous buffers (memory map of the ADT / XNU `gPhysBase` region).
- U5: the exact "update done" poll (decon_reg.c) and whether the HW trigger must be re-armed after a shadow update in command mode.
- U6: which DPU block stalled the bus in run 7 (0147 answers it).
