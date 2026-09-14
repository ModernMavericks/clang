# Build ingredients

Everything baked into the shipped `.pkg`s (both variants), where it is pinned, and how a change to it
reaches a release. An *ingredient* is an input to the product; the *own upstream* is the thing this repo exists
to port. An own-upstream bump cuts `<upstream>-mavericks.1`; an ingredient bump cuts a
`-mavericks.(N+1)` repackage of the same upstream, via
`.github/workflows/repackage-on-ingredient-bump.yml`.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| LLVM/Clang source (own upstream) | `lines/<line>/UPSTREAM_VERSION` | ✅ per-line customManager → `github-tags` on `llvm/llvm-project`, capped to the line's major | `release.yml` on push to main cuts `-mavericks.1` |
| macports-legacy-support shim (prebuilt) | `MLS_VERSION # mavericks-legacysupport` in `build/versions.sh` | ✅ shared preset's `# mavericks-legacysupport` customManager | `build/versions.sh` is a watched path → repackage dispatched |
| LLVM release-signing keys | `keys/llvm-release.asc` | ❌ **untrackable — manual refresh** (see below) | not a watched path; a stale bundle fails the build loudly, never silently |
| MacOSX10.9 SDK | `ModernMavericks/shipyard@v1` (`fetch_sdk.sh`) | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag, so content moves without any path here changing |
| Sparkle framework (embedded in the updater `.app`) | `ModernMavericks/shipyard@v1` (`mavericks_fetch_sparkle`; Sparkle 1.x — the last line that runs on 10.9) | ✅ via `@v1` (github-actions manager) | content moves with `@v1` |
| Sparkle EdDSA public key | `updater/ed25519_key.pub` | ❌ untrackable (our own key) | baked into the updater's `Info.plist` as `SUPublicEDKey`; paired with the `SPARKLE_PRIVATE_KEY` secret |

Not ingredients: `build/*.sh` and `native-bootstrap/` are this repo's own recipe — a change there is a
repackage you cut deliberately (`workflow_dispatch` with `local_release=true`), not something Renovate
drives.

Shipped shim (`build/shim/` → `include/mavericks-compat/` in the toolchain): hand-authored back-fill
headers (`aligned_alloc`, `mbstate_t`) for the handful of 10.9-missing symbols the newer libc++ needs
that the macports-legacy-support shim does not carry. It is our own source, not an external input, so
there is nothing for Renovate to pin or track — but unlike `build/*.sh` it is **baked into the
artifact** (`clang.cfg` references it via `-isystem`), so it is recorded here for anyone auditing what
the shipped toolchain contains. A change to it is a deliberate repackage, like a patch.

## Why no source checksum is pinned for LLVM

There is no `LLVM_SHA256` in `build/versions.sh` on purpose. A pinned hash cannot vouch for a tarball
that does not exist yet, so it is exactly the thing that blocks the bot: every LLVM bump would need a
human to fetch and paste one. Instead `build/build-cross.sh` GPG-verifies
`llvm-project-<ver>.src.tar.xz` against `keys/llvm-release.asc` — a signature vouches for bytes nobody
has seen, which is what makes a Renovate bump of `UPSTREAM_VERSION` self-contained.

## Why the LLVM signing keys are untracked

`keys/llvm-release.asc` is LLVM's published release-key bundle, fetched verbatim from
<https://releases.llvm.org/release-keys.asc> — the URL llvm/llvm-project's own release body names
under "Verifying Packages". There is no version or datasource for Renovate to compare against, so
there is nothing to track.

It carries **all six** LLVM release managers rather than only whoever signed the currently pinned
release. LLVM rotates who cuts a release (22.1.1 was Douglas Yung), so a single-key bundle would make
a routine Renovate bump fail on an unrelated-looking GPG error the day the rotation lands — defeating
the point of preferring a signature to a hash. Carrying the set LLVM publishes for this purpose is
their own trust model, not a widening of ours. Refresh the file if LLVM adds a release manager; the
failure mode is a loud build failure at `gpg --verify`, never a silent downgrade.

## Lines, and the two variants a line ships

A **line** is an LLVM major (`lines/22/UPSTREAM_VERSION` = 22.1.1). Lines are separate products that
install side by side, so a clang-22 user is never carried onto clang-23; adding a major is one new
`lines/<major>/UPSTREAM_VERSION` plus a same-shaped, same-capped Renovate manager. Each line's manager
uses a per-line `depName` (`llvm-22`) with `packageName` pointing at the real repo — one shared
`depName` could not be capped per line, and an uncapped line is one Renovate bump away from silently
becoming a different product.

Each line ships **two variants from one release**, which never coexist on a machine:

| Variant | Runs on | Prefix | Identifier | Install floor |
|---|---|---|---|---|
| native | x86_64 Mavericks (the flagship) | `/usr/local/mavericks-clang-<line>` | `dev.modernmavericks.clang.clang<line>` | **10.9.5** |
| cross | modern arm64 macOS | `/usr/local/mavericks-clang-<line>-cross` | `dev.modernmavericks.clang.clang<line>-cross` | none |

Both target `x86_64-apple-macos10.9`, and both are built on the modern arm64 runner in one run — the
native variant is cross-*hosted* using the cross variant as its compiler, so nothing x86_64 is ever
executed during the build. Their `build-info-*.txt` records must agree on `llvm` and `legacy_support`
(conformance compares any key appearing in more than one variant); `variant`, `arch`, `prefix`, `pkg`
and `identifier` are the keys that are supposed to differ.

## Conformance deviations

Machine-read by `artifact-facts.sh` as `- <check>:<glob> : <reason>` (one line each, plain glob):

- shipyard-cmake-only:native-bootstrap/*: this tree bootstraps a whole toolchain from nothing on a
  stock 10.9 box, so it cannot presuppose an installed shipyard, and its `cmake` is deliberately not
  whichever one is on `PATH`. `build_tools()` builds cmake 3.19.8 into `toolchains/tools/bin` (the
  newest the 10.9 libc++ can compile — 3.21+ fails) and prepends that to `PATH`; stages A–C then
  configure LLVM 3.9.1/6.0.1/14.0.6 with exactly it, and stage D switches to the `cmake-new` it
  builds later, named through `$CMAKE`. Writing `shipyard-cmake` in stages A–C would substitute a
  different cmake for the one the stage was pinned to and require the pkg on a box that by
  construction has nothing installed. None of these configures a shipyard consumer — no
  `find_package(MavericksShipyard)` is involved — so the runtime refusal never fires here either.
  Revisit if native-bootstrap ever builds this repo's own CMakeLists.txt, or if the shipyard pkg
  becomes a bootstrap prerequisite.

The cross pkg's lack of a 10.9.5 install floor used to need one too — it runs on modern macOS and
only *targets* 10.9, and with no updater there was no appcast to declare its minimum system version.
`appcast-cross.xml` now declares it (`--min-os 11.0`), so conformance passes on its own.

## Deferred from family conventions (not artifact-conformance checks)

- **Generic (opt-in) updater icon** — the Sparkle updater ships the standard macOS app icon by
  explicit opt-in (`MAVERICKS_ALLOW_GENERIC_ICON=ON`), embedding no artwork at all, pending a real
  Mavericks-Clang mark. Not the LLVM dragon (trademark, and it would read as official LLVM). See
  `updater/ICON-CREDIT.txt`.
- **SDK not redistributed** — the Apple MacOSX10.9 SDK is not baked into the artifact. The pkg ships
  `libexec/fetch_sdk.sh` and fetches on first use (golang precedent + redistribution cleanliness).
