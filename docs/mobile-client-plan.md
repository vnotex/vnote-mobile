# VNote Mobile: Repository and Implementation Plan

Status: proposed implementation handoff; the technology choices are approved, not an assertion that mobile ports already work.

## 1. Assignment and fixed decisions

Create a separate repository for VNote's iOS and Android clients. Build a new mobile-first frontend, reuse VNote's existing core, and reuse open-source editor/rendering components. Do not fork another complete note-taking application or port the Qt desktop interface.

This document is the starting contract for the implementation agent. First inspect the pinned upstream sources, produce detailed designs for the risky boundaries, then implement the phases below. Refine internal APIs and file layout when supported by evidence; do not silently change the stack, notebook format, compatibility requirements, or acceptance gates.

| Area | Decision |
| --- | --- |
| Application | Flutter stable / Dart; one mobile application for both platforms |
| Presentation state and DI | Riverpod; constructor-injected services, no global core singleton |
| Notebook engine | Existing C++17 `vxcore`, consumed through its public C ABI |
| Dart/native boundary | `dart:ffi` and `ffigen`, with a small asynchronous native host for ownership and execution |
| Markdown editor | CodeMirror 6 / TypeScript in the platform WebView |
| WebView integration | `webview_flutter`; narrow Swift/Kotlin extensions only where its platform APIs are insufficient |
| Preview | Bundled `markdown-it` and DOMPurify; bundled KaTeX and Mermaid for the supported math/diagram subset |
| Build | Flutter tooling, existing core CMake build, Android NDK, Xcode, Node.js LTS for web assets |
| Native integrations | Swift on iOS; Kotlin on Android; prefer maintained plugins when they satisfy the contract |
| Data | VNote-compatible notebook files; no second authoritative notes database |
| Initial sync backend | Existing `vxcore` WebDAV backend and its desktop-compatible protocol |
| Distribution | Android and iOS store builds; no desktop-style self-updater |

Pin exact SDK, NDK, dependency and generator versions during initialization. Use lockfiles and a reproducible web-asset build. Do not select a floating `latest` core revision or download executable/editor assets at runtime.

## 2. Product boundary

### First complete mobile release

- Offline-first bundled notebooks: create, reopen, browse folders, create/rename/move/delete notes and folders within a notebook, and use the core's recycle-bin behavior where supported.
- Markdown and plain-text editing, with source mode, formatting toolbar, undo/redo, search within a note, and read preview.
- Notebook-wide text search and tags using core APIs; stable navigation to search results.
- Images and file attachments, relative links and supported VNote internal note links.
- CommonMark/GFM-style preview, including tables, task lists and fenced code; a documented, fixture-tested subset of math and Mermaid. Unsupported syntax remains intact in source.
- Import/export of a bundled notebook, Markdown files and their supported assets; opening an existing notebook must not regenerate its identities.
- WebDAV connect/bootstrap, manual sync, foreground automatic sync, progress, credential rotation, conflict resolution and recoverable errors.
- Share-in text, URLs, images and files; share/export out through system UI.
- Phone and adaptive tablet layouts, light/dark themes, accessibility, and localization infrastructure. English and Simplified Chinese UI are initial targets.
- Visible local-save and remote-sync states; recovery after interruption without silently overwriting newer edits.

### Explicitly outside the first release

Git and Jianguoyun backend UI, raw-notebook sync, direct live editing of arbitrary cloud-provider folders, iCloud Drive as a second sync engine, encrypted-note editing, visual mind-map editing, desktop plugins/tasks, PDF/office editing, desktop UI parity, collaboration/CRDTs, a new account service, a hosted VNote sync server, and guaranteed background synchronization.

These are scope boundaries, not permission to corrupt unsupported content. Detect unsupported/encrypted formats through core metadata and capabilities; explain the limitation and refuse unsafe editing. Preserve opaque files, metadata, attachments and sidecars in supported notebook import/export and sync paths. Do not fall back from encrypted content to plaintext. If core cannot safely preserve a notebook containing unsupported content, reject the operation before mutation and explain why.

## 3. Source provenance and prerequisites

The desktop reference inspected when writing this plan is VNote commit `f8026adb4c43f78d90251148e24b6e72ca28f3d7`. Its recorded `libs/vxcore` gitlink is `c3319ca9a7dfd5432cad1f7c35de6be099fc87bf`.

The configured upstream is <https://github.com/vnotex/vxcore.git>. Initialize it recursively at the reference revision if remotely available. Verify availability before relying on the pin: local inspection does not establish that a commit is published. If unavailable, obtain the actual published reference from the owner; do not silently substitute an older public revision or a different notebook format. Later pin changes require compatibility evidence and a recorded reason. Push any authorized core changes to the core remote before publishing a mobile gitlink that references them.

Read these paths in the desktop reference or its submodule; they are reference paths, not proposed paths in the new repository:

- `libs/vxcore/AGENTS.md` and `libs/vxcore/README.md`.
- `libs/vxcore/CMakeLists.txt` and `libs/vxcore/third_party/CMakeLists.txt`.
- `libs/vxcore/src/platform/path_provider.cpp`, `libs/vxcore/src/api/vxcore_api.cpp` and `libs/vxcore/src/core/config_manager.cpp`.
- `libs/vxcore/include/vxcore/vxcore.h` and `libs/vxcore/include/vxcore/vxcore_types.h`.
- `libs/vxcore/include/vxcore/notebook_json_keys.h` and `libs/vxcore/include/vxcore/vxcore_log.h`.
- `libs/vxcore/docs/bundled-notebook.md`, plus `libs/vxcore/src/sync/AGENTS.md`.
- `src/core/services/AGENTS.md`, specifically the sync state model, save/sync exclusion, deferred apply, credentials and search threading contracts.
- The corresponding current save/sync/editor integration code when the documentation and public declarations leave an ownership question unresolved. Read desktop code as a compatibility reference; do not pull Qt into the mobile application or copy code without checking its license.

Confirmed: `vxcore` is a Qt-free C++ library with a public C ABI and an MIT top-level license. Bundled notebook JSON/files are authoritative; the core's SQLite metadata database is a derived cache. The desktop consumer owns scheduling and important durability/coordination policy.

Not yet verified: mobile builds, complete transitive dependency portability, Apple/Android transport and credential integration, native packaging, CodeMirror behavior on devices, or the full compatibility matrix. Treat these as Phase 1 gates, not completed features. The inspected `vxcore_context_create` ignores `config_json`; there is no supported sandbox-path injection mechanism. The path-provider prerequisite in section 5.3 must be resolved before first device use. Native transport also needs an explicit audit: Android currently falls into OpenSSL/curl configuration intended for non-Apple Unix, while the Apple branch assumes SDK-provided libcurl headers and library. Verify iOS support instead of assuming that macOS dependencies exist in the iOS SDK; make any necessary portable dependency changes upstream.

Required development access: a Mac with the selected Xcode for iOS builds, a physical iPhone, a physical Android phone, simulators/emulators, and a controlled WebDAV endpoint. Android work on Windows/Linux is useful but does not prove iOS readiness. Store accounts, signing identities, app identifiers, repository publication and the new application's license require owner decisions/credentials before public distribution; never invent or expose them.

## 4. Proposed new repository

Use `vnote-mobile` as the working repository name; a different directory name is harmless. This is an approved creation layout for the future initialization task, not a list of files to add to the desktop repository. Create files as their phase needs them, not as empty scaffolds.

```text
vnote-mobile/
  README.md
  AGENTS.md
  apps/
    vnote_mobile/
      lib/
        app/
        features/
        services/
      android/
      ios/
      assets/editor/
      test/
      integration_test/
      pubspec.yaml
  packages/
    vxcore_bridge/
      lib/src/
      lib/src/generated/
      native/
      hook/
      test/
      ffigen.yaml
      pubspec.yaml
    editor_web/
      src/
      test/
      package.json
      package-lock.json
  third_party/
    vxcore/                    # Pinned recursive git submodule
  docs/
    mobile-client-plan.md      # Copy this handoff into the new repository
    architecture.md
    compatibility.md
    verification.md
    adr/
  scripts/
  .github/workflows/
```

Use Dart workspace tooling if supported by the pinned SDK; do not introduce a monorepo framework just to run two packages. The TypeScript editor is an independently buildable npm package. Scripts deterministically build it into the Flutter asset bundle and fail on missing/stale outputs. Record the policy for generated FFI code and web assets; CI must detect drift whichever artifacts are committed.

Keep mobile presentation and orchestration in the app until another real consumer justifies a package. Keep the bridge small: memory ownership, thread scheduling, event transport and wrappers around public core operations. Notebook rules, merging, encryption, search algorithms and sync protocols remain in `vxcore`. Missing portable capabilities belong in minimal upstream core changes, not a permanently divergent mobile copy.

## 5. Architecture and non-negotiable contracts

### 5.1 UI and application services

Widgets render Riverpod state and issue intents. Application services own editor sessions, notebook operations, save coordination, sync scheduling and platform interactions. Only the bridge calls core APIs. Avoid passing native handles through widgets/providers as ordinary application data.

Represent notebook, note and editor-session identities explicitly. Use stable core IDs and validated relative paths; do not treat display names as identity. Keep transient UI state, device settings and credentials out of portable notebook metadata unless the core schema explicitly defines the field.

### 5.2 FFI, ownership and execution

A Dart isolate is not a guarantee of a permanently dedicated OS thread. The baseline design uses a dedicated native owner thread for context creation/destruction and thread-affine core/metadata operations. Long-running worker-safe work executes on bounded native workers under the core's actual concurrency contract. The Dart UI calls only bounded, nonblocking enqueue/control functions; completion arrives asynchronously.

During detailed design, produce an operation/thread matrix covering every used API, handle lifetime, callback thread, cancellation behavior and required notebook gate. Do not assume the entire C ABI is thread-safe or that moving every call to arbitrary isolates solves affinity. Do not serialize a long network operation on the only executor needed for cancellation, editor acknowledgements or metadata handshakes.

Use `ffigen` for the public headers and the small host ABI. Wrap raw results in typed Dart APIs; generate or centrally map shared JSON keys from the authoritative header rather than hand-maintaining divergent constants. Respect `vxcore_string_free` and every handle-specific release function. Borrowed callback strings must be copied before the callback returns. Dart objects must never outlive freed native context/buffer handles through stale callbacks.

Define request IDs, session generations, cancellation ownership and result/error envelopes. Errors retain the core error code and a redacted user-facing explanation. A cancelled/closed session cannot be resurrected by a late completion. Native callbacks must not wait for the Dart UI or re-enter the core under a native lock. Shutdown cancels/wakes handshakes, stops/drains owned work and detaches callbacks before freeing the context. Search is caller-drained in the core; explicitly select the in-process `simple` search backend for mobile, never the external `rg` backend or a shell-command fallback. Begin with its single-threaded correctness path and add bounded drain workers only with measured need.

### 5.3 Storage and notebook compatibility

Keep working notebooks in app-private persistent storage and supply their root paths to the supported notebook create/open APIs. Those notebook roots are distinct from the core's own app-data and local-data directories.

At the inspected revision, `vxcore_context_create` ignores `config_json`, and neither it nor the configuration-update API supports app/local-data path overrides. `ConfigManager` selects paths before loading config: test mode, a portable directory beside the executable, or the desktop-oriented `PathProvider`. The Apple local-data branch uses `Library/Caches`; Android falls through to Linux XDG/HOME logic. The core stores session configuration in local-data as well as derived data, so mobile must not treat that entire namespace as disposable.

A minimal upstream path-override API is a Phase 0/1 prerequisite. Apply explicit app-data and local-data roots before path resolution/config loading, preserve their separate namespaces, and validate nonempty absolute paths without changing desktop defaults. The native platform adapter must obtain approved persistent sandbox locations and reject cache/temporary locations for these roots. The detailed design must define ownership, validation and desktop regression coverage before implementing the API. Use OS cache locations only for proven-disposable data with a separate lifecycle. Do not invent ignored JSON keys, alter HOME/environment variables, enable test mode in production, or use a writable folder beside the executable as a sandbox workaround.

The bundled `vx_notebook` metadata and configurable assets layout are managed by core APIs. Do not rewrite their schemas in Dart. Preserve UUIDs, tags, attachments, unknown supported metadata fields, note bytes and unsupported content across import/export and sync. The core owns schema migration; mobile must not perform a speculative migration or downgrade.

Do not introduce SQLite/Isar/Hive as another authoritative store of note bodies. App settings and recoverable editor-draft state may use a small app-private store with a documented lifecycle; neither may replace notebook truth.

Document-provider URIs are not ordinary filesystem paths. For the first release, import into a managed working copy and export a copy using iOS/Android pickers. Implement security-scoped access and Android URI permissions only for the duration required. Reject unsafe archives, path traversal, symlinks/reparse hazards and ambiguous destination collisions before publication. Do not point a live notebook at both an external folder-sync app and the internal WebDAV synchronizer.

### 5.4 Editor session, bridge and save durability

CodeMirror owns the active editable text and undo history; application services own its session and revision, and `vxcore` owns durable notebook writes. Do not parse and reserialize Markdown to save it. Opening/previewing without editing must not change bytes. Honor the core's source-specific line-ending policy and preserve other content outside the edited range.

Define a versioned TypeScript/Dart protocol with explicit load, ready, edit, acknowledgement, save, selection and close events. Include document ID, session generation and monotonic revision; reject stale/out-of-order messages. Bound message sizes and queues. Batch edits rather than copying the entire note through JavaScript, Dart and C++ on every keystroke. Use full snapshots at load/resynchronization/save boundaries where needed. Specify UTF-16 JavaScript/Dart offsets versus UTF-8 core bytes and test surrogate pairs, combining marks and IME composition.

Autosave while foregrounded, not only on pause/close. Distinguish editor revision, queued/in-flight save revision and last durably saved revision. An old save acknowledgement cannot mark newer text clean. A failed save remains visible and recoverable. Show 'Saved locally' only after the corresponding core write succeeds; show 'Synced' separately. Never silently discard unsaved edits on navigation, WebView reload, app suspension or sync apply.

Specify recoverable draft checkpoints for acknowledged editor changes not yet committed to the notebook, with bounded retention and identity/revision checks during recovery. A recovered draft must not blindly overwrite a newer disk or remote version; present a recoverable conflict/copy. Do not promise survival of keystrokes that never crossed a durable acknowledgement boundary or guarantee a lifecycle callback before OS termination.

Ordinary file-backed buffers currently use `vxcore_buffer_save`. The similarly named `vxcore_buffer_prepare_save` / `execute_save` / `complete_save` API is documented as memory-buffer-only at the inspected revision; it must not be assumed to support ordinary/encrypted notes. Inspect the desktop save orchestration and the pinned core implementation before defining the mobile snapshot/update/save sequence. Serialize operations on the same mutable buffer and writes per notebook, including external-change detection, so a save cannot race a newer content update or clean-state acknowledgement.

### 5.5 Rendering and WebView security

Bundle all editor, parser, sanitizer, fonts, styles, math and diagram code into the app. The editor must work in airplane mode. `markdown-it` is not automatically equivalent to VNote's cmark fork: use golden compatibility fixtures for the supported dialect, relative/internal links and assets. Where semantics differ, implement narrow extensions or use the existing renderer through a supported adapter; do not change the note format to fit the parser.

Treat Markdown, raw HTML, diagrams, SVG and imported attachments as untrusted. Disable raw HTML by default, sanitize generated preview HTML/SVG, enforce a restrictive CSP and configure renderers in their safe modes. Do not allow note content to execute JavaScript, invoke the privileged editor bridge or navigate the editor WebView. Preview must be isolated from the privileged editor context, with no native command channel reachable from untrusted content.

Use narrowly scoped asset handlers and validated notebook-relative resource resolution, not broad `file://` access or arbitrary filesystem/network fetching. Block remote images/resources by default; external links require an explicit user action and a safe scheme allowlist. Block `javascript:` and unapproved custom schemes. Strip secrets from diagnostics and enforce payload/resource size limits to avoid a diagram or attachment exhausting the process. Theme changes must affect both Flutter and editor/preview without losing text or selection.

### 5.6 Sync, credentials and lifecycle

Reuse the existing WebDAV backend exactly; a generic WebDAV file uploader or a second Dart sync engine is not a substitute. Query backend capabilities and reuse its bootstrap, conflict and recovery APIs. Do not rewrite desktop routing merely because mobile has not yet enabled another backend.

Implement the same readiness predicates as desktop: S0 cleanly disabled; S1 enabled with a supported backend but no URL; S2 complete routing without credentials; S3 enabled with a missing/unsupported backend (classify this before S1); S4 routing and credentials but no runtime registration; S5 complete routing, credentials and runtime registration; S6 disabled with orphan credentials; S7 an in-flight overlay. S5 is configured/ready, not proof that connectivity or a password is currently valid. Derive these states from facts, not a second persisted mobile enum. An unimplemented mobile backend must be shown as unsupported, not registered automatically.

The consumer owns foreground auto-sync policy, coalescing and scheduling. Manual sync bypasses the auto-sync delay but not readiness/exclusion checks. Use per-operation cancellation and generation checks. Do not introduce timers or mobile policy inside `vxcore`. Reconcile on startup/resume, respect user auto-sync settings, and provide a freshness check without duplicate concurrent operations. Background execution is best-effort; the first release must remain correct if the OS grants none.

Preserve the desktop safety sequence for deferred WebDAV apply:

1. Snapshot/stage under the notebook IO gate; release it during network exchange.
2. Without holding the gate, reserve the affected editor sessions and collect protected dirty paths, including relevant sidecars. Suspend new saves and drain already-running writers; do not force-save or discard dirty editors to make sync proceed.
3. Set the runtime apply reservation, reacquire the gate, and invoke the deferred apply phase with the protected paths.
4. Release the gate; refresh metadata on its owner thread and reload only clean affected buffers while the reservation remains valid. Refresh actual installed paths even after a partial failure.
5. Retire the reservation and publish exactly one operation result. Failed apply/refresh must not advance the last-success timestamp. Cancellation and shutdown must release every reservation without use-after-free or deadlock.

This is a portability contract, not a request to import Qt's executor. The detailed design must map it to the native host and Dart sessions, including bounded handshake waits and failure recovery. Missing safe APIs are upstream prerequisites; do not bypass them with direct filesystem mutation.

Credentials belong in iOS Keychain and Android Keystore-backed encrypted storage, using a reviewed plugin or narrow adapter. Never put them in URLs, notebook JSON, editor JavaScript, logs, crash reports or a plaintext fallback. Use backend/endpoint/notebook-scoped keys. Handle missing/locked storage, rotation and deletion explicitly. Preserve usable credentials on failed enable/rotation; successful disable removes local runtime/config routing and credentials according to core semantics but never deletes remote notebooks. Handle orphan cleanup on startup. Use HTTPS with certificate validation by default; any plaintext HTTP support must be an explicit, disclosed policy, never an automatic downgrade.

Conflict choices come from backend capabilities. Offer 'Keep both' only when the core says it is allowed; do not invent it for metadata, encrypted or other unsupported conflicts. Keep unresolved local and remote data recoverable, and preserve per-file errors in a partially successful resolution batch.

### 5.7 Platform integrations

Share extensions/intents must not create a competing writer to the live notebook. Persist a bounded, validated incoming payload in an app-owned inbox, then let the main application's normal service/gate path import it. iOS App Group storage and Android intent grants need explicit ownership and cleanup. A killed app, duplicate delivery or failed attachment copy must not lose an acknowledged inbox item or import it twice.

Use system pickers/share sheets and request only necessary permissions. Local-notebook removal must distinguish removing a device copy from deleting note content or remote data. Avoid logging note bodies, attachment paths containing private data, passwords or tokens. Keep diagnostics local/redacted unless the user explicitly exports them; no telemetry service is part of this plan.

## 6. Implementation phases and exit gates

Complete each phase as a working vertical slice. A generated screen, successful compile or mocked response is not completion. Build/test checks and runtime observations are complementary; record actual evidence, platforms and limitations in `docs/verification.md`.

| Phase | Work and deliverables | Exit gate |
| --- | --- | --- |
| 0. Initialize and design | Create the separate repository, copy this plan, pin tools/core, record source availability, establish app/bridge/editor builds and CI, write the required ADRs below | Clean checkout resolves dependencies; exact core pin and compatibility target are recorded; no mobile-ready claim without execution |
| 1. Portability and editor proof | Implement and verify the upstream sandbox-path prerequisite; build core dependencies for both mobile platforms; implement a minimal real async bridge; run a minimal CodeMirror session on both devices | Device-created notebook can save/reopen; core errors reach Dart; IME/selection/undo work in the WebView; native-thread/callback design is exercised without Qt |
| 2. Offline notebook workflow | Notebook/folder/note operations, tags, core search, managed import/export, attachments, unsupported-content guards | Desktop-created fixture opens on mobile; mobile mutations reopen correctly on desktop; cancelled/failed imports do not publish partial notebooks |
| 3. Durable editor and preview | Versioned editor protocol, formatting actions, bounded autosave/recovery, source/preview compatibility, safe math/diagrams, theming/accessibility | Out-of-order save results cannot lose text; acknowledged saved content survives process kill; recovering drafts cannot overwrite newer content; malicious previews cannot access bridge/files/network |
| 4. WebDAV interoperability | Native credentials, bootstrap, foreground/manual scheduling, phased apply, conflicts, cancellation and recovery | Desktop-to-mobile-to-desktop round trip preserves identities, text and assets; concurrent dirty editing and interrupted sync preserve both recoverable versions |
| 5. Mobile integration and release readiness | Share-in/out, pickers, tablet layouts, localization, final accessibility/performance work, signing/store configuration and dependency notices | All first-release scenarios pass on both devices; clean CI builds APK/AAB and iOS app/archive configurations; owner-provided signing permits installable release builds; no hidden platform skips |

Phase 1 is a stop/go gate for technical assumptions, not permission to ship a reduced prototype. If a device/SDK/dependency prevents it, finish independent work and report the exact missing prerequisite; do not silently switch stacks or mark iOS done based on an Android run. Do not publish repositories, push upstream changes or submit store builds without the owner's authorization.

Required ADRs before the corresponding implementation:

1. Native packaging, dependency audit (including Android OpenSSL/curl and the Apple SDK libcurl assumption), SDK/deployment targets, and the upstream app/local-data path-override API required by section 5.3.
2. Core owner-thread/worker matrix, asynchronous FFI protocol, callback ownership, cancellation and shutdown.
3. Editor text/revision protocol, UTF conversion, durability acknowledgements and recovery policy.
4. Markdown compatibility subset, asset resolution and WebView trust boundaries.
5. WebDAV capabilities, state reconciliation, save/apply reservations, credentials and conflict UI.
6. Import/export and share-in transaction boundaries, platform storage and backup/privacy policy.

ADRs select one implementation, explain rejected alternatives and list observable acceptance cases. Do not turn open questions into placeholder production branches. The new app's own license and store identity remain explicit owner decisions before publication; the MIT license of `vxcore` does not relicense transitive dependencies or copied desktop code.

## 7. Verification contract

### Build and CI

- Build Android `arm64-v8a` for devices and the selected emulator ABI, normally `x86_64`; verify modern Android native-library packaging, including 16 KB page-size compatibility where required.
- Build iOS arm64 device and the selected simulator architecture(s) with a pinned compatible Xcode. Simulator-only success is insufficient. Set minimum OS versions from the audited Flutter/plugin/native dependency intersection and record the choice; comply with current store target-SDK requirements separately.
- Run Dart analysis/unit/widget tests, TypeScript editor/protocol/security tests, FFI ownership/error tests, and affected core tests. Keep tests deterministic and fixture-based; no production accounts or personal notebooks.
- Build bundled web assets before Flutter packaging, check binding/asset regeneration, initialize submodules recursively, and test a clean checkout rather than relying on a developer's build directory.
- Use the real core for boundary and interoperability tests. Mocks are allowed for isolated presentation tests, never as proof of storage/sync correctness.
- CI may use a controlled local WebDAV service. Real-device verification supplements simulator/emulator automation and is required before release.

### Mandatory behavioral cases

1. Desktop notebook -> mobile open/edit/save -> desktop reopen, preserving note/folder IDs, tags, asset references, unknown metadata and untouched bytes. Opening/previewing alone produces no content mutation.
2. Unicode names and text, emoji/surrogate pairs, combining marks, Chinese/Japanese IME composition, RTL text, CRLF/LF policy, fenced code, relative links, tables, math and diagrams.
3. Rapid typing while saves complete out of order, note switching, undo after save, WebView recreation and theme changes. A stale acknowledgement never marks newer edits clean.
4. Kill/restart immediately after durable save acknowledgement; kill during draft checkpoint, attachment import and sync. Recovery must be idempotent and must not overwrite a newer on-disk generation.
5. Disk full, permission denial, cache eviction, oversized note/resource, malformed notebook/archive, unsafe paths, attachment collisions and unavailable secure storage. Failures are actionable and leave existing data recoverable.
6. Concurrent desktop/mobile edits, dirty open buffer during incoming apply, rename/delete conflicts, binary conflicts, partial apply/refresh failures, network loss, expired credentials, certificate rejection, cancellation and repeated resume.
7. Sync disabled with orphan credentials; failed rotation; unsupported backend; notebook close/remove while work is queued; late callbacks after session retirement. No false 'Synced' state or leaked reservation.
8. Script/HTML/SVG injection, malicious links and diagrams, remote resource tracking, forged/stale bridge messages and path escape attempts. No note-controlled native command or arbitrary local-file read.
9. Share into a stopped app, duplicate incoming delivery, multiple attachments, revoked URI grants and failed inbox import. Acknowledged payloads remain recoverable and are consumed at most once.
10. VoiceOver/TalkBack, dynamic text, keyboard visibility/insets, hardware keyboards, rotation, tablet resizing and reduced motion on actual app surfaces.

Use representative fixtures: an ordinary notebook, a 10,000-note notebook, a 1 MiB Markdown note, a long single line and attachment-heavy content. Phase 1 records baseline devices and measured startup/open/input/save/search times; detailed design sets explicit budgets before optimization. The UI must not synchronously execute native disk/network work. Oversized workloads require an explicit safe limit or usable behavior, not an application crash or silent truncation. Do not publish timing claims from debug builds or fabricated measurements.

Never use personal notebooks for destructive/interruption tests. Keep desktop compatibility fixtures versioned and assert semantic/data outcomes rather than source text, wiring or mock echoes. Document every skipped platform/check and why; a skip is not a pass.

## 8. Agent working instructions

- Initialize only the new repository. This desktop repository is a read-only reference unless a separately scoped upstream change is necessary and authorized.
- Preserve the fixed stack and first-release boundaries. Ask only about material product changes, unreachable prerequisites, licenses/identities, destructive operations or external authorization; inspect source/configuration before asking technical questions that the repository can answer.
- Before each nontrivial slice, list exact affected paths, inspect existing contracts, state the verification plan and obtain an independent plan review. Review again after implementation and verification; resolve blockers before committing or advancing the gate. Reviewers must not concurrently edit or run duplicate builds/tests.
- Implement one end-to-end slice at a time; split independent work only after interfaces and ownership are explicit. Keep production code free of fake backends, silent fallbacks, temporary no-ops and unfinished placeholders.
- Keep shared core changes minimal, tested against desktop consumers, and separately committed in the upstream repository. Never hide patches in a build script or vendor an untracked fork.
- Update architecture/compatibility/verification documentation alongside changes. Record exact commands, revisions, results, device/OS versions and unresolved blockers. Do not claim mobile support from a host-only core build.
- Use small reviewable commits, exclude generated secrets/signing material and preserve unrelated work. Do not publish or push without authorization. New repository instructions must reflect its actual tooling rather than blindly copy desktop-only build rules.

### Copyable kickoff instruction

> Initialize a separate `vnote-mobile` repository from this plan. Keep Flutter/Riverpod, `vxcore` via Dart FFI, and CodeMirror 6 in `webview_flutter` as fixed choices. Treat the referenced VNote repository as read-only. Start with Phase 0 and the required detailed designs, verify the exact upstream core revision and dependencies, and then implement the real Phase 1 slice on both platforms. Continue through the numbered phases after their acceptance gates pass; do not stop at generated scaffolding. Preserve VNote notebook compatibility and the save/sync/security contracts. Report missing Mac/device/signing access precisely and complete independent reachable work without claiming blocked checks passed. Ask before changing product scope, publishing, or making destructive changes.

## 9. External reference material

- Flutter FFI and native build integration: <https://docs.flutter.dev/platform-integration/bind-native-code>
- Flutter platform WebView package: <https://pub.dev/packages/webview_flutter>
- Riverpod: <https://riverpod.dev/>
- CodeMirror and mobile editing support: <https://codemirror.net/>
- markdown-it: <https://github.com/markdown-it/markdown-it>
- DOMPurify: <https://github.com/cure53/DOMPurify>
- KaTeX: <https://katex.org/>
- Mermaid: <https://mermaid.js.org/>
- Core source: <https://github.com/vnotex/vxcore>

These are integration references, not a license/security audit or proof that their latest releases are mutually compatible. Pin and verify the chosen dependency set in Phase 0/1.
