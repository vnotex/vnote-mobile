# Mobile architecture

The [handoff plan](mobile-client-plan.md) is the product contract. This document distinguishes the managed notebook boundary from designs not yet implemented. Runtime evidence belongs in [verification.md](verification.md).

## Managed notebook and editor boundary

`apps/vnote_mobile` is the Flutter app in the root Dart workspace. `lib/services/editor_session.dart` owns a generation-bound volatile source mirror; Riverpod supplies the constructor-injected session dependency; Flutter listens to its immutable `ValueNotifier` states. Only a matching, validated edit batch advances the mirror. A received acknowledgement does not mean disk persistence.

`packages/editor_web` independently builds CodeMirror source/highlighting/history into `apps/vnote_mobile/assets/editor`. The view owns editable text, selection and undo; the host owns generation, document identity and accepted revisions. A narrow JSON channel is the only application boundary. No path, credential, notebook handle, renderer or filesystem command is exposed to JavaScript.

The document identity binds the real notebook and node IDs. `notebook_session.dart` coordinates native writes and a separate on-disk revision watermark; a received editor acknowledgement remains volatile, not a durable draft or sync result. Theme changes reconfigure the existing view. Explicit discard is distinct from successful save. Loading and editing untrusted Markdown as source never executes its HTML.

Root `scripts/verify.mjs` is the supported asset/dependency/check/packaging entrypoint. The Node build emits deterministic bundled assets, dependency license notices, application licenses and a hash manifest. Outputs are ignored; the source and dependency locks are authoritative. Check mode fails on absent or changed output rather than silently repairing it. Native sources remain pinned through recursive gitlinks.

## Native ownership and storage

`packages/vxcore_bridge` owns the real context, notebook, buffer, bounded requests/events and FFI allocation releases. The additive `vxcore_context_create_with_paths` copies validated, nonoverlapping app/local roots before configuration loading; legacy context creation keeps its desktop defaults. The platform adapter obtains persistent Application Support/internal-files locations. Notebook bodies and metadata are written only through core APIs.

The implemented host has one native owner OS thread for context/metadata/buffer lifetime and ordinary writes. A process-wide core-job mutex additionally protects the core's unsynchronized global UUID generator across separate hosts; admission, cancellation, notification and event drain stay outside it. There are no network workers yet. The later sync design requires the additional upstream concurrency gates before network/owner overlap. Dart calls bounded enqueue/control functions, not synchronous disk/network APIs. Ordinary writes reload and compare the exact disk SHA-256 before `set_content_raw` plus `buffer_save` under owner exclusion; memory-only prepared saves are not a substitute.

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

These ADRs select designs and acceptance cases. Their existence does not establish that the corresponding mobile implementation or device tests exist. The current slice exercises repeated correlated snapshots and actual Write/On disk completion, not `draftDurable` or the full saved-receipt protocol. Reopen drains and destroys the old native owner before starting a new editor revision epoch. Native teardown/join runs on a cleanup isolate, with the listener retained until join completes; UI disposal never joins a native thread.
