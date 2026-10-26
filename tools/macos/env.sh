# shellcheck shell=bash
# Build and phone-tool environment for an Apple-silicon Mac (docs/BUILD.md "macOS host"). Source it from the repo root:
#   . tools/macos/env.sh
# Needs: Arm GNU Toolchain 15.2.rel1 darwin-arm64 aarch64-none-elf in ~/.local/opt (the boot-safety audit's self-tests are pinned
# to GCC 15 code shapes; Homebrew's GCC 16 fails them), Rosetta, `brew install coreutils flock shellcheck` and
# `brew install --cask android-platform-tools`, and .venv with lz4 + cryptography (python3 -m venv .venv && .venv/bin/pip install lz4 cryptography).
_pixos_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
_pixos_tc=${PIXOS_ARM_TOOLCHAIN:-$HOME/.local/opt/arm-gnu-toolchain-15.2.rel1-darwin-arm64-aarch64-none-elf}/bin/aarch64-none-elf-
[ -x "${_pixos_tc}gcc" ] || echo "env.sh: ${_pixos_tc}gcc not found (set PIXOS_ARM_TOOLCHAIN)" >&2
_pixos_brew=$(brew --prefix 2>/dev/null || echo /opt/homebrew)
export PATH="$_pixos_root/tools/macos:$_pixos_brew/opt/coreutils/libexec/gnubin:$PATH"
export CROSS_PREFIX=$_pixos_tc CROSS_OBJDUMP=${_pixos_tc}objdump CROSS_NM=${_pixos_tc}nm CROSS_READELF=${_pixos_tc}readelf
export PYTHON=$_pixos_root/.venv/bin/python
unset _pixos_root _pixos_tc _pixos_brew
