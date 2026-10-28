# 47 - A real battery reading on the Pixel 6 (MAX77759 fuel gauge over HSI2C12)

Status: DESIGN, 2026-10-27. F1 implemented as xnu patch 0156 (`sweetfg=1`, ADT /sweet-fg), not yet run. Tags: **[src file:line]**, **[obs]**, **[guess]**.
Sources (outside git, `~/pixelios-artifacts/refs/`): `gs-dts` (kernel/gs @ android-gs-raviole-5.10-android13-qpr3, 6e771b23) and
`gs-bms` = `kernel/google-modules/bms` @ the same branch (1cf4358a).

## 1. Today

The status bar's 100 % is a constant: xnu 0061 (`SweetBattery`, an `IOPMPowerSource`) came from the Xiaomi port and reads a Qualcomm
SPMI PMIC only with `sweetbattery=1`; otherwise it publishes a static full battery [src xnu/patches/0061-sweet-battery-spmi.patch:440-470].
The publishing half (`poll()` -> `setCurrentCapacity`, `setVoltage`, `setIsCharging`, `setExternalConnected`, :289-297, :389) is reusable;
only the data source is wrong for gs101.

## 2. The hardware

- Battery: 4520 mAh (`google,chg-battery-capacity`) [src gs101-oriole-battery.dtsi:9-11].
- Fuel gauge: the MAX77759's ModelGauge m5 block, `max77759_fg` = `compatible "maxim,max77759"`, I2C address **0x36**, alert FG_INT_L on
  **gpa9-3** (active low), `maxim,gauge-type = <2>` (= `MAX_M5_GAUGE_TYPE`, max1720x_battery.h:27), `maxim,rsense-default = <500>`
  (10 uOhm units = 5 mOhm) [src gs101-raviole-battery.dtsi:155-166]. (`MAX_M5_I2C_ADDR 0x6C` in max_m5.h:22 is the 8-bit form of 0x36.)
- Bus: `hsi2c_12: hsi2c@10D50000`, `samsung,exynos5-hsi2c`, USI v2 (`samsung,usi-i2c-v2`), 400 kHz (`clock-frequency`), default clock
  200 MHz, SCL clock stretching, interrupt `IRQ_USI12_USI_PERIC1`, clocks `VDOUT_CLK_PERIC1_USI12_USI` + `GATE_PERIC1_TOP0_USI12_USI`, pins
  **gpp23-4 (SCL) / gpp23-5 (SDA)** [src gs101-usi.dtsi:337-351; gs101-raviole-battery.dtsi:123-128]. Same peripheral block (PERIC1) and pad
  bank (gpp23) as the touchscreen's USI11/SPI11 that xnu already clocks (soc.json "touch"), so the CMU/USI handling is shared ground.

## 3. Registers to read (16-bit, little-endian on the wire) [src gs-bms]

| Reg | Name | Unit | Source |
|---|---|---|---|
| 0x21 | DevName | identity (first read: proves the bus) | max1720x.h:62 |
| 0x06 | RepSOC | 1/256 % (`val >> 8` = %) | max1720x.h:33; max1720x_battery.c:522-526 |
| 0x09 | VCell | 78.125 uV | max1720x.h:36; max1720x_battery.h:46-50 |
| 0x0A / 0x0B | Current / AvgCurrent | s16 * 1.5625 uV / Rsense (`val * 156250 / rsense` uA, rsense in 10 uOhm) | max1720x.h:37-38; max1720x_battery.c:534-538 |
| 0x08 | Temp | s16 / 256 degC | max1720x.h:35; max1720x_battery.c:540-544 |
| 0x05 / 0x35 | RepCap / FullCapRep | capacity (reg_to_micro_amp_h with rsense) | max1720x.h:32,76; max1720x_battery.h:33 |
| 0x11 / 0x20 | TTE / TTF | time to empty / full | max1720x.h:45,61 |
| 0x00 | Status | flags | max1720x.h:27 |

Charging = `AvgCurrent > 0` [guess on the sign convention: verify against a plugged-in reading]; external power = USB VBUS (the USB gadget
already knows it is enumerated) or the MAX77759 charger block (another I2C address on the same bus, not needed for a first version).

## 4. Stages

| Stage | What | Risk |
|---|---|---|
| F1 | Shim read-only: the HSI2C12 registers and the CMU_PERIC1 USI12 gate/mux words (behind the same "is the block clocked" gate the touch probe uses, run 7 lesson), the gpp23 pin config | read-only |
| F2 | Shim: configure USI12 as I2C, one HSI2C read transaction `0x36: 0x21` (DevName), then RepSOC/VCell; the bus is put back as found. Programming model from Linux `drivers/i2c/busses/i2c-exynos5.c` (to fetch and cite) | controller writes only; reads from the gauge |
| F3 | XNU: an HSI2C12 read helper + `SweetBattery` data source for gs101 (RepSOC, VCell, AvgCurrent, Temp every 30 s, the existing timer), selected by board | the gauge is only read, never written (no model loading, no config) |

## 5. Unknowns

- U1: whether ABL leaves HSI2C12 clocked and configured (it may read the gauge for off-mode charging): F1 answers it.
- U2: the HSI2C timing values for 400 kHz from the PERIC1 USI12 clock as XNU finds it.
- U3: the sign of Current while charging, and whether RepSOC is valid without Android's model load (`max_m5` loads a model at boot in
  Android; the gauge keeps its own state across reboots, so it should already be learned) [guess].

## 6. F1 as built (xnu 0156)

F1 runs inside XNU, not the shim: the same place F3 will live, and the touch driver (xnu 0088/0089) already reads CMU_PERIC1 and the gpp23 bank
there. `bsd/dev/sweet_fg_gs101.c`, boot-arg `sweetfg=1`, delay `sweetfgdelay` (default 60 s). It prints the CMU_PERIC1 USI12 words (mux 0x650/0x654,
div 0x1810, gates ipclk_5 0x2030 / pclk_5 0x2050 / rstnsync 0x206C, QCH 0x3030: Linux clk-gs101.c:4047-4105), the sysreg USI12 mode (0x10C21010),
the gpp23-4/5 pad state, and the HSI2C12 registers (i2c-exynos5.c:37-60) plus its USI CON/OPTION only when both gates read CG_VAL = 1. Nothing is
written. The answers decide F2: if ABL leaves USI12 clocked and in I2C mode (U1), F2 is one controller setup and a read of DevName (0x21).
