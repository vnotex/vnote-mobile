# Verification record

## Gate status

Managed notebooks and Phase 3 durable editing/isolated preview are implemented and exercised on Android. **Publication, iOS and physical-device gates remain open:** core pins are local until authorized publication; current public WK APIs do not meet the all-protocol editor/preview boundary. Earlier sections are historical checkpoint evidence; the final section records the current Phase 3 result and its limits. Only owned test notebooks are intentionally mutated; no production account is used.

## Source and host toolchain evidence

Observed on Windows 10.0.26300.9711, 2026-11-01:

| Check | Observed result |
| --- | --- |
| `git ls-remote https://github.com/vnotex/vxcore.git` | Main/HEAD `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf` published |
| Recursive submodule initialization | Core pin plus cmark `6148f317138d873041043742e61d26c74d31c6a1` and libgit2 `a418d9d4ab87bae16b87d8f37143a4687ae0e4b2` checked out |
| Flutter pinned tag checkout and `flutter --version --machine` | Flutter 3.47.9, revision `c197ca5199e9ee5661e865596c9c07294dfab51c`, Dart 3.13.7 |
| Node archive hash and execution | Node 24.22.2, npm 11.19.1; Windows archive SHA-256 `ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2` matches official manifest |
| Java archive hash and `java -version` | Temurin 17.0.20.1+1; archive SHA-256 `e53a79c3c3d86865bd7e787903884331068e71321714ffd44f145785affc7cb0` matches Adoptium metadata |
| Initial host tools | CMake 3.29.2, Ninja 1.12.0; GNU 13.2.0 and MSVC 19.44.35229.0 available |
| License source text | Verbatim VNote `COPYING.LESSER` SHA-256 `e3a994d82e644b03a792a930f574002658412f62407f5fee083f2555c5f23118`; canonical GNU `COPYING` SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |

Flutter, Node and Java were downloaded under ignored `.tools`, not substituted into global Node/Flutter installations. The pinned Flutter checkout is detached; doctor reports an unknown channel and binaries not on PATH. These warnings are expected for the local exact-revision installation, not suppressed by changing the pin.

## Real unchanged core build and runtime

```sh
cmake -S third_party/vxcore -B .tools/core-build -G Ninja -DVXCORE_BUILD_SHARED=OFF -DVXCORE_BUILD_CLI=OFF -DVXCORE_BUILD_TESTS=OFF -DVXCORE_BUILD_TOOLS=OFF -DVXCORE_INSTALL=OFF
cmake --build .tools/core-build --target vxcore --parallel 4
```

Configuration succeeded with GNU 13.2.0; build **failed** when upstream SQLite flags passed MSVC `/W0` to GCC (`linker input file not found`). No source workaround was applied.

```sh
cmake -S third_party/vxcore -B .tools/core-msvc -G "Visual Studio 17 2022" -A x64 -DVXCORE_BUILD_SHARED=OFF -DVXCORE_BUILD_CLI=OFF -DVXCORE_BUILD_TESTS=OFF -DVXCORE_BUILD_TOOLS=OFF -DVXCORE_INSTALL=OFF
cmake --build .tools/core-msvc --config Release --target vxcore --parallel 4
cmake -S third_party/vxcore -B .tools/core-msvc -DVXCORE_BUILD_CLI=ON -DCMAKE_INSTALL_BINDIR=bin
cmake --build .tools/core-msvc --config Release --target vxcore-cli --parallel 4
.tools/core-msvc/bin/Release/vxcli.exe version
```

MSVC Release core and CLI built successfully. The real linked CLI printed **`VxCore v0.1.0`**. The inspected CLI `version` branch calls the public version ABI without creating a context, so it does not resolve/write user-profile configuration. Existing upstream compiler warnings remained visible. This proves host compile/link/version execution only, not storage, threads or mobile support.

## Mobile development access

`flutter doctor -v`, `flutter devices --machine` and `flutter emulators` were executed. Android SDK 36.1.0 is installed with API 36/build-tools 36.0.0, but command-line tools are absent and doctor cannot determine license status. An existing SDK license file was found; no new SDK terms were accepted. Java was initially absent from PATH and is now available as the verified local JDK above.

`flutter emulators --launch Medium_Phone` succeeded. `adb devices -l` listed `emulator-5554`, model `sdk_gphone16k_x86_64`. It runs Android 17 / API 37; `getconf PAGE_SIZE` returned `16384`. This is an emulator, not a physical Android device.

No Mac/Xcode runtime, physical iPhone, physical Android device or controlled WebDAV endpoint is available in this session. iOS/physical-device checks are **not passed**. CI configuration is not evidence that a hosted runner executed it; no workflow was published or dispatched.

## Editor checks and Android runtime

Executed with the pinned local Node/Flutter and `JAVA_HOME` pointing to the verified JDK:

```sh
node scripts/verify.mjs verify
node scripts/verify.mjs android
```

| Check | Observed result |
| --- | --- |
| `npm ci` and enforced Dart workspace lock | Dependencies resolve from committed lockfiles; package-local Dart lock removed by workspace tooling |
| TypeScript typecheck and behavioral tests | Passed; 16 tests, zero failures/skips |
| Flutter analysis and Dart session tests | No analyzer issues; 34 tests passed |
| Deterministic asset build/check | Bundles, full runtime license notices and exact application license texts match expected bytes |
| Missing/stale output probes | Both checks exited 1 on a removed/modified generated CSS file; restored output passed check. No probe artifact remains |
| Android debug packaging | `apps/vnote_mobile/build/app/outputs/flutter-apk/app-debug.apk` built successfully |
| Platform XML parsing | Android manifest, iOS Info.plist and edited Xcode scheme parsed; this is not an Xcode build |

The Android build automatically installed NDK 28.2.13676358 and Flutter's CMake 3.22.1 into the existing Android SDK using its already-accepted license. No `--licenses` acceptance command was run. npm reports that esbuild's pinned postinstall is not yet covered by its `allowScripts` policy; this warning remains visible. No dependency vulnerability-clearance claim is made.

Browser smoke used the actual bundled CodeMirror page in Chromium with a throwaway external host channel, not a production fallback or storage mock. Observed source editing with emoji/CJK/combining marks and CRLF, undo/redo, light/dark changes without text loss, exact revision-3 snapshot, stale-generation rejection without mutation, literal script text (not HTML execution), and a CSP-blocked external fetch. A 65,537-unit paste was refused without changing source. A history-boundary smoke first exposed `Selection points outside of document` when the temporary history restore normalized CRLF; preserving LF-only splitting fixed it. The final run accepted 211 separate edits, retained exact CRLF source, pruned to 200 undo groups and remained editable. These are browser results, not physical IME evidence.

Installed the final APK on `emulator-5554` using `adb install -r`, then launched `com.example.vnote_mobile/.MainActivity`. Screenshots and UI hierarchy inspection confirmed the real Flutter/WebView ready handshake at revision 0. Android input inserted `Mobile_smoke`; the host reached revision 11. Flutter toolbar Undo removed the prefix, Redo restored it, theme changed both surfaces, and Check snapshot reported **“Snapshot matched revision 13; not saved.”** The LGPLv3 expansion rendered the actual bundled license text. The discard dialog's Keep open retained source/revision 13; explicit Discard and close returned from the activity. The software keyboard and resized editor were observed. The test emulator, browser tab and local HTTP server were stopped afterward.

No notebook persistence, preview renderer, WebDAV, iOS execution, physical-device IME/accessibility or release performance was exercised. No timing claims are inferred from debug builds. CI jobs are configured for editor/Dart checks, Android debug packaging, unsigned iOS device/simulator builds and a Windows real-core version smoke, but have not been dispatched. A fresh staged-source export was also verified as described below; hosted CI and iOS execution remain unperformed.

## Fresh source-tree verification

Exported the staged source with `git checkout-index --all --prefix=.tools/clean-checkout/`, excluding ignored dependencies, assets and build directories. Cloned vxcore separately into that export with `git clone --no-checkout`, checked out the exact core revision, and ran `git submodule update --init --recursive` there. This is an index export of the pending implementation, not a claim that an unpublished commit was cloned from a remote.

With `FLUTTER` pointing to the same pinned SDK, ran:

```sh
node .tools/clean-checkout/scripts/verify.mjs verify
```

The fresh tree resolved npm/Dart locks, generated its assets, passed TypeScript checks/15 tests, passed Flutter analysis/34 tests, and produced an asset manifest identical to the original tree (all source and output hashes match). SDK/package download caches were reused, but no repository dependency, generated asset or build directory was copied. The disposable export was removed after comparison. This does not substitute for iOS or native mobile builds.

## Implementation-review corrections

The implementation review approved the slice but identified machine-specific Azure feed URLs in the initial npm lock. Regenerated that lock against `https://registry.npmjs.org` and checked that all 50 tarball references use the public registry, with the same dependency versions and tree topology. The lock-generation experiment preserved the existing Lezer versions rather than silently accepting newer public releases. No temporary overrides were added to the application manifest. Root verification/packaging commands and the documented standalone install now explicitly select the public registry.

Using a new isolated `.tools/npm-public-cache` (public-registry metadata/tarballs only), reran the full `verify` and `android` commands: 16 TypeScript tests, clean Flutter analysis, 34 Dart tests, deterministic build/check and Android debug packaging passed. This second test run includes a shared `prepareHistoryPrune` regression with CRLF, selection at document end, and actual CodeMirror undo/redo after restoration. The editor calls that same helper. Mixed-ending pruning remains unexercised on Android; it has automated shared-code and Chromium evidence, not a physical-device claim.

Reinstalled and cold-launched the rebuilt public-registry APK on the same Android emulator. Input `Registry_checked` appeared in the editor and Check snapshot again matched the Dart mirror at revision 13. The emulator was then stopped. The temporary lock-generation directory and isolated cache were removed; user-level npm configuration was not changed. The fresh source-tree export above predates these review corrections and is not relabeled as a second post-correction export.

## Gates remaining after the editor-only kickoff

- Additive context-level persistent app/local roots before core initialization, with desktop regressions; no ignored JSON, environment or test-mode production workaround.
- Actual Android OpenSSL/curl and iPhoneOS/simulator curl/dependency builds, TLS trust handling, release symbols and 16 KB native packaging.
- Real asynchronous Dart/native host and notebook create/save/reopen, errors, ownership and teardown. No empty bridge or mock backend stands in for these.
- Core ordinary-save crash safety and durable draft/write-intent recovery before persistence labels; concurrent error-state synchronization and bounded search cancellation/result behavior before those workers are enabled.
- Desktop/mobile fixture round trips, real-device IME/accessibility/performance and process-kill tests; preview isolation, WebDAV, import/export/share and release scenarios in plan section 7.
- Owner-controlled upstream changes/publication, store IDs, signing and LGPL distribution review. No push or store submission occurred.


## Native notebook slice (historical: core c1f8475)

This section records the original native slice before platform isolation. Its
Windows DACL/recovery implementation and globally selected replacement writer
were subsequently removed; the current platform contracts are described in
[ADR 0001](adr/0001-native-packaging-and-storage.md) and
[ADR 0003](adr/0003-editor-protocol-and-durability.md). The earlier results below
remain historical evidence, not tests of the current desktop save policy.

The next slice introduces the additive explicit-root core API, checked ordinary
source publication, the bounded native owner host, generated FFI, and the
Personal/Welcome.md workflow. Desktop compatibility baseline remains f8026adb;
core changes are separately committed and the current gitlink/toolchain manifest
is authoritative. No core or mobile push is authorized or performed.

### Build and behavioral evidence

- OpenSSL 3.5.9 source archive verified against SHA-256
  `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`;
  built for Android x86_64 and arm64 with NDK 28.2.13676358/API 28.
- Native CMake wrapper built full vxcore, dependencies and vnote_host for both
  Android ABIs. `llvm-readelf -lW` reported `0x4000` alignment for every LOAD
  segment. Dynamic dependencies were only libc, libm and libdl; the C++ runtime
  and native dependencies are linked into the host.
- ffigen 23.0.0/libclang 18.1.1 generated the host bindings from the real C header;
  regeneration check matched. The generator's YAML-deprecation and intentional
  opaque-forward-declaration warnings remain visible; unused core callback
  typedefs were excluded rather than exposing an enum-sized native ABI.
- TypeScript typecheck and 18 protocol/history tests passed.
- Nine real Dart/native bridge tests passed: UTF-8/BOM/CRLF and empty writes,
  identity-preserving reopen, same-mtime conflict detection, invalid/oversized
  input, unsupported/encrypted content, cancellation/close and isolated roots.
- Flutter analysis reported no issues; all 54 editor/coordinator tests passed.
  The added real-core Write → Reopen → revision-one Write regression failed
  before reopening a fresh native host and passed after that correction.
- The native C++ host test executable passed its real-core scenarios.
- Upstream MSVC regression suites passed: test_context_paths,
  test_atomic_buffer_save, test_core, test_buffer_save_read_only,
  test_file_utils, test_session_persistence and test_buffer (7/7). Test roots
  were unique system-temp directories outside any Git working tree.

Commands used include `node scripts/verify.mjs verify`,
`node scripts/verify.mjs android`, native CMake configure/build for
`.tools/host-windows` and `.tools/host-android-{x64,arm64}-28`, and serial ctest
runs selecting the seven upstream suites. JNI/native build inputs resolve from
the pinned Dart workspace lock. Builds use no Qt and no runtime downloads.

### Actual Android surface and persistence

Installed the native APK on Medium_Phone (`emulator-5554`, Android 17/API 37,
x86_64, 16 KB pages). The real app created a bundled notebook under
`files/notebooks/Personal`, with separate `files/core/app` and `files/core/local`
roots. The editor reached On disk revision 0 from actual native reads.

Entered `Native_roundtrip_` through Android input and used Write. The physical
Welcome.md bytes changed; notebook, folder and note IDs remained unchanged.
Reopen drained the old native owner and installed a fresh revision-zero editor.
A second write succeeded, and force-stop/cold-launch retained exact file bytes
and all three portable IDs. Making the note read-only caused core error 6 to
reach Flutter without changing its previous bytes; repairing permissions and
retrying wrote the retained source successfully. Native core, OpenSSL and
libgit2 license text was visible in the app.

The initial welcome text was restored through the actual CodeMirror transaction
and native Write, not a direct filesystem body edit. Android's debug WebView
endpoint was used for that final fixture restoration after an ADB keyboard
shortcut opened Gboard's unrelated microphone prompt (permission denied).
The debug socket/port forward were released. The AVD and app are left running
for the user's testing, as requested.

### Failures found and resolved

- Native Windows Perl is not a Unix OpenSSL build environment. The helper uses
  Git's Unix Perl/Bash and hash-pinned missing CPAN modules, preserving PERL5LIB
  across native make. No Git/OpenSSL source patches or TLS verification bypasses.
- NDK headers require C99 inline in libgit2; only Android libgit2/util targets
  override the old C90 setting. SQLite now links Threads::Threads instead of a
  nonexistent Android libpthread; optional statx is gated at Android API 30.
- The public core types header's unguarded C++ namespace broke actual C/FFI
  parsing; a __cplusplus guard repaired it without changing ABI layout.
- Android app UIDs can search `/data` but cannot enumerate it. Root validation
  now requires traversal for ancestors, reserving read/write checks for storage.
- Dart's UTF-8 decoder consumes a leading BOM; the bridge restores the original
  source code unit so editing/writing cannot drop those bytes.
- A core buffer test inherited Git attributes when TEMP was placed inside this
  repository. Running in a unique external system-temp directory removed that
  fixture contamination; no production behavior or assertion was weakened.
- Windows ReplaceFileW added inherited ACEs. Real disposable-file experiments
  and the core regression showed the change. The preservation mode temporarily
  protects the original DACL, restores it exactly, and rejects callers unable
  to preserve permissions. The final test compares owner/group/DACL semantics,
  creation time, denied-delete sharing failure, old bytes, dirty state and cleanup.
- Microsoft documents partial ReplaceFileW errors that can move/remove the
  original path. The mode now reserves a recovery directory, never overwrites a
  leftover backup, restores only into an absent original path, and retains both
  copies on uncertain outcomes. Error 1176/1177 and abrupt termination in that
  Windows multi-step window were **not fault-injected**. Protection may remain
  hardened after failure/interruption; retained recovery entries are not trash.

### Gates still open

No iOS build/runtime or physical-device check was performed. OpenSSL/curl linking
is not TLS trust-store/connectivity validation. Full desktop VNote UI fixture
roundtrips, autosave, durable draft/write-intent journal, saved receipts,
startup recovery, import/export, preview, WebDAV and release signing remain
unimplemented or unverified as their planned phases specify. Windows replacement
is recoverable multi-step publication, not crash-atomic or a power-loss claim.
CI is configured but not dispatched; the new core gitlink must be published to
the core remote before publishing this mobile commit.


## Platform-isolation follow-up

The shared C-header language guard and `Threads::Threads` remain universal.
Android/iOS select the mobile context extension and POSIX writer from
`src/mobile/`; default desktop selects the original in-place writer. The optional
desktop mobile-API test extension does not alter persistence. Windows DACL/recovery
code and its explicit links were removed. The generic platform-isolation rule is
in the core `AGENTS.md`.

Observed verification:

- Shared headers compiled as C and C++; the mobile header compiled with its
  availability definition and did not declare the extension in the default mode.
- Default MSVC core: CLI reported `VxCore v0.1.0`; six selected suites passed
  (`test_core`, `test_buffer_save_desktop`, `test_buffer_save_read_only`,
  `test_session_persistence`, `test_file_utils`, `test_buffer`). Hardlinked bytes
  and identity survived saves, and a writable handle denying deletion did not
  prevent saving. `test_folder_manager` also built with the selected desktop source.
- Explicit desktop test-API mode: `test_context_paths` and
  `test_buffer_save_desktop` both passed. The library contained the mobile context
  API but no `MobileFileWriter` symbols; the default static library contained no
  mobile context API symbol.
- The default Windows shared-library SDK built and installed without the mobile
  header directory. Its installed DLL returned version `0.1.0` and did not export
  the mobile context API. Loading required the existing optional libidn2 runtime
  directory discovered by CMake; this was not a standalone distribution audit.
  Configuring the test-only API with installation enabled failed as intended.
- The initial static-SDK installation probe failed on existing dependency export
  sets. The default shared-SDK configuration passed; no unrelated static packaging
  changes were made.
- Android x86_64 built `test_context_paths`, `test_atomic_buffer_save` and the
  direct-compile `test_folder_manager`, including both selected mobile save sources.
  The path suite ran successfully on Medium_Phone. The atomic suite ran under the
  actual app UID in a disposable app-private directory and passed source/ID
  roundtrips, binary/empty data, failure/dirty-state, symlink/directory/FIFO rejection
  and mode preservation. Android policy denied hardlink-fixture creation; that
  specific prerequisite is reported unavailable, not counted as device coverage.
- Default Linux core also built with GCC 13.3/CMake 3.28.3 in WSL Ubuntu. The CLI
  reported `VxCore v0.1.0`; five selected suites passed (`test_core`,
  `test_buffer_save_desktop`, `test_buffer_save_read_only`, `test_file_utils`,
  `test_session_persistence`), including real hardlink and symlink preservation.
  Missing OpenSSL development files were supplied by extracting Ubuntu
  `libssl-dev`/`libssl3t64` 3.0.13-0ubuntu3.16 into the ignored tools directory and
  exposing its multiarch headers; no system packages were installed. A prior
  local OpenSSL source-build attempt timed out and is not counted as evidence.
- A separate Linux real-filesystem smoke exercised the actual desktop and mobile
  writer implementations: desktop preserved hardlink/symlink identity; mobile
  rejected both without mutation. CMake also detected the native Threads target.
- The verification pipeline passed 18 web tests, 9 real bridge tests, 54 Flutter
  tests, analysis and generated-FFI drift checks. The C++ native host lifecycle and
  storage executable passed with the explicit desktop test API.
- The arm64/x86_64 APK built and ran on Medium_Phone. A CodeMirror edit followed by
  actual Write changed the note bytes without changing portable IDs. Original
  source was restored through the editor and native Write; Reopen and a cold
  launch retained exact bytes/IDs, with the editor visibly ready. Temporary device
  fixtures and the debug port forward were removed.

macOS/iOS, physical-device, file-protection and interruption gates remain unrun.
The GUI checks establish the Android explicit-write workflow, not autosave or
power-loss durability. No core/mobile push or CI dispatch was performed.


## Managed notebook navigator

This independent offline slice adds the Personal notebook browser, nested folder
and Markdown/plain-text creation, rename/move/delete, and identity-bound note
selection. Catalog and editor owners are exclusive. It does not complete the
remaining Phase 1 device/iOS gates or all Phase 2 functionality. vxcore remains
unchanged at the separately squashed `b0e157f` pin.

### Executed boundary and interoperability checks

- Native C++ host executable passed its real-storage, admission, cancellation,
  terminal-credit, lifecycle, catalog-mode and mutation cases, including a real
  Windows handle preventing an asset move after the note had moved. The host
  reported that partial outcome rather than clean success.
- The bridge suite passed 33 tests covering nested Unicode CRUD, source/identity
  preservation, desktop-fixture metadata/assets, missing and unsupported content,
  mode/owner exclusion, collisions, readonly paths, junction/linked-resource
  guards, implicit resource side effects, partial creation and bounded listings.
  Exactly 10,000 direct children retained their full identity set; 10,001 and
  malformed listings failed explicitly without truncation.
- TypeScript typecheck and 18 protocol/history tests passed. The strict load
  language is Markdown or plain text only. FFI and canonical JSON keys are
  generated from the real C/public-core headers, not manually duplicated schema.
- Flutter analysis reported no issues, and all 73 editor/coordinator/workspace
  and browser interaction tests passed after the fixes described below.
- The versioned desktop fixture was produced through the default Windows desktop
  vxcore DLL, with the mobile test API absent. It includes a Unicode Markdown
  note, BOM/CRLF plain text, tags/custom metadata, a PNG asset/attachment and opaque
  bytes. A separate mobile-host smoke renamed/moved/edited the note and exercised
  core deletion/recycling. The default desktop DLL then reopened that mutated
  notebook and verified notebook/node UUIDs, edited UTF-8 bytes, tags, custom
  metadata, attachment references, PNG, untouched plain text and opaque bytes.
  This is a desktop-engine roundtrip, not a desktop Qt UI claim.

### Actual Android surface

The arm64/x86_64 debug APK built and ran on Medium_Phone. The existing Personal
notebook and Welcome.md were not replaced. Through the actual Flutter controls,
the smoke created nested folders and a note, opened it, cancelled a dirty return,
then completed Write before returning to the browser. A later explicit Discard
retained the previously saved bytes. Note rename/move and folder rename/move
preserved the observed note/folder UUIDs and source.

A real plain-text note used zero CodeMirror language providers (Markdown used
one), displayed literal markup without HTML elements, and retained exact CRLF
bytes through native Write. A duplicate filename surfaced core error 5 without
changing the existing file. Delete confirmation disclosed possible permanent
fallback; Cancel retained the subtree, and confirmed deletion moved the owned
smoke files to the core recycler. The original notebook/root/Welcome UUIDs and
Welcome source were checked unchanged. No production Dart filesystem writes or
fake catalog records were used.

### Integration failures found and corrected

- Core ID-to-path lookup reads a lazy SQLite cache and treats the root's empty
  path as not found. The bridge now anchors the root ID from core metadata and
  uses bounded public core listings on cache misses. Missing indexed nodes may
  be deleted through their authoritative parent record, never opened for editing
  or used as a creation destination.
- Review found that a contradictory SQLite cache hit still prevented lookup and
  that an unrelated legacy basename could block another identity. Cached paths
  now fall through to authoritative listings when verification fails (allocation
  failures still propagate). Search applies path-safety checks only where it
  traverses, while portable-name policy is enforced on mutation targets. A native
  regression deliberately changed only the derived SQLite filename: rename by ID
  failed before the fix and passed afterward, preserving bytes and identity on
  reopen. A separate legacy-sibling regression passed without changing that
  sibling's metadata.
- A removed parent is rejected before create, so that is not a valid partial-
  creation fixture. The regression now denies file creation in an existing owned
  directory while leaving parallel metadata writable, proving the post-create
  file-size check and subsequent missing-entry refresh/deletion behavior.
- Core Markdown moves can implicitly move relative files, overwrite destinations
  or orphan another indexed file, and can ignore resource failures. The host uses
  the same pinned public cmark parser for bounded preflight and verifies resource
  postconditions. Unsafe moves are refused before dispatch; no host file-copy
  replacement or private core API was introduced.
- The asset insertion API returned a notebook-relative path. The fixture's source
  link was corrected through the default desktop buffer API to be document-relative;
  IDs, tags/custom metadata, attachment metadata and image bytes were retained.
- A move picker initially notified its ancestor workspace during widget building.
  Its initial request now runs after the first frame; the failing browser widget
  regression passes. Widget fixture cleanup also now awaits shutdown inside the
  fake clock and performs synchronous outer teardown, avoiding an unrelated
  cross-zone wait on an already completed fake-clock future. The rebuilt APK
  opened/cancelled the corrected picker on a clean launch without a framework
  build-phase exception.
- Android automation initially waited for a nonexistent Create label (the dialog
  uses Save) and overlong action batches exhausted its harness deadline. Bounded
  actions and actual accessibility labels were used; these harness failures are
  not counted as app failures or passes.

Final commands `node scripts/verify.mjs verify` and
`node scripts/verify.mjs android` passed, including asset publication/checks and
the arm64/x86_64 package. The app was cold-launched after installation and left
on the ready notebook browser.

Remaining limitations: no macOS/iOS, physical-device, Qt UI, release signing or
power-loss verification. Multi-notebook management, search/tag UI, managed
import/export, attachment editing, preview, autosave/recovery and WebDAV remain
planned work. Debug builds are not performance evidence. No upstream change,
repository publication or store submission occurred.


## Notebook search and tags

The next offline slice adds notebook-wide saved-text search, optional case/tag
filters, stable result navigation, tag creation and assignment. Search and tags
use vxcore APIs on the native owner; no Dart filesystem writer or second index.
The core extension is default-off first-match-per-file content search plus the
existing-or-defined tag replacement rule. Desktop search defaults are unchanged.

### Executed verification

- Built and ran `test_simple_search_backend`, `test_search` and `test_folder` in
  the MSVC Release core build: all three suites passed. Coverage includes repeated
  1 MiB matching lines, regex/literal first match, UTF-16 columns, exclusions,
  default multiple matches, C API parsing, non-simple backend rejection when
  available, orphan preservation/removal and undefined-name rejection.
- Native host real-storage regressions passed, including singleton core search,
  row/byte caps, valid clipped Unicode snippets, omitted unsupported notes,
  admission reservations, cancellation/shutdown and event lifetime. A 10,001-file
  fixture exercises the 10,000-row cap. Complete-or-error tag loading is covered.
- All **38 bridge tests** passed. New coverage exercises nested literal/case/tag
  search, old result IDs after move/rename, deleted-result rejection, dense lines,
  explicit missing/encrypted/unsupported/oversized exclusions, and tag persistence
  while preserving desktop UUIDs, note/asset bytes and custom metadata.
- Flutter analysis reported no issues after correcting one test-only missing
  brace. All **87 Flutter tests** passed, including stale search/assignment tokens,
  sole-owner result opening, cancellation/shutdown, orphan selection, and distinct
  mutation-success/refresh-error outcomes.
- `node scripts/verify.mjs android` regenerated/checked offline assets and built
  the debug APK for arm64 and x86_64. This is debug build evidence, not a release
  performance or physical-device claim.

### Actual Android surface

Installed the APK on Medium_Phone and cold-launched it. Searching `personal`
found the existing Welcome note at line 3; opening the result showed its exact
source, and Discard returned through the existing safe-close dialog. Created
`Search demo/Tagged.md`, entered `MobileSearchToken with saved body` in the real
WebView and used Write. Created and assigned `MobileSearch` through note actions.
Text search and combined text/tag filtering returned the nested note with its
first-line snippet; tapping opened the same source. After force-stop/relaunch,
tag-only search returned the same node UUID and exact saved bytes. The original
notebook UUID and Welcome.md bytes were unchanged. Screenshots verified the
actual Flutter surface, including the result and tag filter. The demo note/tag
are retained for manual testing, and the AVD/app remain running.

Automation initially omitted Android's `hint` attribute for the empty search
field and later toggled off a newly-created, already-selected tag. Inspecting the
actual field/checkbox and portable metadata corrected the harness; these were
not app failures. No throwaway production fallback or smoke source was added.

Remaining offline work includes multi-notebook management, import/export and
attachment editing. Tag-tree deletion/reparenting, editor preview, autosave/draft
recovery and WebDAV are not included. No iOS, physical-device, Qt UI, power-loss,
release-signing or publication claim follows from this verification.


## Managed multi-notebook library

The library now discovers the existing `notebooks/` children, creates named blank
notebooks in opaque sibling roots, selects/reopens by observed UUID, and renames
through full core configuration updates. Existing Personal storage is unchanged.
Fresh installations require explicit creation. Missing open is never create;
existing-root create returns an error, including for non-notebook directories,
files and links. Unavailable or duplicate-UUID roots are visible, not repaired.
Core remains pinned at `64237fb`; no upstream changes were needed for this slice.

### Executed verification

- Native host Release real-storage suite passed. New cases reject absent open
  and every existing create target, validate display names, and preserve the full
  notebook configuration and non-config bytes through rename/reopen.
- All **47 bridge tests** passed, including desktop-fixture rename with unchanged
  IDs, tags, metadata, assets, other configuration and note bodies; expected-ID
  mismatch; Windows junction rejection; and read-only rename failure.
- Flutter and bridge analysis reported no issues. All **112 Flutter tests** passed.
  New cases exercise independent same-name notes across notebooks, restart
  discovery, existing Personal preservation, duplicate UUIDs, stale rows and
  workspace callbacks, replaced/missing roots, active-editor refusal, close/join
  ordering, close-error recovery, shutdown during discovery, visible partial
  creation and the storage candidate limit/link guards.
- Generated FFI/core JSON key drift checks passed. The final
  `node scripts/verify.mjs android` run regenerated/checked offline assets and
  built both arm64 and x86_64 debug ABIs.

### Actual Android surface

Installed and cold-launched the multi-notebook app on Medium_Phone. The library
showed the existing Personal notebook. Created a second notebook, added its own
`Welcome.md`, and entered `LibraryDemoBody` in the WebView. Cancel in the
return-to-notebook dialog retained the unwritten editor; Write then returned to
the browser. Renamed that notebook to Projects and selected both notebooks from
the library: Personal showed its original Welcome source, Projects showed its
independent saved body. Projects search did not return Personal's content and its
tag selector did not expose Personal's MobileSearch tag.

Compared on-device bytes and portable metadata: Personal's notebook configuration,
Welcome body, prior search-demo body and tag assignments were unchanged. Projects
has a distinct notebook UUID. Installed the final rebuilt APK, cold-launched again,
and reopened Projects: its name, notebook/node IDs and exact saved body persisted.
Screenshots verified the actual library and selected editor surfaces. Projects is
retained for manual testing; the AVD/app remain running on the library screen.

### Verification corrections and limits

- The first native rename fixture populated tags while leaving tagsModifiedUtc at
  zero, triggering core's existing open-time legacy-tag migration. A valid
  nonzero fixture timestamp isolates rename preservation; no core behavior was
  suppressed or changed.
- The first Flutter test launch overlapped the native test process holding the
  Windows DLL, so linking failed with LNK1104. Re-ran only after that process
  completed. Native-execution and Flutter/bridge hook builds were then serialized.
- Test fixtures initially compared Windows path spelling/trailing separators and
  passed mixed separators to `mklink`; they now assert filesystem identity and use
  native command paths. Tooltip finders returned RawTooltip rather than IconButton;
  the consumer tests now locate the actual ancestor button. These were harness
  defects, not successful app checks.
- Rapid synthetic `adb input text` produced a different editor string from the
  requested injection. Paced entry produced the exact observed/saved/reopened
  `LibraryDemoBody`. This slice makes no high-rate input/IME or performance claim;
  the observed synthetic-input limitation remains for the editor/device gates.
  Automation also needed explicit deletion rather than assuming Ctrl+A selected a
  Flutter field, and recovered from one failed UI hierarchy dump.

No import/export, notebook removal, attachment editing, draft recovery, preview,
WebDAV, iOS/physical-device, power-loss, release-signing or publication claim is
made. Both fixture-based host verification and emulator interaction are recorded;
neither substitutes for the remaining device gates.


## Whole-notebook ZIP export

Implemented native read-only snapshot capture, bounded worker ZIP creation,
retained export recovery/cleanup and system Save As adapters. Core remains at
`64237fb`. Ordinary notebook opening/recovery is unchanged: export uses a separate
capability that refuses auto-restore, recovery and migration side effects before
creating its context. Notebook serialization is never replaced with a Dart writer.

### Executed verification

- Native MSVC Release real-storage suite passed, including opaque/hidden/recycle/
  ciphertext/sidecar preservation, classified runtime omission, credential and
  unsafe layout refusal, source identity changes, snapshot cancellation/close,
  small output reservations, 100,000-entry rejection, and persisted foreign
  session records refused before recovery can touch another notebook.
- **54 bridge tests passed**; generated FFI/core-key drift checks and bridge
  analysis passed. New coverage includes export-only admission, existing
  destination/budget guards, complete portable bytes, no-source-migration opening,
  credential refusal without rewriting config, links/junctions and settled cleanup.
- **139 Flutter tests passed, with one Windows skip**. The skipped case creates a
  literal backslash filename, which Windows cannot represent; its POSIX worker
  guard is not counted as executed here. Tests cover real snapshots/ZIPs, retry,
  retained/corrupt/interrupted copies, explicit safe leftovers cleanup, provider
  leases, cancellation/shutdown, stale confirmation, and release of native owner
  before provider IO. An export completion cannot retire a newer library admission.
  App analysis reported no issues. Reconciliation/discard now has its own phase,
  rather than showing an ineffective Cancel button for an uncancellable cleanup.
- A throwaway scale scenario used the real native snapshot and worker encoder for
  **10,000 Unicode notes plus a 257 MiB opaque file**, then an archive containing
  **65,536 empty directories**. Independent Python ZIP reads verified all note
  bodies/IDs, Unicode flags, opaque bytes/CRC and empty directories. The second
  archive contained **65,542 entries** with a ZIP64 end record and valid CRCs.
  The temporary test and generated host ZIP artifacts were removed afterward.
- Android debug packaging through `node scripts/verify.mjs android` passed for
  arm64 and x86_64, including offline asset regeneration/checks and enforced lock.
  The archive dependency is exactly4.6.0; crypto3.0.8/path1.9.1 retain existing
  resolved versions, and the newly resolved posix dependency is locked at6.5.4.
- APK NOTICES contained archive's derived-code notices and posix's MIT notice.
  The actual Legal UI showed archive's two license entries, including the JZLib
  attribution. `LICENSE-other.md` is explicitly bundled because Flutter's normal
  collector reads only NOTICES/LICENSE, not that additional upstream notice file.

### Actual Android and desktop round trip

On Medium_Phone, Export Projects reached the real Android Documents UI. Cancelling
kept the prepared ZIP and retry controls. Force-stop/cold-start restored the same
prepared copy with an ambiguous-external-outcome warning. Save As then completed
to Downloads. Independent Python ZIP CRC/content checks matched every Projects
file exactly. App-private staging was removed only after provider completion;
all10 managed source files remained byte-for-byte unchanged.

The external Android ZIP was unpacked into an owned temporary directory and opened
using the existing default Windows desktop SDK C API (mobile extension disabled),
not the mobile host wrapper. Notebook/node IDs, `LibraryDemoBody` and every portable
file remained unchanged after desktop open/read/close. The child process isolated
core test storage under its own TMP/TEMP. Its first DLL load failed because Python
3.12 excludes PATH from default DLL dependency lookup; adding the declared
Strawberry IDN runtime directory to that child loader resolved it. No installed
SDK, system file or user-profile core configuration was modified.

The rebuilt app also exported Personal through Save As. Its seven files, including
nested note metadata and tag configuration, matched the original baseline exactly.
The two external ZIP copies remain in Downloads for manual inspection. The final
rebuilt APK was reinstalled and its hash matched the local build. Its explicit
Discard confirmation was exercised both with Cancel (copy retained) and Discard
(private staging removed); all managed source bytes still matched the baseline.
The app remains running on the library screen. Android package flags show no
ALLOW_BACKUP and no broad storage/media permission. These
checks do not establish cloud/OEM device-transfer behavior.

### Corrections and remaining limits

The first100,000-entry native fixture exceeded its existing120-second result wait.
Snapshot inventory repeatedly restatted identical absolute ancestors and duplicated
Windows attribute/type queries. The implementation now validates those ancestors
at phase boundaries, retains root/relative-component checks before access and
no-follow identity handles, and uses one Windows attribute-handle inspection.
The original entry count and test wait were retained; the suite then passed.
No performance guarantee follows from these debug/host checks.

ZIP central-directory finalization is synchronous inside the worker and bounded
by the entry/path caps; cancellation waits through it, then is checked before
ready publication. A committed copy is retained if cancellation wins afterward.
Provider cancellation during copying can leave an incomplete external file;
provider completion is not remote synchronization or atomic replacement proof.

Android backup exclusion is configured and its package opt-out exercised. iOS
implements scene-aware export and stable directory-group exclusion, and its plugin
registration matches the pinned Flutter headers, but **no Xcode build, iOS picker,
iOS backup artifact or physical-device transfer has been exercised**. Native
provider-revocation/disk-full/device-loss scenarios are not claimed from injected
controller failures. The earlier rapid synthetic-input limitation remains outside
this slice. Managed import, Markdown/assets-only export, attachment editing,
preview/recovery, WebDAV and publication remain subsequent work.


## Whole-notebook ZIP and folder import

Implemented private ZIP/provider-folder preparation, strict archive and metadata
validation, identity collision checks, no-replace directory publication, quarantine
and restart reconciliation. Core remains at `64237fb`; utf8proc 2.12.0 is a pinned
host dependency, not a core fork or a second notebook serializer.

### Executed host and scale verification

- MSVC Release native real-storage suite passed, including strict import identity
  walking and the existing export/lifecycle guard regressions.
- **97 bridge tests passed**. Bridge analysis, generated FFI/JSON-key drift,
  enforced dependency lock, offline editor asset checks, TypeScript checking and
  all **18 editor protocol tests** passed. Android debug packaging passed for
  arm64 and x86_64. The all-in-one verification command first stopped at an obsolete
  test that treated `syncEnabled: true` as unsafe; that refusal expectation was
  removed. The preservation fixture now carries enabled Boolean preferences, while
  actual `vx_sync` residue is tested as a refusal. The full bridge rerun passed.
- **282 Flutter tests passed, with two Windows skips**; app analysis reported no
  issues. Skips are the POSIX provider-file symlink case and literal-backslash
  export filename case; these platform-specific paths are not claimed as exercised.
  The suite covers archive boundaries, provider/worker cancellation and joins,
  stale tokens, identity collisions, quarantined publication/restart, foreign-root
  protection, committed edits, staging exclusion and existing export behavior.
- Throwaway real-library imports passed with **10,000 Unicode notes** plus an opaque
  hidden file, and with a **ZIP64 archive containing 65,536 empty directories**.
  Both traversed preparation, guarded core/identity validation, directory
  publication, commit and discovery. All note bodies/IDs and the opaque bytes were
  checked after publication; the directory count and final directory survived.
  Observed host durations were about 3 minutes and 10 minutes respectively, not a
  mobile performance guarantee. Temporary test-harness additions were removed.

### Executed Android and desktop round trip

- Imported a notebook produced independently by the default Windows desktop SDK
  C API (fixture producer revision `b0e157f`, mobile test API disabled) through the
  real Android ZIP picker. Every initial portable file matched exactly: UUIDs,
  nested Unicode paths, tags, custom metadata, unsupported bytes and an image asset.
- Force-stop/cold-start with a second prepared import restored **Validate and
  import**. Re-importing the same UUID offered **Open existing notebook**, opened
  the existing copy, and created no additional managed root. Explicit discard
  removed only private staging.
- A valid but over-100:1 ZIP was refused before publication. Its equivalent folder
  was selected through the actual system tree picker and imported successfully.
  Independent ZIP/folder comparison established identical source file sets and
  bytes; imported hidden sidecar and compressible body bytes were preserved.
  The final UI exposes fixed, redacted ratio guidance and the folder alternative.
- Cancelling the system ZIP picker retained a visible, explicitly discardable
  attempt. Incomplete provider input was not reported as prepared or published.
- Opened the imported Unicode Markdown note in the real WebView editor, appended
  `MobileImportEdit`, used **Write**, reopened from disk, and re-exported through
  system Save As. Independent ZIP CRC/content checks verified the intended edit,
  stable identities/tags/custom metadata and unchanged asset bytes. The default
  desktop SDK opened/read/closed that Android export with matching IDs and source.
- Original Personal/Projects files, external source ZIP and external source folder
  remained byte-for-byte unchanged. Settled import/export staging was empty after
  explicit discard/completion. Both packaged Android host ABIs contain the complete
  pinned utf8proc MIT/Unicode license bytes.

### Corrections and verification limits

The strict metadata walker initially rejected the ordinary `autoSyncEnabled: true`
preference even when sync was disabled. Validation now preserves Boolean preference
fields while retaining credential/runtime/recovery guards; the independent desktop
fixture then imported without rewriting its config.

The first device refusal hid archive safety errors behind a generic message. Only
a dedicated exception carrying fixed application-authored diagnostics now crosses
to the UI; arbitrary codec exceptions/source excerpts remain redacted.

A same-process editor-to-export smoke exposed a real Android failure: after WebView
initialization, an unqualified `AndroidManifest.xml` asset lookup could select the
added WebView package instead of this app, failing storage protection checks.
The adapter now selects the cookie obtained from the app's backup-rule resource
([TypedValue.assetCookie](https://developer.android.com/reference/android/util/TypedValue#assetCookie),
[AssetManager API](https://developer.android.com/reference/android/content/res/AssetManager#openXmlResourceParser(int,java.lang.String))).
The same WebView → library → Save As sequence then succeeded without restarting;
ZIP bytes matched the preceding successful roundtrip. Import preparation and
same-UUID refusal also succeeded in that same process. Temporary error-category
instrumentation was removed. This is actual AVD regression evidence, not a new
Android instrumentation test suite. Final installed APK SHA-256 matched the build;
the library remains running with both original and imported notebooks and no
private transfer staging.

The AVD's default graphics backend repeatedly stalled System UI and package
installation. Cold-starting the same AVD with SwiftShader GLES and Vulkan disabled
restored usable interaction without wiping user data. UI automation also needed to
wait for picker presentation, navigate out of a picker subdirectory before cancel,
and scroll an offscreen filename into view; these are not claimed app fixes.

The implementation checkpoint found borrowed Android raw descriptors were not
closed by `FileInputStream/FileOutputStream(FileDescriptor).use`. The pre-fix app
retained four descriptors under private transfer paths. All raw `Os.open` sites now
close in `finally`, without separately closing provider-adopted descriptors. A
rebuilt APK completed folder preparation with **1,024 probe files** plus notebook
content, ZIP preparation and Save As; cancellation during a partial folder copy
also settled correctly. `/proc/<app-pid>/fd` showed **zero retained imports/exports
file descriptors** after each completion/cancellation/discard. The exported ZIP
still matched the earlier roundtrip bytes. Owned probe files were removed. The
corrected installed APK matched its build, and original notebooks/edited imported
source remained unchanged.

The review also corrected iOS scope ownership: acquire security-scoped access
synchronously in the picker callback, release it from the coordinated worker even
on early cancellation, before result delivery. The confirmed existing `Info.plist`
now enables `LSSupportsOpeningDocumentsInPlace` for the `asCopy: false` picker and
passes plist parsing. This remains source/configuration review, not Xcode or iOS
runtime verification.

Windows host/injected interruption cases do not establish physical power-loss,
actual disk-full/provider-revocation or OEM backup/transfer behavior. iOS coordinated
picker/security-scope/backup code is implemented but has no Xcode build or device
runtime proof here. Share-in, Markdown/assets-only cohorts, attachment editing,
preview/recovery, WebDAV and publication remain later work.


## Files and assets ZIP export

Added a second explicit export profile through the existing native snapshot,
worker archive and system Save As pipeline. Notebook backup remains the default;
content export retains raw hierarchy/bytes but omits the entire `vx_notebook` tree
and configured recycle data. Format is persisted/correlated, never inferred from
the destination filename. Core remains at `64237fb`; no dependency or platform
adapter changed.

### Executed device and compatibility checks

- Both Android ABIs packaged successfully through `scripts/verify.mjs android`,
  including locked dependencies and rebuilt/checked offline assets.
- Actual Medium_Phone dialog exposes Notebook backup and Files and assets. The
  content confirmation visibly discloses the entire metadata-tree omission,
  protected-content refusal and link/backup limitations.
- Exported Desktop fixture as content through the real Save As picker. Cancelling
  retained one schema-2 `filesAndAssets` artifact. Force-stop/cold-start retained
  the exact ready marker and showed the format/non-backup warning visually. The
  accessibility dump omitted some ordinary Text labels; a screenshot verified the
  rendered warning rather than treating that automation timeout as an app failure.
- Retried Save As. External ZIP bytes exactly matched the retained private ZIP.
  Independent Python CRC and entry/body checks matched every selected source file,
  including nested Unicode Markdown, plaintext, opaque bytes and the managed PNG;
  no `vx_notebook` entry was present.
- Exported the same source with the default Notebook backup choice. Every portable
  file matched the baseline. The independent default desktop SDK reopened/read/
  closed the backup with the original notebook/node IDs and edited source intact.
- Attempted bundled-notebook import of the metadata-free content ZIP. Preparation
  refused it with a missing notebook-root explanation; no live root was published.
  Explicit discard removed only staging. `/proc/<app-pid>/fd` showed zero retained
  private transfer file descriptors after both export modes and refusal cleanup.

- Created an independent encrypted notebook through ordinary desktop-core APIs,
  imported it through Android's real ZIP picker, then selected Files and assets.
  The UI refused protected content with the notebook-backup alternative and no
  remaining export staging. Notebook backup then preserved every ciphertext,
  key and metadata byte exactly. The owned Protected export fixture remains in the
  AVD library for manual refusal/backup checks; no user notebook was encrypted.

### Native verification and corrections

**99 bridge tests** and **18 editor protocol tests** passed, along with bridge
analysis, TypeScript checking, generated FFI/JSON-key drift and locked asset gates.
The final app analysis reported no issues and **322 Flutter tests passed**, with
the two existing Windows skips (POSIX provider-file symlink and literal-backslash
export filename). Real-storage widget checks cover both format selections,
retry/restart and legacy schema-1 backup recovery.

Their first run exposed a test-harness issue: the completion `Completer` was created
in the fake widget zone while its native/worker work ran in `tester.runAsync`.
The operation completed, but its completion microtask waited in the paused fake
zone until timeout. Moving that completion into the real IO zone fixed all three
focused cases; the full suite then passed without extending the timeout.

The MSVC Release native real-storage suite passed. It covers both profiles,
selected-only budget accounting, encrypted flags/suffix/signatures, complete raw
metadata graphs, omitted-directory aliases, missing and lazy assets, and empty
content. Windows live-data DROP and omitted-data LEAK cases were exercised. The
coexisting `VX.JSON`-beside-`vx.json` case was skipped because this filesystem aliases
those names; that case is not counted as executed.

The first positive projection fixture accidentally created lowercase `nested`
before declaring live `Nested` on Windows. The new exact-spelling guard correctly
refused it. The fixture's unrelated runtime-lookalike data now uses `unindexed/`,
leaving deliberate alias-refusal fixtures intact; the full native rerun passed.

### Scale and final installation

A throwaway real-native/controller/worker scenario exported **10,000 nested Unicode
Markdown notes**, a managed binary attachment, BOM/CRLF/combining-mark/emoji source,
hidden opaque data and a custom recycle tree. Independent Python ZIP reads checked
all 10,000 bodies, every selected file/directory, CRC and UTF-8 flags against the
original inputs; metadata/recycle omissions were exact and every source byte stayed
unchanged. The observed host run was about 4 minutes 29 seconds, not a mobile
performance guarantee. Its first attempt used an incorrectly prefixed absolute
temporary path and failed before opening a notebook; correcting the test path to
repo-relative fixed the probe. Temporary harness and host fixture/ZIP artifacts
were removed after proof.

All 22 preexisting managed files, including Personal/Projects and the prior desktop
fixtures, remained byte-for-byte unchanged. Final installed APK SHA-256 matched the
built package. Import/export staging was empty, no transfer descriptors remained,
and the app was cold-started and left running on the Medium_Phone library. The new
owned encrypted fixture and external ZIP copies remain available for manual checks.

No iOS build/runtime, physical-device, actual power-loss or OEM backup/transfer
claim follows from these checks. Standalone Markdown/assets import, share-in,
attachment editing, durable drafts/preview, WebDAV and release gates remain open.


## Standalone cohorts and ordinary-note resources

The mobile integration consumes reviewed local core prerequisite `a334ea0` (not
pushed). It adds raw file/ZIP/folder cohorts, retained attachment/image operations,
resource Save As and revision/selection-bound source insertion. The core prerequisite
was independently reviewed before this mobile plan; both mobile workflows share
one staging reservation and actual-state recovery boundary.

### Executed host and editor checks

- Full real-native Dart bridge suite: **111 tests passed**. Full Flutter suite:
  **382 passed**, with the two existing Windows platform skips. Bridge and app
  analysis reported no issues. Native MSVC Release host built, and the complete
  real-storage C++ executable passed through ctest. Generated FFI/JSON-key drift
  checks matched the public headers.
- TypeScript checking, **23 editor tests**, deterministic bundle/license build and
  asset checks passed with pinned Node 24.22.2. An initial npm child inherited
  global Node 25.9 and was refused by the pin gate before tests; fixing its PATH,
  not changing the pin, allowed the checks to run.
- An independent exported-bridge smoke built and attached **10,000 nested Unicode
  Markdown notes**, plus a separate BOM/CRLF/combining-mark/emoji cohort containing
  hidden/opaque bytes and linked binary data. Every input body was compared after
  attach and rename. Sealed IDs survived retry/reconciliation, and original note,
  configuration bytes and IDs stayed unchanged. Rebuilding a sealed plan was
  refused. This Windows storage proof is not a mobile performance guarantee.
- The same smoke exercised actual add, untrack, track, rename, bounded binary export,
  image insertion and remove APIs. Exported bytes/hash matched the original;
  untracking retained bytes; the unindexed image survived a fresh resource owner.
- Actual bundled CodeMirror in Chromium received typed source and a flushed current
  selection, then emitted the insertion edit before its correlated received ack.
  Duplicate replay was inert; one Undo restored the exact pre-insert source, and
  Redo restored the link. Moving the cursor caused stale rejection without source
  changes; subsequent typing still worked. Synthetic composition events held the
  selection barrier until completion. This is not physical-device IME evidence.

### Integration defects found and corrected

Resource-only preflight initially ran during ordinary NOTE opening too, changing
its missing-file error behavior. Restricting that preflight to RESOURCES preserved
the established note-open contract while actual resource operations still validate
on their owner. An obsolete test expecting automatic deletion of malformed import
journals was removed rather than re-pinning unsafe cleanup; the reviewed core now
preserves ambiguous legacy state and refuses recovery.

Cohort destination comparison initially appended an empty root node component,
leaving a trailing separator unlike the core's import-root result. A complete
private attempt was retained and no dispatch/live publication occurred. Root paths
now append only nonempty relative components. Library resource integration exposed
the related legitimate trailing separator returned by directory APIs; validated
transfer directory roots now remove that empty final component without relaxing
no-follow or ownership checks. The dirty-NOTE resource regression then passed,
with unsaved source and on-disk revision unchanged.

Early new test fixtures omitted provider accepted-name records and export consent;
native correctly refused them. Fixtures now follow the real closed schemas. A test
and throwaway smoke also captured native-owner futures in isolate closures; moving
the filesystem request closure to a top-level function fixed the harness without
passing a core context across isolates.


### Executed Android workflows and desktop interoperability

Both Android arm64/x86_64 ABIs were packaged through the pinned root build command.
Installed on Medium_Phone (Android 17/API 37, 16 KiB pages), without clearing app
data. The final installed APK hash matched the built package. The final grouping
dialog was visually checked after correcting its disclosure to **new node IDs**,
not new notebook IDs.

- Actual system ZIP and folder pickers each imported the same seven raw files into
  separate child cohorts: Unicode Markdown, CRLF/BOM/combining-mark/emoji source,
  nested references, binary data, a hidden sidecar and an empty file. Every byte
  was compared independently with the original input. Folder permission came from
  the actual SAF confirmation, not a filesystem bypass.
- Force-stop/cold-start after ZIP preparation retained identical `prepared.json`
  and `ids.json`; Apply committed the same sealed root ID. Discarding private
  staging left the live cohort intact.
- A standalone Markdown file selected through the file picker refused a conflicting
  child name before publication. Explicit pre-seal name change then prepared and
  committed it without replacing the prior cohort. An escaping local dependency
  was refused with no live child/prefix. Cancelling the system picker retained a
  visible zero-byte attempt that explicit discard removed.
- Imported the previous real Files and assets export through the new ZIP path.
  All four source files and their old UUID-named asset path remained byte-exact;
  the imported note received a new core ID. No old path or source link was rewritten.
- On a dirty ordinary-note editor, the real image picker published a 68-byte PNG
  while leaving the exact received source and native body unchanged. Insert image
  added escaped literal Markdown. One Undo restored all earlier unwritten source;
  Redo restored the link. Explicit Write advanced the on-disk revision, and Reopen
  installed revision zero from the exact captured CodeMirror bytes. The PNG and
  note ID survived later process restart.
- Added a 1,792-byte tracked binary attachment, untracked it without deleting bytes,
  tracked it again, and renamed it. Save As cancellation retained a verified private
  snapshot. Force-stop/cold-start displayed the ambiguous-external-copy warning and
  preserved its ready marker. Save As again produced an external file exactly equal
  to the original binary. Explicit removal then cleared attachment membership and
  the selected file without modifying source or the unrelated PNG.
- Exported the new notebook through the existing whole-backup/system Save As flow.
  Independent ZIP CRC and byte comparisons covered both raw cohorts, edited source
  and image. The default Windows desktop SDK opened/read/closed that Android backup
  with the same notebook/node IDs and every portable file unchanged. Its isolated
  test-mode paths did not enable the mobile writer or change production defaults.

The new owned **Offline workflows** notebook remains on the AVD for manual testing.
All 26 preexisting managed files, including Personal/Projects and prior fixtures,
were byte-for-byte unchanged. Settled imports/exports/cohorts/resources roots were
empty; `/proc/<app-pid>/fd` contained no retained transfer-file descriptors. Browser
sessions, debug forwarding and owned throwaway fixture/scenario files were removed.
The final app and AVD remain running.

### Recovery boundaries and verification limits

Added real-filesystem regressions for charging an attempt after it moves under
`vx_import`, including physical children moved before parent publication; a foreign
replacement of its recorded wrapper identity refuses allocation. A controlled
unexpected-name outcome retains real copied bytes/dispatch evidence across a fresh
owner, refuses both recovery-as-success and re-copy, and permits only explicit
private abandonment. This models a suffix result before receipt; it is not a claim
that a timing-dependent external-writer race was reproduced on a device.

One fast ADB text-injection burst rendered fewer characters than its command string.
Preservation/Write checks used the actual CodeMirror source, not that command as an
oracle. A later instrumented burst arrived intact; this does not establish a cause
or physical-device IME/no-dropped-input coverage. The diagnostic input was discarded
through the normal editor disposition barrier, not written to the notebook.

No iOS build/runtime, physical-device, actual power-loss/disk-full, provider
revocation or OEM backup/transfer guarantee follows from these checks. The share
inbox, durable editor drafts/autosave/preview, WebDAV, publication and release gates
remain open. No repository was pushed.


## Phase 3: durable editing and isolated preview

Observed on the existing Windows host and Medium_Phone Android 17/API 37,
16 KiB-page AVD with WebView 156.0.8078.47. No app-data reset or repository push.

### Final automated and packaging checks

| Executed check | Result |
| --- | --- |
| Pinned `node scripts/verify.mjs verify` | Passed dependency/assets, generated FFI drift, TypeScript and both Dart analyzers |
| Editor/protocol/formatting/render policy tests | 103 passed |
| Native bridge Dart tests | 159 passed; one Windows symlink-privilege skip |
| Flutter tests | 416 passed; two platform skips |
| Release `native_host_test` rebuild and execution | `Native host real-storage tests passed` |
| Core cold-context prerequisite CTest selection | 6/6 passed: core, context paths, workspace, notebook-record reconciliation, session persistence and buffer |
| Pinned `node scripts/verify.mjs android` | arm64-v8a and x86_64 packaged; all three LOAD segments in each native library aligned to 16,384 bytes |

The installed APK SHA-256 matched the final build:
`d3ef23e5cdcb3bb958e7e411d49ba01ab46bc19bc53d737db37f56b5bf8c32a9`.
The separately reviewed core prerequisite is committed at
`2ddf4281ccd14d79da6101cb26157e434f6ae243`; default desktop session restoration
remains covered and unchanged. Explicit-root mobile contexts start cold rather
than resurrecting a legacy open notebook/buffer before application ownership.

Real-storage regressions cover torn unacknowledged tails, corrupt acknowledged
frames, publication obstruction, immutable save/export candidates across
compaction, UTF-16 boundaries, dirty revision-zero rebasing, exact source-versus-
encoded-disk receipts, conflict reconciliation and bounded retention. Preview
regressions cover confinement, MIME/dimensions, stale handles, immutable exports,
joined revocation and prior-process reclamation without deleting unready exports,
current unpublished pins, linked or unrecognized data.

### Executed durable editor and recovery workflows

- In the owned **Durability preview** notebook, actual CodeMirror input autosaved
  303 UTF-8 bytes containing Japanese, accents, math and diagrams. Bold formatting
  saved the next revision; one Undo restored all original bytes exactly.
- Force-stop with an actual open native notebook/buffer, then cold-start/reopen,
  preserved the saved source without implicit-session restoration failure.
- A controlled external change to `Security.md` made autosave refuse. The UI
  retained received/draft revision 2 and saved revision 1; force-stop/restart
  recovered exact private `ZR` while preserving `External newer disk\n` on disk.
  Restore refused the conflict. Actual Save As exported exact `ZR`; explicit
  keep-disk/discard removed only the private recovery record.
- In a second controlled conflict, restoring the known matching opening bytes
  allowed explicit Restore. The new capture visibly began at received/draft 0
  with **Saved none**, without modifying disk. Only its later real saved receipt
  established revision 0 and exact `External newer disk\nX` on disk.
- Corrupting an owned inactive manifest produced visible quarantine, not a
  fabricated text recovery. Actual Save As emitted a 1,539-byte `VXDRAFT1` archive
  containing the exact malformed manifest bytes. Explicit staging and draft
  discard left the saved notebook body unchanged.

### Executed renderer, navigation and native network boundary

The native visible preview contained two MathML expressions, a flowchart and a
sequence diagram, plus a decoded 16×16 local PNG. Its editor bridge was undefined.
Raw/unsupported source remained nonactive. The final AVD screenshot shows the
rendered math and both diagrams; the editor remains a separate retained surface.
An opaque preview-file link passed explicit host confirmation and actual Android
Save As; the exported 33 bytes matched the original binary. Private export staging
was then explicitly discarded. Internal note links use the host navigation
barrier; confirmed external navigation handed off to system browser UI rather
than loading inside the viewer (Chrome first-run UI was not accepted).

An exact one-MiB Unicode long-line source rendered without truncation. Native
viewer text contained 1,048,574 UTF-16 units / 1,048,576 UTF-8 bytes, including an
emoji crossing the 32,768-unit transport boundary. Its SHA-256 matched the input:
`a358f48953a3f5e0bb4bf81649e67d3552ab0443aa9e9c1fa585f0b7126d68a5`.
This exposed and corrected a split-surrogate chunk boundary and excessive
per-unit native encoder construction; output now uses scalar-safe chunks and a
reused buffered encoder. Trusted cold-start bounds remain separate from untrusted
render work. A bounded cold-run timeout was observed; explicit Refresh later
succeeded without changing source. This is not a universal latency guarantee.

The actual renderer JavaScript was deliberately paused before a math/diagram job.
The independent native watchdog retired only its renderer process after 2,010 ms.
The main app PID, saved source and an editor-document identity marker survived.
After returning to source, one real Undo still worked and restored exact prior
bytes. The UI disclosed the timeout rather than claiming successful rendering.

Owned HTTP, TLS and UDP observers had positive controls. In actual native editor
and preview documents with CSP deliberately bypassed, HTTP(S), ws/wss,
WebTransport and RTC attempts failed; RTC exposed no configured ICE servers.
A running blob worker also failed its fetch/WebSocket attempts (and editor worker
WebTransport); inherited blank frames and the preview srcdoc failed fetches.
Counter snapshots showed only the observation query, not probe egress. The editor
probe separately demonstrated no CSP meta and successful inline execution, so
CSP denial is not the claimed native proof. The final source/APK restored CSP;
no diagnostic bypass is shipped. An earlier nested RTC probe caused Chromium's
native bad-IPC renderer termination while the main app survived; it was not
misreported as a successful child execution.

Browser preference changes exercised dark/high-contrast, 2× text and reduced
motion without changing source; original Android system settings were restored.
UI automation observed labeled editor/recovery controls. Full physical-device IME,
TalkBack/VoiceOver and platform accessibility certification are not established.

Both sealed legacy and v2 preview generations left by dead app processes were
reclaimed on the next real preview admission. The current v2 owner remained live.
The v2 export workflow still produced exact bytes after this cutover.

### Implementation review corrections

The new real-native rollback regression first failed with `base` instead of
`conflict`. Recovery now requires no established receipt before accepting an
opening-base fallback; matching pending intended bytes still take precedence.
The targeted 15 tests passed, followed by the complete checks above. On the AVD,
a saved revision 1 followed by an acknowledged revision 2 and a controlled disk
revert to its exact opening bytes stayed a conflict across process restart.
Actual Restore refused, preserved the original token and saved receipt, and did
not publish a successor. Explicit keep-disk/discard left the original disk bytes.

A native debugger then changed only the cached renderer name so the live Binder
could not be proved safe to kill. Render and close settled as errors, not success;
all seven snapshot files and the live peer remained. Source was accessible, and
the final UI did not falsely show capture progress while retirement was pending.
Restoring the cached name alone still released nothing. The retry authorized a
kill; a breakpoint at the actual death callback showed the original PID absent
while every file was still retained. Only after that handler and local readers
joined did close reclaim them. The main PID and exact source survived.

Android automatically started a replacement service process while the old death
callback was paused. One-handshake-per-generation admission prevents that peer
from replacing the original binding; the final release boundary also rechecks
for a live endpoint after queued handshake work. Render replies and consumed
cancel/close callbacks cannot be answered again after later death. No duplicate-
completion exception appeared in the exercised main-process log. View disposal
removes its UI even on failure without dropping the unjoined renderer lease.

The full suite ran after the receipt/error-completion corrections. The final
presentation condition passed workspace analysis; final binding/release guards
were packaged for both Android ABIs and the debugger scenario repeated on that
installed APK. A subsequent cold preview reached its visible time limit; after
debugger detachment, explicit Refresh rendered normally. No timeout budget was
relaxed and no diagnostic code was added. Debugger sessions and forwards were
removed; the final APK hash, 16 KiB alignment and continuation baseline were checked
again after these scenarios.

### Preservation, cleanup and remaining gates

All 58 non-fixture notebook files matched the persisted **continuation** SHA-256
baseline using byte-safe archive transport, including space/Unicode paths. The
original pre-phase baseline was lost when the Python harness terminated; this
comparison does not establish that earlier interval. All intentional notebook
mutations stayed in the owned Durability preview notebook. A quoted-path ADB
reader initially returned error text instead of bytes; the archive comparison
resolved that harness error without changing any notebook data.

Owned probe services, 11 local fixture/TLS files, 11 remote temporary/export files,
browser sessions and Android debug forwards were removed. Resource staging was
empty. The final AVD and app remain running on the demonstration preview.

No iOS build/runtime, physical-device, actual power-loss/disk-full or OEM backup
promise follows from these checks. Public WK APIs still lack the required
all-protocol guarantee; iOS editing/preview remains visibly fail-closed, not a
claimed working port. Share-in, WebDAV, publication and release gates remain open.
