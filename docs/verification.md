# Verification record

## Gate status

The editor/build kickoff is implemented and locally exercised. **Neither Phase 0 nor Phase 1 has passed.** A Windows core build and an editor-only session do not establish notebook persistence, mobile native packaging, desktop compatibility or iOS readiness. No personal notebook or production account is used.

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

## Remaining native/product gates

- Additive context-level persistent app/local roots before core initialization, with desktop regressions; no ignored JSON, environment or test-mode production workaround.
- Actual Android OpenSSL/curl and iPhoneOS/simulator curl/dependency builds, TLS trust handling, release symbols and 16 KB native packaging.
- Real asynchronous Dart/native host and notebook create/save/reopen, errors, ownership and teardown. No empty bridge or mock backend stands in for these.
- Core ordinary-save crash safety and durable draft/write-intent recovery before persistence labels; concurrent error-state synchronization and bounded search cancellation/result behavior before those workers are enabled.
- Desktop/mobile fixture round trips, real-device IME/accessibility/performance and process-kill tests; preview isolation, WebDAV, import/export/share and release scenarios in plan section 7.
- Owner-controlled upstream changes/publication, store IDs, signing and LGPL distribution review. No push or store submission occurred.
