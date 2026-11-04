# Mobile packaging and owner release gates

These commands package locally. They never install over an existing application, clear its data, upload an artifact, submit to a store, or publish a release. A successful unsigned build is **not** an owner release. App/store registration, signing ownership, App Group entitlement authorization, physical-device behavior and legal/store review are external gates; configuration does not establish that they passed.

## Explicit modes

From the repository root, using the toolchain versions in `toolchains.json`:

```sh
node scripts/release.mjs android unsigned-validation
node scripts/release.mjs ios unsigned-validation
node scripts/release.mjs android owner-release
node scripts/release.mjs ios owner-release
```

`--gate-only` checks the selected mode and owner prerequisites without resolving dependencies or creating package artifacts. With no owner inputs, `owner-release --gate-only` fails clearly before generating anything. `verify.mjs android-package` and `verify.mjs ios-package` are aliases for **unsigned validation only**. `verify.mjs android` remains the development debug build. `verify.mjs ios` validates an unsigned device app and archive, then builds a debug simulator app.

Prerequisites include the pinned Flutter/Dart, Node/npm, CMake, Ninja, Java, Android SDK/NDK, Python, Git and resolved submodules. Set `ANDROID_HOME` (or `ANDROID_SDK_ROOT`); Android build-tools must include `aapt2`, `zipalign` and `apksigner`; SDK command-line tools must provide `apkanalyzer` for Flutter’s final AAB check. The exercised command-line package is `cmdline-tools;19.0` (build `13114758`), also selected in CI. Missing analyzer tooling fails preflight before builds. On iOS, macOS and the exact Xcode version/build in `toolchains.json` are mandatory. iOS packaging also needs the Android toolchain: the shared in-app notices include the actual locked Android runtime graph, not a guessed transitive dependency list.

Resolve and review locks/verification evidence using [dependency-notices.md](dependency-notices.md) before invoking the package command. Normal packaging uses strict verification and never rewrites locks or accepts new artifact hashes. It runs the existing web asset generator, `flutter pub get --enforce-lockfile`, a non-installing debug Android bootstrap to configure native notices, and actual release Maven resolution. iOS also performs an unsigned device bootstrap to configure its native notices. The complete notices are generated before final packaging. These bootstrap outputs are not certified releases.

Only after all applicable checks succeed does the command move its work directory into:

- `.tools/release/android/unsigned-validation/` or `owner-release/`: APK, AAB, dependency inventory, CycloneDX SBOM, notices and `package-result.json`.
- `.tools/release/ios/unsigned-validation/`: unsigned `.app`, unsigned `.xcarchive`, inventory, SBOM, notices and result.
- `.tools/release/ios/owner-release/`: signed `.app`, signed `.xcarchive`, locally exported IPA, inventory, SBOM, notices and result.

Existing certified output is never silently overwritten. Preserve it elsewhere or remove that specific output explicitly before a replacement run. A failed operation may retain `.tools/release/work-*` diagnostics/build material, but never emits a successful result or promotes it into a certified mode directory.

Each `artifacts[].name` in `package-result.json` resolves relative to that certified
directory. Android validates the final copied `<mode>.apk` and `<mode>.aab`, so
the recorded names, lengths and hashes describe those exact files.

## Android owner inputs

Supply these through the protected local environment or the protected CI environment, not checked-in properties, command-line password arguments or source assets:

| Variable | Required value |
| --- | --- |
| `VNOTE_ANDROID_APPLICATION_ID` | Registered non-development application ID |
| `VNOTE_ANDROID_KEYSTORE` | Existing protected keystore file |
| `VNOTE_ANDROID_KEY_ALIAS` | Distribution key alias, never `androiddebugkey` |
| `VNOTE_ANDROID_STORE_PASSWORD` | Keystore password |
| `VNOTE_ANDROID_KEY_PASSWORD` | Private-key password |
| `VNOTE_ANDROID_CERT_SHA256` | Independently reviewed signing-certificate SHA-256 fingerprint |

The script opens the certificate using `keytool` with password-by-environment, checks the pin and expiry, and rejects Android Debug certificates and development IDs. Actual Gradle signing must also succeed; merely supplying filenames cannot pass packaging. Release Gradle tasks require `VNOTE_PACKAGE_MODE=owner-release` or the explicit `unsigned-validation` value. Release has **no debug-key fallback**. Only the release variant changes application ID/signing; debug/profile keep the existing development identity and signing behavior.

APK validation checks the actual package ID, audited notice asset, uncompressed 16 KiB ZIP alignment, every packaged native ELF `PT_LOAD` alignment, the complete arm64/x86_64 native runtime, and the owner certificate (or absence of signing for unsigned mode). AAB validation checks its protobuf manifest identity, required module structures, actual native ELFs and `BundleConfig` split alignment, notices, and JAR signature/certificate. The configuration excludes unsupported 32-bit native payloads from release only. These checks do not replace a real 16 KiB device installation/launch test or store validation.

## iOS owner inputs and entitlement ownership

| Variable | Required value |
| --- | --- |
| `VNOTE_IOS_BUNDLE_ID` | Registered main app bundle ID |
| `VNOTE_IOS_EXTENSION_ID` | Registered extension ID under the app ID prefix |
| `VNOTE_IOS_APP_GROUP` | Actual authorized `group.…` identifier; never synthesized |
| `VNOTE_IOS_TEAM_ID` | Actual ten-character Apple team ID |
| `VNOTE_IOS_SIGNING_IDENTITY_SHA1` | Installed distribution certificate identity fingerprint, with its private key available in the keychain |
| `VNOTE_IOS_APP_PROFILE` | Protected main app distribution provisioning profile file |
| `VNOTE_IOS_EXTENSION_PROFILE` | Protected extension distribution provisioning profile file |
| `VNOTE_IOS_EXPORT_METHOD` | Explicit `app-store-connect`, `release-testing`, or `enterprise` |

Profile gates decode the real signed profiles and require exact app/team identities, the requested App Group, the selected installed certificate, future expiry, distribution rather than `get-task-allow`, and matching export type. Wildcard IDs are not accepted. The owner must register the App Group and enable it for both IDs; scripts cannot authorize entitlements.

Only the owner Release command generates ignored, private files:

- `apps/vnote_mobile/ios/Flutter/Owner.xcconfig`
- `apps/vnote_mobile/ios/Flutter/Owner-App.entitlements`
- `apps/vnote_mobile/ios/Flutter/Owner-Extension.entitlements`

The script refuses to overwrite pre-existing owner files and removes only files it generated. It supplies `-xcconfig` explicitly to Release build/archive. It maps the environment to `VNOTE_APP_BUNDLE_ID`, `VNOTE_EXTENSION_BUNDLE_ID`, `VNOTE_APP_GROUP`, `DEVELOPMENT_TEAM`, `VNOTE_APP_ENTITLEMENTS`, `VNOTE_EXTENSION_ENTITLEMENTS`, `VNOTE_APP_PROFILE`, `VNOTE_EXTENSION_PROFILE`, manual signing and the certificate identity. The two profiles are installed only when absent, and temporary installations are removed afterward. Existing different profiles with the same UUID are never overwritten.

Do **not** include Owner.xcconfig unconditionally from `Release.xcconfig`: Profile uses that same file. Debug/Profile retain development IDs and no group entitlement. Unsigned validation uses the development IDs, no App Group, and `CODE_SIGNING_ALLOWED=NO`; share-in is visibly unavailable without a configured group, not redirected into fallback storage. The checked-in entitlement templates are not authorization and are not used in unconfigured builds.

Owner app/archive validation checks identities, signatures and actual signed entitlements. Export uses explicit manual provisioning options and `destination=export`; it never requests provisioning updates or uploads. An App Store export method creates a local package only. Xcode/Swift compilation, provisioning, device sharing and installation remain unverified until exercised on macOS and authorized hardware.

## CI and secret handling

`verify.yml` names unsigned package checks explicitly. `release.yml` is manual, separates unsigned validation from owner-signed jobs, and has no upload/publication step. Owner jobs use the `mobile-release` protected environment and dedicated self-hosted runners (`mobile-release-android` / `mobile-release-ios`). Repository owners must configure required reviewers, trusted refs and runner access before enabling them; a workflow YAML file cannot create those protections. Install the pinned tools, keystore/profile files and private-key keychain on those runners via the owner's secret provisioning process. SDK setup uses the runner's already accepted licenses; it does not automatically accept unrelated SDK license agreements. Environment secrets contain only the protected paths/passwords/fingerprints listed above. Missing values fail instead of skipping signing.

Packaging does not echo protected arguments or tool output from owner signing operations. Do not enable Gradle debug/stacktrace logging, shell tracing, or print environment variables in a signing job. Never check in certificates/private keys, keystores, provisioning profiles, generated Owner files, notebook fixtures or private build logs. Native dependency and Maven handoffs contain local build paths and stay under ignored `.tools`; distributed inventory omits those paths.
