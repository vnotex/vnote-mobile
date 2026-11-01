# Compatibility baseline

## Provenance

| Source | Exact revision | Role |
| --- | --- | --- |
| [VNote](https://github.com/vnotex/vnote/commit/f8026adb4c43f78d90251148e24b6e72ca28f3d7) | `f8026adb4c43f78d90251148e24b6e72ca28f3d7` | Read-only desktop compatibility and LGPLv3 reference |
| [vxcore](https://github.com/vnotex/vxcore/commit/c3319ca9a7dfd5432cad1f7c35de6be099fc87bf) | `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf` | Publicly available, unchanged recursive mobile gitlink |
| cmark | `6148f317138d873041043742e61d26c74d31c6a1` | Core's VNote renderer fork |
| libgit2 | `a418d9d4ab87bae16b87d8f37143a4687ae0e4b2` | Core dependency even without mobile Git UI |

Remote refs and recursive checkout were verified during initialization. Branch heads are not dependency pins. No core changes were made or pushed. Additional FetchContent pins and license disposition are recorded in [ADR 0001](adr/0001-native-packaging-and-storage.md).

## Notebook contract

Bundled notebook JSON/files remain authoritative. Core SQLite metadata is a derived cache; a Flutter source mirror is volatile state, not notebook truth. Preserve stable notebook/node UUIDs, source bytes, tags, assets, unknown supported metadata and opaque/unsupported files. The current editor validation app opens no notebooks and therefore proves **no desktop/mobile data round trip**.

Encrypted-note editing, raw notebook sync, desktop plugins and unsupported editor formats remain outside the first release. That never permits plaintext fallback, identity regeneration, silent mutation or dropping opaque data. Import/export uses managed copies and preflight; core owns notebook schema and migrations.

Exact-source editor offsets are UTF-16; native bodies are UTF-8. Opening without editing must not normalize line endings, Unicode or Markdown. CommonMark/GFM, KaTeX and Mermaid rendering are later fixture-gated subsets, not implied by CodeMirror syntax highlighting. The privileged editor has no preview renderer.

## Tool/platform selection

[toolchains.json](../toolchains.json) records exact initialization pins. Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1 were executed locally. Android editor builds select API 36, minimum API 24, NDK 28.2.13676358, Gradle 9.3.1, AGP 9.1.0 and Kotlin 2.4.0 from the pinned Flutter template. iOS selects deployment 15.0 and Xcode 26.6 (17F113), SDK 26.5; the [macOS CI image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) lists that Xcode. This selection is not iOS build evidence or the completed full-native dependency intersection.

The current core's Apple SDK libcurl assumption and Android OpenSSL branch must be verified or minimally corrected upstream before native packaging. Test arm64 devices and selected emulator/simulator ABIs separately, including Android 16 KB native-library packaging and release dead stripping. Windows compile success cannot establish either mobile ABI.

## Release compatibility remains open

Required fixtures and interruptions are specified in plan section 7 and the ADRs: desktop/mobile/desktop identity-preserving round trips; 10,000 notes; 1 MiB source and long lines; attachment-heavy imports; IME/Unicode/CRLF; process-kill recovery; malicious preview/resources; WebDAV conflicts, partial apply and credentials; sharing deduplication; physical-device accessibility and input.

Do not label these passed without the actual platforms, commands, fixture results and limitations in [verification.md](verification.md). LGPLv3 is selected for the new app; signing identities, store identifiers and publication remain owner-controlled.
