#!/bin/bash
# Oriole: everything queued for the next phone session, in one go (phone in fastboot or recovery, oriole; macOS: . tools/macos/env.sh first).
#
#   device/google/oriole/batch-next.sh                   (all three runs, ~45 min)
#   ONLY=dump|wlan device/google/oriole/batch-next.sh    (one part)
#
# 1. dump (15 min, iOS): kernel 49194a5 (xnu 0145-0148) + the CoreAnimation GPU overlay (gpu/eagl 235ae9f, with the icon surface probe)
#    + sweetdpudump=7 (xnu 0147: READ-ONLY DECON0, windows and DPP RDMA registers at the 600th swap, a "reading <block>" line and
#    100 ms before each block; the DPU SysMMUs, bits 8/16, are NOT read in this run: run 7 hung on the 0146 dump, docs/research/44 s.0.3).
#    If someone is at the phone: unlock it and open the home screen once (the icon probe logs what the icon surfaces hold).
#    If this run hangs (no USB log, no restart): the last "SWEET DPU: reading ..." line names the block; hold Power+VolDown, rerun ONLY=wlan.
# 2.+3. wlan (batch-wlan2.sh without RUN_C): the link chain to S36 with 1200 s, then the XNU read-only attach + firmware container check.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 2
export PIXOS_DEVICE=oriole
K=${KERNEL:-$HOME/pixelios-artifacts/xnu-49194a5/kernel.development.sweet}
OV=${OVERLAY:-$HOME/pixelios-artifacts/overlays/eagl7}
[[ -f $K ]] || { echo "error: no kernel $K (tools/ci-kernel --commit <sha of 0148>)" >&2; exit 2; }
[[ -f $OV/usr/local/lib/libpixosgl.dylib.gz ]] || { echo "error: no overlay $OV (pixelios-userland gpu/eagl/build-eagl.sh BASE_PLIST $OV)" >&2; exit 2; }
tools/phone-lock run --owner batch-next -- tools/to-fastboot.sh 600 >/dev/null 2>&1 || { echo "phone not in fastboot (hold Power+VolDown, then rerun)"; exit 1; }

if [[ -z ${ONLY:-} || ${ONLY:-} == dump ]]; then
	echo "== 1. iOS + GPU overlay + read-only DPU dump (mask 7)"
	KERNEL=$K EXTRA_ARGS="sweetfb_hz=60 sweetdpudump=7" SKIP_A=1 RUNB_LABEL=oriole-dpu1-ios device/google/oriole/batch-eagl1.sh "$OV"
	f=$(ls -dt logs/runs/*oriole-dpu1-ios 2>/dev/null | head -1)/usbnet.log
	echo "-- DPU lines"; grep -h "SWEET DPU" "$f" 2>/dev/null | cut -f2 | cut -c1-230
	echo "-- icon probes"; grep -h "pixos-eagl: probe" "$f" 2>/dev/null | cut -f2 | cut -c1-230 | head -30
	tools/phone-lock run --owner batch-next -- tools/to-fastboot.sh 600 >/dev/null 2>&1 || { echo "phone not back in fastboot after the dump run (hold Power+VolDown): stop"; exit 1; }
fi
if [[ -z ${ONLY:-} || ${ONLY:-} == wlan ]]; then
	echo "== 2./3. Wi-Fi: link chain to S36, then the XNU read-only attach"
	KERNEL=$K device/google/oriole/batch-wlan2.sh
fi
