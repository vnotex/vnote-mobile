# Dependency notices, inventory and corresponding source

The notice pipeline is fail-closed evidence collection, **not legal advice, legal clearance, vulnerability certification or store approval**. License grants, attribution and notices remain in their original language. Application terms remain GNU LGPL version 3 only, with full `COPYING.LESSER` and `COPYING` bundled beside `DEPENDENCIES.txt` and displayed through the existing in-app license sheet.

## Evidence sources

- **Dart:** the runtime closure starting at `vnote_mobile` in Pub's actual package graph; exact `pubspec.lock` versions and hosted archive hashes; actual installed package license bodies. SDK packages identify the pinned Flutter revision. The existing audited `archive-4.6.0.txt` supplement remains included. Flutter's actual `sky_engine/LICENSE` retains the engine's bundled third-party notices.
- **JavaScript/fonts:** the existing `packages/editor_web/build.mjs` esbuild contribution audit, exact npm lock version/integrity/source, actual package grants, and existing hash-audited embedded Babel/React/Mermaid/font evidence. Its editor/preview notice generation is extended, not replaced. It additionally emits `.tools/notices/npm-runtime.json`.
- **Native:** the existing CMake notice pipeline reads the exact configured sources and also emits `native-dependencies.json` and `native-NOTICE.txt` in each native build directory. Source provenance includes the current checked core pin, actual cmark/libgit2 submodule revisions, CMake-pinned curl/pugixml archives, the libsodium adapter and core commits, pinned utf8proc/OpenSSL, NDK version, and hashes of vendored SQLite/JSON/thread-pool sources. SQLite's notice comes from its actual source header. The thread-pool header omits the MIT grant, so CMake retrieves the actual [v5.1.0 license](https://raw.githubusercontent.com/bshoshany/thread-pool/v5.1.0/LICENSE.txt) with SHA-256 `712a867cc12ebfcdecf6cea097f5aa7ec5acaa435a8f818c9f370960df35acbf`. The existing pinned nlohmann grant is retained.
- **Maven:** Gradle resolves the real `releaseRuntimeClasspath`, including transitives, artifact hashes and POM/parent POM files. The app lockfile fixes versions; Gradle verification checks both binaries and metadata. The generator reads actual JAR/AAR and nested `classes.jar` NOTICE/LICENSE files and POM license/source declarations. It never assumes Apache-2.0 from a group name. An explicit Apache license URL in the resolved POM may use the complete, hash-audited Apache grant already shipped in the pinned npm artifact. Flutter's known release artifact families are allowed only at the exact SDK engine revision and use the actual aggregate engine license body; arbitrary `io.flutter` packages are not exempted.

Missing/unknown grants, missing POM/source evidence, changed hashes, unlocked Maven runtime components and changed native-source identities fail generation. There is no generic-license fallback and no network request by the notice generator. Dependency retrieval is done only by the existing pinned dependency/build tools. A changed graph requires deliberate lock/evidence review, not turning verification off in normal builds.

Release compile/runtime configurations are version-locked. Debug/profile select
engine ABIs dynamically for the chosen emulator/device and are not version-locked;
their resolved artifacts still require the same checksum verification evidence.
This preserves ordinary single-device `flutter run` and profile builds without
weakening the fixed two-ABI release graph or accepting new artifact hashes.

## One-time lock/evidence generation after all source changes land

The integrator owns this step; do not generate dependency state concurrently with source edits. Commands below are from the repository root except for the explicitly named Gradle working directory. On Windows use the pinned `flutter.bat` and `gradlew.bat` equivalents and set environment variables through PowerShell rather than POSIX `export`.

1. Install the pinned tools, initialize exact submodules, run `flutter pub get --enforce-lockfile`, then `node scripts/verify.mjs assets`. If this implementation deliberately changes Pub dependencies, update/review the workspace Pub lock once first, then use `--enforce-lockfile` thereafter.
2. Set `VNOTE_PACKAGE_MODE=unsigned-validation`. With working directory `apps/vnote_mobile/android`, run the following single deliberate bootstrap invocation. This is the **only** workflow where newly resolved checksums are accepted for review:

   ```sh
   ./gradlew :app:resolveDependencyLocks :app:dependencyNoticeInputs \
     :app:assembleDebug :app:assembleProfile :app:assembleRelease :app:bundleRelease \
     -Ptarget-platform=android-arm64,android-x64 \
     --write-locks --write-verification-metadata sha256 \
     --dependency-verification lenient --no-daemon
   ```

   This creates the approved `apps/vnote_mobile/android/app/gradle.lockfile` and `apps/vnote_mobile/android/gradle/verification-metadata.xml`, including task-time artifact/POM resolution. It does not certify those hashes as trustworthy. Review additions against upstream provenance before retaining them. Metadata verification must stay enabled. Retain the lock/verification files in source control; never include private handoff paths in them. A dependency error is a blocker to investigate, not permission to accept arbitrary replacement artifacts.
3. From the root, collect actual built mobile notices:

   ```sh
   node scripts/dependency_notices.mjs \
     --native .tools/host-android-arm64-28 \
     --native .tools/host-android-x64-28
   ```

   A configured iOS build adds `--native .tools/host-ios-arm64-iphoneos`. Multiple native inputs aggregate platform-specific notices. Do not pass a desktop host build as evidence of a mobile dependency graph.
4. Exercise strict packaging and compare generated evidence:

   ```sh
   node scripts/release.mjs android unsigned-validation
   node scripts/dependency_notices.mjs --check \
     --native .tools/host-android-arm64-28 \
     --native .tools/host-android-x64-28
   ```

   The release command re-resolves actual release Maven inputs under strict verification, regenerates notices from locked sources, and validates the final notice-bearing APK/AAB. It does not update locks or verification metadata. iOS app/archive execution requires macOS and the matching toolchain; its configured CI job is not evidence that it ran locally.

On an ordinary reproducible build with reviewed locks already present, the release command performs the needed resolution/build/generation automatically. To regenerate only the Maven handoff, run `:app:dependencyNoticeInputs -Ptarget-platform=android-arm64,android-x64 --dependency-verification=strict --no-daemon` with explicit unsigned-validation mode from the Android directory. `--check` compares expected outputs byte-for-byte; it does not silently repair them.

## Generated output manifest

Before running the pipeline, account for these outputs:

| Producer | Output |
| --- | --- |
| Existing editor generator | Existing editor/preview HTML, CSS, JS, fonts, NOTICE.txt, manifest.json, legal COPYING/COPYING.LESSER; additional `.tools/notices/npm-runtime.json` |
| Native CMake configure | Each native build directory: `licenses.cpp`, `native-NOTICE.txt`, `native-dependencies.json`, `thread-pool-LICENSE.txt`, `sqlite-NOTICE.txt` |
| Gradle evidence task | `.tools/notices/android-runtime.json` (private build-local paths; never distribute) |
| Deliberate Gradle lock bootstrap | `android/app/gradle.lockfile`, `android/gradle/verification-metadata.xml` under `apps/vnote_mobile/` |
| Notice generator | `apps/vnote_mobile/assets/legal/DEPENDENCIES.txt` |
| Notice generator | `.tools/notices/dependency-inventory.json`, `.tools/notices/sbom.cdx.json` |
| Release packaging | Mode-labeled local package directories, copies of the inventory/SBOM/notices, `package-result.json`; see [mobile-release.md](mobile-release.md) |

The inventory is deterministic: sorted components/evidence, exact versions and hashes, no timestamps or private absolute build paths. CycloneDX contains the resolved components and evidence hashes; the accompanying inventory and text provide complete original license bodies and source evidence. Repeated identical bodies in the text refer to their earlier SHA-256 section rather than dropping the grant. Keep inventory/SBOM/notices together with any package delivered externally.

## Corresponding source, modifications and relinking

Before any binary distribution, the owner must establish and retain the license-compliant source delivery method and satisfy each included component's terms. At minimum:

1. Preserve the exact application source commit, all tracked build scripts/configuration, toolchain pins, Pub/npm/Gradle locks and verification evidence, complete application license files, generated notices and this documentation. Preserve the exact vxcore/cmark/libgit2 submodule sources and every pinned fetched source archive, not just repository URLs that may later disappear.
2. Preserve all local modifications as real source or patches against those exact inputs, with clear modification provenance. The native host, Flutter shell and web editor source are part of this application. The VNote cmark fork and bundled third-party adaptations are not unmodified upstream packages; their actual source and attribution must accompany the source offer/delivery as required. Do not describe a pin alone as complete corresponding source.
3. Rebuild the editor through its pinned npm lock/build, resolve Pub through its lock, then rebuild the native `vnote_host` with the supplied CMake configuration and target SDK/NDK. Native dependencies are statically linked into that host; provide the source/build material and any required linkable objects needed to produce the combined work with modifications. Rebuild the Flutter application and packages through the explicit validation command. Where a recipient needs installation information or a permitted re-sign/relink route, provide it as the applicable licenses require; owner signing secrets are not source-code artifacts and must not be published.
4. Retain libgit2's exact GPLv2 text and linking exception, every bundled dependency's terms, copyright/NOTICE text, font OFL/Reserved Font Name restrictions and any source-distribution obligations. The linking exception is not blanket permission to discard libgit2 modification obligations. Review LGPL combined-work, reverse-engineering/relinking and installation requirements and any tension with the intended app-store/device distribution terms with qualified counsel.
5. Build source distributions from a reviewed tracked-source allowlist and explicit submodule/source archives, never by zipping the working directory. Exclude `.tools`, build caches, `.dart_tool`, `node_modules`, generated Owner configs/entitlements, local.properties, keystores/private keys/profiles, notebook data, user fixtures and smoke artifacts. Inspect the final source archive member list before handing it off. Keep the **public** dependency inventory, SBOM, notices and required corresponding source even though their build-local originals live under `.tools`.

A successful generator or package signature does not establish that the owner's source distribution, relinking arrangements, privacy statements, accessibility/device testing, store registration or legal review are complete.
