#!/bin/bash
# extract-wlanfw.sh: take the BCM4389 Wi-Fi files out of a Pixel factory image, read-only, and pack them for xnu (docs/research/39 s.1, s.3).
#
#   tools/extract-wlanfw.sh FACTORY_ZIP [OUT_DIR]      OUT_DIR default ~/pixelios-artifacts/wlan-fw-<board>-<build>
#
# FACTORY_ZIP: the outer zip from developers.google.com/android/images (e.g. oriole-bp4a.....zip). Steps: unzip the inner image-*.zip,
# take vendor.img from it (simg2img if sparse), dump /firmware/{fw_bcmdhd.bin,bcmdhd.cal,bcmdhd_clm.blob} and the region variants with
# debugfs (brew install e2fsprogs; vendor.img is ext4, research 39 s.1), write MANIFEST.txt (sizes, sha256, CRC32, source hashes) and
# OUT_DIR/wlanfw.bin = tools/pack_wlanfw.py container for xrun --wlanfw. Nothing is flashed; the blobs stay outside git (AGENTS.md rule 4).
set -euo pipefail
zip=${1:?usage: $0 FACTORY_ZIP [OUT_DIR]}
here=$(cd "$(dirname "$0")" && pwd)
DEBUGFS=${DEBUGFS:-$(command -v debugfs || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)}
[[ -x $DEBUGFS ]] || { echo "error: debugfs not found (brew install e2fsprogs)" >&2; exit 1; }
base=$(basename "$zip" .zip)                       # e.g. oriole-bp4a.251205.006-factory-1234abcd
board=${base%%-*}
build=$(echo "$base" | cut -d- -f2)
out=${2:-$HOME/pixelios-artifacts/wlan-fw-$board-$build}
mkdir -p "$out/files"
w=$(mktemp -d "${TMPDIR:-/tmp}/wlanfw.XXXXXX")
trap 'rm -rf "$w"' EXIT

inner=$(unzip -Z1 "$zip" | grep -E '/image-.*\.zip$' | head -1)
[[ -n $inner ]] || { echo "error: no image-*.zip inside $zip" >&2; exit 1; }
unzip -q -j "$zip" "$inner" -d "$w"
unzip -q -j "$w/$(basename "$inner")" vendor.img -d "$w"
v=$w/vendor.img
if [[ $(xxd -p -l 4 "$v") == 3aff26ed ]]; then      # Android sparse image magic 0xed26ff3a
	simg2img "$v" "$w/vendor.raw.img"
	v=$w/vendor.raw.img
fi
"$DEBUGFS" -R "ls -l /firmware" "$v" 2>/dev/null | grep -E 'bcmdhd|fw_bcm' >"$out/firmware-ls.txt" || true
for f in fw_bcmdhd.bin bcmdhd.cal bcmdhd_clm.blob; do
	"$DEBUGFS" -R "dump /firmware/$f $out/files/$f" "$v" 2>/dev/null
	[[ -s $out/files/$f ]] || { echo "error: /firmware/$f missing in vendor.img (see $out/firmware-ls.txt)" >&2; exit 1; }
done
for f in $(awk '{print $NF}' "$out/firmware-ls.txt" | grep -E '^(bcmdhd\.cal_|bcmdhd_clm\.blob_)'); do
	"$DEBUGFS" -R "dump /firmware/$f $out/files/$f" "$v" 2>/dev/null || true
done
{
	echo "source: $(basename "$zip") sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
	echo "vendor.img sha256 $(shasum -a 256 "$v" | cut -d' ' -f1)"
	for f in "$out"/files/*; do
		printf '%s %s sha256 %s crc32 %s\n' "$(basename "$f")" "$(stat -f %z "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)" \
			"$(python3 -I -c 'import sys,zlib;print("%08x"%(zlib.crc32(open(sys.argv[1],"rb").read())&0xffffffff))' "$f")"
	done
} >"$out/MANIFEST.txt"
python3 -I "$here/pack_wlanfw.py" "$out/wlanfw.bin" --fw "$out/files/fw_bcmdhd.bin" --nvram "$out/files/bcmdhd.cal" --clm "$out/files/bcmdhd_clm.blob"
cat "$out/MANIFEST.txt"
echo "container: $out/wlanfw.bin"
