#!/bin/sh
# build-cross.sh -- cross-build a RELOCATABLE, batteries-included clang that runs on arm64 and
# targets x86_64 Mavericks (10.9). Host tools native arm64; target runtimes via LLVM_RUNTIME_TARGETS.
#
# This is the EASY direction. Wowfunhappy's native-bootstrap/build.sh climbs 3.9 -> 6 -> 14 -> 22
# only because the stock 10.9 seed (Apple clang-3.5) cannot build modern LLVM; on a modern host the
# seed is a modern Apple clang and one CMake build does the whole job.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?mavericks-shipyard not found; install it -- see its README}"
JOBS="$(mavericks_build_jobs)"

STAGE="$WORK/stage$CROSS_PREFIX"          # DESTDIR-style staging at the install prefix
SRC="$WORK/llvm-project-$LLVM_VERSION.src"
BLD="$WORK/llvm-build"
mkdir -p "$WORK"

echo "==> 1. pinned 10.9 SDK + legacy-support shim"
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; export SDK
[ -d "$SDK" ] || { echo "FATAL: 10.9 SDK not found: '$SDK'" >&2; exit 1; }
LEGACY_A="$(sh "$HERE/fetch-legacy-support.sh" | tail -1)"
LEGACY_INC="$(dirname "$(dirname "$LEGACY_A")")/include"
[ -f "$LEGACY_A" ] || { echo "FATAL: legacy-support .a missing" >&2; exit 1; }

echo "==> 2. fetch + GPG-verify LLVM source"
# The signature -- not a pinned hash -- is what makes a Renovate bump of UPSTREAM_VERSION
# self-contained: it vouches for a tarball nobody has seen yet. See keys/llvm-release.asc.
command -v gpg >/dev/null 2>&1 \
  || { echo "FATAL: gpg not found; it verifies the LLVM source tarball (brew install gnupg)" >&2; exit 1; }
tb="$WORK/llvm-project-$LLVM_VERSION.src.tar.xz"
[ -f "$tb" ]     || curl -fsSL -o "$tb" "$LLVM_SRC_URL"
[ -f "$tb.sig" ] || curl -fsSL -o "$tb.sig" "$LLVM_SIG_URL"
GNUPGHOME="$WORK/gpg"; export GNUPGHOME; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$HERE/../keys/llvm-release.asc"
gpg --batch --quiet --verify "$tb.sig" "$tb" || { echo "FATAL: LLVM source signature failed" >&2; exit 1; }
rm -rf "$SRC"; tar -xf "$tb" -C "$WORK"
[ -d "$SRC/llvm" ] || { echo "FATAL: tarball did not unpack to $SRC" >&2; exit 1; }

echo "==> 3. configure (arm64 host tools + x86_64/10.9 runtimes)"
# THE RUNTIMES TARGET IS NOT THE PRODUCT TARGET, and it cannot be. LLVM's runtimes/CMakeLists.txt
# check_apple_target() hard-rejects any platform-specific Apple triple in LLVM_RUNTIME_TARGETS --
# "x86_64-apple-macos10.9" fails with FATAL_ERROR and has no opt-out, because compiler-rt on Darwin
# builds every platform/arch from one configuration and so must be named by a bare darwin triple.
# (The check runs for every LLVM_RUNTIME_TARGETS entry, so dropping compiler-rt does not avoid it.)
# So the runtimes are built as x86_64-apple-darwin with RUNTIMES_BUILD_ALLOW_DARWIN, and 10.9 is
# imposed the way compiler-rt expects: deployment target + the pinned 10.9 sysroot + osx-only archs.
# $TARGET_TRIPLE stays the PRODUCT's default target (what clang.cfg selects); tests/smoke-target.sh
# is what proves the pairing actually yields a 10.9 binary.
RUNTIME_TARGET="x86_64-apple-darwin"
# Per-runtime-target flags use the RUNTIMES_<triple>_<var> prefix. -fno-jump-tables is
# belt-and-suspenders for old-linker relocation quirks.
#
# compiler-rt is BUILTINS ONLY, which takes eight explicit OFFs rather than the four obvious ones.
# Everything else in compiler-rt pulls in sanitizer_common, which needs os/log.h (10.12+) that neither
# the 10.9 SDK nor the legacy-support shim has -- the shim carries os/lock.h, not os/log.h. Turning
# off SANITIZERS alone leaves CTX_PROFILE and GWP_ASAN at their default ON, and the build still dies
# in sanitizer_mac.cpp with a missing header that looks nothing like "you forgot a switch".
#
# HOST-LIBRARY HYGIENE -- three settings, all load-bearing for a SHIPPED toolchain. LLVM opportunis-
# tically links whatever optional libraries the BUILD HOST happens to have, bakes the absolute path
# into every binary's load commands, and the result installs fine and dies at first launch on a user's
# machine. Measured, not theorised: before these, verify-relocatable.sh found 94 of 97 staged Mach-O
# depending on /opt/pkg/lib/libz.1.dylib and /opt/pkg/lib/libedit.0.dylib.
#
#   ZSTD=OFF                 -- no libzstd on a stock macOS at all, so there is nothing to link but a
#                               package manager's copy.
#   CMAKE_IGNORE_PREFIX_PATH -- keeps find_package/find_library out of every package-manager prefix
#                               (pkgsrc, Homebrew, MacPorts, Fink), so zlib resolves to the SDK's
#                               libz.tbd => a dependency on /usr/lib/libz.1.dylib, present everywhere.
#   LIBEDIT=OFF              -- LLVM's FindLibEdit goes through pkg-config, which ignores
#                               CMAKE_IGNORE_PREFIX_PATH entirely, so the prefix guard cannot reach
#                               it. The shipped product is a compiler and linker; libedit only serves
#                               interactive line editing (clang-repl/clang-query), so dropping it
#                               removes a host-dependent dependency rather than a feature we ship.
#
# ncurses is left alone: it resolves to /usr/lib on macOS and the audit confirms it. libxml2 is OFF
# for the same class of reason (llvm-mt is not part of this product).
#
# -isystem the directory that DIRECTLY CONTAINS the wrapper headers, not its parent. This is the
# whole mechanism: macports-legacy-support ships shadow headers (time.h, stdlib.h, dirent.h, ...) that
# #include_next the SDK header and add the newer-than-10.9 declarations, so they only work when they
# shadow the real header name. Pointed at the parent (.../include) they are merely reachable as
# <LegacySupport/time.h>, which nothing includes -- and libc++ then fails to compile with
# "use of undeclared identifier 'CLOCK_REALTIME'" / 'CLOCK_MONOTONIC_RAW', because on Apple its
# steady_clock calls clock_gettime unconditionally. Same wiring native-bootstrap/build.sh proved.
#
# -include shim/aligned_alloc.h back-fills the ONE 10.9-missing symbol the shadow headers do not cover
# and libc++ cannot be told to stop using (see that header). Runtimes sub-build only -- never the
# shipped clang.cfg.
RC="-isystem $HERE/shim/include -isystem $LEGACY_INC/LegacySupport -include $HERE/shim/aligned_alloc.h -fno-jump-tables"
rm -rf "$BLD"
shipyard-cmake -G Ninja -S "$SRC/llvm" -B "$BLD" \
  $(mav_ccache_args) \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$CROSS_PREFIX" \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt" \
  -DLLVM_RUNTIME_TARGETS="$RUNTIME_TARGET" -DRUNTIMES_BUILD_ALLOW_DARWIN=ON \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw" \
  -DCLANG_DEFAULT_CXX_STDLIB=libc++ -DCLANG_DEFAULT_LINKER=lld \
  -DCLANG_DEFAULT_RTLIB=compiler-rt \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_OSX_SYSROOT=$SDK" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_OSX_ARCHITECTURES=x86_64" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_C_FLAGS=$RC" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_CXX_FLAGS=$RC" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_EXE_LINKER_FLAGS=$LEGACY_A" \
  "-DRUNTIMES_${RUNTIME_TARGET}_CMAKE_SHARED_LINKER_FLAGS=$LEGACY_A" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_ENABLE_IOS=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_ENABLE_WATCHOS=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_ENABLE_TVOS=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_DARWIN_osx_ARCHS=x86_64" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_SANITIZERS=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_XRAY=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_LIBFUZZER=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_PROFILE=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_MEMPROF=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_ORC=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_CTX_PROFILE=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_COMPILER_RT_BUILD_GWP_ASAN=OFF" \
  "-DRUNTIMES_${RUNTIME_TARGET}_DARWIN_macosx_CACHED_SYSROOT=$SDK"

echo "==> 4. build + install into staging"
ninja -C "$BLD" -j "$JOBS"
rm -rf "$WORK/stage"; DESTDIR="$WORK/stage" ninja -C "$BLD" install

echo "==> 5. assemble: legacy-support + clang.cfg (default target = x86_64 Mavericks)"
install -d "$STAGE/lib" "$STAGE/include" "$STAGE/libexec" "$STAGE/SDKs"
cp "$LEGACY_A" "$STAGE/lib/"
rm -rf "$STAGE/include/LegacySupport"; cp -R "$LEGACY_INC/LegacySupport" "$STAGE/include/"
# Our own tracked back-fills, kept OUT of the vendored LegacySupport/ tree so that stays a verbatim
# copy of upstream. Shipped because the defect they patch is in the 10.9 SDK, so it hits USER
# compiles too, not just the runtimes build (see build/shim/include/sys/_types/_mbstate_t.h).
rm -rf "$STAGE/include/mavericks-compat"; cp -R "$HERE/shim/include" "$STAGE/include/mavericks-compat"

# Where LLVM actually put the x86_64/10.9 C++ runtime. DISCOVERED, not assumed: LLVM lays per-target
# runtimes under lib/<triple>/ with LLVM_ENABLE_PER_TARGET_RUNTIME_DIR (the runtimes-build default)
# but has moved this before, and a stale hardcoded path would produce a clang++ that links against
# nothing and fails only at the first user's link step.
RTDIR="$(dirname "$(find "$STAGE/lib" -name 'libc++.a' -print 2>/dev/null | head -1)")"
[ -d "$RTDIR" ] || { echo "FATAL: no libc++.a under $STAGE/lib -- did the runtimes build run?" >&2; exit 1; }
for lib in libc++.a libc++abi.a libunwind.a; do
  [ -f "$RTDIR/$lib" ] || { echo "FATAL: $lib missing from $RTDIR" >&2; exit 1; }
done
RTREL="${RTDIR#"$STAGE"/}"          # e.g. lib/x86_64-apple-macos10.9
echo "    target C++ runtime: $RTREL"

# First-use SDK fetch: ship the pinned-SDK fetch script; the SDK itself is deliberately NOT
# redistributed (Apple's bytes). clang.cfg references $CROSS_PREFIX/SDKs/MacOSX10.9.sdk relatively.
cp "$SHIPYARD_SCRIPTS/fetch_sdk.sh" "$SHIPYARD_SCRIPTS/mavericks_fetch.sh" "$STAGE/libexec/"

# -Wl,-U,__availability_version_check is a PRODUCT-level flag, not a build workaround. Any 10.9-targeted
# program using @available/__builtin_available pulls compiler-rt's os_version_check.c.o, which
# references that symbol. compiler-rt declares it __attribute__((weak_import)) and NULL-checks it
# before use, falling back to parsing /System/Library/CoreServices/SystemVersion.plist -- precisely
# because it is absent before macOS 10.15. But weak_import only gets the linker off the hook when some
# library DECLARES the symbol, and the 10.9 SDK naturally does not, so ld64.lld fails the link outright:
#
#   ld64.lld: error: undefined symbol: _availability_version_check
#   >>> referenced by libclang_rt.osx.a(os_version_check.c.o)
#
# -U names that one symbol as legitimately-undefined, restoring the behaviour compiler-rt was written
# for. Scoped to a single symbol, and in the cfgs rather than this build alone so that USERS of either
# toolchain get it too -- LLVM's own sources hit this, and so will anyone else's.
#
# MIND THE UNDERSCORES: -U takes the MACH-O symbol, which carries the leading underscore C symbols
# get, so the C name `_availability_version_check` is `__availability_version_check` here. lld's
# diagnostic prints the C spelling, so copying the name out of the error message yields a -U that
# matches nothing and silently does not fix the link. `nm -m` on the archive member is what settles it.
#
# NOT -undefined dynamic_lookup, which also links but switches OFF undefined-symbol checking for the
# whole binary -- a real missing symbol would then ship and fail at launch. The reference is already
# `weak external` in the object (compiler-rt declares it __attribute__((weak_import))), so with -U it
# stays weak and dynamically-looked-up: 10.9's dyld binds it to NULL, compiler-rt's own NULL check
# fires, and the plist path runs. Verified on a built binary, not assumed.
#
# clang.cfg / clang++.cfg -- ported from native-bootstrap/build.sh wire_clang22, retargeted to
# x86_64/10.9. clang >= 12 auto-loads <driver>.cfg from its own bin dir, so the polyfill applies with
# zero per-project flags. Wired the NON-INVASIVE way: -isystem header shadows (which #include_next the
# SDK header and only take effect when code includes the normal header, so a bare -E or an .s file is
# untouched) plus a static archive resolved at link time. Deliberately NO -include force-header: that
# breaks build systems that probe the compiler and pollutes assembly.
printf '%s\n' \
  "--target=$TARGET_TRIPLE" \
  '-isysroot <CFGDIR>/../SDKs/MacOSX10.9.sdk' \
  "-mmacosx-version-min=$MACOS_MIN" \
  '-isystem <CFGDIR>/../include/mavericks-compat' \
  '-isystem <CFGDIR>/../include/LegacySupport' \
  '-Wl,-dead_strip_dylibs' \
  '-Wl,-U,__availability_version_check' \
  '<CFGDIR>/../lib/libMacportsLegacySupport.a' \
  '-lobjc' '-framework CoreFoundation' '-framework Security' '-framework CoreServices' \
  > "$STAGE/bin/clang.cfg"
# The C++ driver additionally links the toolchain's C++ runtime STATICALLY but GAP-FILLING, so every
# C++ executable is self-contained and portable with no rpath: -nostdlib++ (don't pull the libc++
# dylib) plus a portable-ld wrapper that appends the three .a at the END of the link line. A static
# archive supplies only what is still undefined when reached, so a normal program gets the whole STL
# while a program bundling its own libc++ resolves that first and gets no duplicate-symbol error.
printf '%s\n' \
  "--target=$TARGET_TRIPLE" \
  '-isysroot <CFGDIR>/../SDKs/MacOSX10.9.sdk' \
  "-mmacosx-version-min=$MACOS_MIN" \
  '-isystem <CFGDIR>/../include/mavericks-compat' \
  '-isystem <CFGDIR>/../include/LegacySupport' \
  '-nostdlib++' \
  '-Wl,-U,__availability_version_check' \
  '<CFGDIR>/../lib/libMacportsLegacySupport.a' \
  '-lobjc' '-framework CoreFoundation' '-framework Security' '-framework CoreServices' \
  '--ld-path=<CFGDIR>/portable-ld' \
  > "$STAGE/bin/clang++.cfg"
# portable-ld: the real ld64.lld, then the x86_64 C++ runtime appended LAST (dependency order:
# libc++ -> libc++abi -> libunwind). Resolves its own dir, so the toolchain stays relocatable.
printf '%s\n' '#!/bin/sh' \
  'DIR="$(cd "$(dirname "$0")" && pwd)"' \
  'RT="$DIR/../'"$RTREL"'"' \
  'exec "$DIR/ld64.lld" "$@" "$RT/libc++.a" "$RT/libc++abi.a" "$RT/libunwind.a"' \
  > "$STAGE/bin/portable-ld"
chmod +x "$STAGE/bin/portable-ld"

echo "OK: staged cross toolchain at $STAGE"
