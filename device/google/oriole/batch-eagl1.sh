#!/bin/bash
# Oriole hardware batch "eagl1" (2026-10-27): the first Wi-Fi link run on oriole, then iOS with CoreAnimation on the GPU.
#
#   device/google/oriole/batch-eagl1.sh OVERLAY_DIR        (phone in fastboot, oriole; macOS: . tools/macos/env.sh first)
#   SKIP_A=1 device/google/oriole/batch-eagl1.sh OVERLAY_DIR   (run B only)
#
# OVERLAY_DIR: built by pixelios-userland gpu/eagl/build-eagl.sh (libpixosgl.dylib.gz, libpixosgl-load.dylib, pixos-gz-unpack,
# pixosgl.crash, launchd.plist with job org.pixelios.gl-unpack).
#
# Run A, ~12-20 min on oriole (the USB log is slow: S34 at +705 s), shim only (fastboot boot, no iOS): --wlan-link=36, the table-driven BCM4389 power-up chain of
#   soc/google/gs101/wlan_seq.json (same rows as on bluejay, where S00-S36 ran with restore=ok; oriole uses the same pins,
#   board.json "wlan"): PERST/WLAN_EN, PCIe1 PHY isolation release and PHY tables, link up, iATU/BAR setup, the chip id read (S30),
#   EROM and core state reads, SRPWR request, SYS_MEM reset + bank sizing, ARM CA7 halt (S34-S36 are the only chip writes); then
#   the teardown of every started step (module power cut, PHY powered down, isolation set again, pins back to input). Nothing
#   persists past the run. Expect line: "LINK summary"; probe-run turns stopped=timeout|fault|refused or restore=FAILED into FAIL.
# Run B, 15 min, iOS: boots 6-8 setup (--touch, --dvfs), --gpu-handover (shader rail on, as in batch gpu1), sweetmali=1, and the
#   overlay: backboardd gets libpixosgl-load.dylib (boot-arg sweetenv), which loads Mesa + the EAGLContext stand-in, so
#   CoreAnimation's EAGLServer gets a GLES 3.1 context and should render on the Mali-G78 instead of its CPU renderer. If backboardd
#   crashes twice before 120 GPU frames, the loader falls back to the CPU renderer by itself (the display comes back).
# Nothing writes storage except the overlay (files under /usr/local in the iOS root, inside userdata).
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 2
ov=${1:?usage: $0 OVERLAY_DIR}
[[ -f $ov/usr/local/lib/libpixosgl-load.dylib && -f $ov/usr/local/lib/libpixosgl.dylib.gz ]] || { echo "error: $ov is not a build-eagl.sh overlay" >&2; exit 2; }
export PIXOS_DEVICE=oriole
K=${KERNEL:-$HOME/pixelios-artifacts/xnu-04457e5/kernel.development.sweet}
out=$HOME/pixelios-artifacts/batch-eagl1-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"

if [[ -z ${SKIP_A:-} ]]; then
echo "== run A: Wi-Fi link chain S00-S36 with teardown (shim only)"
tools/probe-run --build-args "--pstore-fast --wlan-link=36" --expect "LINK summary" --timeout 1200 --label wlan-oriole1 >"$out/run-a.txt" 2>&1
echo "run A exit $?: $(head -1 "$out/run-a.txt")"
# after a shim run the phone comes back in recovery (observed 2026-10-27: ~6 min after the last log line); to-fastboot moves it
tools/phone-lock run --owner batch-eagl1 -- tools/to-fastboot.sh 600 >/dev/null 2>&1 || { echo "phone not back in fastboot after run A: stop here (hold Power+VolDown, then rerun with SKIP_A=1)"; exit 1; }
fi

echo "== run B: iOS, CoreAnimation on the GPU (15 min)"
tools/xrun --kernel "$K" --board oriole --no-camera --gui --touch --dvfs 1803000,1836000,1826000 --gpu-handover \
	--cpus 8 --duration 900 --restart 960,bootloader --overlay "$ov" \
	--args "sweetiolog=- sweetsample=- sweetmali=1 sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/local/lib/libpixosgl-load.dylib sweetnull=backboardd,SpringBoard,pixos-gz-unpack" \
	--fail-on 'panic\(cpu|Kernel trap at' --label ${RUNB_LABEL:-oriole-eagl1-ios} >"$out/run-b.txt" 2>&1
echo "run B exit $?: $(head -1 "$out/run-b.txt")"

a=$(ls -dt logs/probe/*wlan-oriole1* 2>/dev/null | head -1)
b=$(ls -dt logs/runs/*${RUNB_LABEL:-oriole-eagl1-ios} 2>/dev/null | head -1)
{
	echo "== summary (run A: ${a:-none}, run B: ${b:-none})"
	[[ -n $a ]] && grep -h -E "LINK (table|S[0-9]+ (ok|timeout|fault|refused)|summary|T[0-9]+ fault)|WLAN SUMMARY|chipid|0x4389" "$a"/usb.txt 2>/dev/null | cut -c1-200 | tail -60
	if [[ -n $b ]]; then
		f=$b/usbnet.log
		grep -h -E "pixos-eagl|pixos-gz-unpack|pixos-gl:|pixos-drm:|SWEET MALI: (GPU reset|refused|MMU fault|no |open refused)|GPU RAILON|exec backboardd|CoreAnimation" "$f" | cut -f2 | cut -c1-240 | head -150
		printf 'backboardd execs %s, touch events %s, panics %s, SpringBoard lines %s\n' "$(grep -c 'exec backboardd' "$f")" \
			"$(grep -c 'SWEET HID: touch' "$f")" "$(grep -c 'panic(' "$f")" "$(grep -c '|SpringBoard|' "$f")"
	fi
} | tee "$out/summary.txt"
echo "saved: $out"
