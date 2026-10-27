# 46 - Screen brightness on the Pixel 6 (Samsung s6e3fc3 OLED over MIPI DSI command mode)

Status: DESIGN, 2026-10-27. Nothing built or run. Tags: **[src file:line]**, **[obs]**, **[guess]**. Sources as research 44 (`gs-display`,
`gs-dts` in `~/pixelios-artifacts/refs/`).

## 1. Today

Brightness stays where the bootloader left it: nothing in PixOS sends the panel a brightness command. iOS's brightness slider and
auto-brightness have no effect [obs: no brightness path in xnu 0046/0077; IOMFB selectors seen from backboardd in run eagl3: 3, 4, 5, 6, 8,
12, 15, 17, 22, 27, 28, 29, 33, 50, 55, 57, 68, 74, 79, 84; which, if any, is brightness is unknown].

## 2. The panel command

- Oriole's panel: `samsung,s6e3fc3` [src gs-dts gs101-oriole-display.dtsi:10-12], driver `panel-samsung-s6e3fc3.c`.
- Brightness range: min 4, max 4095, Android default 1023 [src panel-samsung-s6e3fc3.c:642-644]; above max = HBM, a separate WRCTRLD (0x53)
  bit (`S6E3FC3_WRCTRLD_HBM_BIT` 0xC0, :40, :265-266): not used here.
- Command: standard DCS `set_display_brightness` 0x51 with the 12-bit value big-endian: `exynos_panel_set_brightness` swaps the bytes
  (panel-samsung-drv.c:839-855) and `mipi_dsi_dcs_set_display_brightness` sends the u16 little-endian, so on the wire: `51 HI LO`
  (e.g. 1023 = `51 03 FF`) [src]. Sent as a DCS long write (data type 0x39, 3 bytes) [guess on long vs short: the Linux helper sends a
  2-byte parameter, which `mipi_dsi_create_packet` turns into a long write; verify in drm_mipi_dsi.c].

## 3. Sending it from XNU (DSIM0)

- DSIM0 `0x1C2C0000` (size 0x300) [src gs101-drm-dpu.dtsi:176 "dsi"].
- Long write: payload words to `DSIM_PAYLOAD` +0x5C (bytes little-endian in the word: `0x51 | HI << 8 | LO << 16`), then the header to
  `DSIM_PKTHDR` +0x58 = data type 0x39 | word count low << 8 | word count high << 16 (`DSIM_PKTHDR_ID/DATA0/DATA1`, regs-dsim.h:233-238;
  `dsim_reg_wr_tx_header/_payload`, dsim_reg.c:2251-2261) [src].
- FIFO state: `DSIM_FIFOCTRL` +0x68: EMPTY_PH_SFR bit 10, EMPTY_PL_SFR bit 8, FULL_PH bit 11, FULL_PL bit 9 (regs-dsim.h:252-259) [src].
- Command mode batching: `DSIM_CMD_CONFIG` +0x80, `PKT_GO_EN` bit 16, `PKT_GO_RDY` bit 17 (regs-dsim.h:302-307). With packet-go enabled the
  DSIM holds commands until it is told to go (the Linux driver queues and releases them around vblank, exynos_drm_dsim.c:2091+). The plan
  only sends when `PKT_GO_EN` is clear; otherwise it logs and does nothing [src for the bits; behaviour with it set = guess].
- `DSIM_CMD_STATUS` +0x8C (abnormal cause bits 7:0) is read after the send.

## 4. Stages

| Stage | What | Risk |
|---|---|---|
| L1 | Read-only: DSIM0 `CMD_CONFIG`, `FIFOCTRL`, `CMD_STATUS`, `SFR_CTRL` (+0x64) added to the staged DPU dump (new mask bit 32, after DECON/RDMA have been read safely at least once: the run 7 lesson) | read-only; same caution as 0147 |
| L2 | Boot-arg `sweetbright=N` (4..4095, refused otherwise): at the 600th swap, if `PKT_GO_EN` = 0 and both FIFOs are empty, one `51 HI LO` long write, poll FIFOCTRL for empty (<= 20 ms), log CMD_STATUS. Visible test: N=200 then N=4000 | a wrong packet = a glitch or the panel ignoring it; values stay inside Android's own range |
| L3 | iOS brightness: find how backboardd sets brightness (an IOMobileFramebuffer selector or a backlight IOService property), translate its value to 4..4095 and send it as in L2 | found (section 4a): BrightnessControl `brightness-nits` on a `backlight-control` service; implemented in xnu 0149 |

## 4a. iOS side (found 2026-10-27 with ipsw on the iOS 16.7 cache, read-only)

- IOMobileFramebuffer sends brightness only once a BrightnessControl object is matched to it (`iomfb_bc_up` sets the enabled flag at
  object +0xB39 for a "BuiltIn" panel; `kern_SwapSetBrightness` otherwise logs "Brightness control is not enabled") [obs-RE].
- BrightnessControl.framework (`BCAppleBacklightBrtControl`) matches an IOService with `backlight-control` (IOPropertyMatch), reads
  `IODisplayParameters` (`brightness` {min,max}, `BrightnessMilliNits` {min,max,value} / 1000 = nits, optional `BrightnessMicroAmps`) and
  builds `BuiltIn`/`MaxNits`/`MinNits` from them; `setNits:` = `IORegistryEntrySetCFProperties(service, {"brightness-nits": nits * 65536})`
  (16.16) [obs-RE]. IOMFB selectors found on the way: 0x32 (50) = SetBrightnessCorrection (2 scalars, called by backboardd in run eagl3),
  0x42 (66) = SPLCSetBrightness (2 scalars) [obs-RE].
- xnu patch 0149 implements this (L3), with the hardware write behind `sweetbright=1` (L2) and the DSIM read in the dump mask bit 32 (L1).

## 5. Unknowns

- U1: whether the bootloader leaves packet-go enabled (L1 answers it).
- U2: whether a command sent between TE-triggered frames needs to wait for frame done (`DSIM_INTSRC` frame-done bit) to avoid a glitch.
- U3: iOS's brightness entry point and value scale (L3).
