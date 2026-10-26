# shellcheck shell=bash
# Linux/macOS host differences for the phone tools (phone-state, fboot.sh, probe-run, hang-recover). Sourced; changes nothing on Linux.
#   timeout   macOS has none: Homebrew coreutils' gtimeout (`brew install coreutils`), else fail loudly; never run a phone command unbounded.
#   LSUSB     the command that lists USB ids: `lsusb` when installed (also the test stubs on PATH), else tools/usb-ids (sysfs / IORegistry).
#             A variable, not a function, so it still runs under `timeout`.
#   mtime F   modification time of F in epoch seconds (GNU `stat -c %Y`, BSD `stat -f %m`).
if ! command -v timeout >/dev/null 2>&1; then
	if command -v gtimeout >/dev/null 2>&1; then
		timeout() { gtimeout "$@"; }
	else
		timeout() { echo "timeout: not installed (macOS: brew install coreutils)" >&2; return 127; }
	fi
fi
# shellcheck disable=SC2034  # LSUSB is read by the sourcing script
if command -v lsusb >/dev/null 2>&1; then LSUSB=lsusb; else LSUSB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usb-ids"; fi
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
