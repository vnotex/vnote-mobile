# ADR 0003: Editor protocol and local durability

Status: received acknowledgements and explicit native Write/On disk state are implemented; the durable draft/save-receipt design remains unimplemented. Executed checks are recorded in [verification](../verification.md).

Scope: [mobile plan sections 5.4 and 7](../mobile-client-plan.md). The Phase 1 managed-note integration exercises load, edits, repeated snapshots, explicit native writes, selection, undo, theme changes and guarded close. The JavaScript protocol still uses **received acknowledgements only**; the separate Flutter on-disk watermark reflects only a completed native write. It must not emit `draftDurable` or `saved`, show “Saved locally”, or imply a core connection before those paths exist. The complete-release contract below remains required.

## Evidence and ownership

- Core reference: `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`. The [public buffer ABI](../../third_party/vxcore/include/vxcore/vxcore.h) supplies raw-byte get/set, ordinary `vxcore_buffer_save`, external-change checks and a line-ending override query. Its prepare/execute/complete save API explicitly supports **memory buffers only**, not ordinary/encrypted notes.
- Ordinary persistence calls the platform-selected `SaveBufferFileContent`. [Android/iOS persistence](../../third_party/vxcore/src/mobile/buffer_file_save_mobile.cpp) uses checked temporary-file publication, preserving mode bits and flushing file/directory. [Desktop persistence](../../third_party/vxcore/src/platform/buffer_file_save_desktop.cpp) retains the original in-place writer. The initial Windows DACL/recovery expansion is removed; desktop test API opt-in does not select mobile saves. This is not a full crash-recovery journal or a power-loss guarantee. [Buffer::SaveContent](../../third_party/vxcore/src/core/buffer.cpp) also changes the core revision on successful save. Protocol revisions therefore cannot be aliases for core revisions.
- The pinned desktop [BufferSaveQueue](https://github.com/vnotex/vnote/blob/f8026adb4c43f78d90251148e24b6e72ca28f3d7/src/core/services/buffersavequeue.cpp) captures text/revision and serializes raw set + save by buffer FIFO and notebook gate. Reuse that ownership policy, not its Qt implementation or its successful completion for a superseded job: an unexecuted mobile save must never receive a durable-success acknowledgement.
- CodeMirror owns editable text, selection and undo. The application editor service owns session identity, protocol validation, a delta-updated in-memory mirror, draft persistence and save scheduling. Core owns notebook writes. Neither the mirror nor drafts replace notebook truth.

## Decision: protocol version 1

The following names are **TypeScript/Dart wire fields**, not existing core APIs. Load, received/rejected acknowledgement, edit, selection barriers, revision-bound insertion, repeated write-boundary snapshots and guarded close are implemented for the managed note; durable save/recovery fields remain design requirements. Messages are JSON data, never interpolated JavaScript. Every document message has `{v: 1, type, documentId, generation, revision, requestId}`. `documentId` is an opaque binding to stable notebook ID + node ID; validated paths are separate service data. The managed document uses the actual notebook/node IDs and a SHA-256 disk base, not a fabricated identity.

`generation` is a fresh host-issued unpredictable 128-bit token for every session/WebView replacement. `revision` is an integer in `0..9007199254740991`, starts at zero on a new load, and advances by exactly one per accepted edit batch. `requestId` is unique within a generation. Before exhaustion, drain and resynchronize into a new generation; never wrap. A current document has only one writable session. Nothing from JavaScript can select another native buffer by supplying a path or ID.

| Message | Direction and required payload | Effect |
| --- | --- | --- |
| `load` | Host → editor: exact `text`, `language: markdown/text`, `baseVersion`, `lineEndingPolicy`, initial selection, limits, `reason: open/resync/recovery` | Install one snapshot with editing disabled. `baseVersion` is an opaque host token binding node identity, exact disk SHA-256/length and relevant source policy; it is not just mtime. Never replace dirty text without the recovery/resync barrier below. |
| `ready` | Editor → host: matching load `requestId`, revision, text length | Confirms installation, not persistence. Host validates the response before granting edit credits. A version mismatch leaves the editor read-only with an actionable error. |
| `edit` | Editor → host: `baseRevision`, sorted `changes: [{from,to,insert}]`, resulting selection | All half-open ranges address the same base document. Require `revision = baseRevision + 1`, nonoverlap, valid boundaries and limits. Apply the whole batch or none. Local transactions may be composed into this one changeset without losing CodeMirror undo grouping. |
| `ack` | Host → editor: original `requestId`, `stage: received/draftDurable/saved/rejected`, `throughRevision`; optional typed error and absolute credit counters | `received` means validated and applied to the volatile mirror. `draftDurable` means replayable draft data was durably committed through that revision. `saved` requires successful corresponding core write plus committed save receipt. `rejected` never advances revision or durability. |
| `save` | Editor ↔ host: `mode: request/snapshotRequest/snapshot`, `reason: manual/autosave/close/resync`, target revision; snapshot response includes exact text | Flush the current edit batch first. Ordinary saves use the host's captured mirror at the requested revision, so no full JS copy is required. Explicit snapshot requests are allowed only at load/resync/save boundaries; they are not edit substitutes. A snapshot must match the requested revision and mirror before use. Completion is `ack`, not the snapshot response. |
| `selection` | Set/update: `anchor`, `head`; host barrier: `mode: request`; correlated editor reply: `mode: current`, `anchor`, `head` | The barrier waits for composition, flushes edits and cancels coalesced selection delivery. Its directed selection is bound to the exact returned revision. No text mutation or revision increase. |
| `insert` | Host → editor: exact `text`, `anchor`, `head` at the barrier revision; editor → host: correlated `ack`, `stage: received/rejected` | Require matching generation, revision and directed selection. One isolated undo transaction emits its normal `edit` before `received`; receipt never advances the on-disk watermark. |
| `close` | Host ↔ editor: `mode: request/ready`, final revision, `disposition: save/retainDraft/discard` | Stop new transactions, complete composition and flush edits. Retire only after the chosen durable barrier, or explicit user-confirmed discard. A close timeout is not success. |

The current load requires `language` to be exactly `markdown` or `text`, selected from the core filetype. Plain text does not install a Markdown parser. Source headings and accessibility labels use trusted text, never note-controlled HTML. Unknown languages fail closed; changing a theme does not change the document language.

Host-to-editor toolbar/undo/redo commands enter CodeMirror's ordinary transaction path and consequently produce `edit`; they do not mutate the mirror independently. Theme changes reconfigure the existing view and must not trigger a load, reset history, or change revision. Neither operation authorizes a notebook save by itself.

Validate origin/session binding, schema, integer ranges and encoded message length before acting. Reject unknown version/type, overlapping changes, wrong document/generation and revision gaps. Exact duplicate requests can replay their last acknowledgement without applying twice; a repeated request ID with different content is a protocol fault. Keep the last 64 request fingerprints/results per generation; an older duplicate triggers bounded resync rather than speculative application. A stale acknowledgement is ignored, not an error that dirties or cleans the new session.

On a gap/hash mismatch, freeze edits, retain the editor's current text and pending changes, and negotiate a resync snapshot at its revision. Never load the host's older mirror over that text. If the two states cannot be reconciled unambiguously, preserve both as a recovery conflict. A transport reload creates a new generation, not an opportunity to reuse old callbacks.

## Text, offsets and IME

Use **exact source UTF-16 code-unit offsets** on the wire and in Dart. UTF-8 conversion happens once for a captured native save, not for every keystroke. UTF-8 decoding is strict; preserve an existing UTF-8 BOM as source metadata and restore it on save. Invalid UTF-8 or another unsupported encoding opens with an explanation and an export-preserving read-only path; never replacement-decode and save damaged bytes.

Configure CodeMirror with `EditorState.lineSeparator.of('\n')` and initialize with `Text.of(source.split('\n'))`. Its documented [line separator behavior](https://codemirror.net/docs/ref/#state.EditorState%5ElineSeparator) permits retaining CR code units inside each line. Serializing the lines with `\n` reconstructs the original source. This is a design selection, not a device round-trip result. Do not add a second per-line ending table. CRLF occupies two wire units; a lone CR is retained as an explicit source control character rather than silently converted. CR display, cursor motion and accessibility require fixtures/device evidence before release.

- No NFC/NFD normalization, whitespace trimming or Markdown reserialization. Combining sequences remain byte-exact; grapheme navigation uses editor behavior, while wire offsets remain code units.
- Neither edit boundaries nor selections may bisect a valid surrogate pair or CRLF pair. Replacements may include the entire pair. Reject malformed external messages; user-facing movement commands choose valid boundaries. Reject committed lone surrogates, without silently substituting U+FFFD.
- Without an explicit core override, existing separators and pasted source remain exact. New Enter/toolbar line breaks use the most frequent separator in the loaded source (ties use first occurrence; a file with none uses LF). Undo restores the original inserted/deleted source, not a freshly normalized variant.
- Query `vxcore_buffer_get_line_ending_override` at load/save. An explicit LF/CRLF/CR source policy governs output on the next **edited** save; that whole-output EOL conversion is the sole permitted out-of-range normalization. It must be disclosed as source policy and tested. Opening, previewing, or pressing save on an unchanged note never rewrites it. Keep the exact editor snapshot and encoded disk result hashes distinct so a source-policy conversion cannot masquerade as an external conflict or reset undo.
- IME composition remains locally provisional until `compositionend` and the final CodeMirror transaction are processed. Do not send half-surrogates, request an authoritative snapshot, reconfigure the document, navigate away, or show a clean state mid-composition. Reserve one edit slot and up to 65,536 inserted code units before starting composition. Finalize to one validated batch; composition cancellation leaves the pre-composition document unchanged. Save/close waits for finalization; after five seconds show a finish-composition prompt and retain the view rather than pretending success.
- Enforce limits before accepting the canonical transaction, including during composition. A rejected final candidate must be visibly identified; retain an in-limit candidate for copy/retry until dismissed. Never roll back previously accepted edits to make space. Uncommitted IME candidates are not durably acknowledged and survival of OS-owned input state is not promised. Platform behavior that cannot reject a prospective oversized composition without corrupting the prior document fails the device gate; it is not permission to truncate.

## Literal limits and flow control

MiB/KiB mean powers of 1024. These are selected initial safety bounds, not measured performance claims.

| Resource | Version 1 limit |
| --- | --- |
| Editable document | 4 MiB encoded UTF-8 body and 4,194,304 UTF-16 code units, both enforced; supports the plan's representative 1 MiB note and long single line |
| Full load/resync/save snapshot envelope | 32 MiB UTF-8 JSON, including escaping; at most one transfer in each direction per session |
| Edit envelope | 512 KiB UTF-8 JSON, at most 256 ranges and 65,536 inserted UTF-16 units total |
| Unreceived edits | At most 8 batches **and** 2 MiB encoded payload, including pending local batch |
| Not-yet-draft-durable edits | At most 32 batches **and** 8 MiB encoded payload, including unreceived work |
| Control envelope / queue | 8 KiB; 32 pending requests; selections coalesce to one latest update, at most 20/second |
| Edit batching | Flush after at most 50 ms or before a limit/save/close boundary |
| Queued saves | One immutable in-flight snapshot and one newest pending target per buffer; only capture the pending snapshot when it starts |
| Undo retention | At most 200 completed groups and 16 MiB retained changed-text payload; prune oldest complete groups with visible history-limit notice, never the current document or active composition |

Credit accounting includes the worst-case JSON encoding of the proposed transaction before it enters the canonical editor state. Credit replenishment follows validated `received` and `draftDurable` acknowledgements independently. The editor-only proof has volatile credits only; it must advertise draft persistence as unavailable, not synthesize draft acknowledgements.

An oversized paste/replace-all is rejected **as one mutation**, with an accessible “Edit exceeds limit; paste a smaller portion or import a file” explanation. Leave prior text, selection, undo, clipboard and notebook untouched; never silently truncate or commit a prefix. Queue exhaustion temporarily prevents further mutations with a visible “Waiting for local recovery storage” or transport-specific state; selection/copy and retry remain available. Previously accepted changes stay in the bounded queue and are not evicted. At five seconds without progress, offer retry or recovery export; no timeout invents success. Large notes remain preserved/importable/exportable without loading them into the editor.


### Implemented manual-write boundary

Only one snapshot transfer is pending at a time, but subsequent writes may request new snapshots. The host request revision is a lower bound: CodeMirror first finishes composition and flushes edits, then replies with its current revision. Dart accepts the snapshot only when that revision and text equal its validated mirror. Full snapshot replay payloads are retired after receipt. Native success updates only the captured on-disk revision and returned base hash; later edits remain unwritten.

The `written` close disposition is a Phase 1 barrier, not the future `saved` receipt: JavaScript and Dart both require that no pending/composing edit advanced beyond the approved written revision. A rejected barrier leaves source available. Reopen drains the old native host and starts a new one before resetting editor revision zero. Unwritten changes still require explicit discard or a successful Write. A leading UTF-8 BOM is retained as an editor code unit (Dart's decoder otherwise consumes it) and re-encoded unchanged.

### Resource-link insertion

`EditorSession.insertText` first obtains a current selection barrier, then sends one bounded insertion. A cursor move or edit between those messages rejects the operation without moving the cursor or freezing unrelated editing. Replay cannot insert twice. Transport loss, disposal and rejected or malformed acknowledgements settle the pending operation without treating unreceived text as durable.

Asset publication and link insertion are separate outcomes: failure to insert leaves the already-published asset available for a later explicit insertion, never another binary copy or an automatic retry at a new cursor. Only **Write** commits the source. Markdown links use the core-validated note-relative path with each URI segment encoded once; labels are escaped as literal Markdown, not HTML or JavaScript.

## Foreground save and durability barriers

Maintain separate `editorRevision`, `receivedRevision`, `draftRevision`, pending/in-flight save revision and `savedRevision`. A locally pending transaction already makes the UI dirty even before its batch receives a revision. “Saved locally” requires no pending transaction/composition, `editorRevision == savedRevision`, and a valid notebook write receipt for that generation. “Synced” is a separate WebDAV result, never an editor acknowledgement.

1. Persist an exact opening base and append validated edit batches to an app-private draft journal with identity, generation, revision chain, checksums and source policy. Flush after 250 ms or 64 KiB of new journal data, whichever occurs first; only a completed durable commit permits `draftDurable`. The deadline schedules work, not a promise that slow/full storage completed it.
2. Foreground autosave starts 750 ms after the last completed edit, with a five-second maximum delay from first dirty edit even under continuous typing. Composition delays the notebook save but not a visible dirty indication. Manual save bypasses debounce. Pause/resume requests a save opportunistically; correctness never relies on a final lifecycle callback or background execution.
3. Capture immutable snapshot `R` from the mirror, ensure its draft prefix is durable, and persist a write-intent containing expected disk base hash, intended byte hash and request identity. Obtain the per-buffer FIFO reservation and per-notebook I/O gate through the native host; never synchronously block Flutter on disk I/O. Before updating the core buffer, verify current source identity/policy and exact disk base, and run the core external-change/state checks under the same exclusion. A differing/missing file requires conflict recovery, not overwrite.
4. For an ordinary file-backed buffer, perform `vxcore_buffer_set_content_raw(snapshotBytes)` then `vxcore_buffer_save` as one serialized operation. No concurrent update, reload, external-change poll, close or sync apply may touch that mutable buffer. Do not use the memory-only snapshot ABI. The native owner-thread/executor matrix governs where these calls run. Dirty editors are protected during deferred sync apply, not force-saved to clear a reservation.
5. On core success, durably record the resulting byte hash and saved revision before emitting `saved`. On failure, retain draft/write-intent, original error code and dirty state. Preserve edits accepted after `R`; a success for `R` only advances the saved watermark to `R`. A coalesced unstarted save returns a distinct superseded result, never `saved`.
6. Once set-content/write has started, cancellation is advisory: drain and record the real outcome. A retired generation may not receive UI completion, but the recovery service must still reconcile its operation. Retire native handles only after owned work has settled.

**Complete-release durability gate:** the Android/iOS ordinary writer no longer truncates the live note first. File/directory flushing improves the mobile explicit-write boundary, but parent flush can fail after publication; an IO error is not proof the old bytes remained at the original path. The draft/write-intent journal, saved receipt, startup reconciliation, iOS file-protection checks and physical-device interruption matrix remain required before claiming complete-release crash recovery. Desktop retains its pre-mobile in-place writer; host tests do not establish device durability. No Dart direct-write bypass is authorized.

## Draft recovery and retention

Use a small app-private persistent append-only journal and manifest, outside notebook roots and cache directories. Write checksummed framed records, flush them, then atomically replace/flush the manifest before acknowledging its revision. Ignore an incomplete unacknowledged tail after interruption, never an acknowledged prefix. Base snapshots are created only at load/recovery-resync or save checkpoints; keystrokes append deltas, not full note copies. Compact only after a new base/manifest is durable; retain the preceding generation until replacement is complete.

Bound storage to 32 unresolved documents, 32 MiB per document and 256 MiB globally, including manifests, bases, logs and compaction space. Reserve capacity before accepting a new durable obligation. Delete superseded committed checkpoints after a subsequent successful disk comparison; keep the latest saved receipt/base for seven days. **Never age-evict an unresolved draft**: show it in recovery management and stop accepting additional draft obligations when the quota is exhausted. Export or explicit user discard frees space. These are recovery files, not portable metadata or a second note database.

On WebView-only reload, use the application's still-live accepted mirror, keep pending persistence obligations and load a fresh generation. On process restart, validate journal schema/checksums, stable notebook/node identity and base version before presenting recovered content:

- Disk equals the draft's expected base: offer “Restore draft”; load recovered text as dirty in a new generation. Recheck the base under the notebook gate before its eventual save.
- Disk equals a recorded successful write hash: recognize that saved prefix and replay only later edits. A crash between core success and recording the receipt may be reconciled by exact intended-byte comparison, never by mtime alone.
- Disk differs, the identity moved/deleted, source policy changed, or a write-intent is unresolved with partial bytes: preserve disk and draft separately and present a recoverable conflict/copy. Do not silently repair over the differing file, even if it resembles our interrupted save. Resolve moved notes through stable IDs, not the old path.
- An invalid journal remains quarantined/exportable with a visible error. Encrypted/unsupported notes must never acquire plaintext drafts via a fallback.

The guarantee is for acknowledged durable prefixes under tested process-kill conditions. Keystrokes still in the WebView, provisional composition, received-only changes, device loss and unsupported filesystem/power-loss behavior are explicitly outside that guarantee.

## Rejected alternatives

- Full text on every keystroke: unnecessary repeated JS/Dart/native allocation and copying.
- Parallel line-ending metadata: unnecessary while exact source with LF-only splitting preserves CR bytes; retain the simpler source representation and test it.
- One “ack”/dirty boolean, core revisions as wire revisions, or success for superseded saves: falsely cleans newer text.
- Saving only on close/pause; WebView localStorage as authoritative recovery; silently evicting drafts: termination/data-loss hazards.
- Calling the memory save-snapshot API for ordinary files, parallel mutable-buffer access, or direct Dart notebook writes: violates actual core/ownership contracts.

## Observable acceptance cases (not executed)

1. Exact load → ready → no-edit close leaves bytes unchanged, including BOM, mixed CRLF/LF/CR, combining sequences and unsupported Markdown. Exercise 1 MiB source and a 1 MiB single line.
2. Valid UTF-16 edits round-trip emoji, combining marks, Chinese/Japanese IME and RTL; split surrogate/CRLF ranges, lone-surrogate commits and invalid encodings are rejected without changing prior bytes. Test source overrides separately from unspecified policy.
3. Wrong generation, duplicate/different request payloads, revision gaps and stale selection/ack messages cannot mutate another session. Resync preserves both states when ambiguous.
4. At every byte/range/queue limit and one beyond it, an oversized paste/IME/replace-all cannot partially mutate text; UI explains refusal, clipboard and prior undo stay intact, and draining credits permits retry.
5. Hold save `R`, type `R+1`, complete `R`: editor stays dirty. Repeat across failed, superseded, cancelled and late completions; no false saved/synced status.
6. Kill after each `draftDurable`/`saved` acknowledgement and each write/journal/compaction stage; recover exactly the acknowledged prefix or a visible conflict without overwriting newer disk/remote data. Inject disk-full and permission failures.
7. Change theme, rotate, undo after save, switch notes and recreate the WebView without silently losing text/selection. Composition blocks unsafe teardown; unexecuted lifecycle callbacks do not undermine recovery.
8. Phase 1's editor-only surface reports volatile/received state only and cannot display durable saved status. Full durability cases remain unpassed until the real host/core/journal paths and both devices are exercised.
