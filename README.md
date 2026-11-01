# VNote Mobile

Flutter iOS/Android client for VNote. Implementation follows the [mobile plan](docs/mobile-client-plan.md).

Current scope is an **editor validation session**, not a working notebook client. Text is held in memory only; closing the app can lose it. There is no native notebook connection, local-save acknowledgement, preview renderer or sync implementation. The complete product boundary remains unchanged. Phase 0 and Phase 1 are not complete; see [verification and blockers](docs/verification.md).

## Development

Use the exact versions in [toolchains.json](toolchains.json): Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1. Do not upgrade the core or SDK implicitly.

```sh
git submodule update --init --recursive
node scripts/verify.mjs verify
node scripts/verify.mjs android
node scripts/verify.mjs ios
node scripts/verify.mjs run
```

Run commands at the repository root. `verify` installs locked editor/Dart dependencies, builds and checks assets, then runs TypeScript and Dart checks. `android` produces a debug APK; `ios` requires macOS/Xcode 26.6 and builds unsigned device and simulator apps. `run` performs the same asset/dependency gate before Flutter device selection. These commands do not configure release signing, accept SDK licenses or publish anything.

Flutter may be on PATH, specified by the `FLUTTER` environment variable, or installed at `.tools/flutter`. Windows commands require PowerShell 7. On Windows the locally downloaded Node can be invoked as `./.tools/node-v24.22.2-win-x64/node.exe`; its matching npm is used by the script. Set `JAVA_HOME` to a JDK matching the Android pin before building (the local download is `.tools/java/jdk-17.0.20.1+1`). SDK caches and machine paths are not committed.

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
- `third_party/vxcore` is the unchanged recursive C++17 core pin. Its public C ABI will sit behind a dedicated native owner thread; no global core singleton or second note database.
- Desktop reference: `f8026adb4c43f78d90251148e24b6e72ca28f3d7`; core: `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`.

Read [architecture](docs/architecture.md), [compatibility](docs/compatibility.md) and the six ADRs linked there before extending the boundary. Native sandbox paths, mobile TLS packaging and durability are prerequisites, not ignored errors or permission to replace core operations with Dart filesystem writes.

Android `com.example.vnote_mobile` and iOS `com.example.vnoteMobile` are generated development identities, not owner-approved store identifiers.

## License

VNote Mobile is licensed under **GNU LGPLv3**, matching VNote by owner decision. See [COPYING.LESSER](COPYING.LESSER) and its incorporated [GNU GPLv3 terms](COPYING). No warranty is provided under those terms.

`COPYING.LESSER` is copied verbatim from the pinned VNote reference; `COPYING` is the canonical GNU GPLv3 text. The MIT license of vxcore and licenses/notices of Flutter, CodeMirror and all other dependencies remain unchanged. Generated editor assets include their bundled dependency notices, and the app includes both application license texts. This is not a completed release license/SBOM review; distribution must also satisfy source, modification/relinking and store obligations.
