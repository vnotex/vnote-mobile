# ADR 0001: Native packaging and persistent core roots

Status: native build hook and explicit-root ABI implemented; Android arm64/x86_64 builds and x86_64 device-surface checks are recorded in verification. Android platform-trust fixture checks are recorded separately; iOS, physical-device and release trust-store gates remain open, so this does not complete Phase 1.

## Evidence and dependency audit

Compatibility baseline: VNote `f8026adb4c43f78d90251148e24b6e72ca28f3d7`, recursive vxcore `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`. Source references below are relative to this ADR; the core gitlink is authoritative, not branch names. The application license is GNU LGPLv3 by owner decision, not a change to dependency licenses.

[Core CMake](../../third_party/vxcore/CMakeLists.txt) requires CMake >=3.18, C++17, PIC, Threads and non-Windows Iconv. [Dependency CMake](../../third_party/vxcore/third_party/CMakeLists.txt) includes all of the following even with CLI/tests/tools disabled; lack of Git/encryption UI does not remove their native dependencies.

| Component | Exact source/version evidence | License/distribution disposition |
| --- | --- | --- |
| vxcore | pin above; project 0.1.0 | MIT; retain LICENSE |
| SQLite | vendored `sqlite/sqlite3.h`: 3.47.2; source ID `2aabe05e2e8cae4847a802ee2daddc1d7413d8fc560254d93ee3e72c14685b6c` | Copyright dedication in source; retain provenance |
| nlohmann/json | vendored `nlohmann/json.hpp`: 3.11.3 | MIT header notices |
| VNote cmark fork | recursive gitlink `6148f317138d873041043742e61d26c74d31c6a1`; CMake 0.31.2 | BSD-2-Clause main code plus MIT-derived components; retain complete COPYING, not just first notice |
| libgit2 | recursive gitlink `a418d9d4ab87bae16b87d8f37143a4687ae0e4b2`; header 1.7.2 | GPLv2 with explicit linking exception; retain full COPYING including bundled component notices. Exception is not a relicense of modifications |
| libsodium adapter | `9b2848dfc1b917a9410f0de9d81059b26cbfaa8d` | Dependency CMake installs adapter LICENSE separately; exact fetched license inventory remains a release gate |
| libsodium | adapter's recorded official pin `93a7d0d41fe2e32409b5d00386946f491750b7de` | Separate upstream LICENSE; verify recursive fetched tree against pin before packaging |
| libcurl (non-Apple) | 8.22.0 archive; SHA-256 `d54dd598bf05927a726deb38df31c6a255ba83ff1de57c5d1464dac3ed8f44a1` | Ship archive COPYING; curl license, not LGPL |
| pugixml | 1.16 archive; SHA-256 `4cee1ca4aad395170f4c7a07824f3bdd41f28316c6e1e1090a1425b278ec0b4b` | Ship archive LICENSE.md (MIT); verify fetched archive/license |
| OpenSSL | required by non-Apple Unix branch; **not pinned by core** | Android cross-build version, source hash, license and notices must be selected together; never resolve host OpenSSL |
| Platform/runtime dependencies | Threads, Iconv, Apple CoreFoundation; libgit2 builtin regex/http parser and bundled zlib off Apple, system zlib on Apple | Audit actual linked components and their embedded notices per ABI; system SDK dependencies are not evidence of an available iOS API |

The audit is source/configuration evidence, not a complete resolved binary SBOM or vulnerability clearance. In particular, fetch hashes in CMake are expected hashes, not evidence that an archive was verified here. Keep exact resolved source hashes, transitive notices, generator/plugin locks and a release binary dependency inventory. LGPLv3 application distribution must supply corresponding source and applicable modification/relinking materials; store signing/terms and any static-link obligations require a distribution review before publication. Never replace dependency licenses with the application's license.

## Packaging decision

Use a Flutter package build hook under `packages/vxcore_bridge/hook/` to drive the existing CMake graph, not a second source list in Gradle/Xcode. Follow [Flutter native bindings/build hooks](https://docs.flutter.dev/platform-integration/bind-native-code). The hook, generated FFI boundary and native owner host are implemented in `packages/vxcore_bridge`. Build-time dependency preparation is explicit in `scripts/native_deps.mjs`; no assets are downloaded at runtime. Cache outputs by exact core/dependency pins, target triple, SDK, architecture, configuration and toolchain flags; report native code assets to Flutter. Fail for missing or mismatched inputs; do not fall back to a host binary. Generate FFI declarations from public headers plus the separate host ABI with pinned ffigen.

Build static PIC vxcore/dependencies into the host artifact, with `VXCORE_BUILD_SHARED=OFF`, `VXCORE_BUILD_CLI=OFF`, `VXCORE_BUILD_TESTS=OFF`, `VXCORE_BUILD_TOOLS=OFF`, `VXCORE_INSTALL=OFF`. Link Android host as a packaged shared library; use the pinned Flutter hook-supported Apple code-asset linkage, retaining required symbols in release builds. There is one C++ runtime choice per target; never pass C++ STL types, exceptions or allocator ownership across the public C ABI. Preserve export visibility, `size_t` width, enum values, calling conventions and matching allocators. Test release dead-stripping and generated layouts, not only debug loading.

Requested target set: Android arm64-v8a device plus x86_64 emulator; iOS arm64 device plus selected simulator architectures as distinct SDK slices. Exact native selections are in [toolchains.json](../../toolchains.json): Flutter 3.47.9/Dart 3.13.7, Android API 36/minimum 28/NDK 28.2.13676358, iOS minimum 15.0/Xcode 26.6. The Android notebook APK includes vxcore and was exercised on a 16 KB x86_64 emulator; both native ABIs have 16 KB ELF LOAD alignment. iOS remains unexecuted. CMake 3.29.2/Ninja 1.12.0 are host tools. The complete Flutter/plugin/native dependency intersection, physical-device support and release packaging remain verification gates; emulator execution is not physical-device coverage.

### Transport gates

Android enters `UNIX AND NOT APPLE`: top-level `find_package(OpenSSL REQUIRED)`, libgit2 `USE_HTTPS=OpenSSL`, curl `CURL_USE_OPENSSL=ON`. OpenSSL 3.5.9 is source-built with the pinned NDK for both selected ABIs and supplied through target-only CMake paths. The native runtime verifier delegates to the platform trust manager while retaining peer/hostname checks; actual certificate/hostname device evidence is recorded separately in verification. NDK presence does not supply OpenSSL. Curl uses HTTP-only protocol selection with TLS, threaded resolver, basic/digest auth; no automatic plaintext downgrade or certificate bypass is allowed.

The desktop Apple branch retains SDK libcurl/SecureTransport. The iOS branch now selects bundled curl and the pinned OpenSSL cross-build instead of assuming iPhoneOS supplies libcurl. Verify iPhoneOS and simulator SDK headers, symbols, availability and permitted linkage separately. The source-build option retains the same WebDAV implementation and SecTrust adapter; missing target SDK/build prerequisites remain a stop gate, never permission to substitute a Dart uploader or macOS library. Verify Iconv, filesystem/process compilation and unused external-rg code as well. No mobile support is claimed from these branches.

## Persistent roots decision

[Context creation](../../third_party/vxcore/src/api/vxcore_api.cpp) ignores `config_json`. [ConfigManager](../../third_party/vxcore/src/core/config_manager.cpp) chooses roots and session-loading policy in its constructor. Default desktop contexts read both `vxcore.json` and `vxsession.json`; explicit-root contexts load user configuration but start with an empty session before constructing managers. [PathProvider](../../third_party/vxcore/src/platform/path_provider.cpp) uses desktop HOME/XDG on Android and `Library/Caches` for Apple local data. Local data includes durable session state and cannot be treated entirely as disposable cache.

The implemented **mobile context-level C ABI**, declared only in `vxcore/mobile/vxcore_mobile.h`, is:

```c
#include <vxcore/mobile/vxcore_mobile.h>

VxCoreError vxcore_context_create_with_paths(
    const char *config_json, const char *app_data_path,
    const char *local_data_path, VxCoreContextHandle *out_context);
```

CMake selects `src/mobile/context_mobile.cpp` and `src/mobile/config_manager_mobile.cpp` only for Android/iOS, publishing `VXCORE_MOBILE_API=1`. Default desktop builds do not declare, compile or install the extension. The explicit `VXCORE_ENABLE_MOBILE_TEST_API=ON` option exposes only this API for desktop-hosted bridge tests, requires `VXCORE_INSTALL=OFF`, and never selects mobile save behavior.

Keep `vxcore_context_create`'s signature and existing desktop defaults/ignored-config semantics unchanged. Both entry points share internal `vxcore::InitializeContext` manager wiring; the new one passes owned path options into ConfigManager construction. Do not introduce a global setter. UTF-8 input strings are borrowed only during creation and copied into that context. Clear output handle on failure. Validate both roots before default path resolution, `LoadConfigs`, directory creation or other initialization side effects: reject null, empty, malformed UTF-8, relative and identical roots (including normalized/equivalent aliases); preserve separate namespaces and reject containment/aliasing that defeats separation. Return parameter error for invalid roots, IO error for inaccessible roots, never silently use desktop defaults. Explicit valid roots take precedence over test/portable/default resolution only for this context. They are immutable for its lifetime.

Explicit-root creation never reads legacy `vxsession.json` or automatically opens recorded notebooks, buffers or workspaces. The app owns notebook admission and its separate durable draft recovery; stale or malformed legacy core sessions cannot bypass that boundary. User configuration is not changed to implement this policy. Normal explicitly admitted operations/shutdown may still write core session state. Default desktop creation retains its original restoration behavior. Host export/resource admission retains no-follow regular/single-link identity checks for the session path because later core writeback must remain confined; it no longer parses obsolete restoration contents.

The platform adapter obtains persistent app-private sandbox locations: separate `app` and `local` children of Android internal files storage / iOS Application Support, plus a separate managed notebooks root. Validate canonical ancestry against OS-provided persistent roots and reject cache/temp or escaped/symlinked destinations. Notebook create/open root arguments do not configure core roots. Backups distinguish user settings/notebooks from device-only state and rebuildable indexes; only proven-disposable content goes in OS caches. Never change HOME, use portable executable folders, enable test mode in production, or put ignored path keys in JSON. No context probe may touch a user's profile.

## Rejected alternatives

A global pre-create setter races independent contexts. Reusing `config_json` without implementation silently writes the wrong directories. Vendoring a mobile fork or dependency downloads hidden in a hook defeats source reproducibility. Assuming system iOS curl from macOS results, or dropping WebDAV/Git-linked dependencies because their UI is absent, defeats the actual link graph.

## Observable acceptance gates

- Clean recursive checkout resolves the recorded artifacts/locks; native hook builds and loads each selected release ABI, with export/FFI ownership checks and no host libraries in target output. Android page-size compatibility and iOS device linkage are exercised.
- Device TLS tests accept a trusted endpoint and reject hostname mismatch, expired/untrusted certificates and downgrade. iOS curl and Android OpenSSL provenance/trust wiring are recorded.
- New path ABI creates/reopens config/session/notebook fixtures solely in isolated approved roots; cache eviction leaves durable state intact. Invalid roots cause no default-profile writes. Two contexts with different explicit roots remain isolated; changed input storage does not change retained paths.
- Desktop legacy create tests cover platform defaults, portable `config/app` and `config/local`, and controlled test-mode roots without behavior changes. Both default and explicitly test-enabled desktop configurations retain the original in-place writer and its link/permission behavior. Failure cleanup leaves no published context; persistence errors surface.
- Exact SDK intersection, fetched license inventory, SBOM and LGPL/store distribution review are completed before release. Actual commands, results and platform limits are recorded in [verification](../verification.md).
