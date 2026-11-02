# VNote Mobile

Flutter iOS/Android client for VNote. Implementation follows the [mobile plan](docs/mobile-client-plan.md).

The app opens a managed **notebook library** through the real native core. Existing Personal data is discovered in place; a fresh installation starts with an empty library and explicit **New notebook**. Create, select and rename notebooks without changing their storage roots or UUIDs. Inside each notebook, create Markdown/plain-text notes and folders, rename/move/delete nodes, search saved text and manage tags. Import a bundled notebook from a ZIP or system-selected folder, preserving its original identities and portable bytes. Export either a complete saved notebook backup or a files-and-assets ZIP from its library row through system Save As. **Write** commits the captured editor revision; **Reopen** starts a fresh native/editor session. Returning from the editor requires Write/Discard/Cancel before **Notebooks** can switch the selected notebook. Library discovery, catalog and editor owners never overlap. Unwritten input is still volatile: autosave, draft recovery, preview and sync are not implemented. Full Phase 1 device/iOS gates remain open; see [verification and blockers](docs/verification.md).

## Development

Use the exact versions in [toolchains.json](toolchains.json): Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1. Native builds also require CMake 3.29.2, Ninja 1.12.0 and Android NDK 28.2.13676358. Do not upgrade the core or SDK implicitly.

```sh
git submodule update --init --recursive
node scripts/verify.mjs verify
node scripts/verify.mjs android
node scripts/verify.mjs ios
node scripts/verify.mjs run
```

Run commands at the repository root. `verify` installs locked editor/Dart dependencies, builds and checks assets, then checks generated FFI drift, TypeScript, the real native bridge tests, and Flutter. `android` produces an arm64/x86_64 debug APK requiring Android 9/API 28; `ios` requires macOS/Xcode 26.6 and builds unsigned device and simulator apps. `run` performs the same asset/dependency gate before Flutter device selection. These commands publish/check bundled editor assets before packaging; tests alone do not update the WebView bundle. They do not configure release signing, accept SDK licenses or publish anything.

Flutter may be on PATH, specified by the `FLUTTER` environment variable, or installed at `.tools/flutter`. Windows commands require PowerShell 7. On Windows the locally downloaded Node can be invoked as `./.tools/node-v24.22.2-win-x64/node.exe`; its matching npm is used by the script. Set `JAVA_HOME` to a JDK matching the Android pin before building (the local download is `.tools/java/jdk-17.0.20.1+1`). SDK caches and machine paths are not committed.

Linux host builds also require OpenSSL development headers and libraries. Desktop native assets are test harnesses: the bridge explicitly enables `VXCORE_ENABLE_MOBILE_TEST_API` with installation disabled. This exposes isolated roots without enabling the mobile writer; default desktop vxcore builds expose no mobile API.

Native binding generation uses ffigen 23.0.0 and libclang 18.1.1 with the pinned NDK headers, and generates catalog JSON keys from the authoritative core constants:

```sh
python -m pip install --index-url https://pypi.org/simple --target .tools/libclang --no-deps libclang==18.1.1
dart run scripts/generate_bindings.dart
dart run scripts/generate_bindings.dart --check
```

The generator supports an explicit LLVM root via `LIBCLANG_PATH`; otherwise it uses the local wheel's real library through a temporary LLVM-layout directory link. Windows OpenSSL builds require Git for Windows (Unix Bash/Perl) and GNU `gmake`; the build helper downloads hash-pinned missing Perl modules locally. OpenSSL 3.5.9 is built from a verified source archive per target. Tool downloads occur at build time only; no TLS verification is disabled and no system Git/Perl files are patched.

After every completed coding task, rebuild and deploy to the **Medium_Phone** AVD, launch the app, and **leave the AVD/app running for user testing**. Repository publication is separate: publish an authorized core commit before pushing a mobile gitlink that references it.

The web editor can be built independently:

```sh
npm --prefix packages/editor_web ci --registry=https://registry.npmjs.org
npm --prefix packages/editor_web run build
npm --prefix packages/editor_web run check
```

Generated editor and legal assets are ignored, never downloaded at runtime. `check` recomputes their expected bytes without overwriting them and fails for missing/stale output. Use the root packaging commands, not a bare `flutter build` against potentially stale assets. A clean checkout must regenerate assets before packaging. Commit `package-lock.json` and the root workspace `pubspec.lock`; do not commit package-local Dart locks.

## Architecture and compatibility

- Flutter/Riverpod owns presentation and editor-session orchestration.
- CodeMirror 6 is bundled into `webview_flutter`; source text is never rendered as HTML in the privileged editor.
- `packages/vxcore_bridge` wraps the C++17 core C ABI on a dedicated native owner thread. The core selects sandbox-root initialization and checked ordinary-note publication only for Android/iOS; desktop builds retain in-place saves; there is no global core context or second note database.
- Desktop compatibility reference: `f8026adb4c43f78d90251148e24b6e72ca28f3d7`; original core baseline: `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`. The current core gitlink and `toolchains.json` record the separately committed implementation pin.

Read [architecture](docs/architecture.md), [compatibility](docs/compatibility.md) and the six ADRs linked there before extending the boundary. Mobile TLS trust integration, iOS execution and full draft durability remain gates, not ignored errors or permission to replace core operations with Dart filesystem writes.

Android `com.example.vnote_mobile` and iOS `com.example.vnoteMobile` are generated development identities, not owner-approved store identifiers.

## Browser safety and remaining work

Delete uses the core's behavior: it attempts recycling but may permanently delete
when recycling fails. The confirmation discloses this; there is no mobile restore
promise. Unsafe resource layouts, linked paths, destructive collisions and moves
that would orphan another indexed linked note are refused. A core mutation can
partially apply on IO failure; the browser refreshes and never presents failure as
proof of rollback. Markdown move preflight uses the already-pinned cmark parser.

Search uses the core's simple backend, with literal text and an optional case-
sensitive match and tag filter. Each matching note shows its first matching line;
opening resolves the current node ID rather than trusting the displayed path.
Only saved, supported Markdown/plain-text notes are searched; excluded notes and
result limits are disclosed. Tags are stored by core APIs in portable metadata;
existing undefined assignments remain visible and are preserved unless removed.
Tag loading is complete-or-error. Tag-tree deletion/reparenting is not exposed.

The library lists immediate children of the existing managed `notebooks/` root.
New notebooks use opaque sibling directories; Rename changes only their display
name through a full core configuration update. Missing, malformed, linked or
duplicate-UUID entries are not silently recreated, repaired or merged. Discovery
is capped at 1,000 candidate notebooks and fails rather than publishing a partial
library. A failed create may leave an unavailable owned entry for inspection;
failure is not proof of rollback. There is no notebook-removal UI in this slice.

Whole-notebook ZIP export preserves portable metadata, IDs, hidden/opaque files,
assets, encrypted sidecars and recycle content. It excludes only classified local
runtime data and refuses unsafe paths, embedded credentials or unresolved recovery;
it is not a Git-history backup. The ZIP itself is not encrypted. Export is bounded
to 1 GiB of source and 100,000 entries within a 4 GiB staging budget. Cancelled or
failed saves retain one prepared ZIP for retry; interrupted/corrupt staging has an
explicit discard action that never deletes the notebook. Snapshot capture closes
its native owner before ZIP/provider work, so other notebooks can open afterward.

The export dialog also offers **Files and assets** for Markdown/plain-text
interchange. It preserves original relative paths and raw bytes, including hidden
and opaque files, but omits the **entire `vx_notebook` directory** and configured
recycle data. It is not a notebook backup: identity, tags and configuration are
absent. Protected content refuses this format; use Notebook backup instead.
Nothing is decrypted, converted, flattened or link-rewritten. References to omitted
or external data and VNote IDs may not work. The chosen format and warning survive
cancel/restart; existing prepared notebook backups remain recoverable.

Whole-notebook import prepares a private copy before **Validate and import**.
ZIP input is limited to 1 GiB, the expanded tree to 2 GiB and each file to 256 MiB;
100:1 expansion, 100,000-entry and portable-name guards reject unsafe input.
For highly compressible but otherwise valid content, use **Import folder** after
discarding the refused ZIP copy. Duplicate notebook UUIDs offer the existing copy,
never overwrite or regenerate identities. Interrupted publication is quarantined
and reconciled before normal discovery; explicit discard cannot delete a foreign
or committed notebook. Import and export share one staging reservation.

Android ZIP/folder pickers and Save As are exercised. The iOS transfer adapter is
implemented but has not been built or run here. OS backup exclusion is configured and requested, not a
verified guarantee across iOS/OEM transfers. Keep your own exported copies before
app removal or device loss. See [export/privacy contract](docs/adr/0006-import-share-and-privacy.md).

Standalone Markdown/assets import, share-in and attachment editing remain planned
offline work; preview, autosave/recovery and sync remain later gates. No iOS or
physical-device completion follows from Android/host verification.

## License

VNote Mobile is licensed under **GNU LGPLv3**, matching VNote by owner decision. See [COPYING.LESSER](COPYING.LESSER) and its incorporated [GNU GPLv3 terms](COPYING). No warranty is provided under those terms.

`COPYING.LESSER` is copied verbatim from the pinned VNote reference; `COPYING` is the canonical GNU GPLv3 text. The MIT license of vxcore and licenses/notices of Flutter, CodeMirror and all other dependencies remain unchanged. Generated editor assets include their bundled dependency notices; the native host embeds the actual core/dependency notices, and the app includes both application license texts. This is not a completed release license/SBOM review; distribution must also satisfy source, modification/relinking and store obligations.

The pinned Dart archive codec's [derived-code notices](apps/vnote_mobile/licenses/archive-4.6.0.txt) are included through Flutter's additional-license mechanism; its MIT license and the posix package license are included by the standard collector.
