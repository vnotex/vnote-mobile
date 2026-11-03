# Mobile architecture

The [handoff plan](mobile-client-plan.md) is the product contract. This document distinguishes the managed-notebook navigator/editor boundary from later product phases. Runtime evidence belongs in [verification.md](verification.md).

## Managed notebook and editor boundary

`apps/vnote_mobile` is the Flutter app in the root Dart workspace. `lib/services/editor_session.dart` owns a generation-bound volatile source mirror; Riverpod supplies the constructor-injected workspace dependency; Flutter listens to its immutable `ValueNotifier` states. Only a matching, validated edit batch advances the mirror. A received acknowledgement does not mean disk persistence.

`packages/editor_web` independently builds CodeMirror source/highlighting/history into `apps/vnote_mobile/assets/editor`. The view owns editable text, selection and undo; the host owns generation, document identity and accepted revisions. A narrow JSON channel is the only application boundary. No path, credential, notebook handle, renderer or filesystem command is exposed to JavaScript.

The document identity binds the real notebook and node IDs. `notebook_session.dart` coordinates one immutable in-flight native save and one newest pending target; `editor_drafts.dart` persists accepted deltas on joined filesystem workers. Received, draft-durable and saved watermarks remain separate; only the native committed prefix advances durability, never an editor reply or a timer. The core-classified Markdown/plain-text language is fixed by the load envelope; plain text installs no Markdown parser. Theme changes reconfigure the existing view. Explicit discard is distinct from successful save. Loading and editing untrusted Markdown as source never executes its HTML.

Root `scripts/verify.mjs` is the supported asset/dependency/check/packaging entrypoint. The Node build emits deterministic bundled assets, dependency license notices, application licenses and a hash manifest. Outputs are ignored; the source and dependency locks are authoritative. Check mode fails on absent or changed output rather than silently repairing it. Native sources remain pinned through recursive gitlinks.

## Managed notebook navigator

`notebook_workspace.dart` owns one managed notebook workflow: either a catalog host
or a `NotebookSession`, never both. The catalog has no open editor buffer. Folder
browsing and create/rename/move/delete run through core APIs on its native owner.
Selected notes are opened by notebook/node UUID after catalog shutdown. Core SQLite identity lookup is only a lazy cache: the bridge anchors the root ID in core metadata and resolves cache misses through bounded authoritative core listings, without reading/rebuilding notebook schemas itself. Returning
from the editor completes quiesce plus Save/Keep draft/Discard/Cancel, drains the editor owner, then
reopens the catalog with the already observed notebook UUID. Missing/replaced
notebooks are errors, not opportunities to recreate identities.

The browser displays real indexed children, including missing and unsupported
content. Native filetype and protection checks admit only supported Markdown or
plain-text bodies to the editor. Structural actions refresh after every attempted
mutation; a failed refresh marks retained data stale and does not imply rollback.
`Delete` explicitly warns that core recycling can fall back to permanent deletion.
There is no mobile restore promise or second recycle implementation.

Listing JSON stays core-owned until event release. Dart decodes it using generated
`CoreJsonKeys` from the authoritative core header, including `nodeExists = "exists"`
and nested `metadata.encrypted`. Native admission reserves bounded result space
before dispatch and retains actual ownership through cancellation and shutdown.
Names, IDs, resolved paths and configured resource namespaces are checked before
mutation; external/traversing layouts are refused without rewriting metadata.
Markdown file moves additionally preflight the core's implicit linked-resource
side effects with the same pinned public cmark parser. Destinations cannot be
overwritten, linked indexed nodes cannot be orphaned, and resource postconditions
are checked after core success. This is not a new transaction/rollback guarantee.

The offline application includes the managed library, search/tags, notebook and
files/assets interchange, standalone cohorts, and ordinary-note resources.
Durable drafts/autosave and isolated preview are implemented; the stopped-app
share inbox, sync and unverified platform/release gates remain separate.

## Native ownership and storage

`packages/vxcore_bridge` owns the real context, notebook, buffer, bounded requests/events and FFI allocation releases. The Android/iOS extension `vxcore_context_create_with_paths`, declared in `vxcore/mobile/vxcore_mobile.h`, copies validated, nonoverlapping app/local roots before configuration loading. Default desktop builds neither expose this extension nor change legacy context defaults. Desktop-hosted bridge tests explicitly enable only the context extension, not mobile persistence. The platform adapter obtains persistent Application Support/internal-files locations. Notebook bodies and metadata are written only through core APIs.

The implemented host has one native owner OS thread for context/metadata/buffer lifetime and ordinary writes. Explicit-root context construction skips legacy core session loading before any manager can reopen notebooks or buffers; app-owned draft recovery and explicit admission determine all live owners. A process-wide core-job mutex additionally protects the core's unsynchronized global UUID generator across separate hosts; admission, cancellation, notification and event drain stay outside it. There are no network workers yet. The later sync design requires the additional upstream concurrency gates before network/owner overlap. Dart calls bounded enqueue/control functions, not synchronous disk/network APIs. Ordinary writes reload and compare the exact disk SHA-256 before `set_content_raw` plus `buffer_save` under owner exclusion; memory-only prepared saves are not a substitute.

CMake selects the checked POSIX writer from `src/mobile/` only for Android/iOS; desktop saves use the original in-place implementation from `src/platform/buffer_file_save_desktop.cpp`. The Windows DACL/recovery path from the initial native slice has been removed. Shared callsites and the native owner-thread protocol are unchanged.

No second authoritative note database, mobile notebook-schema rewrite, credential store in JavaScript, generic WebDAV uploader or Qt interface is introduced. The complete product still requires share-in, WebDAV interoperability and the documented platform/release evidence.

## Durable source and preview ownership

Private `drafts/` is persistent and separate from notebook truth; `previews/` is
disposable only after joined readers/renderers/export leases retire. Native draft
commands share the existing no-follow filesystem helpers and one journal/quota
mutex. Immutable candidates precede core writes, and committed receipts bind both
original source and encoded disk hashes. Startup reconciles exact actual state
before writers; differing disk/identity/policy becomes an inspectable conflict.
New WebView tokens are checkpointed before load and cannot inherit stale revisions.

`preview_session.dart` owns one active and one newest pending immutable capture.
The NOTE owner resolves confined resources/stable navigation IDs; FS workers own
sealed files. Android heavy rendering runs in the nonexported dedicated process;
the visible viewer installs only final sanitized output and manages bounded image
residency. Its controller has no editor JavaScript channel. The native watchdog
joins or retires renderer ownership before staging cleanup.

Native policy proof precedes source/markup delivery in every editor/renderer/viewer.
Android uses exact intercepted response headers, a WebView-only deny proxy when
INTERNET is granted, and public settings/client denial. Its Flutter-owned Chrome
client remains intact; public callbacks deny permission, chooser, console and dialog
capabilities before load. WK remains capability-gated rather than claiming that
content rules/CSP alone block every network protocol. See ADR 0004 for the explicit
iOS limitation and ADR 0003 for source/close/recovery invariants.

## Offline transfer boundaries

The library acquires one synchronous reservation across notebook import/export,
cohorts and resources before provider or worker awaits. `transfer_worker.dart`
joins filesystem isolates and provider cancellation before freeing borrowed native
tokens. Native filesystem commands share no-follow/hash/identity helpers and a
quota ledger which includes still-owned attempts moved into notebook journals.
Startup reconciles pending effects before admitting ordinary writers; uncertain
targets remain unavailable rather than being rediscovered as fresh data.

Cohort preparation bulk-indexes an isolated private workbook through core APIs,
closes its builder owner and seals complete content/metadata plus generated IDs.
The destination catalog consumes a separate attempt through core journaled attach.
Authoritative reachability and durable receipts decide commit; retries never
reconstruct IDs or trust stale paths. Dart does not serialize notebook metadata.

Resource operations reuse the editor's NOTE owner, or a fresh metadata-only
RESOURCES owner during recovery. Protected bodies and persisted restore work are
refused before buffer opening. Listing does not create directories; bounded export
copies bytes before provider IO. Desired operations, possible dispatch and proved
outcomes are distinct durable records. A raced suffix is retained as ambiguous,
not silently linked or copied again. Session Write/switch/close joins its resource
barrier, and library shutdown drains controllers before native owner retirement.

CodeMirror insertion first returns an exact current selection after flushing edits,
then accepts one revision/selection-bound transaction. Its received acknowledgement
follows the normal edit batch and cannot advance disk state. An already-published
asset survives stale cursor, transport and insertion failures for explicit reuse.

## Decisions and gates

| ADR | Selected boundary |
| --- | --- |
| [0001](adr/0001-native-packaging-and-storage.md) | Native dependency packaging, explicit persistent sandbox roots and platform-selected mobile API |
| [0002](adr/0002-native-execution.md) | Owner/worker matrix, ownership, bounded events, cancellation and shutdown |
| [0003](adr/0003-editor-protocol-and-durability.md) | Exact-source UTF-16 protocol, received/durable/saved distinctions, autosave and recovery |
| [0004](adr/0004-rendering-security.md) | Unprivileged preview, bundled parser/math/diagrams, resource and navigation policy |
| [0005](adr/0005-webdav-coordination.md) | Readiness facts, stage/network/apply reservations, credentials and conflicts |
| [0006](adr/0006-import-share-and-privacy.md) | Managed imports, journaled publication, share inbox, backup and privacy |

These ADRs select designs and acceptance cases. Their existence does not establish that the corresponding mobile implementation or device tests exist. The current slice implements version-two received/draft-durable/saved boundaries and source-preserving recovery. These contracts do not claim physical-device power-loss or iOS browser capability. Reopen drains and destroys the old native owner before starting a new editor revision epoch. Native teardown/join runs on a cleanup isolate, with the listener retained until join completes; UI disposal never joins a native thread.
