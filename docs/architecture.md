# Mobile architecture

The [handoff plan](mobile-client-plan.md) is the product contract. This document distinguishes the initial editor boundary from designs not yet implemented. Runtime evidence belongs in [verification.md](verification.md).

## Initial editor boundary

`apps/vnote_mobile` is the Flutter app in the root Dart workspace. `lib/services/editor_session.dart` owns a generation-bound volatile source mirror; Riverpod supplies the constructor-injected session dependency; Flutter listens to its immutable `ValueNotifier` states. Only a matching, validated edit batch advances the mirror. A received acknowledgement does not mean disk persistence.

`packages/editor_web` independently builds CodeMirror source/highlighting/history into `apps/vnote_mobile/assets/editor`. The view owns editable text, selection and undo; the host owns generation, document identity and accepted revisions. A narrow JSON channel is the only application boundary. No path, credential, notebook handle, renderer or filesystem command is exposed to JavaScript.

The validation document has a transient diagnostic identity, not a fabricated core UUID. Source is memory-only and must not display saved/synced state. Theme changes reconfigure the existing view. Explicit discard is distinct from successful save. Loading and editing untrusted Markdown as source never executes its HTML.

Root `scripts/verify.mjs` is the supported asset/dependency/check/packaging entrypoint. The Node build emits deterministic bundled assets, dependency license notices, application licenses and a hash manifest. Outputs are ignored; the source and dependency locks are authoritative. Check mode fails on absent or changed output rather than silently repairing it. Native sources remain pinned through recursive gitlinks.

## Native boundary is not connected

There is intentionally no empty `vxcore_bridge` package or fake persistence service. The pinned core has no supported app/local-data path injection. Calling it with invented `config_json` keys would write desktop-oriented paths. The real host must be implemented only after the additive upstream prerequisite and mobile dependency builds are verified.

The selected design uses one native owner OS thread for context/metadata/buffer lifetime and ordinary saves, per-buffer FIFO, a per-notebook IO gate, and separately admitted network workers. Dart calls bounded enqueue/control functions, not synchronous disk/network APIs. Ordinary files use `set_content_raw` plus `buffer_save` under one reservation; memory-only prepared saves are not a substitute.

No second authoritative note database, mobile notebook-schema rewrite, credential store in JavaScript, generic WebDAV uploader or Qt interface is introduced. The complete product still requires VNote-compatible notebook operations, recovery, preview and WebDAV interoperability.

## Decisions and gates

| ADR | Selected boundary |
| --- | --- |
| [0001](adr/0001-native-packaging-and-storage.md) | Native dependency packaging, explicit persistent sandbox roots and desktop-compatible additive API |
| [0002](adr/0002-native-execution.md) | Owner/worker matrix, ownership, bounded events, cancellation and shutdown |
| [0003](adr/0003-editor-protocol-and-durability.md) | Exact-source UTF-16 protocol, received/durable/saved distinctions, autosave and recovery |
| [0004](adr/0004-rendering-security.md) | Unprivileged preview, bundled parser/math/diagrams, resource and navigation policy |
| [0005](adr/0005-webdav-coordination.md) | Readiness facts, stage/network/apply reservations, credentials and conflicts |
| [0006](adr/0006-import-share-and-privacy.md) | Managed imports, journaled publication, share inbox, backup and privacy |

These ADRs select designs and acceptance cases. Their existence does not establish that the corresponding mobile implementation or device tests exist. The editor-only slice exercises received acknowledgements; full durable draft/save behavior remains gated.
