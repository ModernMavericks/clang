#!/bin/sh
# Package the staged native toolchain: a flat component pkg wrapped in a product archive that enforces
# the 10.9.5 install floor. This variant RUNS on 10.9, so the floor is a REQUIREMENT (the mirror of the
# cross pkg's deliberate absence of one), and a bare component pkg cannot express it -- an OS floor is
# a productbuild/Distribution concept. Emits build-info-native.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE="$WORK/stage-native$NATIVE_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: run build-native.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="$HERE/../dist"; mkdir -p "$DIST"
PAYLOAD="$WORK/stage-native"
NAME="mavericks-clang-${CLANG_LINE}-native-$VER.pkg"
# Assemble on LOCAL disk and move the finished artifact into dist/ -- same reasoning as the cross
# packaging: pkgbuild's scratch dir lands next to its output, and on an NFS-hosted repo that turns
# minutes into an hour. On CI dist/ is runner-local and this is a no-op.
OUTDIR="$WORK/out"; mkdir -p "$OUTDIR"

# Do not redistribute the Apple SDK: strip the first-use symlink tests/smoke-native.sh created, so no
# build-machine path ships. verify-relocatable.sh audits Mach-O only and would not see a symlink.
rm -rf "$STAGE/SDKs"; mkdir -p "$STAGE/SDKs"
[ -z "$(ls -A "$STAGE/SDKs" 2>/dev/null)" ] || { echo "FATAL: $STAGE/SDKs is not empty" >&2; exit 1; }

# Stage the Sparkle updater .app, its daily-check LaunchAgent and the postinstall that loads the
# agent, via the shared helper. UPD_APP is exported by release.yml's updater build step. With no
# updater built, package the toolchain alone (a local toolchain-only build still works) -- but then
# REMOVE whatever a previous run staged: $PAYLOAD persists between runs, so a leftover .app would
# ship silently, announcing a version it is not.
UPD_APP="${UPD_APP:-}"
UPD_DIR="/Library/Application Support/ModernMavericks"
UPD_LABEL="dev.modernmavericks.ClangUpdater-updatecheck"
set --                        # build_component_pkg.sh gets --scripts only when there IS a postinstall
if [ -n "$UPD_APP" ] && [ -d "$UPD_APP" ]; then
  scr="$OUTDIR/pkg-scripts-native"; rm -rf "$scr"; mkdir -p "$scr"
  sh "$SHIPYARD_SCRIPTS/stage_updater.sh" \
    --stage "$PAYLOAD" \
    --app "$UPD_APP" \
    --app-dir "$UPD_DIR" \
    --agent-label "$UPD_LABEL" \
    --scripts-out "$scr"
  set -- --scripts "$scr"
else
  echo ">> WARNING: no updater at '$UPD_APP'; packaging the toolchain alone (build it: shipyard-cmake --build build/updater --target ClangUpdater)" >&2
  rm -rf "$PAYLOAD$UPD_DIR" "$PAYLOAD/Library/LaunchAgents/$UPD_LABEL.plist"
fi

find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

comp="$OUTDIR/mavericks-clang-${CLANG_LINE}-native-component.pkg"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$NATIVE_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  "$@" \
  --out "$comp" >/dev/null

sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" \
  --identifier "$NATIVE_IDENTIFIER" \
  --title "Clang for Mavericks ${CLANG_LINE} — LLVM ${LLVM_VERSION} for OS X 10.9" \
  --component "$comp" --out "$OUTDIR/$NAME" --host-arch x86_64
rm -f "$comp" "$OUTDIR/mavericks-clang-${CLANG_LINE}-native-component-components.plist"
mv "$OUTDIR/$NAME" "$DIST/$NAME"
echo "built $DIST/$NAME"

# What this variant was built FROM. Conformance compares any key appearing in more than one variant,
# so llvm/legacy_support/target must match the cross record; variant/arch/prefix/pkg/identifier are
# the keys that are supposed to differ.
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-native.txt" \
  variant=native arch=x86_64 prefix="$NATIVE_PREFIX" pkg="$NAME" identifier="$NATIVE_IDENTIFIER" \
  llvm="$LLVM_VERSION" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-native.txt"
