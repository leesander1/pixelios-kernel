#!/bin/bash
# Flash the iOS root to userdata, once per image. DESTROYS userdata: pass --yes-erase-userdata after the user confirmed.
#   tools/fflash-userdata.sh IMG --yes-erase-userdata [--force] [--sparse]
#   --sparse  (TP-025) flash IMG.simg, made by AOSP img2simg (every uniform block a FILL chunk, never DONT_CARE), after two independent
#             readers agree it expands to IMG: tools/sparse_check.py and simg2img, each must reproduce IMG.sha256. Needed with fastboot 37
#             on a 16 GiB-RAM host: for a raw image bigger than RAM, copy_avb_footer() reads the whole file and dies "Failed reading from
#             userdata" before sending anything (fastboot.cpp, observed 2026-10-26); for sparse input it skips that step.
# Refuses: a caller that does not hold the phone lock (TP-020), no IMG.sha256 / hash mismatch, the same image already flashed (state file) unless --force,
# an image bigger than the target's userdata partition (board.json userdata_mib), a phone that is not the target (PIXOS_DEVICE, default bluejay:
# tools/phone-target.sh) or not unlocked.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/phone-target.sh
. tools/hostcompat.sh   # timeout on a macOS host
phone_target || exit 2
img=""; yes=0; force=0; sparse=0
for a in "$@"; do case "$a" in --yes-erase-userdata) yes=1 ;; --force) force=1 ;; --sparse) sparse=1 ;; *) img=$a ;; esac; done
[ -f "$img" ] && [ -f "$img.sha256" ] || { echo "usage: $0 IMG --yes-erase-userdata (needs IMG.sha256)" >&2; exit 2; }
[ "$yes" = 1 ] || { echo "REFUSED: this erases userdata; pass --yes-erase-userdata after the user confirmed" >&2; exit 1; }
# the image must fit the target's userdata partition (measured GPT size, board.json): fastboot would otherwise fail part-way through the erase
mib=$(${PYTHON:-python3} -I tools/boards.py "$PHONE_TARGET" --get userdata_mib 2>/dev/null) || { echo "REFUSED: no userdata_mib for $PHONE_TARGET (board.json)" >&2; exit 1; }
bytes=$(wc -c <"$img" | tr -d ' ')
[ "$bytes" -le $(( mib * 1048576 )) ] || { echo "REFUSED: $img is $bytes bytes, the $PHONE_TARGET userdata partition is $mib MiB" >&2; exit 1; }
want=$(cut -d' ' -f1 "$img.sha256"); got=$(sha256 "$img")
[ "$want" = "$got" ] || { echo "REFUSED: $img does not match its .sha256" >&2; exit 1; }
state=${FLASH_STATE:-$HOME/pixelios-artifacts/flashed-userdata.txt}
if [ "$force" = 0 ] && grep -q "^$got " "$state" 2>/dev/null; then
	echo "REFUSED: this exact image was already flashed ($(grep "^$got " "$state" | tail -1)); use --force to flash it again" >&2; exit 1; fi
flashimg=$img
if [ "$sparse" = 1 ]; then
	flashimg=$img.simg
	command -v img2simg >/dev/null && command -v simg2img >/dev/null || { echo "REFUSED: --sparse needs img2simg and simg2img (brew install simg2img)" >&2; exit 1; }
	if [ ! -f "$flashimg" ] || [ "$flashimg" -ot "$img" ]; then
		echo "converting to Android sparse: $flashimg" >&2
		img2simg "$img" "$flashimg.partial" >&2 && mv "$flashimg.partial" "$flashimg"
	fi
	${PYTHON:-python3} -I tools/sparse_check.py "$flashimg" --sha256 "$got" --size "$bytes" >&2 || { echo "REFUSED: $flashimg does not expand to $img (tools/sparse_check.py)" >&2; exit 1; }
	chk=$flashimg.check; rm -f "$chk"
	simg2img "$flashimg" "$chk" >&2 && back=$(sha256 "$chk") || back=""
	rm -f "$chk"
	[ "$back" = "$got" ] || { echo "REFUSED: simg2img expands $flashimg to sha256 '$back', not $got" >&2; exit 1; }
	echo "sparse ok: both readers reproduce $img" >&2
fi
tools/phone-lock check >&2 || { echo "REFUSED: the phone lock is not held by you (tools/phone-lock run --owner NAME -- CMD, or use tools/xrun / tools/probe-run, which take it after the build)" >&2; exit 1; }
prod=$(timeout 15 fastboot getvar product 2>&1 | sed -n 's/^product: *//p' | head -1)
unl=$(timeout 15 fastboot getvar unlocked 2>&1 | sed -n 's/^unlocked: *//p' | head -1)
[ "$prod" = "$PHONE_TARGET" ] && [ "$unl" = yes ] || { echo "REFUSED: product='$prod' unlocked='$unl' (target $PHONE_TARGET)" >&2; exit 1; }
# M7 (docs/PLAN-BOOT-SPEED.md): keep fastboot's own output and print what was really sent, to settle whether holes in the image are skipped
mkdir -p logs; fl=logs/flash-$(date -u +%Y%m%dT%H%M%SZ).log; t0=$(date +%s)
fastboot flash userdata "$flashimg" 2>&1 | tee "$fl"; el=$(( $(date +%s) - t0 ))
# Real payload = non-zero 4096-byte blocks (holes/zero blocks are not sent). `stat %b` is ZFS-compressed size, so it is not printed (docs/research/46).
# Streaming scan, ~1.4 GB/s measured on a cached 3 GiB file (~8 s for 11 GiB; the sha256 above just read the image); capped at 20 s.
s0=$(date +%s)
if nzr=$(timeout 20 python3 -I tools/nonzero-blocks.py "$img" 2>/dev/null); then
	nzdesc="$(awk -v n="${nzr% *}" 'BEGIN{printf "%.2f", n*4096/1073741824}') GiB non-zero data (${nzr% *} of ${nzr#* } 4 KiB blocks; scan took $(( $(date +%s) - s0 )) s)"
else nzdesc="non-zero scan skipped (over 20 s)"; fi
echo "flash stats: $(grep -c "^Sending sparse" "$fl") sparse part(s) sent of $(grep -o "Sending sparse 'userdata' [0-9]*/[0-9]*" "$fl" | tail -1 | grep -o "/[0-9]*" | tr -d /) , $el s, image $bytes bytes apparent, $nzdesc (log $fl)"
echo "$got $(date -u +%FT%TZ) $img" >> "$state"
echo "flashed; recorded in $state"
