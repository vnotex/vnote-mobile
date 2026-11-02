# ADR 0006: Managed import, share transactions and privacy

Status: whole-notebook ZIP/folder import, ZIP export, retained-artifact recovery and system picker adapters are implemented; Android is exercised. iOS build/runtime and actual backup/transfer artifacts remain unverified. Share-in and Markdown/assets-only import/export remain selected designs, not implemented paths.

Scope: [mobile plan sections 5.3 and 5.7](../mobile-client-plan.md). Retain the full first-release import/export/share boundary, including opaque content preservation. Related boundaries: editor drafts in [ADR 0003](0003-editor-protocol-and-durability.md), preview resources in [ADR 0004](0004-rendering-security.md), and the native host's owner-thread/notebook gate.

## Evidence and selected authority

At core pin `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`:

- [Bundled notebook metadata](../../third_party/vxcore/docs/bundled-notebook.md) lives in notebook JSON/files; SQLite is derived. Notebook/node UUIDs, tags, attachments, sidecars and unknown supported metadata are compatibility data, not disposable mobile cache.
- The [public ABI](../../third_party/vxcore/include/vxcore/vxcore.h) provides `vxcore_folder_get_share_paths`, `vxcore_folder_get_import_paths`, `vxcore_notebook_collect_node_ids`, `vxcore_folder_attach_imported` and `vxcore_notebook_recover_imports`.
- `vxcore_folder_attach_imported` accepts staged `content/` and `metadata/` trees with final IDs/name and journals their publication. Its documented commit point is replacement of the destination parent's `vx.json`; recovery runs before metadata-cache rebuild. ID collection walks authoritative JSON rather than the incomplete lazy SQLite index.
- `vxcore_file_import`/`vxcore_folder_import` copy and can generate unique destination names. They are not documented as an idempotent, atomic multi-item share transaction. Repeating them blindly after an ambiguous crash is therefore not selected.

The application services own incoming transactions, quotas, permissions and recovery. Core owns notebook metadata and mutation. The extension/intent receiver may write only the incoming inbox; **it never opens or writes the live notebook**. Implemented whole-notebook transfer states are described below; cohort/share states remain proposed application contracts, not new platform/core API names.

## Managed copies, import and export

Use platform document pickers to read provider documents into app-private persistent staging. Provider URLs/Android `content:` URIs are capabilities, not filesystem paths. After import the managed working copy is authoritative; edits do not write back through the picker grant or run alongside a provider's folder synchronizer. Export explicitly creates a new copy through system UI. Local removal, content deletion and remote deletion are different actions with different confirmation text.

### Whole bundled notebook

1. Reserve a transaction ID, staging quota and destination slot. Copy all selected bytes into an owned nonpublished staging tree, using the archive/provider preflight below. Preserve original files and record a checksummed inventory.
2. Validate metadata shape, identities, referenced layout and supported capabilities without regenerating IDs. No speculative mobile migration, suffix filter or “supported files only” copy. A notebook UUID already managed on this device is a duplicate, not permission to invent another UUID; offer opening the existing notebook or a separately reviewed replacement/conflict flow, never silent overwrite/merge.
3. Before core open, persist a publication manifest binding the selected final managed root, notebook UUID and complete inventory hash. Atomically rename the validated tree to that previously nonexistent root on the same filesystem, then open through the normal core owner-thread path. If validation requires core opening, do it only after safe sandbox paths exist, against owned staging, with publication/recovery state recorded; never the user's profile or original provider tree.
4. Register success only after core open/recovery succeeds. A crash between rename and registration is reconciled from the manifest and matching root/UUID; do not create another copy. An open failure leaves the owned copy quarantined/retryable and does not publish it in the notebook list as usable. Cleanup may delete only this transaction's owned staging/root, never a preexisting user notebook.

Whole-notebook publication is an application-owned directory transaction, not direct mutation of an existing notebook. No core open may make a partially copied tree authoritative. Core schema migration, if any, remains core-owned and must satisfy preservation fixtures; a format that cannot be safely preserved is rejected before live publication.

### Implemented whole-notebook import

The library takes a synchronous transfer reservation before any provider await.
Import and export cannot allocate overlapping staging, including retained or
recovered artifacts. Existing notebooks may open during provider copy/extraction;
validation/publication requires return through the editor disposition barrier.
A complete private source is prepared first; publication requires a separate
**Validate and import** confirmation. Cancelled or refused input remains available
for retry or explicit discard, not silently evicted.

Android uses `ACTION_OPEN_DOCUMENT`/`ACTION_OPEN_DOCUMENT_TREE` with temporary
capabilities, bounded worker copying and no broad/persistable grants. Activity
detachment cancels import, including configuration changes; results wait for copy
leases to settle. Raw Android descriptors have explicit `finally` ownership;
streams created from an existing descriptor do not own it. iOS acquires security
scope before returning from the picker callback and releases it after coordinated
worker copying, including early cancellation. In-place opening is declared for the
`asCopy: false` picker; no iOS runtime evidence is claimed. Provider folders
record accepted original names in `accepted.jsonl`. The completed copy must match
those names and types byte-for-byte, including hidden files.

ZIP headers are independently preflighted before the maintained archive decoder:
local/central fields, ZIP64 bounds, descriptors, CRC/size expectations, overlapping
ranges, encoding, entry types and all path collision keys. Pinned utf8proc 2.12.0
provides NFC/NFD plus full Unicode case folding consistently across platforms.
Store/deflate extraction runs on a worker through a bounded disk-backed sink,
checking actual bytes, CRC and cancellation. A sole wrapper directory is accepted
only when it contains the whole notebook; extra siblings are never dropped.
Preparation records the complete actual tree in sorted, hashed `inventory.jsonl`.
No notebook metadata is regenerated or normalized.

Before core open, the native strict walker validates configuration, reachable
folder/file metadata, references, unique identities and runtime/credential guards.
Ordinary Boolean sync preferences are preserved; their presence is not itself an
active sync operation. A fresh transaction-local read-only core owner must return
exactly the strict walk's identities. Current managed candidates undergo the same
strict identity walk and guarded collection; unresolved candidates cannot prove
absence. Duplicate notebook UUIDs offer **Open existing notebook**; other identity
collisions refuse. The permissive upstream collector alone is not an absence proof.

`publication.json` is intent, not success. It binds the inventory, original directory
identity and fixed `nb-<transaction>` destination before a same-filesystem,
no-replace rename. Cancellation is honored before rename; afterward the real outcome
is drained. Guarded destination open/close precedes `committed.json`. Startup checks
actual source/destination identities and reconciles this journal before ordinary
discovery. Unregistered targets stay quarantined; missing committed targets are
never replayed from old input. Explicit discard may remove an unregistered target
only when its journal and physical directory identity match. Foreign/preexisting
and committed live roots are never cleanup targets. Invalid private leftovers
require current-token confirmation; ambiguous live ownership remains blocked.

Stable private records are `request.json`, `captured.json`, `prepared.json`,
`publication.json` and `committed.json`, schema version 1. `inspection/` is disposable
derived core state only after owner join. The shared `DocumentTransferPlatform`
channel owns both directions; the former export-only channel has no alias.

### Markdown/assets and share cohorts into an existing notebook

Publish each incoming cohort as **one newly named child folder** at the user-selected destination, showing this grouping before acceptance. A text/URL share creates a note in that folder; images/files become its managed assets/attachments or additional files as appropriate. There is no append-to-open-note path in the initial share implementation, and no hidden mutation of a dirty editor.

Build the cohort with existing core notebook/folder/file/attachment APIs in an isolated temporary bundled notebook under approved persistent staging. Core generates final new IDs for newly created material; imported VNote folder bundles retain their existing IDs. Obtain the staged folder's paths via `vxcore_folder_get_share_paths`, then close the temporary notebook and arrange the final `content/` and `metadata/` staging pair. Do not synthesize a parallel `vx.json` serializer in Dart. Opaque files not indexed by core must still be copied unchanged as part of the subtree. Assets escaping that subtree must be accounted for and preserved safely; reject a cohort whose layout cannot be transplanted intact rather than rewrite links or lose assets.

Before destination publication, durably retain the complete prepared `content/` and `metadata/` trees, not only the original incoming files. Record the final cohort/root ID, every generated ID, destination notebook/parent ID, chosen folder name and prepared inventory hash. These immutable prepared bytes preserve core-generated IDs across retries without inventing metadata in Dart. Reserve room for them and a separate disposable attempt copy within staging quotas; keep the prepared copy until the consumption receipt commits. Use the native owner-thread service and per-notebook gate to re-resolve the parent, run authoritative ID/collision checks, and call `vxcore_folder_attach_imported` on the attempt copy, with only one active attempt for the durable plan. Core handles the journaled content/metadata publication. A busy sync/apply reservation defers it; do not bypass the gate. The user-visible completion covers the entire cohort, not an imported prefix.

On restart or an ambiguous result, run core import recovery before other mutations/sync, then resolve the recorded root ID in authoritative metadata. If the recorded ID was committed, persist the application receipt and do **not** attach/import again, even if the folder was subsequently renamed. If core rolled back and the ID is absent, recreate the disposable attempt copy from the retained prepared trees, verify their hashes/IDs, revalidate and retry. Never rerun ID-generating file creation to reconstruct an already planned attempt. Unexpected partial identities, conflicting names, recovery errors or ambiguous manifests require visible recovery, not renaming and replaying the import. Any core preservation/atomicity gap found by interruption fixtures is an upstream gate, not authorization for manual live-metadata writes.

### Export

Capture a stable on-disk notebook/folder copy under the notebook mutation gate, then release the gate before provider I/O. Drain in-flight writers; unsaved editor text remains protected. If dirty drafts exist, ask whether to save first or export the last saved notebook with an explicit warning; never force-save to obtain a snapshot. Do not hold the gate during a slow cloud-provider transfer.

Export a complete bundled notebook with IDs, unknown supported metadata, tags, recycle-bin content, opaque files and sidecars intact. A Markdown/assets export preserves its source bytes and the selected asset tree; disclose when it is not a notebook backup and does not contain notebook metadata. Include hidden/unknown files inside the portable tree unless they are positively classified runtime/secret material; never use a general “ignore dotfiles” or extension allowlist.

Finish copying to an export staging artifact before invoking system UI. A cancelled/failed provider write leaves the live notebook unchanged and the source export retryable. Do not claim arbitrary providers support atomic replace: where they do not, cancellation may leave an explicitly identified incomplete **external copy**, which must not be reported as success. Export temporary files are cleaned by the owning transaction after grants settle or on next startup.

### Implemented whole-notebook export

The library export action is available only after the editor's existing disposition
barrier has returned to the library. It does not force-save or capture unwritten
editor input. The source copy is produced by a dedicated read-only export owner;
that owner is joined before worker ZIP creation or system UI. Live note metadata
and bodies are never serialized/reconstructed by the export controller.

The archive contains the notebook contents at its root, without a synthetic outer
folder. Portable hidden/unknown files, raw configuration, IDs, tags, assets,
recycle content and encrypted note/key sidecars are retained. The exact
`vx_notebook/vx_sync` runtime tree is excluded only after the public sync recovery
check; unresolved import/transfer trees and cleanup-triggering residues refuse
export. Unclassified `.git` data, links/reparse/hardlinked/special files, external
asset/recycle layouts and unsupported path shapes also refuse rather than being
silently dropped. There is no extension/dotfile/ignored-pattern filter.

Known credential keys (`credentials`, `syncCredentials`, `personalAccessToken`,
`pat`, `password`) at configuration root or directly under metadata refuse export.
Password-bearing URL userinfo, nonempty query or fragment also refuse; username-
only routing is retained. Config is copied raw, never stripped or rewritten. This
is not a scanner for arbitrary secrets a user may store in their note bodies.

| Export resource | Hard limit |
| --- | --- |
| Source bytes | 1 GiB total; no separate 256 MiB import-file cap |
| Portable entries | 100,000 files/directories |
| Paths | Depth 32; component 255 UTF-8 bytes; relative path 1,024 UTF-8 bytes |
| Owned staging | 4 GiB combined snapshot/archive; 128 KiB marker allowance |
| Free-space headroom | 64 MiB beyond the conservative reservation |
| Active/retained work | One operation and one prepared ZIP in normal use |

The combined reservation includes source bytes and a conservative deflate/header
bound, not only the raw copy. Actual IO/output failures are checked. Snapshot copy
uses a 256 KiB buffer. ZIP uses pinned [archive 4.6.0](https://pub.dev/packages/archive/versions/4.6.0),
streamed deflate and incremental 64 KiB steps on a worker isolate; no full-file or
full-archive buffering. The central-directory finalizer is bounded by the entry/path
limits but synchronous; cancel waits through it and is checked before publishing
ready state. ZIP64 is supported. Import-specific expansion and destination
normalization checks below are enforced by the separate import decoder.
Backslashes and ambiguous components are refused before the encoder can normalize
them; accepted spelling is retained.

Each app-private `exports/<transaction>/` directory has a versioned request marker
published by temporary write, flush and rename before snapshot creation. A complete
ZIP, size and streaming SHA-256 precede a separate ready marker. Only then may raw
snapshot bytes be removed. Initialization cleans proven-owned interrupted
preparation, retains complete ZIPs, and surfaces unmarked/corrupt/multiple records
for explicit current-item cleanup. Unknown data is never automatically deleted;
confirmed cleanup stays within that immediate export-root child and does not follow
links. This prevents a crash-before-marker from permanently wedging the export slot.

Save validates the current artifact and its bytes/hash. Cancel/provider failure
retains it; a process interruption may leave an external copy completed or partial,
so retry explicitly saves another chosen copy. Discard waits until no native,
worker or provider lease remains and requires confirmation. Success means Android
finished writing/closing its provider stream, or UIKit reported export completion;
it does not prove remote-provider synchronization or arbitrary atomic replacement.
Only settled successful saves remove the prepared source automatically.

Android uses `ACTION_CREATE_DOCUMENT` and a bounded worker copy via ContentResolver,
without broad storage permission or persistent grants. iOS uses scene-aware
`UIDocumentPickerViewController(forExporting:asCopy:)`; its initial filename is the
actual `notebook.zip`, because this API has no suggested-name argument. It retains
the picker/delegate/source through completion or dismissal. Post-presentation
non-success, including scene loss, reports possible incomplete external output.
The iOS adapter has no runtime/build evidence on this Windows workstation.

## Archive/provider preflight and quotas

Selected archive interchange is ZIP (store/deflate, including valid ZIP64 within limits). Other archive types, encrypted archives, split volumes and unsupported compression methods are rejected with an explanation; opaque archive attachments are preserved, not recursively extracted. Import can also accept provider-selected files/trees under the same path/size rules.

| Resource | Initial hard limit |
| --- | --- |
| Archive input | 1 GiB compressed bytes |
| Published import tree | 2 GiB uncompressed total, 256 MiB per regular file, 100,000 entries including directories |
| Expansion | At most 100:1 per entry and total, using `uncompressed / max(1, compressed)`; enforce actual streamed counts, not only headers |
| Paths | Depth 32; 255 UTF-8 bytes per component; 1,024 UTF-8 bytes per relative path |
| Staging | One active notebook import, at most 4 GiB globally including copy/commit overhead; reserve required declared size plus 64 MiB free-space headroom and stop on actual exhaustion |
| Processing | At most 4 concurrent streams, fixed 256 KiB copy buffers; cancellation checked between chunks; no full-archive buffering |

Declared totals are only a preliminary reservation; dishonest sizes, CRC failures, truncated streams and actual quota overruns abort before publication. A legitimate highly compressible notebook may exceed the ratio limit: explain the refusal and allow a nonarchive picker copy under the same byte/count limits, not automatic relaxation. A 10,000-note representative notebook must fit the entry limit; individual oversized files remain safely exportable/preserved where no import is attempted.

Preflight **all entries** and the complete destination collision set before publication:

1. Reject absolute/rooted paths, drive prefixes, UNC/device paths, backslashes, NUL/control characters, `.`/`..` components, empty internal components, duplicate names and file/directory prefix collisions. ZIP entry names are paths, not URLs: never percent-decode them. Relative provider display names are not trusted native paths.
2. Reject trailing dots/spaces, reserved device basenames and characters that create cross-platform ambiguity. Decode names using an unambiguous supported encoding; require UTF-8 names or plain ASCII when no encoding flag exists, and reject contradictory extra-field names. Do not silently repair names or normalize them on disk.
3. Build collision keys per path component with Unicode NFC plus Unicode case folding, and separately NFD plus case folding; reject any duplicate key, including file-versus-directory and parent-prefix collisions. Retain the exact original spelling when it is unambiguous. Recheck against the actual destination filesystem's existing entries and core metadata; do not assume either iOS or Android is always case-sensitive/normalization-preserving.
4. Reject symlinks, hard-link encodings, reparse points, junctions, devices, FIFOs, sockets and unexpected entry types. Do not follow links in a selected provider/local tree. Extract only into an exclusively owned, newly created directory; check every parent and final open without following links to prevent a validation/open race. Do not restore executable permissions, ownership or arbitrary extended attributes from an archive.
5. Validate central-directory and local-header consistency, methods, sizes, entry bounds and overlap; do not trust the central directory alone. Use a maintained parser with a bounded streaming API and test malformed/overlapping archives. Nested archives are ordinary opaque bytes and do not increase extraction depth.
6. Extract into quarantined staging while hashing every file and counting actual bytes. Inspect the resulting tree again for containment/type/name collisions before publication. Revalidate the destination under its gate immediately before commit. A rejected/cancelled import leaves no live entries or metadata and no acknowledged prefix.

The archive's notebook-relative `assetsFolder` and sidecar references receive separate containment/capability validation. Absolute or outside-root asset configuration is preserved as metadata in a quarantined copy but cannot be accepted as a complete self-contained managed import unless all required content is safely represented without changing that configuration. Explain and reject unsafe publication rather than silently dropping resources.

## Unsupported content and identity

Unsupported/encrypted note bodies, mind maps, office/PDF documents, attachments, hidden sidecars and unknown supported metadata remain byte-for-byte opaque where their notebook can safely be preserved. Detect protected/unsupported editing through core metadata/capabilities; refuse editing and never create a decrypted/plaintext fallback or draft. No “convert to Markdown” on import. Unknown metadata that core would drop or a unsupported schema migration makes live import unsafe: reject and retain the original/staging for export instead of claiming compatibility.

Imported existing notebook/folder IDs never regenerate to dodge collisions. Newly imported standalone files/share text receive new IDs through core **once per durable transaction plan**, not on every ambiguous retry. Asset names/layout remain core-owned. Name collisions are resolved before the plan is accepted: the user may choose a different new cohort folder name, but this never authorizes overwriting an existing note or changing opaque internal paths.

## Bounded, deduplicated share inbox

The selected inbox is an app-owned persistent directory plus a small transactional ledger containing receipt state, hashes and opaque storage references, not notebook bodies as a second database. On iOS it resides in an owner-configured App Group shared by app/extension; on Android it resides in app-private storage reached by the intent receiver. No application identifier, App Group identifier or entitlement is invented here. Exact plugin/adapters and minimum OS support require platform audit.

| Resource | Limit |
| --- | --- |
| One delivery | 64 attachments, 64 MiB per attachment, 256 MiB total; text/URL payload at most 1 MiB UTF-8 |
| Pending inbox | 200 acknowledged, unconsumed deliveries and 1 GiB total including manifests |
| Writers | 2 concurrent incoming deliveries; excess deliveries fail visibly rather than being acknowledged in RAM |
| Dedup receipts | 10,000 durable content fingerprints/transaction receipts; no automatic eviction of active or consumed dedup records |
| Temporary cleanup | Incomplete, never-acknowledged staging older than 24 hours; recheck ownership/active lease first |

**States:** `receiving → ready → importing → consumed`; `failed` retains retryable bytes, and `discarded` requires explicit user action. Only complete, durably committed `ready` data earns “Received by VNote.” OS callback delivery or a temporary provider URI alone does not.

1. Create an opaque transaction directory and reserve bytes/count capacity transactionally before copying. All writers use process-safe bounded ledger locking; no WebView or core handle crosses into the extension. When capacity/lock/access is unavailable, fail clearly without acknowledging receipt.
2. Copy every text/URL/attachment stream into owned storage while the platform grant is valid. Validate name, size, type and hash; do not fetch URLs or decode/render arbitrary files. Durably flush bytes and manifest, then commit `ready` in the ledger. A failure in any attachment fails the whole delivery and leaves the sender's original untouched.
3. Fingerprint a versioned canonical manifest containing the exact UTF-8 text/URL, ordered attachment names/media types/lengths and SHA-256 byte hashes. Do not use temporary URI, filename alone, delivery timestamp or an assumed OS-global delivery ID as identity. Commit fingerprint uniqueness with the receipt so two concurrent identical deliveries cannot both become new inbox items. Store fingerprints locally only.
4. A duplicate fingerprint returns the existing ready/failed/consumed receipt without importing again. Intentionally sharing identical content again requires an explicit “Import another copy” action that creates a fresh application transaction nonce. This deliberately favors deduplication over guessing whether identical OS deliveries were intentional.
5. The main app claims `ready` with a durable operation lease and uses the staged-cohort core transaction above. Keep inbox bytes until the recorded root ID is committed and the `consumed` receipt is durable. A kill after core publication but before consumption is reconciled by that recorded ID, not a fresh import. Repeated startup/retry cannot create another folder or note.
6. Consumed payload bytes may be reclaimed after the consumption receipt commits; retain fingerprint, transaction ID and destination stable ID as the tombstone. Full dedup history refuses new unique receipts with an actionable explanation. Only explicit “Forget share history” clears settled tombstones and explains that it also removes duplicate-delivery protection; it must not clear pending/failed obligations. No silent time-based eviction weakens the at-most-once promise for retained receipts.
7. Failed/ready acknowledged content never expires automatically. Provide retry, system export and explicit discard. Disk full stops new acceptance rather than deleting prior acknowledged items. A removed destination notebook is not permission to replay a consumed delivery elsewhere.

Before other startup/resume notebook writers or sync run, reconcile `importing` leases against core recovery and stable IDs. Expired leases do not by themselves authorize a second writer. Corrupt ledgers/manifests quarantine the item and report it; do not attempt a best-guess reimport. Inbox acceptance, notebook commit and system share-out completion are distinct user-visible states.

## Platform permission ownership

- **iOS:** the picker/extension adapter owns acquired security-scoped access and balances its release after the managed copy settles, including cancellation/error. The share extension loads incoming item-provider data and copies it into the configured App Group while authorized. It does not assume a provider URL survives extension termination. Use the platform-required coordinated access for provider documents. App Group file protection must be compatible with the explicit access policy; if storage is unavailable while locked, fail/defer visibly, never write to unprotected temporary fallback storage.
- **Android:** consume only the grants attached to the selected picker/share delivery, including each applicable multi-item URI. Copy through the content resolver while permission exists; no URI-to-absolute-path conversion. The first release does not request persistent grants for a live provider-backed notebook. If an implementation temporarily takes a persistable grant to complete a resumable copy, its transaction owns and releases it on completion/cancel; it still must not acknowledge receipt before owned bytes exist. Revoked grants produce a retryable/reselect error, not zero-byte success.
- Neither platform requests broad storage/media-library permissions just to import user-selected documents. Camera/microphone/background permissions are not part of these flows. Share-out grants read access only to the exact temporary exported files through system UI, never the notebook root; grant cleanup follows the platform lifecycle rather than premature revocation while a recipient reads.
- Each adapter tracks outstanding grants/leases by transaction and reconciles them at startup where supported. Platform callbacks are not evidence of eventual recipient persistence. UI says “Shared to system UI” separately from successful local export.

References: [Apple document picker](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller), [security-scoped resource access](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [Android Storage Access Framework](https://developer.android.com/guide/topics/providers/document-provider), [receiving shared data](https://developer.android.com/training/sharing/receive), and [secure file sharing](https://developer.android.com/training/secure-file-sharing). Actual plugin capability, entitlements and device behavior remain implementation gates.

## Backup and privacy policy

Working notebooks, durable drafts and the inbox use persistent sandbox storage, not OS caches. Persistent core app-data/local-data namespaces are separate and must not be globally relocated to a disposable cache. Only proven-derived search/metadata caches, rendered previews and reproducible web assets are disposable; classify files rather than deleting all core local data.

Select **no automatic OS cloud backup or device-transfer inclusion of app-private notebook data in the first release**. Exclude managed notebooks, core configuration/local data, drafts, inbox, temporary exports, dedup ledger and credential ciphertext using the platform's actual backup/data-extraction controls; include App Group contents in the iOS audit. Explain at onboarding/settings that app removal/device loss may remove local data and that explicit notebook export/WebDAV are the available portable-copy mechanisms. WebDAV synchronization is not represented as immutable backup. Minimum-OS/vendor differences in exclusion must be tested and disclosed; an unverified platform rule is not a guarantee. User-created external exports are controlled by the destination provider and may be cloud-backed.

Implemented controls: Android explicitly disables backup and provides old/new XML
exclusions for all documented credential/device-protected storage domains, including
both cloud backup and device transfer. No `device_external` domain is invented.
iOS storage preparation sets/verifies exclusion on stable Application Support,
`core/`, `notebooks/`, `exports/` and `imports/` directories before child writes, repeats at
startup/before export, and never replaces those group directories. This follows
[Apple's directory-group guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup),
which explicitly says exclusion is guidance, not a guarantee. Failure is visible;
there is no unprotected fallback. Android manifest flags are exercised, but actual
OEM transfer/iOS backup artifacts remain an open verification gate.

Credentials remain in iOS Keychain/Android Keystore-backed encrypted storage via the reviewed credential service. Select device-bound, nonsynchronizing credential storage and require reauthentication after migration. No plaintext fallback, notebook metadata credential, share-in secret, WebView credential, signing key or recovery secret enters the inbox/portable export. Known core sync runtime/session state and application vault data are not portable notebook payload. Preserve unknown user files rather than deleting anything that looks private; if a legacy notebook actually embeds known credential fields, stop export/import and explain the remediation instead of silently leaking or rewriting them.

Do not log note bodies, snippets, clipboard data, incoming filenames/private paths, URL userinfo/query tokens, provider capabilities, content hashes or credentials. Internal transaction IDs may appear in redacted local diagnostics. No telemetry/crash-upload service is selected. Diagnostic export is opt-in, locally generated/redacted and inspectable before sharing. Secrets/signing material and personal fixtures never enter Git or CI artifacts. Clear preview caches and unnecessary exported copies, but do not claim secure erasure on flash storage.

Draft/inbox retention contains private content by design and is visible in storage settings. “Remove device copy” first handles unsaved drafts and acknowledged inbox targets with save/export/discard choices; it does not delete remote notebooks. Explicit discard removes owned local recovery content and permissions, with a warning that an already exported copy cannot be recalled. Never silently clear unsaved drafts or pending shares just to satisfy a storage quota.

## Rejected alternatives

- Editing provider URLs directly or dual-syncing a live notebook: incompatible permissions, ownership and conflict semantics.
- Extract-then-check into a live notebook, sanitizing unsafe names, or filtering unsupported extensions: publication hazards and lost compatibility data.
- Repeated single-file imports plus a final “done” flag: duplicates/partial cohorts after crash between core write and application receipt.
- A share extension as a second notebook writer, acknowledging temporary URI references, or memory-only inbox dedup: loses accepted items under termination/grant expiry.
- Automatic unresolved-item eviction, default cloud backup of private transient data, or blanket stripping unknown notebook files: privacy/retention/compatibility violations.

## Observable acceptance cases

See [verification](../verification.md) for executed whole-notebook cases. Share-in,
physical power-loss and iOS/backup cases below remain unexecuted gates.

1. Import/export a desktop notebook with 10,000 notes, Unicode names, IDs/tags/unknown supported metadata, attachments, encrypted/unsupported bodies and opaque sidecars. Reopen on desktop and compare semantic metadata plus exact untouched bytes. Unsupported unsafe notebooks reject before publication.
2. Every quota boundary and one over it, ZIP bombs, false sizes/CRC, overlapping headers, traversal, absolute paths, symlinks/reparse swaps, device names, case/NFC/NFD collisions and file-directory prefix collisions leave the live destination unchanged.
3. Kill/cancel at each staging/publication/core-import/ledger step. A cohort is absent or recoverably committed in full, never an acknowledged prefix; recovery precedes sync and ordinary mutations.
4. Share into a stopped app, kill after “Received”, revoke every provider grant, fail the second attachment, and deliver identical payloads concurrently/repeatedly. All acknowledged bytes remain recoverable and each retained receipt produces at most one committed cohort, including a kill after core commit before the consumed receipt.
5. Retry an ambiguous import after destination rename/move; stable IDs prevent duplication. Metadata-cache incompleteness cannot hide ID collisions. App history reset requires explicit confirmation and never drops pending obligations.
6. Audit grants, entitlements, locked-device failures and recipient share-out reads on both platforms. No live notebook access from an extension or broad storage grant is required.
7. Inspect actual backup/restore/device-transfer artifacts and diagnostic/export bundles: app-private secrets/drafts/inbox are excluded according to the disclosed policy; full notebook exports preserve portable user content and no application credentials.
8. Disk full, read-only destination, provider cancellation and core recovery failure remain visible/retryable. Cleanup touches only transaction-owned artifacts; device-copy removal cannot delete remote data or silently discard drafts/shares.
