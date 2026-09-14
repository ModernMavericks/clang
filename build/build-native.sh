#!/bin/sh
# build-native.sh -- cross-HOST LLVM: produce an x86_64/10.9-HOSTED clang on an arm64 builder, using
# the Phase-1 cross clang as the compiler. Only the host tools are cross-compiled; the x86_64/10.9
# runtimes + polyfill assets are REUSED from the staged cross toolchain (identical target triple), so
# nothing x86_64 is ever executed on the arm64 host except TableGen (built natively below).
#
# The dependency on build-cross.sh having run is an intentional bootstrap ordering -- the Phase-1
# clang IS the Phase-2 compiler -- not a hidden coupling. It buys a lot: that toolchain already
# defaults to x86_64/10.9 and its clang.cfg makes every binary it emits self-contained (static
# gap-filling libc++), polyfilled and relocatable, so the host tools come out correct with zero extra
# linker plumbing. Hand-wiring Apple clang to do the same would mean reconstructing that whole bundle
# on the command line for a codebase this size.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?mavericks-shipyard not found; install it -- see its README}"
JOBS="$(mavericks_build_jobs)"

CROSS_STAGE="$WORK/stage$CROSS_PREFIX"
[ -x "$CROSS_STAGE/bin/clang" ] || { echo "FATAL: run build-cross.sh first (need $CROSS_STAGE/bin/clang)" >&2; exit 1; }
SRC="$WORK/llvm-project-$LLVM_VERSION.src"
[ -d "$SRC/llvm" ] || { echo "FATAL: LLVM source missing at $SRC (run build-cross.sh)" >&2; exit 1; }

echo "==> 1. make the cross clang usable as a compiler (populate its first-use SDK symlink)"
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; export SDK
[ -d "$SDK" ] || { echo "FATAL: 10.9 SDK not found: '$SDK'" >&2; exit 1; }
mkdir -p "$CROSS_STAGE/SDKs"
[ -e "$CROSS_STAGE/SDKs/MacOSX10.9.sdk" ] || ln -sf "$SDK" "$CROSS_STAGE/SDKs/MacOSX10.9.sdk"

echo "==> 2. native TableGen (arm64, Apple clang) -- the only build-time-executed tools"
TBLGEN_BLD="$WORK/native-tblgen-build"
if [ ! -x "$TBLGEN_BLD/bin/clang-tblgen" ]; then
  shipyard-cmake -G Ninja -S "$SRC/llvm" -B "$TBLGEN_BLD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DLLVM_ENABLE_PROJECTS="clang" -DLLVM_TARGETS_TO_BUILD="X86" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
  ninja -C "$TBLGEN_BLD" -j "$JOBS" llvm-tblgen clang-tblgen llvm-min-tblgen
fi

echo "==> 3. cross-configure the HOST tools (clang;lld) as x86_64/10.9"
# CC/CXX = the Phase-1 cross clang (see header). CMAKE_CROSSCOMPILING + CMAKE_SYSTEM_NAME tell CMake
# never to RUN a built binary -- the x86_64/10.9 output cannot execute on this arm64 host.
#
# CMAKE_OSX_* are pinned to the 10.9 SDK ON PURPOSE, even though the cross clang's clang.cfg already
# injects -isysroot/-mmacosx-version-min. Setting CMAKE_SYSTEM_NAME puts CMake in charge of the Apple
# platform flags, and its CMAKE_OSX_SYSROOT defaults to the HOST SDK (macOS 26) -- appended AFTER the
# config-file flags, so it would win. The build would then silently compile against the modern SDK and
# only fail much later, in tests/smoke-native.sh, as a wrong min-OS. Stating them here makes CMake
# agree with the cfg instead of fighting it.
#
# Host-library hygiene, same reasoning as build-cross.sh (which measured 94 of 97 binaries polluted):
# ZLIB/ZSTD/TERMINFO/LIBXML2 off, LIBEDIT off because its finder goes through pkg-config and ignores
# CMAKE_IGNORE_PREFIX_PATH, and the prefix guard for everything that does honour it.
NATIVE_BLD="$WORK/native-build"
rm -rf "$NATIVE_BLD"
shipyard-cmake -G Ninja -S "$SRC/llvm" -B "$NATIVE_BLD" \
  $(mav_ccache_args) \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$NATIVE_PREFIX" \
  -DCMAKE_C_COMPILER="$CROSS_STAGE/bin/clang" -DCMAKE_CXX_COMPILER="$CROSS_STAGE/bin/clang++" \
  -DCMAKE_CROSSCOMPILING=ON -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DLLVM_HOST_TRIPLE="$TARGET_TRIPLE" -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLLVM_TABLEGEN="$TBLGEN_BLD/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="$TBLGEN_BLD/bin/clang-tblgen" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw" \
  -DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_CXX_STDLIB=libc++

echo "==> 4. build + install host tools into the native staging prefix"
ninja -C "$NATIVE_BLD" -j "$JOBS"
rm -rf "$WORK/stage-native"; DESTDIR="$WORK/stage-native" ninja -C "$NATIVE_BLD" install
STAGE="$WORK/stage-native$NATIVE_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: native clang not installed at $STAGE/bin/clang" >&2; exit 1; }

echo "==> 5. reuse Phase-1's x86_64/10.9 runtimes + polyfill assets + cfgs (identical target triple)"
# Discover where the cross build laid the target C++ runtime, then copy THOSE FILES BY NAME.
#
# Emphatically not `cp -R "$RTDIR/." "$STAGE/$RTREL/"`. With LLVM_ENABLE_PER_TARGET_RUNTIME_DIR off --
# which is what this configuration actually produces -- RTDIR is the cross prefix's plain lib/, whose
# other 200-odd entries are the arm64 host toolchain: libclang-cpp.dylib, libLTO.dylib, every
# libclang*.a. Copying the directory would drop arm64 binaries on top of the x86_64 ones this build
# just produced, silently replacing the native libclang-cpp.dylib with one the target cannot load.
RTDIR="$(dirname "$(find "$CROSS_STAGE/lib" -name libc++.a -print 2>/dev/null | head -1)")"
[ -d "$RTDIR" ] || { echo "FATAL: no libc++.a under $CROSS_STAGE/lib" >&2; exit 1; }
RTREL="${RTDIR#"$CROSS_STAGE"/}"    # 'lib' here; 'lib/<triple>' under a per-target-runtime-dir build
echo "    reusing target C++ runtime from $RTREL"
install -d "$STAGE/$RTREL" "$STAGE/lib" "$STAGE/include" "$STAGE/libexec"
copied=0
for pat in 'libc++*.a' 'libc++abi*.a' 'libunwind*.a' \
           'libc++*.dylib' 'libc++abi*.dylib' 'libunwind*.dylib' 'libc++.modules.json'; do
  for f in "$RTDIR"/$pat; do
    [ -e "$f" ] || continue
    cp -p "$f" "$STAGE/$RTREL/"; copied=$((copied + 1))
  done
done
[ "$copied" -gt 0 ] || { echo "FATAL: copied no runtime files from $RTDIR" >&2; exit 1; }
for lib in libc++.a libc++abi.a libunwind.a; do
  [ -f "$STAGE/$RTREL/$lib" ] || { echo "FATAL: $lib missing from $STAGE/$RTREL" >&2; exit 1; }
done

# compiler-rt builtins: the native build has LLVM_ENABLE_RUNTIMES="" and so produces none of its own,
# but CLANG_DEFAULT_RTLIB is compiler-rt on Darwin -- without these a user's first link fails.
RT_BUILTINS="$(find "$CROSS_STAGE/lib/clang" -type d -name darwin 2>/dev/null | head -1)"
if [ -n "$RT_BUILTINS" ]; then
  install -d "$STAGE/${RT_BUILTINS#"$CROSS_STAGE"/}"
  cp -p "$RT_BUILTINS"/*.a "$STAGE/${RT_BUILTINS#"$CROSS_STAGE"/}/" 2>/dev/null || true
  echo "    reusing compiler-rt builtins from ${RT_BUILTINS#"$CROSS_STAGE"/}"
else
  echo "    WARNING: no compiler-rt darwin dir under $CROSS_STAGE/lib/clang" >&2
fi

# The runtimes' HEADERS, not just their libraries. LLVM_ENABLE_RUNTIMES="" means this build produces
# no libc++ headers either, and a toolchain that ships libc++.a without <iostream> cannot compile a
# single C++ program -- it fails with "'iostream' file not found", which reads like a broken install
# rather than a missing build step. Caught by the "best-effort, never gates" Rosetta smoke, which is
# exactly the kind of defect no amount of inspecting the staged file list would have surfaced.
for h in "c++" "__libunwind_config.h" "libunwind.h" "libunwind.modulemap"; do
  [ -e "$CROSS_STAGE/include/$h" ] || continue
  rm -rf "$STAGE/include/$h"
  cp -R "$CROSS_STAGE/include/$h" "$STAGE/include/"
done
[ -d "$STAGE/include/c++/v1" ] || { echo "FATAL: libc++ headers missing from $STAGE/include/c++/v1" >&2; exit 1; }

cp -p "$CROSS_STAGE/lib/libMacportsLegacySupport.a" "$STAGE/lib/"
rm -rf "$STAGE/include/mavericks-compat" "$STAGE/include/LegacySupport"
cp -R "$CROSS_STAGE/include/mavericks-compat" "$STAGE/include/"
cp -R "$CROSS_STAGE/include/LegacySupport" "$STAGE/include/"
cp -p "$CROSS_STAGE/libexec/"* "$STAGE/libexec/" 2>/dev/null || true
install -d "$STAGE/SDKs"
cp -p "$CROSS_STAGE/bin/portable-ld" "$STAGE/bin/portable-ld"; chmod +x "$STAGE/bin/portable-ld"
# The cross clang.cfg/clang++.cfg are already <CFGDIR>-relative with default target x86_64/10.9 --
# identical semantics for the native toolchain, where host == target. Copy verbatim.
cp -p "$CROSS_STAGE/bin/clang.cfg" "$STAGE/bin/clang.cfg"
cp -p "$CROSS_STAGE/bin/clang++.cfg" "$STAGE/bin/clang++.cfg"

echo "OK: staged native toolchain at $STAGE"
