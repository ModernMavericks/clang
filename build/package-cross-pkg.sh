#!/bin/sh
# Package the staged cross toolchain as a component .pkg. NO 10.9.5 install floor: this pkg RUNS on
# modern macOS (arm64) and only TARGETS 10.9 (golang cross-pkg precedent). Emits build-info-cross.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE="$WORK/stage$CROSS_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: run build-cross.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="$HERE/../dist"; mkdir -p "$DIST"
PAYLOAD="$WORK/stage"     # DESTDIR root; contains .$CROSS_PREFIX
NAME="mavericks-clang-${CLANG_LINE}-cross-$VER.pkg"
# BUILD the pkg on LOCAL disk, then move the finished artifact into dist/. dist/ is inside the repo,
# which on a dev box is an NFS mount: pkgbuild writes a ~2.2GB payload as many small random writes,
# which NFS serves at ~170KB/s -- an hour for what takes minutes locally. One sequential move at the
# end costs a fraction of that. On CI dist/ is runner-local and this is a no-op either way.
STAGING_OUT="$WORK/out"; mkdir -p "$STAGING_OUT"
OUT="$STAGING_OUT/$NAME"

# The Apple 10.9 SDK is NOT redistributed -- the pkg ships libexec/fetch_sdk.sh and the SDK arrives at
# first use. tests/smoke-target.sh legitimately populates SDKs/MacOSX10.9.sdk as a symlink into this
# machine's ~/Library/Caches to prove the clang.cfg path resolves; shipping that symlink would bake a
# build-machine path into the artifact. verify-relocatable.sh only audits Mach-O, so it cannot see a
# stray symlink -- strip it here, then assert nothing is left.
rm -rf "$STAGE/SDKs"; mkdir -p "$STAGE/SDKs"
[ -z "$(ls -A "$STAGE/SDKs" 2>/dev/null)" ] || { echo "FATAL: $STAGE/SDKs is not empty" >&2; exit 1; }

# Stage the Sparkle updater .app, its daily-check LaunchAgent and the postinstall that loads the
# agent, via the shared helper. UPD_APP is exported by release.yml's updater build step. With no
# updater built, package the toolchain alone (a local toolchain-only build still works) -- but then
# REMOVE whatever a previous run staged: $PAYLOAD persists between runs, so a leftover .app would
# ship silently, announcing a version it is not.
UPD_APP="${UPD_APP:-}"
UPD_DIR="/Library/Application Support/ModernMavericks"
UPD_LABEL="dev.modernmavericks.ClangCrossUpdater-updatecheck"
set --                        # build_component_pkg.sh gets --scripts only when there IS a postinstall
if [ -n "$UPD_APP" ] && [ -d "$UPD_APP" ]; then
  scr="$STAGING_OUT/pkg-scripts-cross"; rm -rf "$scr"; mkdir -p "$scr"
  sh "$SHIPYARD_SCRIPTS/stage_updater.sh" \
    --stage "$PAYLOAD" \
    --app "$UPD_APP" \
    --app-dir "$UPD_DIR" \
    --agent-label "$UPD_LABEL" \
    --scripts-out "$scr"
  set -- --scripts "$scr"
else
  echo ">> WARNING: no updater at '$UPD_APP'; packaging the toolchain alone (build it: shipyard-cmake --build build/updater-cross --target ClangCrossUpdater)" >&2
  rm -rf "$PAYLOAD$UPD_DIR" "$PAYLOAD/Library/LaunchAgents/$UPD_LABEL.plist"
fi

# AppleDouble sidecars are what an NFS-hosted stage sprays; they would ship as real payload files.
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

pkg="$(sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$CROSS_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  "$@" \
  --out "$OUT")"
mv "$pkg" "$DIST/$NAME"
rm -f "$STAGING_OUT/$(basename "$NAME" .pkg)-components.plist"
pkg="$DIST/$NAME"
echo "built $pkg"

# What this variant was built FROM (conformance compares variants; a reader can see it).
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-cross.txt" \
  variant=cross arch=arm64 prefix="$CROSS_PREFIX" pkg="$(basename "$pkg")" identifier="$CROSS_IDENTIFIER" \
  llvm="$LLVM_VERSION" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-cross.txt"
