#!/bin/sh
# Single source of truth for every pinned input. Sourced, not executed.
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
export REPO_ROOT
# Heavy build I/O (an LLVM source tree + a full Release build) must live on a LOCAL disk: this repo
# is on an NFS mount, where the build crawls and sprays AppleDouble ._* sidecars. Default to the
# local cache; the durable bits (scripts, pins) stay in the repo. Override with MAVERICKS_WORK --
# but never to a path under the NFS tree. On CI, $HOME/.cache is a fine local path too.
export WORK="${MAVERICKS_WORK:-$HOME/.cache/mavericks-clang/work}"

. "$REPO_ROOT/build/lib.sh"

# A CLANG LINE (the LLVM major) is a product: clang-22 and a future clang-23 install side by side,
# each with its own upstream file, prefixes and identifiers, so a clang-22 user is never carried onto
# 23 unasked. Mirrors golang's GO_LINE / nodejs's NODE_LINE. upstream_version() reads whichever file
# MAVERICKS_UPSTREAM_FILE names, so everything below derives from the line.
export CLANG_LINE="${CLANG_LINE:-22}"
export MAVERICKS_UPSTREAM_FILE="$REPO_ROOT/lines/$CLANG_LINE/UPSTREAM_VERSION"
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "versions.sh: no such line: lines/$CLANG_LINE" >&2; exit 1; }

# Upstream LLVM is the Renovate-tracked lines/<line>/UPSTREAM_VERSION (bare x.y.z). The full package version lives
# in VERSION (<upstream>-mavericks.N), which the release workflow writes and .gitignore excludes; before
# a release is cut fall back to the computed auto version so a build never depends on a committed VERSION.
export LLVM_VERSION="$(upstream_version)"
if [ -f "$REPO_ROOT/VERSION" ]; then
  export PKG_VERSION="$(cat "$REPO_ROOT/VERSION")"
else
  export PKG_VERSION="$(sh "$REPO_ROOT/build/version.sh" auto | sed -n 's/^FULL=//p')"
fi

# LLVM monorepo source tarball. Verified by GPG signature against the vendored release-signer key
# (keys/llvm-release.asc) in build/build-cross.sh -- a signature verifies a version that does not
# exist yet, so a Renovate bump of UPSTREAM_VERSION is self-contained (no hand-pasted hash).
export LLVM_SRC_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
export LLVM_SIG_URL="${LLVM_SRC_URL}.sig"

# The 10.9 legacy-support shim, fetched PREBUILT from the mavericks-legacysupport release
# (ModernMavericks/macports-legacy-support), verified against its SHA256SUMS every run. Renovate bumps
# this pin via the shared preset's `# mavericks-legacysupport` customManager (unquoted, marker on line).
export MLS_VERSION=1.5.2-mavericks.4   # mavericks-legacysupport

# Both variants TARGET x86_64 Mavericks; they differ in what they RUN on.
#   native — runs on x86_64 Mavericks (the flagship a Mavericks user installs); canonical prefix,
#            and its pkg carries the 10.9.5 install floor.
#   cross  — runs on modern arm64 and targets Mavericks; -cross suffix, no floor.
# They never coexist on one machine. Identifiers mirror golang's
# dev.modernmavericks.<repo>.<binary><line>[-cross] shape.
export TARGET_TRIPLE="x86_64-apple-macos10.9"
export MACOS_MIN="10.9"
export NATIVE_PREFIX="/usr/local/mavericks-clang-${CLANG_LINE}"
export CROSS_PREFIX="/usr/local/mavericks-clang-${CLANG_LINE}-cross"
export NATIVE_IDENTIFIER="dev.modernmavericks.clang.clang${CLANG_LINE}"
export CROSS_IDENTIFIER="dev.modernmavericks.clang.clang${CLANG_LINE}-cross"

# $SHIPYARD / $SHIPYARD_SCRIPTS -- which build-cross.sh, the smoke tests and the packagers all read
# after sourcing this file -- come from build/lib.sh above, which sources build/msc.sh. This file
# used to resolve them a second time, its own way.
