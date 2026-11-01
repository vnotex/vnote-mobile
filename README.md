# VNote Mobile

Flutter iOS/Android client for VNote. Implementation follows the [mobile plan](docs/mobile-client-plan.md).

The app opens a managed **Personal** bundled notebook and **Welcome.md** through the real native core. **Write** commits the captured editor revision to the note; **Reopen** starts a fresh native/editor session against the same files and identities. Unwritten input is still volatile: autosave, draft recovery, preview and sync are not implemented. Full Phase 1 device/iOS gates remain open; see [verification and blockers](docs/verification.md).

## Development

Use the exact versions in [toolchains.json](toolchains.json): Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1. Native builds also require CMake 3.29.2, Ninja 1.12.0 and Android NDK 28.2.13676358. Do not upgrade the core or SDK implicitly.

```sh
git submodule update --init --recursive
node scripts/verify.mjs verify
node scripts/verify.mjs android
node scripts/verify.mjs ios
node scripts/verify.mjs run
```

Run commands at the repository root. `verify` installs locked editor/Dart dependencies, builds and checks assets, then checks generated FFI drift, TypeScript, the real native bridge tests, and Flutter. `android` produces an arm64/x86_64 debug APK requiring Android 9/API 28; `ios` requires macOS/Xcode 26.6 and builds unsigned device and simulator apps. `run` performs the same asset/dependency gate before Flutter device selection. These commands do not configure release signing, accept SDK licenses or publish anything.

Flutter may be on PATH, specified by the `FLUTTER` environment variable, or installed at `.tools/flutter`. Windows commands require PowerShell 7. On Windows the locally downloaded Node can be invoked as `./.tools/node-v24.22.2-win-x64/node.exe`; its matching npm is used by the script. Set `JAVA_HOME` to a JDK matching the Android pin before building (the local download is `.tools/java/jdk-17.0.20.1+1`). SDK caches and machine paths are not committed.

Native binding generation uses ffigen 23.0.0 and libclang 18.1.1 with the pinned NDK headers:

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
- `packages/vxcore_bridge` wraps the C++17 core C ABI on a dedicated native owner thread. The core has additive sandbox-root initialization and opt-in atomic ordinary-note publication; there is no global core context or second note database.
- Desktop compatibility reference: `f8026adb4c43f78d90251148e24b6e72ca28f3d7`; original core baseline: `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`. The current core gitlink and `toolchains.json` record the separately committed implementation pin.

Read [architecture](docs/architecture.md), [compatibility](docs/compatibility.md) and the six ADRs linked there before extending the boundary. Mobile TLS trust integration, iOS execution and full draft durability remain gates, not ignored errors or permission to replace core operations with Dart filesystem writes.

Android `com.example.vnote_mobile` and iOS `com.example.vnoteMobile` are generated development identities, not owner-approved store identifiers.

## License

VNote Mobile is licensed under **GNU LGPLv3**, matching VNote by owner decision. See [COPYING.LESSER](COPYING.LESSER) and its incorporated [GNU GPLv3 terms](COPYING). No warranty is provided under those terms.

`COPYING.LESSER` is copied verbatim from the pinned VNote reference; `COPYING` is the canonical GNU GPLv3 text. The MIT license of vxcore and licenses/notices of Flutter, CodeMirror and all other dependencies remain unchanged. Generated editor assets include their bundled dependency notices; the native host embeds the actual core/dependency notices, and the app includes both application license texts. This is not a completed release license/SBOM review; distribution must also satisfy source, modification/relinking and store obligations.
