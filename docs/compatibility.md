# Compatibility baseline

## Provenance

| Source | Exact revision | Role |
| --- | --- | --- |
| [VNote](https://github.com/vnotex/vnote/commit/f8026adb4c43f78d90251148e24b6e72ca28f3d7) | `f8026adb4c43f78d90251148e24b6e72ca28f3d7` | Read-only desktop compatibility and LGPLv3 reference |
| [vxcore](https://github.com/vnotex/vxcore/commit/c3319ca9a7dfd5432cad1f7c35de6be099fc87bf) | `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf` | Original published compatibility baseline; current implementation pin is in toolchains.json |
| cmark | `6148f317138d873041043742e61d26c74d31c6a1` | Core's VNote renderer fork |
| libgit2 | `a418d9d4ab87bae16b87d8f37143a4687ae0e4b2` | Core dependency even without mobile Git UI |

Remote refs and recursive checkout were verified during initialization. Branch heads are not dependency pins. The current core separates explicit context roots and checked ordinary-file publication into mobile-selected sources. Default desktop builds retain legacy roots and in-place ordinary saves; the C-header compatibility fix and portable Threads::Threads linkage remain shared. Desktop test-only mobile API opt-in does not change persistence policy. No core or mobile changes are pushed without owner authorization; the core commit must be published before its mobile gitlink. Additional FetchContent pins and license disposition are recorded in [ADR 0001](adr/0001-native-packaging-and-storage.md).

## Notebook contract

Bundled notebook JSON/files remain authoritative. Notebook indexing in SQLite is derived, but per-device last-success history is retained across native owner retirement. A Flutter source mirror is volatile state, not notebook truth. Preserve stable notebook/node UUIDs, source bytes, tags, assets, unknown supported metadata and opaque/unsupported files. The app now creates/reopens a real managed bundled notebook and preserves its portable IDs across explicit writes and Android process restart. The navigator uses stable node IDs for open/rename/move/delete, preserving core-owned metadata rather than reserializing it in Dart. The versioned `packages/vxcore_bridge/test/fixtures/desktop_notebook.json` contains exact file bytes produced through the default Windows desktop-core C API, including Unicode, plain text, tags/custom metadata, a PNG asset and opaque bytes. That engine fixture is not a claim that the desktop Qt UI roundtrip has been executed.

Encrypted-note editing, raw notebook sync, desktop plugins and unsupported editor formats remain outside the first release. That never permits plaintext fallback, identity regeneration, silent mutation or dropping opaque data. Import/export uses managed copies and preflight; core owns notebook schema and migrations.

Exact-source editor offsets are UTF-16; native bodies are UTF-8. Opening without editing must not normalize line endings, Unicode or Markdown. The committed preview fixtures cover a selected CommonMark/GFM subset, KaTeX and Mermaid flowchart/sequence diagrams, independently of CodeMirror highlighting. Desktop heading slug/duplicate behavior is preserved, but unsupported footnotes and custom application schemes remain literal/inert. The privileged editor has no preview renderer.

Whole-notebook backup remains the identity-preserving interchange format. The
separate Files and assets ZIP preserves raw content paths/bytes but omits the entire
`vx_notebook` directory and configured recycle tree, including unknown metadata
there. It cannot be reopened/imported as a bundled notebook. Protected content
refuses this profile rather than being decrypted or partially skipped. Unsupported
ordinary files stay opaque, not converted. Metadata-dependent and external links
may not work; the content export does not normalize or rewrite source text.

Standalone file/ZIP/folder import creates one new child cohort with core-generated IDs, sealed once for retry. Original hierarchy, Unicode spelling and opaque bytes remain unchanged; local Markdown dependencies must be present and confined. A files/assets ZIP can use this path but does not restore its former notebook IDs or metadata. Publication limits include the wrapper ID and bounded parent/journal images, in addition to the source entry/byte caps.

Ordinary-note resource operations preserve the body and unrelated assets. Metadata-only recovery never decrypts a protected body; tracking changes membership, not bytes. Exact-name collision/ambiguous outcomes retain files rather than accepting a suffix. Image/link insertion first modifies received source, then follows the independent private-draft and autosave boundaries; its operation receipt is not a saved receipt. The current core prerequisite adds fail-closed cohort recovery and checked resource outcomes; malformed legacy journals are not disposable trash.

## WebDAV compatibility

Mobile uses only the existing bundled-notebook WebDAV backend. Git/Jianguoyun
routing stays unsupported/preserved, not automatically rewritten. Remote UUID,
capabilities, conditional requests, conflict versions and recovery journals remain
core-owned. Legacy desktop APIs retain their semantics; mobile prepared lifecycle
calls validate credentials before publication and report committed effects
separately from errors/cleanup. Last-success belongs to the saved snapshot, not to
newer received or privately durable editor text.

Only native receipt-bound Connect may carry a proved clean WebDAV baseline through
managed import. Ordinary ZIP/folder inputs cannot import cursors, even schema-valid
ones or forged in-tree receipts. A duplicate notebook never replaces an existing
root or credential scope. Partial downloads and ambiguous publication stay retained.

Prepared Windows-host clone admission retains ordinary desktop registration limits
for config/session/SQLite recovery paths and downloaded import-recovery paths.
Private assets/snapshots can exceed MAX_PATH; no Windows ceiling is imposed on
Android/iOS. This is not a new Windows long-root notebook contract. Platform TLS,
vault persistence and interoperability evidence must be reported separately from
linking or a host test fixture; see ADR 0005 and verification.

## Tool/platform selection

[toolchains.json](../toolchains.json) records exact initialization pins. Flutter 3.47.9 / Dart 3.13.7 and Node 24.22.2 / npm 11.19.1 were executed locally. Android native builds select API 36, minimum API 28 (Bionic Iconv availability), NDK 28.2.13676358, Gradle 9.3.1, AGP 9.1.0 and Kotlin 2.4.0 from the pinned Flutter template. iOS selects deployment 15.0 and Xcode 26.6 (17F113), SDK 26.5; the [macOS CI image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) lists that Xcode. This selection is not iOS build evidence or the completed full-native dependency intersection.

Android arm64/x86_64 now source-build pinned OpenSSL 3.5.9 and link the complete core into a native asset. The iOS branch selects bundled curl/OpenSSL rather than assuming iPhoneOS supplies libcurl, but has not been executed. Android platform-trust behavior was exercised with an application-scoped fixture CA and strict rejection after its removal; iOS trust/runtime remains unverified. Linking alone is not network evidence. Test arm64 devices and selected emulator/simulator ABIs separately, including Android 16 KB native-library packaging and release dead stripping. Both Android native ELF LOAD segments were checked for 16 KB alignment, and x86_64 ran on a 16 KB emulator. Arm64 physical-device and iOS execution remain required.

Editor wire version two is a clean bundled cutover; no version-one message shim
exists. Persisted phase-two resource exports remain supported data: exact v1
records mean asset exports, while new v2 records explicitly bind asset, immutable
preview-file or immutable draft origin. Missing/unknown origins never fall back
to the selected note's asset API. A verified ready copy can be re-saved without
reopening its original source.

The API-28 installation floor does not imply editor availability on every old
provider. Android source/preview requires WebView 152+ and actual per-document
Connection-Allowlist enforcement. Current public WK APIs cannot establish the
same all-protocol egress boundary independently of CSP; iOS 15–26 source delivery
remains visibly gated, not silently weakened. Physical-device and iOS evidence
must be recorded separately from desktop browser/native-host results.

## Structural-operation boundaries

The core move API can implicitly relocate relative-linked files and can report
success even when an asset move fails. The mobile host preflights those effects
with the pinned cmark parser, rejects collisions/escaping links/indexed linked-node
moves, and checks resource postconditions. A failure may still be a partial core
mutation; the browser refreshes to expose actual state. Delete can fall back from
recycling to permanent removal and is labelled accordingly. Unsafe external or
traversing resource layouts are refused, not rewritten to new portable metadata.

Catalog JSON names come from generated canonical constants (`exists`, not a
literal `nodeExists`; encryption state is nested under `metadata`). Unsupported
files stay visible but do not enter an editable session. Plain-text notes use a
source editor without the Markdown language extension.

## Release compatibility remains open

Required fixtures and interruptions are specified in plan section 7 and the ADRs: desktop/mobile/desktop identity-preserving round trips; 10,000 notes; 1 MiB source and long lines; attachment-heavy imports; IME/Unicode/CRLF; process-kill recovery; malicious preview/resources; WebDAV conflicts, partial apply and credentials; sharing deduplication; physical-device accessibility and input.

Do not label these passed without the actual platforms, commands, fixture results and limitations in [verification.md](verification.md). LGPLv3 is selected for the new app; signing identities, store identifiers and publication remain owner-controlled.
