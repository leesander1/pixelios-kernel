#!/bin/bash
# Oriole hardware batch "wlan2": finish the Wi-Fi link test, then the XNU attach with the Pixel 6 firmware container.
#
#   device/google/oriole/batch-wlan2.sh                 (phone in fastboot, oriole; macOS: . tools/macos/env.sh first)
#   SKIP_A=1 device/google/oriole/batch-wlan2.sh        (runs B only)
#   RUN_C=1 device/google/oriole/batch-wlan2.sh         (also run C: only after the user said yes to the chip RAM writes)
#
# Firmware container: tools/extract-wlanfw.sh on the oriole factory zip -> WLANFW (default the sd1a.210817.015.a4 extraction, outside git).
#
# Run A, up to 20 min, shim only: --wlan-link=36 (the table chain of soc/google/gs101/wlan_seq.json, the same as run wlan-oriole1 which
#   reached S34 before the 600 s timeout: the oriole USB log is slow) with --timeout 1200, so S35 (SYS_MEM reset + bank sizing), S36 (ARM
#   CA7 halt) and the teardown summary (restore=ok) are seen. Chip writes: S34-S36 only, all undone by the module power cut in the teardown.
# Run B, 6 min, iOS kernel only (no GUI needed): --wlan-hold (the shim runs the chain to S30 and leaves the link up) + --wlan-level 2
#   (xnu 0124: READ-ONLY attach, chip id, cores, the three D11 wrapper reads) + --wlanfw (xnu 0128: the firmware container is found at
#   /chosen/memory-map WLANFW and its CRCs match). Expect "SWEET WLAN: stage 1 done level 2".
# Run C (RUN_C=1 only), 6 min: the same with sweetwlan=5 (xnu 0129-0131: guarded writes into the chip's RAM: SYS_MEM/ARM wrappers, the
#   firmware image, NVRAM, length token, rTLV; observed OK on bluejay, run C). The chip is NOT started (level 6 = the reset vector,
#   pinned per board since xnu 0148, is a later, separate step). Everything written is chip RAM, lost when the module power goes at the next reset.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 2
export PIXOS_DEVICE=oriole
K=${KERNEL:-$HOME/pixelios-artifacts/xnu-db4a387/kernel.development.sweet}
FW=${WLANFW:-$HOME/pixelios-artifacts/wlan-fw-oriole-sd1a.210817.015.a4/wlanfw.bin}
[[ -f $FW ]] || { echo "error: no firmware container $FW (tools/extract-wlanfw.sh)" >&2; exit 2; }
out=$HOME/pixelios-artifacts/batch-wlan2-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"
back() { tools/phone-lock run --owner batch-wlan2 -- tools/to-fastboot.sh 600 >/dev/null 2>&1 || { echo "phone not back in fastboot after $1: stop (hold Power+VolDown)"; exit 1; }; }

if [[ -z ${SKIP_A:-} ]]; then
	echo "== run A: Wi-Fi link chain S00-S36 with teardown, 1200 s"
	tools/probe-run --build-args "--pstore-fast --wlan-link=36" --expect "LINK summary" --timeout 1200 --label wlan-oriole2 >"$out/run-a.txt" 2>&1
	echo "run A exit $?: $(head -1 "$out/run-a.txt")"
	back "run A"
fi

xb() { # LABEL EXTRA_ARGS
	tools/xrun --kernel "$K" --board oriole --no-camera --cpus 8 --duration 360 --restart 420,bootloader --wlan-hold --wlan-level 2 --wlanfw "$FW" \
		${2:+--args "$2"} --fail-on 'panic\(cpu|Kernel trap at' --intent wlan --label "$1" >"$out/$1.txt" 2>&1
	echo "$1 exit $?: $(head -1 "$out/$1.txt")"
}
echo "== run B: XNU read-only attach (level 2) + firmware container check"
xb wd2-oriole1 ""
if [[ -n ${RUN_C:-} ]]; then
	back "run B"
	echo "== run C: level 5 (firmware image + NVRAM into the chip's RAM; chip not started)"
	xb wd5-oriole1 "sweetwlan=5"
fi

{
	echo "== summary"
	a=$(ls -dt logs/probe/*wlan-oriole2* 2>/dev/null | head -1)
	[[ -n $a ]] && grep -h -E "LINK (S3[4-6] (ok|timeout|fault|refused|skip)|summary)|chip id" "$a"/usb.txt 2>/dev/null | cut -c1-200
	for l in wd2-oriole1 wd5-oriole1; do
		b=$(ls -dt logs/runs/*$l 2>/dev/null | head -1)
		[[ -n $b ]] && { echo "-- $l"; grep -h "SWEET WLAN" "$b"/usbnet.log | cut -f2 | cut -c1-220 | head -60; }
	done
} | tee "$out/summary.txt"
echo "saved: $out"
