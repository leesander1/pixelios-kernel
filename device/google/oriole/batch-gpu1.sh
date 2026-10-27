#!/bin/bash
# Oriole hardware batch "gpu1" (2026-10-27): two runs back to back, then one summary of every result.
#
#   device/google/oriole/batch-gpu1.sh OVERLAY_DIR       (phone in fastboot, oriole; macOS: . tools/macos/env.sh first)
#
# OVERLAY_DIR: built by pixelios-userland gpu/selftest/build-selftest.sh (pixos-gpu-test + launchd.plist with its three jobs).
#
# Run A, ~2-4 min, READ-ONLY shim probe (fastboot boot, no iOS), all first reads on oriole:
#   --wlan-probe   Wi-Fi path: PCIe1 PHY isolation, HSI domains, WLAN_EN/PERST pins; level 2 only if the PHY is not isolated
#   --gpu-probe    Mali-G78: power domain, CMU, GPU_ID and feature registers
#   --gpu-rails    S2MPG11 GPU rail registers (BUCK2S/BUCK8S/LDO1S) over ACPM, reads only
#   --touch-probe=dvfsr   ACPM DVFS: the CPU cluster rates the firmware reports (confirms the boot 7-8 clock requests)
# Run B, 15 min, iOS: everything from boots 6-8 (--touch, --dvfs, the crash-loop-free launchd.plist) plus
#   --gpu-handover   WRITER: the shim switches the GPU shader rail (S2MPG11 BUCK2S) on, left on for XNU (refused unless it reads off
#                    and its voltage is inside 550-700 mV); first time on oriole
#   sweetmali=1      the kernel's Mali driver and its SweetMali user client (xnu patches 0104/0105)
#   the overlay's three one-shot jobs: pixos-gpu-test clear (t+120 s), surface (t+165 s), triangle (t+210 s)
# Nothing writes storage except the overlay (two files in the iOS root, inside userdata).
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 2
ov=${1:?usage: $0 OVERLAY_DIR}
[[ -x $ov/usr/local/bin/pixos-gpu-test ]] || { echo "error: $ov has no usr/local/bin/pixos-gpu-test" >&2; exit 2; }
export PIXOS_DEVICE=oriole
K=${KERNEL:-$HOME/pixelios-artifacts/xnu-04457e5/kernel.development.sweet}
out=$HOME/pixelios-artifacts/batch-gpu1-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"

echo "== run A: read-only probe (Wi-Fi path, GPU, GPU rails, CPU rates)"
tools/probe-run --build-args "--pstore-fast --wlan-probe --gpu-probe --gpu-rails --touch-probe=dvfsr" \
	--expect "WLAN SUMMARY" --expect "GPU SUMMARY" --timeout 300 --label oriole-gpu1-probe >"$out/run-a.txt" 2>&1
echo "run A exit $?: $(head -1 "$out/run-a.txt")"
tools/phone-state --expect fastboot --wait 180 >/dev/null 2>&1 || { echo "phone not back in fastboot after run A: stop here (hold Power+VolDown, then rerun)"; exit 1; }

echo "== run B: iOS with touch, CPU rates, GPU power-up and the three GPU tests (15 min)"
tools/xrun --kernel "$K" --board oriole --no-camera --gui --touch --dvfs 1803000,1836000,1826000 --gpu-handover \
	--cpus 8 --duration 900 --restart 960,bootloader --overlay "$ov" --args "sweetiolog=- sweetsample=- sweetmali=1" \
	--fail-on 'panic\(cpu|Kernel trap at' --label oriole-gpu1-ios >"$out/run-b.txt" 2>&1
echo "run B exit $?: $(head -1 "$out/run-b.txt")"

a=$(ls -dt logs/probe/*oriole-gpu1-probe* 2>/dev/null | head -1)
b=$(ls -dt logs/runs/*oriole-gpu1-ios 2>/dev/null | head -1)
{
	echo "== summary (run A: ${a:-none}, run B: ${b:-none})"
	[[ -n $a ]] && grep -h -E "WLAN SUMMARY|WLAN l2 |GPU SUMMARY|GPU RAIL decode|DVFS get .* val=|TOUCH: verified" "$a"/usb.txt 2>/dev/null | cut -c1-200
	if [[ -n $b ]]; then
		f=$b/usbnet.log
		grep -h -E "SWEET MALI: (GPU reset|selftest|refused|MMU fault|no |config|open refused)|GPU RAILON|SWEET DEV: done|pixos-drm:|pixos-gpu-(test|clear|surface)|pixos-gles-triangle" "$f" | cut -f2 | cut -c1-220
		printf 'touch events %s, panics %s, SpringBoard lines %s\n' "$(grep -c 'SWEET HID: touch' "$f")" "$(grep -c 'panic(' "$f")" "$(grep -c '|SpringBoard|' "$f")"
	fi
} | tee "$out/summary.txt"
echo "saved: $out"
