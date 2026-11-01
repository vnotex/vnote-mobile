# ADR 0002: Native ownership, execution and cancellation

Status: the serialized owner host for managed notebook operations is implemented; later search/network execution remains a design, not a verified concurrency claim. Phase 1 covers context/notebook/folder/file/buffer create-save-reopen; search and WebDAV rows define later integration, not permission to omit them from the complete release.

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

The streaming API enqueues file chunks in `vxcore.search`; [SimpleSearchBackend](../../third_party/vxcore/src/search/simple_search_backend.cpp) self-drains with `ProcessNext(5)` until completion. With **no external drain threads**, the owner initiator alone gives the single-thread correctness path. Keep this initial choice even though it can delay other owner work; UI/control remains responsive and cancellation takes effect at bounded admission/chunk boundaries, not a promised per-line latency. Later drain workers require measured need plus metadata/config/error-state concurrency evidence; workers do not simply call every search API arbitrarily.

The pinned API accepts `volatile int *cancel_flag`; volatile is not portable cross-thread synchronization. Initial streaming implementation uses a host atomic cancellation bit read by the same-thread batch callback, which sets a request-owned volatile flag **on that same initiating thread**. No external drainers or cross-thread writes to that flag. Set it before dispatch if already cancelled; callback also sets it on result-limit exhaustion. This safely cancels at chunk boundaries; a long in-progress file can delay actual termination. Fine-grained concurrent cancellation requires an additive upstream atomic-token API, not casting `std::atomic<int>*` to `volatile int*`.

## Host ABI and bounded transport

The host ABI is separate from `vxcore_*` exports. The current `vxm_*` boundary implements explicit catalog/note creation, note read/write, catalog list/mutate, cancel/drain/free/close/destroy and a borrowed read-only notices export. Later sync handshakes extend these host protocol choices: versioned submit, cancel, reservation-reply, drain-events, release-event and asynchronous shutdown operations. Use fixed-width request ID and context/notebook/session generation; payloads carry operation, captured editor revision, byte length and explicit ownership. Terminal envelope carries actual core code, redacted explanation and outcome (success/error/cancelled/stale), plus partial-application facts. Never retrieve shared last-error text to label a different operation.

Current admission limits: 64 admitted operations and 32 MiB total queued input per host, 4 MiB editor source, 8 MiB catalog JSON, 64 retained terminals plus one separately reserved close terminal, and 16 MiB aggregate result storage including bounded dynamic metadata; oversized editor input is rejected before mutation with recoverable source preserved. Reserve one terminal slot per admitted request separately from progress/batches. Progress may coalesce; terminal results and save errors may not drop. Search uses small chunks, explicit 10,000-match / 8 MiB delivered-result cap and an explicit incomplete/limit status, not falsely complete truncated results. A single native search chunk can itself exceed transport limits because core constructs its JSON first: reject oversized files/match-heavy work up front where possible and require an upstream bounded result sink before claiming bounded native search memory for arbitrary inputs. Do not advertise queue bounds as a core allocation guarantee.

Core log callbacks execute under the logger mutex; events/search callbacks can arrive on the calling worker. Copy bounded borrowed data before return, redact secrets, and enqueue without calling Dart or synchronously re-entering core. Never wait for UI while holding a core mutex/G. If a required handshake cannot be delivered, fail before apply; progress loss is not permission to lose a terminal outcome. Result release is explicit and independent of context destruction.


The current implementation serializes core jobs across host instances with a process-wide mutex because the core UUID generator has unsynchronized shared RNG state. Contexts and storage remain independently owned. Admission/cancellation/event draining and notifications do not take this core-job gate. Remove or narrow that gate only after upstream global state has a proven concurrency contract.

Dart retains NativeCallable.listener while the owner runs. Close retires admission, drains terminal events, nulls the usable event handle, performs native destroy/join on a cleanup isolate, then closes the callable. Reopen creates a fresh native host as well as a fresh editor generation: the native write-revision watermark cannot be reused after an editor resets to revision zero.

### Catalog and editor ownership

Catalog mode owns a context/notebook but no buffer. Note mode requires the expected
notebook and node IDs, resolves the current path through core, and never creates a
missing notebook or note. Catalog mutations are rejected in note mode; note reads
and writes are rejected in catalog mode. The Flutter workspace drains one owner
before opening the other. All later catalog opens retain the first observed
notebook UUID, including failed-note-open recovery.

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
- See [verification](../verification.md) for exercised owner/FFI/storage cases; search and network-worker gates remain unpassed.
