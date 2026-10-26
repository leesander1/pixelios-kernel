# shellcheck shell=bash
# The ONE phone a run may touch (AGENTS.md rule 2): PIXOS_DEVICE (default bluejay), which must be listed in tools/phone-targets.txt.
# Sourced by phone-state, fboot.sh, probe-run, xrun, hang-recover. phone_target -> sets PHONE_TARGET and returns 0, or prints REFUSED and returns 2.
phone_target() {
	local want=${PIXOS_DEVICE:-bluejay}
	if [[ $want =~ ^[a-z0-9]+$ ]] && grep -qx -- "$want" "$(dirname "${BASH_SOURCE[0]}")/phone-targets.txt"; then
		# shellcheck disable=SC2034  # PHONE_TARGET is read by the sourcing script
		PHONE_TARGET=$want; return 0
	fi
	echo "REFUSED: PIXOS_DEVICE='$want' is not a supported phone (tools/phone-targets.txt)" >&2; return 2
}
