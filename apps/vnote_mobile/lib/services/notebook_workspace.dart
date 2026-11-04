// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';
import 'package:path/path.dart' as p;

import 'editor_session.dart';
import 'editor_drafts.dart';
import 'managed_notebook_storage.dart';
import 'notebook_session.dart';
import 'notebook_sync.dart';
import 'sync_credentials.dart';

typedef OpenCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String expectedNotebookId,
);
typedef OpenNote = Future<NotebookCore> Function(
  ManagedNotebookPaths paths,
  String notebookId,
  String nodeId,
);

@immutable
class NotebookMutationResult {
  const NotebookMutationResult({
    required this.applied,
    this.nodeId,
    this.error,
    this.refreshError,
    this.tags,
  });

  final bool applied;
  final String? nodeId;
  final String? error;
  final String? refreshError;
  final CoreTags? tags;
}

@immutable
class NotebookWorkspaceState {
  const NotebookWorkspaceState({
    this.directory,
    this.session,
    this.busy = false,
    this.stale = true,
    this.closed = false,
    this.error,
    this.mutation,
    this.search,
    this.searching = false,
    this.searchCancelled = false,
    this.searchError,
    this.syncBusy = false,
    this.syncRecoveryRequired = false,
  });

  final CoreDirectory? directory;
  final NotebookSession? session;
  final bool busy;
  final bool stale;
  final bool closed;
  final String? error;
  final NotebookMutationResult? mutation;
  final CoreSearchResult? search;
  final bool searching;
  final bool searchCancelled;
  final String? searchError;
  final bool syncBusy;
  final bool syncRecoveryRequired;

  bool get canBrowse => !busy && !syncBusy && !closed && session == null;
  bool get canMutate => canBrowse && directory != null && !stale && !syncRecoveryRequired;
}

/// Owns one selected notebook: catalog OR selected-note session.
/// Every factory call is pinned to the identity observed by the library.
class NotebookWorkspace extends ValueNotifier<NotebookWorkspaceState> {
  NotebookWorkspace({
    required this._paths,
    required this._notebookId,
    OpenCatalog? openCatalog,
    OpenNote? openNote,
    this._drafts,
  }) : _openCatalog = openCatalog ?? _managedCatalog,
       _openNote = openNote ?? _managedNote,
       super(const NotebookWorkspaceState());

  final ManagedNotebookPaths _paths;
  final String _notebookId;
  final OpenCatalog _openCatalog;
  final OpenNote _openNote;
  EditorDrafts? _drafts;
  SyncCredentials? _syncCredentials;
  NotebookSync? _sync;
  SyncCore? _syncNative;
  _WorkspaceSyncParticipant? _syncParticipant;
  _WorkspaceSyncReservation? _syncReservation;
  Future<void>? _syncAttaching;
  Future<void>? _syncDetaching;
  bool _syncRecoveryRequired = false;
  bool _externalTransferBusy = false;
  bool _ownerTransition = false;
  bool _foreground = true;
  CatalogCore? _catalog;
  NotebookSession? _session;
  String? _previewFragment;
  CoreDirectory? _directory;
  String? _folderId;
  String? _error;
  NotebookMutationResult? _mutation;
  CoreSearchResult? _search;
  CoreTags? _tags;
  CoreEntry? _tagEntry;
  int _searchGeneration = 0;
  bool _searching = false;
  bool _searchCancelled = false;
  String? _searchError;
  String? _transferBlock;
  bool _stale = true;
  bool _shuttingDown = false;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void>? _shutdownFuture;
  Completer<void>? _active;
  Completer<void>? _inboxBarrier;

  String get nativeNotices =>
      _catalog?.nativeNotices ?? _session?.nativeNotices ?? '';

  String get notebookId => _notebookId;
  String get notebookLocation => _paths.notebook;

  void attachDrafts(EditorDrafts drafts) {
    if (_initialization != null || _session != null) {
      throw StateError('Attach private draft storage before opening the workspace.');
    }
    _drafts = drafts;
  }

  NotebookSync get synchronization {
    final existing = _sync;
    if (existing != null) return existing;
    final created = NotebookSync(notebookId: _notebookId, credentials: _syncCredentials);
    _sync = created;
    created.addListener(_syncChanged);
    created.setForeground(_foreground && _inboxBarrier == null);
    return created;
  }

  void attachSyncCredentials(SyncCredentials credentials) {
    if (_initialization != null || _sync != null) {
      throw StateError('Attach synchronization credentials before opening the workspace.');
    }
    _syncCredentials = credentials;
  }

  void setForeground(bool foreground) {
    _foreground = foreground && _inboxBarrier == null;
    _sync?.setForeground(_foreground);
    _session?.setForeground(_foreground);
    if (_foreground) unawaited(_attachCurrentSyncOwner());
  }

  /// Library owns this exclusion across inbox scan and quarantine publication.
  /// Admission closes synchronously; the future joins all previously admitted
  /// catalog/session owners and retires sync before reconciliation may inspect.
  Future<void> beginInboxBarrier() {
    final existing = _inboxBarrier;
    if (existing != null) return existing.future;
    final barrier = Completer<void>();
    _inboxBarrier = barrier;
    _foreground = false;
    final sessionBarrier = _session?.beginInboxBarrier();
    _sync?.setForeground(false);
    _publish();
    unawaited(_joinInboxOwners(sessionBarrier).then(barrier.complete, onError: barrier.completeError));
    return barrier.future;
  }

  Future<void> _joinInboxOwners(Future<void>? sessionBarrier) async {
    await Future.wait<void>([
      _detachSync(),
      if (_active != null) _active!.future,
      ?sessionBarrier,
    ]);
    // An admitted catalog->NOTE transition may have installed a new session.
    await _session?.beginInboxBarrier();
  }

  /// Parent passes true only for the still-current resumed lifecycle epoch.
  /// Transfer quarantine is independent and survives this transient release.
  void endInboxBarrier({required bool foreground}) {
    final barrier = _inboxBarrier;
    if (barrier == null) return;
    if (!barrier.isCompleted) throw StateError('Join inbox owners before releasing the barrier.');
    _inboxBarrier = null;
    _foreground = foreground;
    _session?.endInboxBarrier(foreground: foreground);
    _sync?.setForeground(foreground);
    _publish();
    if (foreground) unawaited(_attachCurrentSyncOwner());
  }

  void setExternalTransferBusy(bool busy) {
    if (_externalTransferBusy == busy) return;
    _externalTransferBusy = busy;
    _publish();
  }

  void _syncChanged() {
    final state = _sync?.value;
    _session?.setSyncActivity(busy: state?.busy ?? false,
      allowsLocalWrites: state?.allowsLocalWrites ?? true);
    _publish();
  }

  void _sessionChanged() {
    // The editor listens to its own session. Publishing every source change here
    // can rebuild an ancestor while its editor surface is being initialized.
    if (!_ownerTransition && _active == null) unawaited(_attachCurrentSyncOwner());
  }

  Future<void> _attachCurrentSyncOwner() {
    if (_shuttingDown || !_foreground || _inboxBarrier != null || _ownerTransition || _active != null) return Future.value();
    final note = _session;
    if (note != null && (note.value.editor?.value.ready != true || note.value.closed)) return Future.value();
    final core = note?.synchronizationCore ?? _catalog;
    if (core == null || identical(_syncNative, core)) return _syncAttaching ?? Future.value();
    final current = _syncAttaching;
    if (current != null) return current;
    final settled = Completer<void>();
    _syncAttaching = settled.future;
    _syncNative = core;
    final participant = _WorkspaceSyncParticipant(this, core, note);
    _syncParticipant = participant;
    _publish();
    unawaited(() async {
      try { await synchronization.attach(core: core, participant: participant); }
      on Object {
        _syncRecoveryRequired = true;
        _error = 'Synchronization readiness could not be established. Use Sync recovery before changing this notebook.';
      } finally {
        _syncAttaching = null;
        settled.complete();
        _syncChanged();
      }
    }());
    return settled.future;
  }

  /// Joins readiness already in progress for this owner, not a queued/manual
  /// synchronization. Resource callers must recheck their owner and admission
  /// after this join; it grants no reservation and never writes editor source.
  Future<void> settleSyncAttachment() => _syncAttaching ?? Future<void>.value();

  Future<void> _detachSync() {
    final pending = _syncDetaching;
    if (pending != null) return pending;
    final settled = Completer<void>();
    _syncDetaching = settled.future;
    unawaited(() async {
      try {
        await _sync?.detach();
        await _syncAttaching;
        _syncNative = null; _syncParticipant = null;
      } on Object {
        _syncRecoveryRequired = true;
        _error = 'Synchronization retirement needs recovery. Native close still drains its work.';
      } finally {
        _syncDetaching = null;
        settled.complete();
        _syncChanged();
      }
    }());
    return settled.future;
  }

  Future<bool> openRecovered(String nodeId, Map<String, Object?> checkpoint) =>
      _openNode(nodeId, restored: checkpoint);

  /// Preview targets are stable native IDs, not note-controlled paths.
  Future<bool> openPreviewTarget(String nodeId, {String? fragment}) =>
      _openNode(nodeId, previewFragment: fragment);

  String? takePreviewFragment(NotebookSession session) {
    if (!identical(session, _session)) return null;
    final fragment = _previewFragment;
    _previewFragment = null;
    return fragment;
  }

  /// Unresolved ownership prevents native reopen/mutations. Library return
  /// remains available so a recovery owner can reconcile the pinned target.
  void setTransferBlock(String? message) {
    if (_transferBlock == message) return;
    _transferBlock = message;
    _session?.setResourceBlock(message);
    _publish();
  }

  Future<void> initialize() =>
      _shuttingDown || _inboxBarrier != null ? Future<void>.value() : _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!_admit()) return;
    try {
      await _openBrowser();
    } on Object catch (error) {
      _browserError(error);
    } finally {
      _retire();
      await _attachCurrentSyncOwner();
    }
  }

  Future<void> _openBrowser() async {
    if (_transferBlock != null) throw StateError(_transferBlock!);
    if (_session != null) throw StateError('The selected note is still open.');
    if (_shuttingDown) return;
    if (_catalog == null) {
      final catalog = await _openCatalog(_paths, _notebookId);
      _catalog = catalog;
      if (_shuttingDown) return;
      final root = catalog.initialDirectory;
      if (_notebookId != root.notebookId) {
        throw StateError(
          'The managed notebook identity changed. It was not recreated.',
        );
      }
      if (_folderId == null || _folderId == root.folderId) {
        _accept(root);
        return;
      }
    }
    _accept(await _catalog!.list(_folderId));
  }

  Future<bool> refresh() async {
    if (_session != null || !_admit()) return false;
    _invalidateSnapshots();
    try {
      await _openBrowser();
      return !_shuttingDown;
    } on Object catch (error) {
      _browserError(error);
      return false;
    } finally {
      _retire();
    }
  }

  Future<bool> navigate(String? folderId) async {
    if (_session != null || !_admit()) return false;
    _invalidateSnapshots();
    try {
      // A failed return-to-folder can still recover to root without forgetting
      // the expected notebook identity or manufacturing a replacement notebook.
      if (_catalog == null) {
        _folderId = folderId;
        await _openBrowser();
      } else {
        _accept(await _catalog!.list(folderId));
      }
      return !_shuttingDown;
    } on Object catch (error) {
      _browserError(error);
      return false;
    } finally {
      _retire();
    }
  }

  Future<bool> search(
    String text, {
    String? tag,
    bool caseSensitive = false,
  }) async {
    if (!value.canMutate || _catalog == null || !_admit()) return false;
    _invalidateSearch();
    final generation = _searchGeneration;
    _searching = true;
    _publish();
    try {
      if (text.isEmpty && (tag == null || tag.isEmpty)) {
        throw StateError('Enter search text or choose a tag.');
      }
      final result = await _catalog!.search(
        text,
        tag: tag,
        caseSensitive: caseSensitive,
      );
      if (_shuttingDown || generation != _searchGeneration) return false;
      _checkNotebookIdentity(result.notebookId);
      _search = result;
      return true;
    } on Object catch (error) {
      if (!_shuttingDown && generation == _searchGeneration) {
        _searchError = describeError(error);
      }
      return false;
    } finally {
      _searching = false;
      _retire();
    }
  }

  /// Query edits invalidate tokens immediately, even while native work drains.
  void clearSearch() {
    _invalidateSearch();
    _publish();
  }

  void cancelSearch() {
    if (!_searching || _searchCancelled) return;
    _invalidateSearch();
    _searchCancelled = true;
    _publish();
  }

  void _invalidateSearch() {
    if (_searching) _catalog?.cancelSearch();
    _searchGeneration++;
    _search = null;
    _searchError = null;
    _searchCancelled = false;
  }

  void _invalidateSnapshots() {
    _invalidateSearch();
    _tags = null;
    _tagEntry = null;
    _publish();
  }

  Future<CoreTags> loadTags([CoreEntry? entry]) async {
    if (!value.canMutate ||
        _catalog == null ||
        (entry != null && (entry.isFolder || !_currentEntry(entry))) ||
        !_admit()) {
      throw StateError('Refresh the notebook before loading tags.');
    }
    _tags = null;
    _tagEntry = null;
    try {
      final result = await _catalog!.tags(entry?.id);
      if (_shuttingDown) throw StateError('The notebook is closing.');
      _checkNotebookIdentity(result.notebookId);
      _tags = result;
      _tagEntry = entry;
      return result;
    } finally {
      _retire();
    }
  }

  Future<NotebookMutationResult?> createTag(
    CoreEntry entry,
    CoreTags snapshot,
    String name,
  ) => _mutateTags(entry, snapshot, (catalog) => catalog.createTag(name));

  Future<NotebookMutationResult?> setTags(
    CoreEntry entry,
    CoreTags snapshot,
    List<String> assigned,
  ) => _mutateTags(
    entry,
    snapshot,
    (catalog) => catalog.setTags(entry.id, List<String>.of(assigned)),
  );

  Future<NotebookMutationResult?> _mutateTags(
    CoreEntry entry,
    CoreTags snapshot,
    Future<void> Function(CatalogCore) operation,
  ) async {
    if (entry.isFolder ||
        !_currentEntry(entry) ||
        !identical(_tagEntry, entry) ||
        !identical(_tags, snapshot) ||
        snapshot.notebookId != _notebookId ||
        !_admit()) {
      return null;
    }
    _invalidateSnapshots();
    var applied = false;
    String? operationError;
    String? refreshError;
    CoreTags? refreshed;
    try {
      try {
        await operation(_catalog!);
        applied = true;
      } on Object catch (error) {
        operationError = describeError(error);
      }
      // Do not cancel writes. Refresh complete assignments even after an error
      // or during shutdown, which joins this entire admitted operation.
      try {
        final result = await _catalog!.tags(entry.id);
        _checkNotebookIdentity(result.notebookId);
        refreshed = result;
        if (!_shuttingDown) {
          _tags = result;
          _tagEntry = entry;
        }
      } on Object catch (error) {
        refreshError = describeError(error);
      }
      return NotebookMutationResult(
        applied: applied,
        nodeId: entry.id,
        error: operationError,
        refreshError: refreshError,
        tags: refreshed,
      );
    } finally {
      _retire();
    }
  }

  /// Lists an actual destination without changing the browser's current folder.
  Future<CoreDirectory> listDestination([String? folderId]) async {
    if (!value.canMutate || _catalog == null || !_admit()) {
      throw StateError('Refresh the notebook before choosing a destination.');
    }
    try {
      final result = await _catalog!.list(folderId);
      if (_shuttingDown) throw StateError('The notebook is closing.');
      _checkIdentity(result);
      return result;
    } finally {
      _retire();
    }
  }

  Future<bool> openNote(CoreEntry entry) async {
    if (entry.isFolder || !_currentEntry(entry)) return false;
    return _openNode(entry.id);
  }

  Future<bool> openSearchHit(CoreSearchResult result, CoreSearchHit hit) async {
    if (!value.canMutate ||
        !identical(_search, result) ||
        result.notebookId != _notebookId ||
        !result.matches.any((current) => identical(current, hit))) {
      return false;
    }
    return _openNode(hit.id);
  }

  Future<bool> _openNode(String nodeId, {Map<String, Object?>? restored, String? previewFragment}) async {
    if (_catalog == null || !_admit()) return false;
    _invalidateSnapshots();
    try {
      final drafts = _drafts;
      if (drafts == null || !drafts.value.initialized) {
        throw StateError('Private draft recovery must finish before opening a note.');
      }
      // Never relinquish the owner reference until its asynchronous join ends.
      _ownerTransition = true;
      await _detachSync();
      await _catalog!.close();
      _catalog = null;
      if (_shuttingDown) return false;
      _previewFragment = previewFragment;
      final session = NotebookSession(
        openCore: () async {
          final core = await _openNote(_paths, _notebookId, nodeId);
          if (_shuttingDown) {
            await core.close();
            throw StateError('The workspace closed while the note was opening.');
          }
          return core;
        },
        drafts: drafts,
        notebookRelative: p.basename(_paths.notebook),
        restored: restored,
        beforeCoreClose: _detachSync,
        onCoreChanged: _sessionChanged,
        onLocalSaved: () => _sync?.localSaved(),
      );
      _session = session;
      session.addListener(_sessionChanged);
      session.setResourceBlock(_transferBlock);
      session.setForeground(_foreground && _inboxBarrier == null);
      final initializing = session.initialize();
      if (_inboxBarrier != null) await session.beginInboxBarrier();
      await initializing;
      if (_shuttingDown) return false;
      if (session.value.editor == null) {
        final openError =
            session.value.error ?? 'The selected note could not open.';
        await session.shutdown();
        session.removeListener(_sessionChanged);
        _session = null;
        session.dispose();
        try {
          await _openBrowser();
          _error = openError;
        } on Object catch (error) {
          _browserError(error);
          _error = '$openError\nBrowser restore failed: $_error';
        }
        return false;
      }
      return true;
    } on Object catch (error) {
      _browserError(error);
      return false;
    } finally {
      _ownerTransition = false;
      _retire();
      await _attachCurrentSyncOwner();
    }
  }

  Future<bool> returnToBrowser(
    NotebookSession session,
    NotebookDisposition disposition,
    EditorSend send,
  ) async {
    if (!identical(_session, session) ||
        disposition == NotebookDisposition.cancel ||
        !_admit(ownerTransition: true)) {
      return false;
    }
    try {
      if (!await session.close(disposition, send) || _shuttingDown) {
        return false;
      }
      await session.shutdown();
      session.removeListener(_sessionChanged);
      _session = null;
      session.dispose();
      if (_shuttingDown) return false;
      try {
        await _openBrowser();
      } on Object catch (error) {
        _browserError(error);
      }
      // The note is closed even when restoring the directory fails. The
      // browser retains its truthful stale snapshot and offers Refresh / Root.
      return true;
    } finally {
      _ownerTransition = false;
      _retire();
      await _attachCurrentSyncOwner();
    }
  }

  Future<NotebookMutationResult?> createNote(String name) => _mutate(
    (catalog, directory) => catalog.createNote(directory.folderId, name),
  );

  Future<NotebookMutationResult?> createFolder(String name) => _mutate(
    (catalog, directory) => catalog.createFolder(directory.folderId, name),
  );

  Future<NotebookMutationResult?> renameNotebook(String name) =>
      _mutate((catalog, _) async {
        await catalog.renameNotebook(name);
        return null;
      });

  Future<NotebookMutationResult?> rename(CoreEntry entry, String name) =>
      _mutate((catalog, _) async {
        await catalog.rename(entry.id, name);
        return entry.id;
      }, entry: entry);

  Future<NotebookMutationResult?> move(
    CoreEntry entry,
    String destinationFolderId,
  ) => _mutate((catalog, _) async {
    await catalog.move(entry.id, destinationFolderId);
    return entry.id;
  }, entry: entry);

  Future<NotebookMutationResult?> delete(CoreEntry entry) =>
      _mutate((catalog, _) async {
        await catalog.delete(entry.id);
        return entry.id;
      }, entry: entry);

  Future<NotebookMutationResult?> _mutate(
    Future<String?> Function(CatalogCore, CoreDirectory) operation, {
    CoreEntry? entry,
  }) async {
    if (!value.canMutate ||
        _catalog == null ||
        (entry != null && !_currentEntry(entry)) ||
        !_admit()) {
      return null;
    }
    _invalidateSnapshots();
    final directory = _directory!;
    var applied = false;
    String? nodeId;
    String? operationError;
    String? refreshError;
    try {
      try {
        nodeId = await operation(_catalog!, directory);
        applied = true;
      } on Object catch (error) {
        operationError = describeError(error);
      }
      // Core operations can partially apply before returning an error. Always
      // refresh, even during shutdown; shutdown waits for this admitted work.
      try {
        _accept(await _catalog!.list(directory.folderId));
      } on Object catch (error) {
        _stale = true;
        refreshError = describeError(error);
      }
      final result = NotebookMutationResult(
        applied: applied,
        nodeId: nodeId,
        error: operationError,
        refreshError: refreshError,
      );
      _mutation = result;
      return result;
    } finally {
      _retire();
    }
  }

  bool _currentEntry(CoreEntry entry) =>
      value.canMutate &&
      _catalog != null &&
      _directory!.entries.any((current) => identical(current, entry));

  void _checkIdentity(CoreDirectory directory) =>
      _checkNotebookIdentity(directory.notebookId);

  void _checkNotebookIdentity(String notebookId) {
    if (notebookId != _notebookId) {
      throw StateError(
        'The managed notebook identity changed. Refresh was refused.',
      );
    }
  }

  void _accept(CoreDirectory directory) {
    _checkIdentity(directory);
    if (_shuttingDown) return;
    _directory = directory;
    _folderId = directory.folderId;
    _stale = false;
  }

  void _browserError(Object error) {
    _error = describeError(error);
    _stale = true;
  }

  bool _admit({bool ownerTransition = false}) {
    if (_shuttingDown || _inboxBarrier != null || _active != null || _ownerTransition ||
        (!ownerTransition && (_transferBlock != null || _syncReservation != null || _syncAttaching != null ||
            (_sync?.value.busy ?? false)))) { return false; }
    _ownerTransition = ownerTransition;
    _active = Completer<void>();
    _error = null;
    _mutation = null;
    _publish();
    return true;
  }

  void _retire() {
    final active = _active;
    _active = null;
    _publish();
    active?.complete();
  }

  void _publish() {
    if (_disposed || _shuttingDown) return;
    value = NotebookWorkspaceState(
      directory: _directory,
      session: _session,
      busy: _active != null || _inboxBarrier != null,
      stale: _stale || _transferBlock != null || _syncRecoveryRequired ||
          (_sync?.value.facts?.refreshRequired ?? false),
      error: _transferBlock ?? _error,
      mutation: _mutation,
      search: _search,
      searching: _searching,
      searchCancelled: _searchCancelled,
      searchError: _searchError,
      syncBusy: _syncAttaching != null || (_sync?.value.busy ?? false),
      syncRecoveryRequired: _syncRecoveryRequired || (_sync?.value.facts?.refreshRequired ?? false),
    );
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _shuttingDown = true;
    _invalidateSnapshots();
    if (!_disposed) {
      value = NotebookWorkspaceState(
        directory: _directory,
        session: value.session,
        closed: true,
        stale: true,
      );
    }
    // Stop pending editor barriers before waiting for a workspace transition
    // that may itself be waiting on one. Native writes still drain normally.
    await _sync?.close();
    await _syncAttaching;
    await _session?.shutdown();
    await _initialization;
    await _active?.future;
    await _session?.shutdown();
    _session?.removeListener(_sessionChanged);
    _session?.dispose();
    _session = null;
    await _catalog?.close();
    _catalog = null;
    _sync?.removeListener(_syncChanged);
    _sync?.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(shutdown().catchError((Object _) {}));
    _disposed = true;
    super.dispose();
  }

  static String describeError(Object error) => error is CoreException
      ? 'Core error ${error.code}: ${error.message}'
      : error is StateError
      ? error.message.toString()
      : error.toString();

  static Future<CatalogCore> _managedCatalog(
    ManagedNotebookPaths paths,
    String expectedNotebookId,
  ) => CoreNotebook.openCatalog(
    appDataPath: paths.app,
    localDataPath: paths.local,
    notebookPath: paths.notebook,
    expectedNotebookId: expectedNotebookId,
  );

  static Future<NotebookCore> _managedNote(
    ManagedNotebookPaths paths,
    String notebookId,
    String nodeId,
  ) => CoreNotebook.openNote(
    appDataPath: paths.app,
    localDataPath: paths.local,
    notebookPath: paths.notebook,
    notebookId: notebookId,
    nodeId: nodeId,
  );
}


class _WorkspaceSyncParticipant implements NotebookSyncParticipant {
  _WorkspaceSyncParticipant(this.workspace, this.core, this.session);
  final NotebookWorkspace workspace;
  final SyncCore core;
  final NotebookSession? session;
  bool get current => identical(workspace._syncParticipant, this) &&
      identical(workspace._syncNative, core) && identical(workspace._session, session);

  @override
  NotebookSyncReservation installSyncReservation(SyncReservationRequest request) {
    if (!current || workspace._shuttingDown || workspace._inboxBarrier != null || workspace._ownerTransition ||
        workspace._syncReservation != null || workspace._transferBlock != null ||
        workspace._externalTransferBusy) {
      throw StateError('Finish the current notebook/transfer ownership before synchronization.');
    }
    final reservation = _WorkspaceSyncReservation(this, request, workspace._active?.future);
    workspace._syncReservation = reservation;
    try { reservation.noteReservation = session?.installSyncReservation(request); }
    on Object { workspace._syncReservation = null; rethrow; }
    workspace._publish();
    return reservation;
  }

  @override
  Future<bool> recoverSyncSources() async {
    if (!current) return false;
    if (session != null) {
      final safe = await session!.recoverSyncSources();
      if (safe && current) { workspace._syncRecoveryRequired = false; workspace._publish(); }
      return safe;
    }
    try {
      final catalog = workspace._catalog;
      if (catalog == null || !identical(catalog, core)) return false;
      final directory = await catalog.list();
      if (!current) return false;
      workspace._accept(directory);
      workspace._syncRecoveryRequired = false;
      workspace._publish();
      return true;
    } on Object { return false; }
  }
}

class _WorkspaceSyncReservation implements NotebookSyncReservation {
  _WorkspaceSyncReservation(this.participant, this.request, this.previousWriter);
  final _WorkspaceSyncParticipant participant;
  final SyncReservationRequest request;
  final Future<void>? previousWriter;
  NotebookSyncReservation? noteReservation;
  bool _retired = false;
  bool _cancelled = false;
  Future<bool>? _aborting;
  NotebookWorkspace get workspace => participant.workspace;
  bool get _owns => !_retired && participant.current && identical(workspace._syncReservation, this);
  void _check() {
    if (!_owns || _cancelled) throw StateError('The synchronization owner changed.');
  }

  @override
  Future<void> drainWriters() async {
    _check();
    await previousWriter;
    await noteReservation?.drainWriters();
    _check();
  }

  @override
  Future<SyncProtection> quiesceAndDrainDrafts() async {
    await drainWriters();
    final source = await noteReservation?.quiesceAndDrainDrafts();
    _check();
    final ids = <String>{...?source?.dirtyNodeIds};
    var known = source?.ownershipKnown ?? true;
    final drafts = workspace._drafts;
    if (drafts != null) {
      await drafts.scan(); _check();
      for (final entry in drafts.value.entries.where((entry) => !entry.resolved)) {
        if (entry.notebookId == null) { known = false; continue; }
        if (entry.notebookId != workspace.notebookId) continue;
        final id = entry.nodeId;
        if (entry.quarantined || id == null) { known = false; }
        else { ids.add(id); }
      }
    }
    return SyncProtection(dirtyNodeIds: ids.toList(), ownershipKnown: known);
  }

  void _release() {
    if (!identical(workspace._syncReservation, this)) return;
    workspace._syncReservation = null; _retired = true;
    workspace._publish();
  }

  @override
  Future<SyncSettlement> settle(SyncRefreshReport? report) async {
    try {
      _check();
      final note = noteReservation;
      if (note != null) {
        final result = await note.settle(report);
        if (!result.safe) { retainRecovery('Source synchronization recovery remains required.'); return result; }
      } else if (report != null) {
        if (!report.metadataRefreshed || report.changedPaths == null) {
          retainRecovery('Synchronization metadata needs an explicit refresh.');
          return const SyncSettlement(safe: false, recoveryRequired: true);
        }
        final catalog = workspace._catalog;
        if (catalog == null || !identical(catalog, participant.core)) throw StateError('Catalog retired.');
        CoreDirectory actual;
        try { actual = await catalog.list(workspace._folderId); }
        on CoreException { actual = await catalog.list(); }
        _check();
        workspace._accept(actual); workspace._invalidateSnapshots();
      }
      _release();
      return const SyncSettlement(safe: true);
    } on Object {
      retainRecovery('Synchronization refresh could not establish current notebook state.');
      return const SyncSettlement(safe: false, recoveryRequired: true);
    }
  }

  @override
  Future<bool> abort() => _aborting ??= _abort();
  Future<bool> _abort() async {
    if (!_owns) return _retired;
    _cancelled = true;
    var safe = true;
    try { safe = await noteReservation?.abort() ?? true; } on Object { safe = false; }
    try { await previousWriter; } on Object { safe = false; }
    if (!_owns) return _retired;
    if (safe) { _release(); } else { retainRecovery('Synchronization cancellation needs source recovery.'); }
    return safe;
  }

  @override
  void retainRecovery(String code) {
    if (!_owns) return;
    noteReservation?.retainRecovery(code);
    workspace._syncRecoveryRequired = true;
    workspace._syncReservation = null; _retired = true;
    workspace._publish();
  }
}
