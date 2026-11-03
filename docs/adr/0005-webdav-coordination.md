# ADR 0005: WebDAV readiness, reservations and credentials

Status: accepted implementation contract for the core, native host and mobile coordinator. Uses the existing WebDAV protocol, not a new uploader. Executed checks and remaining platform/release gates are recorded in [verification](../verification.md).

## Evidence and scope

Baseline vxcore `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`: [public phased sync ABI](../../third_party/vxcore/include/vxcore/vxcore.h), [sync guide](../../third_party/vxcore/src/sync/AGENTS.md), [C wrapper](../../third_party/vxcore/src/api/vxcore_sync_api.cpp). Desktop `f8026adb4c43f78d90251148e24b6e72ca28f3d7`: [service contract](https://github.com/vnotex/vnote/blob/f8026adb4c43f78d90251148e24b6e72ca28f3d7/src/core/services/AGENTS.md), [classifier implementation](https://github.com/vnotex/vnote/blob/f8026adb4c43f78d90251148e24b6e72ca28f3d7/src/core/services/syncstateclassifier.cpp). These are compatibility references, not permission to copy Qt implementation into mobile.

Mobile enables only bundled-notebook `webdav`. Preserve stored `git`/`jianguoyun` routing as unsupported, never migrate it automatically. Core owns bootstrap, UUID binding, journals, preflight, conflicts and recovery. Mobile uses `vxcore_sync_prepare_lifecycle` on O, `vxcore_sync_execute_lifecycle` on W and `vxcore_sync_complete_lifecycle` on O, then frees the joined handle. Query actual clone/deferred-apply capabilities. Legacy enable/credential/clone APIs keep their desktop semantics; their existence alone is not a capability or authentication guarantee.

## State facts and precedence

Derive state on startup/resume/open and after operations from persisted routing, validated secure credential presence and runtime registration. Never persist an S-number. `vxcore_sync_is_ready` checks routing completeness, not authentication or connectivity. Vault lookup errors remain unknown, not absent; block synchronization with actionable recovery while retaining offline access.

Apply base classifier precedence exactly: disabled -> S0/S6; enabled unsupported/missing backend -> S3; supported backend without URL -> S1; complete routing without credentials -> S2; then runtime absence/presence -> S4/S5.

| State | Facts | Mobile action |
| --- | --- | --- |
| S0 | Disabled/absent routing, no credentials; no runtime after reconcile | Enable / sync information |
| S1 | Enabled, supported backend, missing URL; credentials may exist | Complete routing without discarding existing secret |
| S2 | Enabled, supported backend + URL, no usable matching credentials | Supply credentials |
| S3 | Enabled, backend missing or unsupported, regardless of URL/credentials | Explain unsupported routing; do not mislabel as missing URL or automatically migrate |
| S4 | Complete enabled routing, matching credentials, no runtime registration | Async reconcile/enable; surface actual failure, permit retry |
| S5 | Complete enabled routing, matching credentials, runtime registered | Ready/configured, **not connected/authenticated now**; manual sync allowed |
| S6 | Disabled with orphan credentials; no runtime after reconcile | Idempotent vault cleanup or explicit re-enable after pending delete settles |
| S7 | Busy overlay: queued/running sync or pending vault transaction | Preserve underlying base facts, display progress and prevent conflicting operations |

The pinned desktop classifier's `classify()` emits S7 only when base state is S5 and in-progress; its broader service contract counts vault work as busy. Mobile retains base state plus independent busy facts so an S4 reconcile/S6 deletion cannot incorrectly appear idle. Unexpected runtime registration with disabled/incomplete/unsupported routing is reconciled by runtime unregister and reported if that fails, not promoted to S5.

Foreground automatic sync obeys `autoSyncEnabled` and uses one coalescing key per notebook for manual, automatic and freshness requests. The 30-second trailing window is not restarted by every local save; retain one newest pending follow-up. Manual bypasses delay, not readiness/exclusion. Reconcile may request a single freshness check after two minutes. Backgrounding cancels cooperatively and drains actual apply/refresh; close/disable/shutdown retire timers and queued requests. No guaranteed background service or inferred connectivity.

## One operation, seven publication stages

`NotebookSync` orchestrates typed `SyncCore` commands with one operation ID and owner generation. The native host owns the token/context and at most two joined network workers globally. Core diagnostics and UUID generation are synchronized; metadata/SQLite stays on the owner. Reserved internal completion capacity prevents ordinary queue saturation from stranding an owner tail. App reservations are operation-owned objects, not raw pointers or WebView commands.

1. **Admit.** Validate readiness, capability, notebook lifecycle and retirement/recovery preflight. One item owns the whole round trip. Resolve pending core recovery before fresh credential ingress or sync. Do not use composite `vxcore_sync_trigger` on this route: it cannot insert the editor handshake and risks duplicate lifecycle completion.
2. **Stage.** Acquire G after earlier admitted local writers; call `vxcore_sync_stage_only`. Snapshot only durable notebook state, never force-save editor text. Release G before network; new normal saves may resume while the network phase is in progress.
3. **Network.** `vxcore_sync_network_phase` runs on W without G. Incoming deferred bytes remain private; core owns protocol concurrency and recovery. Progress is copied/coalesced and cancellation reaches the operation token via the independent control path.
4. **Reserve and drain.** Install the application reservation synchronously without G, suspend new saves/structural/resource operations, drain already admitted writers, quiesce through the existing editor protocol and flush captured private draft obligations. Classify dirty state AFTER drain. Pass stable dirty node IDs; the native owner resolves physical body paths and authoritative parallel metadata through core APIs. Unresolved transfer/sidecar ownership refuses apply. The five-second deadline/cancellation retires the token, sends a correlated abort and waits for acknowledgement; a late quiesce cannot freeze a successor. Failed abort retains explicit read-only source recovery rather than pretending editing resumed. Never force composition, save or discard.
5. **Apply.** After drain, O sets `vxcore_sync_set_apply_in_progress(...,1)`, then W acquires G and calls `vxcore_sync_apply_phase` with protected paths and token. Core preflights the cohort; do not duplicate its merges in Dart. The runtime flag is not persisted read-only state. Cancellation before dispatch prevents installation; cancellation after partial installation is not rollback. Keep the reservation until actual effects are reconciled.
6. **Refresh.** Capture/free changed paths on every apply outcome and always perform owner metadata refresh after dispatched apply. `vxcore_sync_refresh_notebook_result` reports the original operation code separately from actual refresh success. Missing/oversized paths are unavailable, not an empty affected set. Reload only clean affected sources; unchanged sources retain their view/Undo and dirty sources are never overwritten. A private refresh-required marker precedes apply and survives process death until actual refresh/source settlement. Failed refresh or unavailable paths retain an explicit recovery block and never advance last-success.
7. **Retire.** O clears runtime apply flag idempotently, retires editor/writer reservations, unfreezes safe sessions and releases leases. One completion owner emits exactly one terminal result with original error, changed paths, refresh status and per-file failures. Only complete successful network/apply/refresh and reservation settlement permits `vxcore_sync_set_last_sync_utc` on O; this timestamp is per-device local metadata, not portable config. Timestamp-write failure is visible and does not claim a recorded successful sync. No partial failure advances last-success.

Every error/cancellation/close/shutdown path runs retirement. Close first stops admission and cancels/wakes handshakes, then waits asynchronously for workers and mutation finalization while O remains available. A late reply checks operation/generation/phase and cannot create or revive a reservation. Free tokens/userdata only after native calls and callbacks finish. A five-second pre-apply handshake timeout is not permission to free an in-progress apply or abandon partial refresh.

## Secure credential transaction

Use the dedicated native `vnote.mobile/sync_security` channel, never an editor channel. Android stores AES-256-GCM envelopes in private no-backup files under a non-extractable Keystore key, with fresh nonce, scope/version AAD, checked writes, atomic replacement and directory flush. A missing key with existing ciphertext is unavailable, never regenerated. iOS uses app-private Keychain, AfterFirstUnlockThisDeviceOnly and synchronizable=false. No plaintext fallback. Scope SHA-256 binds backend, canonical HTTPS endpoint and notebook UUID; payload revalidates scope/version. URLs contain no userinfo/query/fragment. Password bytes are not trimmed. Core WebDAV credentials are `extra.username`/`extra.password`; no secret enters notebook JSON, ordinary notifier state, JavaScript, logs or diagnostic text.

Native vault operations are serialized compare-and-swap read/write/delete with opaque revision fingerprints, at most 64 KiB per record and 1,000 scopes. Absence differs from locked/unavailable/corrupt. Versioned encrypted records retain old and candidate secrets plus non-secret transaction identity, routing, references and phase. Confirm each durable result; lost replies reconcile actual revisions instead of assuming no effect. Immutable Dart/Swift strings are not promised zeroization.

- **Enable/bootstrap:** stage candidate securely, execute prepared authenticated enable, persist the COMPLETE notebook config through the owner API, then promote/retire secure versions. Runtime enable does NOT persist routing. Failed config/promotion compensates runtime and routing where proved; ambiguous or failed compensation retains both versions and explicit recovery. Never delete an existing notebook on enable failure.
- **Rotation, same endpoint:** use prepared `credentials`, not legacy `vxcore_sync_set_credentials` as an authentication promise. Candidate authentication/UUID/capability checks use a separate operation/account-bound `credential-validation` namespace, never published probe state. Keep the old provider/baseline until publication. Retained scratch is cleaned by prepared `credentialRecovery` using matching-account credentials; cleanup always reports `committed=false` and never promotes a secret. A post-publication error can report `committed=true`; reconcile actual facts, do not infer rollback from the error code. Promote only after the native outcome is settled, retaining both versions if compensation/recovery remains uncertain.
- **Endpoint change:** not a password rotation. Run `vxcore_sync_check_reconfiguration` and core provider-retirement recovery before changing binding. Preserve notebook/remote identities and journals; never wipe `vx_sync`, rename remote roots or implement retirement by filesystem deletion.
- **Disable:** runtime disable AND owner persistence clearing enabled/backend/URL precede credential deletion; preserve the auto-sync preference. Legacy runtime disable does NOT clear persisted routing. Failed persistence restores prior runtime/routing or reports recovery-required. CAS deletion failure remains an orphan, not absence. No remote data/journals are deleted.
- **Close/startup/orphans:** logical user close serializes durable close anchors and exact-generation secret deletion; shutdown and note/catalog transitions do not delete credentials. Transient native owners use context shutdown rather than explicit notebook close, preserving per-device metadata including last-success. Startup settles prior close/orphan work before new credential ingress. Unknown/corrupt records remain retained; no stale generation can delete a newly stored secret.

Provider changes use core-owned inspect/begin/commit/restore/recover and retained `retired/<uuid>` archives, never Dart manipulation of `vx_sync`. The actual retained provider binding, not only the enabled routing flag, determines an endpoint change; disabling does not erase the old baseline or waive retirement confirmation. Recover prior journals, preflight, unregister, archive, persist disabled routing and commit the archive before enabling a new endpoint. Failed new-endpoint enable may leave visibly disabled routing with the old archive/secure versions retained; it is not a claimed successful rollback. Ordinary desktop APIs and unsupported providers keep their existing semantics.

## Connect and private clone publication

Library Connect creates an owned import wrapper before provisional secure staging.
Only a dedicated empty context under `imports/<id>/runtime/{app,local}` downloads
into its sibling `unpacked`. Native admission clamps the caller budget to current
quota/free space after runtime allocation, reserves prepared-copy/metadata headroom,
and bounds inventory, streaming bytes, projected config and baseline/temp peak.
This is a bounded allocation budget, not an OS reservation against other processes.

No completion receipt exists until real clone success, complete validation and
private-owner join. The sibling receipt binds operation/import/notebook IDs,
endpoint/account, baseline hash, full tree hash and object identities. Ordinary
imports still reject every nonempty `vx_sync`; a schema-valid cursor or forged
in-tree receipt grants no exception. Revalidate the genuine permit through sealed
preparation/publication and preserve the baseline in place. Lost/incomplete attempts
remain retained for explicit discard, never inferred complete from config.json.
After duplicate preflight, provisional credentials are rekeyed before publication;
the native import commits before routing, promotion and credential settlement.
Only configure with the exact clone import ID may establish the first enabled
route without runtime registration: the native bridge derives the sibling wrapper
from the pinned `notebooks/nb-<id>`, verifies its genuine committed clone receipt,
operation/notebook/import IDs, destination identity and unsettled credentials,
and requires the caller's closed configuration to equal the receipt exactly.
An initially disabled, blank, unregistered route ignores the materialized automatic
sync default; an already enabled exact endpoint/preference match is a no-op even
when registered. Every other route or preference refuses unchanged. This exception
does no networking and proves neither authentication nor connectivity; ordinary
configure retains its registered-runtime guard, and workspace reconcile performs
the later prepared credential-bearing enable. A finished receipt grants no authority.
Duplicate UUIDs never replace an existing notebook or secret scope. A complete
imported notebook plus failed credential promotion remains recoverable through the
existing finish action: retry uses the same committed destination and receipt,
without rekeying, republishing, copying or generating another UUID.

## Native platform trust

Register the immutable native policy before sync admission. OpenSSL curl replaces
certificate verification with the bounded native callback (leaf plus intermediates,
16 certificates/1 MiB), while retaining peer and hostname verification. Android
uses the actual platform trust manager under saved/restored network-denying thread
policy; iOS uses SecTrust with SSL hostname policy and trust-network fetches disabled.
Unsupported/unavailable policy fails closed, with no trust-all or test-CA fallback.
The host test CA seam is desktop-test-only; temporary device trust anchors must be
removed and the rebuilt final strict APK checked again. Native WebDAV networking
does not give editor/preview documents network permission; ADR 0004 still applies.

## Capability-driven conflicts

Use `vxcore_sync_get_conflicts` after backend operation serialization; offer only core-supported resolutions via `vxcore_sync_resolve_conflict`. Backend conflict `canKeepBoth` controls Keep both, not a generic UI default: metadata/encrypted WebDAV conflicts cannot acquire that option from file extension guesses. Preserve unsupported/encrypted content; do not edit as plaintext. Local/remote recovery material remains under core control until resolution is acknowledged.

One bounded FIFO batch retains each selected path/resolution and per-file error, then runs the ordinary staged sync path. Distinct batches are not coalesced into a generic trigger and failed choices are not discarded. Revalidate stale conflict/path generations before resolution; a partially successful batch reports successes and failures separately, retaining unresolved choices and recovery data. No direct file replacement or custom merge/upload engine bypasses core capability checks.

## Rejected alternatives and observable acceptance

Rejected: persist S0–S7 as truth; use status polling as readiness; treat S5 as connectivity; force-save dirty editors before apply; hold G during UI handshakes/network; drop changed paths on error; mark sync success before refresh; overwrite vault credentials before authentication; delete secrets after failed disable; universal Keep both; a second Dart WebDAV implementation.

Acceptance requires a controlled endpoint and desktop/mobile fixtures, not personal notebooks:

- Predicate table covers unsupported-plus-missing-URL precedence, missing/locked vault, orphan secrets, unexpected registration and queued vault overlays. Resume/manual/auto produce no duplicate concurrent sync.
- Dirty notes/sidecars, clean sessions, concurrent pending saves and structural writers respect reservation/drain; network permits local saves without metadata races. Timeout/cancel/close at every phase leaves no leaked reservation or stale callback mutation.
- Partial apply installs are refreshed even on failure; dirty editor bytes and both recoverable conflict versions survive, with no advanced last-success timestamp.
- Failed enable persistence, bad-password rotation, vault lock/write/delete failure and process kill at each transaction phase preserve prior usable credentials or explicit recoverable state. Startup cleanup cannot delete a new generation's secret.
- Desktop -> mobile -> desktop round trips preserve UUIDs, notebook JSON, notes and assets; unsupported conflicts have no invented resolution choices. Certificate failures never downgrade.
- Exact executed commands, fixture/device results, review corrections and limitations belong in [verification](../verification.md); this contract alone is not runtime evidence.
