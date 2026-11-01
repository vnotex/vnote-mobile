# Verification record

## Gate status

The managed-notebook native slice is implemented and exercised on Android. **Phase 0 publication and full Phase 1 gates remain open:** the new core pin is local until authorized publication, and iOS/physical-device checks are unperformed. Sections below retain the earlier editor-only evidence and add the native slice results separately. No personal notebook or production account is used.

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
