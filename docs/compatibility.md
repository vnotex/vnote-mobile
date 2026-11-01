# Compatibility baseline

## Provenance

| Source | Exact revision | Role |
| --- | --- | --- |
| [VNote](https://github.com/vnotex/vnote/commit/f8026adb4c43f78d90251148e24b6e72ca28f3d7) | `f8026adb4c43f78d90251148e24b6e72ca28f3d7` | Read-only desktop compatibility and LGPLv3 reference |
| [vxcore](https://github.com/vnotex/vxcore/commit/c3319ca9a7dfd5432cad1f7c35de6be099fc87bf) | `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf` | Original published compatibility baseline; current implementation pin is in toolchains.json |
| cmark | `6148f317138d873041043742e61d26c74d31c6a1` | Core's VNote renderer fork |
| libgit2 | `a418d9d4ab87bae16b87d8f37143a4687ae0e4b2` | Core dependency even without mobile Git UI |

Remote refs and recursive checkout were verified during initialization. Branch heads are not dependency pins. The native slice adds explicit context roots, checked ordinary-file publication, C-header compatibility and mobile CMake fixes in a separate local core commit. No core or mobile changes are pushed without owner authorization; the core commit must be published before its mobile gitlink. Additional FetchContent pins and license disposition are recorded in [ADR 0001](adr/0001-native-packaging-and-storage.md).

## Notebook contract

Bundled notebook JSON/files remain authoritative. Core SQLite metadata is a derived cache; a Flutter source mirror is volatile state, not notebook truth. Preserve stable notebook/node UUIDs, source bytes, tags, assets, unknown supported metadata and opaque/unsupported files. The app now creates/reopens a real managed bundled notebook and preserves its portable IDs across explicit writes and Android process restart. A full desktop VNote UI ↔ mobile fixture round trip has not been executed.

Encrypted-note editing, raw notebook sync, desktop plugins and unsupported editor formats remain outside the first release. That never permits plaintext fallback, identity regeneration, silent mutation or dropping opaque data. Import/export uses managed copies and preflight; core owns notebook schema and migrations.

Exact-source editor offsets are UTF-16; native bodies are UTF-8. Opening without editing must not normalize line endings, Unicode or Markdown. CommonMark/GFM, KaTeX and Mermaid rendering are later fixture-gated subsets, not implied by CodeMirror syntax highlighting. The privileged editor has no preview renderer.

## Tool/platform selection

[toolchains.json](../toolchains.json) records exact initialization pins. Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1 were executed locally. Android native builds select API 36, minimum API 28 (Bionic Iconv availability), NDK 28.2.13676358, Gradle 9.3.1, AGP 9.1.0 and Kotlin 2.4.0 from the pinned Flutter template. iOS selects deployment 15.0 and Xcode 26.6 (17F113), SDK 26.5; the [macOS CI image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) lists that Xcode. This selection is not iOS build evidence or the completed full-native dependency intersection.

Android arm64/x86_64 now source-build pinned OpenSSL 3.5.9 and link the complete core into a native asset. The iOS branch selects bundled curl/OpenSSL rather than assuming iPhoneOS supplies libcurl, but has not been executed. TLS trust-store integration remains unverified; no network-ready claim follows from linking. Test arm64 devices and selected emulator/simulator ABIs separately, including Android 16 KB native-library packaging and release dead stripping. Both Android native ELF LOAD segments were checked for 16 KB alignment, and x86_64 ran on a 16 KB emulator. Arm64 physical-device and iOS execution remain required.

## Release compatibility remains open

Required fixtures and interruptions are specified in plan section 7 and the ADRs: desktop/mobile/desktop identity-preserving round trips; 10,000 notes; 1 MiB source and long lines; attachment-heavy imports; IME/Unicode/CRLF; process-kill recovery; malicious preview/resources; WebDAV conflicts, partial apply and credentials; sharing deduplication; physical-device accessibility and input.

Do not label these passed without the actual platforms, commands, fixture results and limitations in [verification.md](verification.md). LGPLv3 is selected for the new app; signing identities, store identifiers and publication remain owner-controlled.
