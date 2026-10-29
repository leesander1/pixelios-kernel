# Local kernel build (`tools/xnu-mac-build` on macOS, `tools/xnu-local-build` on Linux)

## macOS: `tools/xnu-mac-build`

Builds the same `kernel.development.sweet` as CI on this Mac with whatever Xcode `xcode-select` points at (observed: Xcode 26.6,
2026-10-29). It drives CI's own recipe (blacktop darwin-xnu-build at the `DXB_SHA` pinned in `.github/workflows/xnu.yml`, the same
libfirehose arm64 edit) step by step; only the Xcode differs (CI: Xcode 15.0.1).

```
tools/xnu-mac-build [--fresh] [--jobs N] [--timeout SEC] [--compare CI_KERNEL] [--stack DIR]
```

- Output: `~/pixelios-artifacts/macbuild/out/kernel.development.sweet` (+ `SOURCE.txt` with the commit and Xcode). Logs:
  `~/pixelios-artifacts/macbuild/build.log` (all), `make.log` (raw make). Ends with one `RESULT: PASS|FAIL|ERROR` line.
- Needs: Xcode, Homebrew `jq bash cmake ninja`, ~4 GB free. No sudo, no Apple ID: the Kernel Debug Kit is not used for
  `MACHINE_CONFIG=SWEET` (xnu force-loads a KDK library only for T6000/T8101/VMAPPLE, `makedefs/MakeInc.def:861-864`), so `KDKROOT` is an
  empty directory.
- Incremental: each run patches a fresh copy of pristine xnu (`macbuild/xnu-pristine`) in `macbuild/stage` and `rsync -c`s only changed
  files into the work tree. Observed: cold ~15 min (*guess*: not timed end to end; the setup tools were built during the trial), one
  incremental run 174 s, 8 jobs.
- Network: the three stagers (`0019`/`0020`/`0026`) fetch pinned commits; each pin is mirrored once into `macbuild/mirror/` and later
  runs use the mirror (`url.<mirror>.insteadOf`). On 2026-10-29 this Mac's resolver could not resolve `www.bearssl.org` (`host` could),
  so the BearSSL mirror was seeded by hand: `git -C ~/pixelios-artifacts/macbuild/mirror/https___www_bearssl_org_git_BearSSL.git -c
  http.curloptResolve=www.bearssl.org:443:<ip from host> fetch --depth 1 https://www.bearssl.org/git/BearSSL <bearssl_sha>`.

### The one Xcode difference: iig

Xcode 16+'s `iig` generates code that reads `IORPC.kernelContent` and declares kernel-only `X_Msg` types inside `#ifdef KERNEL`
blocks; xnu-8796's `IORPC` (iokit/IOKit/IORPC.h:222-227) has no such field, so the build fails in `OSObject.iig.cpp` (observed). The
wrapper `macbuild/bin/iig` runs Xcode's iig and then keeps the `#else` branch of every `#ifdef KERNEL ... #endif /* KERNEL */` block in
its output (observed: all 94+94+94+93+36+18+3 such blocks are this one mechanism). The `#else` branch finds the payload with
`IORPCMessageFromMach(rpc.message, false)` in the contiguous `X_Msg_With_Content` layout, which is the layout xnu-8796's own
`IOUserServer` builds (*read*); so DriverKit RPC keeps working, unlike the Linux stand-in's stubs (*not tested on hardware*: PixOS loads no
dext as far as known).

### Compared with CI (observed, local 9575e65 vs CI `xnu-f301c44`, which differs by one small 0162 change)

- External symbols: 24249 CI vs 24250 local; 0 only in CI; 1 only local (`_iBoot_Stage_2_version`, as on Linux).
- SWEET/AppleCLCD symbols: 4 only in CI (`l___const.*` local constant labels the compiler names differently), 1 only local
  (`_sweet_log_start`, a static not inlined).
- Instruction set (llvm-objdump): PAC 0/0, LRCPC2 `ldapur`/`stlur` 0/0, `ldapr` 209/210, SHA3 0/0, BF16/I8MM 0/0: same profile as CI, no
  ARMv8.4+ instructions that the Cortex-A76/A55/X1 lack (the Linux build needed `-mcpu=cortex-a76` for this; Apple clang's
  `-arch arm64` did not).
- Sizes 17,438,616 (CI) vs 16,886,760 B. `LC_BUILD_VERSION` minos/sdk 26.5 locally vs 14.0 in CI (the SDK Xcode ships; *guess*: the boot
  shim ignores it).
- Code generation is Xcode 26 clang vs Xcode 15 clang: different inlining, so record important hardware results with a CI kernel when
  credits allow.

## Linux: `tools/xnu-local-build`

Builds the patched xnu-8796.141.3 `kernel.development.sweet` on this Linux box, without a Mac, as an alternative to the CI round trip
(`.github/workflows/xnu.yml`). Tags: *observed* = measured on this machine on 2026-10-22; *read* = read from source; *guess*.

## Usage

```
tools/xnu-local-build [--fresh] [--stack DIR] [--label NAME] [--jobs N] [--timeout SEC] [--compare CI_KERNEL] [--deps-only] [--make-args STR]
```

One command, no prompts. Ends with one `RESULT: PASS|FAIL|ERROR ...` line; exit 0 / 1 (build failed) / 2 (setup problem, timeout).
Output kernel: `~/pixelios-artifacts/localbuild/out/kernel.development.sweet` (feed it to `tools/xrun --kernel` / `tools/build-xnu-image.sh`).
Logs: `~/pixelios-artifacts/scratch/xnu-local-build.log` (progress) and `~/pixelios-artifacts/localbuild/work/<label>/build.log` (make).
Not part of `tools/check-all.sh` (slow, needs the downloads below).

## Runtime (observed, 4 jobs, `-j4`, on this machine, patches 0001-0093)

| run | wall |
|---|---|
| cold (`--fresh`: patch the tree, install headers, compile ~1100 files, link) | 71 s |
| incremental, nothing changed | 3 s |
| incremental, one patch changed (one `.c` comment) | 16 s (4 s patching + sync, 11 s make) |

CI: ~4 min. The first ever run adds the downloads and the build of mig/tcsh/unifdef (not timed).
An incremental run stages a second patched copy of the tree and `rsync -c`s only the differing files into the work tree, so make
rebuilds only what changed. Changing the stack's headers (`*.h`, `*.defs`, `*.iig`, makefiles, ...) re-installs the headers (a few
seconds more). Editing `tools/xnu-local-build` itself starts the work tree over (its generators and flags are part of the build).

## Disk / RAM

About 3.2 GB under `~/pixelios-artifacts/localbuild` (SDK 1.5 GB, theos 0.8 GB, work tree 0.7 GB, rest small). Never in git or /tmp.
RAM: `make -j4` is capped (`--jobs` above 4 is clamped); the build ran next to a loaded desktop with about 7 GB available. Peak not measured.
Host tools needed: git curl xz make clang perl python3 m4 autoconf automake gawk rsync dpkg apt-get. Missing flex/bison/gawk are unpacked
from Debian `.deb` files into `localbuild/hostroot` (no root).

## What is downloaded, from where

| what | source | pin |
|---|---|---|
| pristine xnu | github.com/apple-oss-distributions/xnu | tag xnu-8796.141.3 (`~/pixelios-artifacts/xnu-pristine`) |
| blacktop build recipe + patches | github.com/blacktop/darwin-xnu-build | 663906528d1cd5ea8fde7de6f16de73db9511549 (same as xnu.yml) |
| Mach-O cctools (ld64, libtool, nm, otool, strip) | github.com/L1ghtmann/llvm-project release test-210562a, iOSToolchain-x86_64.tar.xz | sha256 a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e |
| MacOSX14.0.sdk | github.com/joseluisq/macosx-sdks release 14.0 | sha256 5e4d3be6b445f0eacc0333ff2117e93e4433d8c4fe44053a14f735033a98aaa9 |
| iPhoneOS16.5.sdk | github.com/theos/sdks (HEAD, unpinned; was 0222fd5413cf4b9af096f37b4621afa2688572f7 on 2026-10-22) | only the iPhoneOS16.5.sdk directory |
| AvailabilityVersions | apple-oss-distributions | tag AvailabilityVersions-121, f3b52ca75ee842a8ac593bd7b03f9f4768c15755 |
| libdispatch (firehose) | apple-oss-distributions | tag libdispatch-1415.140.2, cdb61e93e803d0093635f356753a9a30c09836db |
| mig / bootstrap_cmds | github.com/markmentovai/bootstrap_cmds | f337e600741638896fb6056ce87c6479f74b89a3 |
| tcsh (xnu's `doconf` is a csh script) | github.com/tcsh-org/tcsh | b7db07931546178c4cb2542b5fc850c483628ed5 |
| unifdef | github.com/fanf2/unifdef | 08d12cd3059fe072929ea001ad9833f5487fd355 |
| libpthread, BearSSL, hfs sources | the numbered stagers in `xnu/patches/*.sh` fetch them, as in CI | per stager |

The git pins are fetched by exact commit/tag; the two tarballs are checked against the sha256 above at download time.

## How it differs from CI (and what that means)

CI: Xcode 15.0.1 on macOS 14 (Apple clang, Apple ld "new_linker", `iig`, `xcrun`). Local: stock Debian clang 19 as a Mach-O cross compiler,
theos ld64, fake `xcrun`, own stand-ins. Same patch stack (the stagers and the 97 patches that apply; CI skips the same four).

Compared against CI kernel `xnu-6980340` (same xnu/patches as `main`, verified with `git diff 6980340 HEAD -- xnu/patches`), observed with `--compare`:

- Same layout: all segments/sections present with the same sizes within a few bytes, except
  `__TEXT_EXEC/__text` -358 KB (different compiler, no outlining differences matter), `__TEXT/__cstring` -13 KB (shorter source paths),
  `__CTF/__ctf` absent (type debug info, `DO_CTFMERGE=0`), `__DATA/__bss` -8.7 KB.
- External (global) symbols: 24106 CI vs 24110 local; **0 only in CI**; 4 only local = the three stand-ins below plus
  `_iBoot_Stage_2_version` (a 104-byte array that CI does not export; guess: Apple clang makes the tentative definition local).
- SWEET / AppleCLCD symbols (all, normalized): 11 only in CI, 1 only local; all are `static` functions inlined differently
  (`sweet_surface_publish`, `sweet_log_start`) or compiler-outlined `.cold` pieces of `SweetCPU::*`, `sweet_prng_*`. No sweet_*.o,
  SweetHID, SweetCPU or AppleCLCD function or global is missing. The patched code itself is identical (same sources).
- Real behavioural differences (known, none touches the boot path to SpringBoard as far as read from source; **not tested on hardware**):
  1. **DriverKit (user-space drivers) does not work.** Apple's closed `iig` is replaced by the pre-generated headers from the SDK plus
     generated implementations (`$HB/iig-impl.py`): metaclasses, `Dispatch`/`_Dispatch`/`*_Invoke` return `kIOReturnUnsupported`, and the
     wrappers call the kernel's own `*_Impl` directly. In-kernel IOKit is unaffected. DriverKit headers come from the 14.0 SDK, xnu 8796
     is macOS 13.5 (one hand-written method: `IOUserClient::CreateActionKernelCompletion`, a guess at what iig generates, *guess*).
  2. `__cxa_atexit` is a no-op stub. Stock clang lowers the static destructor of libsa's `KLDBootstrap` to `__cxa_atexit`, Apple's to
     `__mod_term_func`; so that one destructor (it clears two bootstrap function pointers after the bootstrap segment is freed) does not run.
  3. `__llvm_profile_*_internal` (kext PGO data) are stubs returning "nothing"; in CI they come from the compiler runtime.
  4. `kalloc_type` allocator hardening: stock clang lacks Apple's type-signature builtins, so the zone segregation hints are an
     approximation (see the header comment in `xnu_clang_compat.h`, generated into `deps/host/inc`). Allocation works; the hardening is weaker.
  5. Code generation differs (clang 19 vs Apple clang 15): different inlining, so a latent undefined-behaviour bug may show up in one
     and not the other. The local kernel is for fast iteration; boot-test it, and use CI for the kernel you record as a result.
  6. **CPU target and instruction set (-mcpu=cortex-a76):** In CI, Apple Clang (`-arch arm64`) targets plain ARMv8.0-A baseline
     (no PAC, no SHA3, no v8.4a features) (*read* from Apple Clang driver). Upstream Debian Clang 19 defaults `-target arm64-apple-macos14.0`
     to `-target-cpu apple-m1` (*read* from Clang driver source and `-###`), which enables ARMv8.4-A, PAC (`FEAT_PAuth`), LRCPC2 (`FEAT_LRCPC2`),
     and SHA3.
     Target hardware cores on sweet (Snapdragon 732G) and bluejay (Tensor G1 / Pixel 6a) are Cortex-A76/A55/X1 (ARMv8.2-A) without PAC or LRCPC2.
     Without `-mcpu=cortex-a76`, Clang 19 emitted 158 `xpaci` instructions (in `_printf`, `_lck_rw_lock_shared`, etc.) and 99 `ldapur`/`stlur`
     instructions (in `_hw_lck_ticket_unlock`, `_firehose_buffer_stream_chunk_install`, etc.) (*observed* in binary). On ARMv8.2-A, these are
     unallocated encodings that trigger Undefined Instruction exceptions (*read* from ARM ARM DDI 0487), causing the silent hang after the
     shim jump observed on hardware (*observed* in run logs/runs/20261022T154525Z-touchx2).
     Passing `-mcpu=cortex-a76` in `tools/xnu-local-build` eliminates all `xpaci` (0), `ldapur`/`stlur` (0), SHA3 (0), and SVE (0) instructions
     (*observed* in binary). `__builtin_return_address(0)` lowers to `xpaclri` (`hint #7`, opcode `0xd50320ff`), which architecturally executes
     as a NOP on all ARMv8.0/8.1/8.2 cores (*read* from ARM ARM). `--compare` now scans for and asserts 0 unsupported instructions.
     Status: matches CI kernel instruction set; ready for hardware boot-test.
- The sha256 differs on every build (the Mach-O UUID), sizes: CI 17,245,776 B, local 15,447,808 B (CTF and symbol tables account for most).

## Troubleshooting

- `RESULT: FAIL build failed`: the first error lines are in the report; full log in `work/<label>/build.log`.
- Stale or odd state: `--fresh` (70 s).
- Debug make: `--make-args "--debug=b"`. A second work tree: `--label NAME`.
