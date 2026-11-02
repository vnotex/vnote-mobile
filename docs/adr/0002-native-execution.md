# ADR 0002: Native ownership, execution and cancellation

Status: the serialized owner host, managed multi-notebook library, notebook search/tags and read-only export snapshots are implemented. Network-worker coordination remains a design, not a verified concurrency claim; iOS and physical-device gates remain open.

## Evidence and decisions

Baseline: vxcore `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`. Authoritative sources are [public ABI](../../third_party/vxcore/include/vxcore/vxcore.h), [types](../../third_party/vxcore/include/vxcore/vxcore_types.h), [log callback contract](../../third_party/vxcore/include/vxcore/vxcore_log.h), [search dispatch](../../third_party/vxcore/src/api/vxcore_search_api.cpp), [sync concurrency seam](../../third_party/vxcore/src/sync/AGENTS.md#threading--callback-contract), and the pinned desktop [service contract](https://github.com/vnotex/vnote/blob/f8026adb4c43f78d90251148e24b6e72ca28f3d7/src/core/services/AGENTS.md). Preserve public JSON keys from [notebook_json_keys.h](../../third_party/vxcore/include/vxcore/notebook_json_keys.h); sync keys additionally live in internal `src/sync/sync_json_keys.h`, so generated bridge mappings must track that source rather than invent a competing schema.

Use one dedicated native owner OS thread per host for context lifetime, metadata, buffers and ordinary saves. A Dart isolate is not an OS-thread affinity guarantee. Dart only submits bounded requests and consumes copied events. The later network design uses two bounded workers globally, at most one lifecycle/sync operation per notebook; they never refresh metadata. No network workers are enabled in the current slice. Phase 1 needs no workers for ordinary saves: its native owner is already off the UI thread. Use a separate lightweight native control path for cancellation, reservation replies and result draining; it does not execute disk/network APIs and must not wait for the owner or notebook gate. Queue capacity and lifecycle admission, not unbounded threads, absorb demand.

### Operation/thread/lifetime matrix

`O` = native owner; `W` = admitted network worker; `G` = per-notebook IO gate; `F` = FIFO for `(notebook, buffer)`; lifecycle lease pins context/notebook until operation retirement. Every call also validates generation. Input strings/bytes remain owned until return; all allocated string outputs are freed with `vxcore_string_free`, including documented error outputs.

| Operations / real API | Executor and exclusion | Lifetime / cancellation |
| --- | --- | --- |
| Context create, configuration get/update, locale; `vxcore_context_create`, platform-selected `vxcore_context_create_with_paths` | O; initialization before admitting other work; explicit roots prerequisite in ADR 0001 | Host owns context; queued cancellation only, no destroy while calls run |
| `vxcore_notebook_create`, `open`, `open_ex`, `list`, `get_config` | O; root/lifecycle admission; G for create/open | Copy/free IDs and JSON; mutation completes once begun; reject unsupported/read-only writes |
| `vxcore_folder_create`, `vxcore_file_create`, `vxcore_folder_list_children`, `vxcore_node_get_path_by_id`, `vxcore_node_get_config`, rename/move/delete | Catalog O + G; no live editor owner for the same notebook | Resolve stable IDs at dispatch; cancel before mutation, retain actual result; refresh after every attempt without claiming rollback |
| `vxcore_notebook_collect_node_ids`, `vxcore_folder_attach_imported`, `vxcore_notebook_recover_imports` | O + G and notebook lifecycle lease; reconcile core import journals and application importing ledger before other mutations/sync | Copy/free returned IDs/JSON; preserve final staged identities for retries. Cancel before attach dispatch, never abandon journaled commit/recovery after mutation. Core attach rechecks collisions and publishes one child-folder cohort; share extensions write only the durable inbox, never the live notebook (ADR 0006) |
| `vxcore_buffer_open`, `open_by_node_id`, `get`, `get_state`, `get_revision`, `get_content_raw` | O; F and G for open/disk interaction | Raw content pointer is borrowed until modification/close: copy immediately, never send pointer to Dart |
| `vxcore_buffer_set_content_raw` then `vxcore_buffer_save` | O + F + G as one indivisible scheduled job | Captured editor generation/revision/bytes retained; cancellation only before mutation, then finish save attempt and publish actual result |
| `vxcore_buffer_reload`, `check_external_changes` | O + F + G; suspend under apply reservation and skip pending/running saves | Never overwrite dirty editor; compare disk/editor bases and report conflict |
| `vxcore_buffer_close`, `vxcore_notebook_close` | O after queue/lease drain, F/G as applicable | Retire session generation before close; unresolved dirty state prevents destructive close |
| `vxcore_search_files`, `search_by_tags` | O, stable notebook/config lifetime; no concurrent lifecycle/config mutations | Allocated result JSON; queued cancellation, discard stale completion after synchronous return |
| `vxcore_search_content_streaming` (or accumulating `search_content_ex`) | Initially O, sole caller-drainer; notebook lease excludes mutation during scan | Streaming callback borrows JSON; copy bounded batches. No invented search handle API; see cancellation path below |
| `vxcore_sync_enable`, `disable`, `set_credentials`, `clone_cancellable`, conflict resolution | W with exclusive lifecycle lease; local mutation G where applicable; no conflicting owner calls during registration/reconfiguration | Secure temporary credentials, tokens and outputs retained until return. Clone has core-managed registration effects; reconcile final metadata on O before publication. No cancellation by freeing resources |
| `vxcore_sync_stage_only` / `network_phase` | Stage W + G; network W without G; one sync item per notebook | Context/notebook pinned; token host-owned. Split phases permit local editing during network only after concurrency gate below is resolved |
| `vxcore_sync_set_apply_in_progress`, `apply_phase`, `refresh_notebook` | Set flag O after save drain; apply W + G; refresh O after G release, reservation still held | Copy/free changed paths even on partial error; reservation lives through clean-buffer refresh, then retires |
| `vxcore_sync_get_capabilities`, `is_registered`, `is_ready`, last-sync get/set | O; timestamp writes after complete successful refresh | Scalars. `is_ready` checks routing only, not credentials/support/connectivity. Do not substitute blocking `get_status` for runtime presence |
| `vxcore_sync_get_status`, `get_conflicts`, `resolve_conflict` | W serialized with backend operations; resolution under mutation exclusion, followed by normal phased sync | Allocated JSON and per-file outcomes retained; no polling op-mutex-heavy status during network |
| `vxcore_sync_create_cancellation`, `cancel`, `free_cancellation` | Control may cancel from any thread; free only after call/handshakes drain | Documented lock-free cancellation; cannot use freed token for a successor |
| `vxcore_prepare_shutdown`, `vxcore_context_destroy` | O after all leases/workers/callbacks drain | Prepare snapshots state; it is not a worker join API |

Memory-only `vxcore_buffer_prepare_save` / `execute_save` / `complete_save` are **not used** for ordinary notes. If a later memory provider uses them, prepare/complete are O; execute may run on a worker with retained provider/bytes even after context close; completion cannot target a closed/replaced buffer; free each handle only after execute/complete, including failures.

### Ordinary saves

Coalesce only pending snapshots to the newest acknowledged editor revision; never replace a running save or exact structural operation. Retain per-buffer FIFO plus notebook gate for saves, reloads, external checks and attachment/structure writers. Before `set_content_raw`, validate current disk base against the editor's loaded/saved base; differing external content is a conflict, not a silent overwrite. After mutation cancellation cannot abandon the save, because core memory now differs from durable content. An old successful completion only advances its captured saved revision, never marks newer editor text clean. Failed writes retain dirty text and recoverable draft intent. Do not send per-keystroke snapshots to core.

The ordinary file provider does not establish an atomic rename/fsync durability contract; follow ADR 0003's durable draft/write-intent and upstream atomic-save prerequisite. Successful `vxcore_buffer_save` is a core-write acknowledgement, not fabricated power-loss evidence. Shutdown must finish an in-progress mutation/save even if the UI session has retired.

## Search: exact configuration and correctness floor

Before any search, on O use `vxcore_context_update_config` with `{"search":{"backends":["simple"]}}` and check success. The persisted path is `<app-data-root>/vxcore.json`, JSON path `search.backends`; [SearchConfig parsing](../../third_party/vxcore/src/core/vxcore_config.cpp) and `CreateSearchManager` select from this array. It is not a search query flag or context-create path option. Do not invoke availability probes for `rg`, subprocesses, or fallback shell commands.

The mobile host enumerates authoritative core directory listings with bounded inspected-node and pending-path counts, then submits one already-confined relative file in each explicit `input_files.files` array. It never submits an empty list (which would trigger whole-notebook fallback) or recursive folder input. The simple backend runs each singleton inline on the owner, with no external drainers. Queries use literal text, optional case sensitivity/tag scope and the core's default-off `firstMatchPerFile` option; the first occurrence is selected before a second line copy can be allocated. Result paths are display-only; opening re-resolves the stable notebook/node IDs.

The pinned core API accepts `volatile int *cancel_flag`; volatile is not portable cross-thread synchronization. Mobile cancellation instead tracks the active search request ID under the host mutex and an atomic stop bit checked between nodes/files. No other thread writes a core volatile flag. Shutdown requests the same search cancellation and drains its terminal before CLOSED. A bounded current core call can delay termination. Active tag mutations and writes always return their real outcome, never a fabricated cancellation.

## Host ABI and bounded transport

The host ABI is separate from `vxcore_*` exports. The current `vxm_*` boundary implements explicit catalog/note creation, note read/write, catalog list/mutate/query/tag/export, cancel/drain/free/close/destroy and a borrowed read-only notices export. Later sync handshakes extend these host protocol choices: versioned submit, cancel, reservation-reply, drain-events, release-event and asynchronous shutdown operations. Use fixed-width request ID and context/notebook/session generation; payloads carry operation, captured editor revision, byte length and explicit ownership. Terminal envelope carries actual core code, redacted explanation and outcome (success/error/cancelled/stale), plus partial-application facts. Never retrieve shared last-error text to label a different operation.

Current admission limits: 64 admitted operations and 32 MiB total queued input per host, 4 MiB editor source, 8 MiB catalog/query JSON, 64 retained terminals plus one separately reserved close terminal, and 16 MiB aggregate result storage including bounded dynamic metadata. Query/tag JSON input is limited to 16 KiB. Successful query events retain the full allocated 8 MiB reservation until release; errors/cancellations free the body before releasing its charge. Tag mutation output reserves metadata only. Oversized input is rejected before mutation.

Search reports at most 10,000 distinct matching notes within 8 MiB, with an explicit incomplete/limit flag and excluded-candidate count. A first-line snippet is at most 512 UTF-8 bytes; line labels are informational, not cursor offsets. The host checks confinement, links, existence, supported editor type, encryption, UTF-8/NUL and 4 MiB file size before dispatch. Invalid structural metadata/IO fails rather than claiming a complete empty search. The core first-match mode removes occurrence-dependent quadratic copying, but preflight is not a filesystem snapshot: an outside writer can race it, and the core retains its own 50 MiB read ceiling. Core transient source/JSON/traversal memory is separate from transport reservations; these limits are not an arbitrary-input total-memory guarantee.

Tag queries return every definition/current assignment or fail; partial assignment arrays are never editable. The core replacement rule preserves already-assigned undefined names but rejects new undefined ones. Tag creation/replacement and refresh are separate operations: a failed refresh does not erase the successful mutation outcome or imply rollback. Search and tag snapshots are invalidated across mutations, refresh, query edits and owner transitions; stale object callbacks cannot open another note or overwrite assignments.

Core log callbacks execute under the logger mutex; events/search callbacks can arrive on the calling worker. Copy bounded borrowed data before return, redact secrets, and enqueue without calling Dart or synchronously re-entering core. Never wait for UI while holding a core mutex/G. If a required handshake cannot be delivered, fail before apply; progress loss is not permission to lose a terminal outcome. Result release is explicit and independent of context destruction.


The current implementation serializes core jobs across host instances with a process-wide mutex because the core UUID generator has unsynchronized shared RNG state. Contexts and storage remain independently owned. Admission/cancellation/event draining and notifications do not take this core-job gate. Remove or narrow that gate only after upstream global state has a proven concurrency contract.

Dart retains NativeCallable.listener while the owner runs. Close retires admission, drains terminal events, nulls the usable event handle, performs native destroy/join on a cleanup isolate, then closes the callable. Reopen creates a fresh native host as well as a fresh editor generation: the native write-revision watermark cannot be reused after an editor resets to revision zero.

### Catalog and editor ownership

The library owns either one selected workspace or one short-lived discovery/create
catalog. It closes/joins each discovery host before the next, because contexts
share app/local session namespaces even when their notebook roots differ. It
lists immediate directory candidates under the existing `notebooks/` parent,
including `Personal` unchanged; no second notebook registry or saved active
selection is required. Names/UUIDs come from core, not a Dart metadata parser.
Canonical parent checks, no-follow candidate handling and native reparse guards
precede metadata access. More than 1,000 candidates fails the complete listing;
malformed/unsafe entries and duplicate observed UUIDs remain visibly unavailable.

Catalog mode owns a context/notebook but no buffer. `openCatalog` requires an
existing root; `createCatalog` sets the explicit native creation flag and requires
an absent root, checked before core create (which otherwise can reopen an existing
notebook or create into an existing directory). Creation never falls back from an
open failure. New roots are opaque `notebooks/nb-<128-bit hex>/` siblings, not display
names. This is app-owned storage admission, not an atomic interprocess reservation
against an outside writer. Failed creation does not authorize deletion, automatic
retry or repair of a partially created root.

The workspace receives explicit paths and a known notebook UUID from the library;
every catalog open, including its first and failed-note-open recovery, is pinned.
Note mode additionally requires a node ID and resolves its current path through
core. Neither mode recreates missing content. Catalog mutations are rejected in
note mode; note reads/writes are rejected in catalog mode. The workspace drains
one owner before opening the other. Returning to the library requires the exact
current workspace token, no editor session and no active operation, then awaits
shutdown/join. The existing editor Write/Discard/Cancel barrier is never bypassed.
Library rows/dialogs and browser/editor widgets retain identity-bound lifetimes.

Notebook rename is a separate root-only catalog operation. Fetch the complete
current notebook configuration, change only `name`, then submit through
`vxcore_notebook_update_config`: that API replaces known fields, it does not merge
an arbitrary partial update. Preserve UUIDs, custom metadata, tags, layout and
other settings; never rename the storage directory or use node basename rules.
Creation and rename share bounded nonblank/control-free UTF-8 display-name checks.
Refresh follows attempted mutation, including partial-error cases; a failed refresh
cannot undo or hide an applied change.

`vxcore_node_get_path_by_id` is a cache lookup, not an absence proof. The root
folder UUID is anchored through core metadata. Cache misses or contradictory cache hits use core folder
listings, bounded to 100,000 inspected nodes and 8 MiB of queued path text;
exhaustion is explicit, never a false NOT_FOUND. Missing indexed nodes may be
resolved for deletion through their parent listing, but never installed as an
editable note or used as a creation destination. Unrelated legacy basenames do
not abort another node's search; mutation targets still obey portable-name policy.
Unsafe branches are not traversed or treated as proof that an ID is absent.

Catalog admission reserves an 8 MiB listing allowance plus bounded metadata under
the existing 16 MiB aggregate output budget; it does not allocate an unused source
buffer. The returned core JSON allocation has a separate owner and is freed only
with `vxcore_string_free`, including errors. Null-plus-success and oversized data
are rejected. On acceptance, reserved credit shrinks under the capacity mutex to
the retained payload/metadata charge; taken events can outlive host destruction.
Dart validates the generated-key schema and the 10,000-direct-child presentation
limit explicitly, never truncates a listing or substitutes an empty folder.

Structural commands use a closed operation enum and bounded IDs/names, not arbitrary
paths from widgets or JavaScript. Once dispatched they finish with their real core
outcome. Refresh is a distinct step after success or failure: the core may already
have changed metadata, so a failed refresh is not proof of rollback. Core delete
may fall back to permanent deletion; the confirmation must disclose that fact.

Markdown file moves also preflight the pinned core's implicit relative-resource
moves on O + G, using the existing public cmark dependency and bounded public
file-size/peek APIs. Incomplete C-string peeks, malformed/oversized source, unsafe
paths, overwrites and implicitly moved indexed nodes are refused before dispatch.
UUID assets and captured resource destinations are checked after core success;
nonfatal core resource failures become explicit partial-outcome errors, never host
filesystem repairs. Ordinary text suffixes do not receive a Markdown move parser.

### Read-only export capture

`CoreNotebook.openExportCatalog` is the only snapshot-capable factory. It sets
`export_only`, requires the observed notebook UUID, forbids creation and rejects
mutations. Ordinary catalog opening/recovery is unchanged. Before context creation,
export-only initialization checks bounded persisted session state for notebook,
buffer and workspace auto-restore records; otherwise context construction could
recover another notebook before the explicit selected open. It refuses restore,
source-changing recovery residue, malformed/unsafe required metadata and tag
migration cases. The user must complete normal open/recovery first. The public
sync reconfiguration guard runs after the proven-clean core open.

`vxm_host_catalog_export` takes an explicit notebook or files/assets format,
rejecting invalid values before request ID/credit consumption. Its bounded summary
includes that format; Dart correlates it with the requested snapshot and the
persistent artifact. It inventories and copies the selected portable tree on O under
the core gate into an absent owned staging directory, using 256 KiB reusable copy
storage and no-follow file handles. Root/relative link checks and file identities
are revalidated; ordinary source changes fail instead of returning a truncated
snapshot. Absolute ancestors are checked at phase boundaries, with root and
relative components checked at each access; this is not an adversarial filesystem
snapshot against a foreign writer. An export result reserves only a 1 KiB summary
plus existing bounded metadata, never a source-sized transport payload.

The content profile uses the same inventory to classify omitted metadata/recycle
and authorize every declared live file, folder and asset. Exact spelling and
excluded-directory identities both matter; an alias is never treated as missing.
All raw contents metadata records are checked, including orphans and aliased names.
Protected metadata/suffixes and streamed envelope signatures refuse without
producing a successful artifact. Excluded entries retain identity checks even
though their bytes are not copied. The full-backup profile retains its original
preservation contract. No serializer, renderer or second native owner is introduced.

Search and snapshot share the mutex-linearized active read-only cancellation
mechanism. Accepted cancellation cannot become late success; close cancels/drains
these reads but finishes active mutations. Partial staging is caller-owned and
cannot be discarded until the native future/close has settled.

The library capture callback always closes/joins the export owner, then retires
only its captured admission token. ZIP generation and system provider I/O run on
the owned copy afterward, outside the notebook gate. A later library open may be
active when export finishes; export completion cannot retire that newer operation.
The ZIP worker is joined before cleanup. Cancellation is checked between body
chunks/entries; the maintained codec's bounded central-directory finalizer is
synchronous, so cancellation there waits until finalization and is checked before
ready publication. A committed ready copy remains retryable if cancellation wins
after publication. See ADR 0006 for artifact ownership, quotas and provider leases.

### Import filesystem worker and guarded core validation

`CoreImportStore` wraps a closed, bounded synchronous filesystem API executed only
on import worker isolates. It creates no core context and performs no notebook
metadata mutation. Requests are at most 16 KiB and allocated responses at most
8 MiB, released by the matching native result function. Pure Unicode path-key
calls use pinned utf8proc. The borrowed atomic cancellation handle survives every
worker/native lease; only the joined owner frees it. Synchronous decompression
checks that handle at sink writes/backreferences rather than killing an isolate
with open files.

Strict incoming and managed metadata inspection precedes core validation. The
catalog-only `collectNodeIds()` terminal retains its full 8 MiB reservation because
only serialized size is known before collection; duplicate IDs are rejected.
Every collected set must equal the strict metadata walk. A sequence of fresh
transaction-local `openExportCatalog` owners validates staged, existing and finally
published notebooks, closing/joining each before the next. No core pointer crosses
isolate/thread boundaries and no global session restore is used for inspection.

One library admission covers identity collision checking, native no-replace
publication, guarded destination open and durable commit receipt. Separate
synchronous transfer reservation prevents import/export staging overlap before any
await. Shutdown drains post-publication completion; cancellation/error is not
proof of rollback. Recovery validates the journal and directory identities before
normal discovery or cleanup. See ADR 0006 for the exact publication boundary.

### Additional upstream concurrency gate

[Context](../../third_party/vxcore/src/core/context.h) stores a plain `std::string last_error`; [sync C ABI](../../third_party/vxcore/src/api/vxcore_sync_api.cpp) writes it in `SyncResult`, while owner/search wrappers also write it. SyncManager's documented state mutex does not synchronize those C-wrapper writes. Concurrent worker/owner error paths are therefore not proven safe at this pin. Before enabling network-worker overlap with owner calls, upstream synchronize per-context error storage/access (with operation results retained separately), and audit lifetime/config reads across that seam. Do not solve this by serializing a long network call on the sole owner/control executor. Phase 1's serialized owner path remains reachable independently. Older contradictory “NOT thread-safe/pre-Wave 10” paragraphs in the sync guide do not override actual implementations or the newer locking section.

## Teardown and alternatives

Stop admission; retire generations; cancel pending jobs and active tokens; wake all reservation waiters. Let mutated saves finish. Keep owner scheduling alive while workers need final apply/refresh retirement; never join a worker from an owner task that the worker is waiting on. Drain/retire reservations and worker leases, then join workers from the shutdown coordinator. Detach event/log subscriptions, wait for in-flight callbacks, release their userdata/tokens, call prepare-shutdown and destroy on O, finally join O. Native memory is not freed merely because a Dart timeout expires. A stuck platform call may leave shutdown pending; forced process termination is not graceful teardown.

Rejected: raw handles in Riverpod/widgets, arbitrary Dart isolates for affinity, an unbounded worker per operation, network on the owner thread, direct native-to-Dart synchronous callbacks, cross-thread volatile writes, and memory-save APIs used for ordinary files.

## Observable acceptance

- Real-core Phase 1 creates, saves, closes/recreates and reopens isolated fixtures with unchanged IDs/bytes; all errors and string releases traverse the asynchronous host.
- Queue saturation and oversized inputs fail explicitly without losing terminal outcomes; UI cancellation/drain stays responsive during slow network and disk IO.
- Rapid revisions, external modification, disk-full and cancel-after-mutation retain correct dirty/draft state; stale results never revive a closed session.
- Zero external search drainers return ordered complete simple results; cancellation and explicit result caps work without a volatile data race. Large single-chunk allocation is addressed before release.
- Sync/owner simultaneous failure paths exercise the upstream error-storage fix; teardown during stage/network/reservation/refresh releases all resources with no use-after-free/deadlock.
- See [verification](../verification.md) for exercised owner/FFI/storage cases; network-worker and remaining device gates remain unpassed.
