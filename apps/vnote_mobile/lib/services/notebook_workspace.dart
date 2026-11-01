// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'editor_session.dart';
import 'notebook_session.dart';

typedef OpenCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String? expectedNotebookId,
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
  });

  final bool applied;
  final String? nodeId;
  final String? error;
  final String? refreshError;
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
  });

  final CoreDirectory? directory;
  final NotebookSession? session;
  final bool busy;
  final bool stale;
  final bool closed;
  final String? error;
  final NotebookMutationResult? mutation;

  bool get canBrowse => !busy && !closed && session == null;
  bool get canMutate => canBrowse && directory != null && !stale;
}

/// The sole owner of the managed notebook: catalog OR selected-note session.
/// Every factory call after discovery is pinned to the observed notebook UUID.
class NotebookWorkspace extends ValueNotifier<NotebookWorkspaceState> {
  NotebookWorkspace({
    Future<ManagedNotebookPaths> Function()? obtainPaths,
    OpenCatalog? openCatalog,
    OpenNote? openNote,
  }) : _obtainPaths = obtainPaths ?? ManagedNotebookPaths.obtain,
       _openCatalog = openCatalog ?? _managedCatalog,
       _openNote = openNote ?? _managedNote,
       super(const NotebookWorkspaceState());

  final Future<ManagedNotebookPaths> Function() _obtainPaths;
  final OpenCatalog _openCatalog;
  final OpenNote _openNote;
  ManagedNotebookPaths? _paths;
  CatalogCore? _catalog;
  NotebookSession? _session;
  CoreDirectory? _directory;
  String? _notebookId;
  String? _folderId;
  String? _error;
  NotebookMutationResult? _mutation;
  bool _stale = true;
  bool _shuttingDown = false;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void>? _shutdownFuture;
  Completer<void>? _active;

  String get nativeNotices =>
      _catalog?.nativeNotices ?? _session?.nativeNotices ?? '';

  Future<void> initialize() =>
      _shuttingDown ? Future<void>.value() : _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!_admit()) return;
    try {
      await _openBrowser();
    } on Object catch (error) {
      _browserError(error);
    } finally {
      _retire();
    }
  }

  Future<void> _openBrowser() async {
    if (_session != null) throw StateError('The selected note is still open.');
    _paths ??= await _obtainPaths();
    if (_shuttingDown) return;
    if (_catalog == null) {
      final catalog = await _openCatalog(_paths!, _notebookId);
      _catalog = catalog;
      if (_shuttingDown) return;
      final root = catalog.initialDirectory;
      if (_notebookId != null && _notebookId != root.notebookId) {
        throw StateError(
          'The managed notebook identity changed. It was not recreated.',
        );
      }
      _notebookId ??= root.notebookId;
      if (_folderId == null || _folderId == root.folderId) {
        _accept(root);
        return;
      }
    }
    _accept(await _catalog!.list(_folderId));
  }

  Future<bool> refresh() async {
    if (_session != null || !_admit()) return false;
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
    if (entry.isFolder || !_currentEntry(entry) || !_admit()) return false;
    try {
      // Never relinquish the owner reference until its asynchronous join ends.
      await _catalog!.close();
      _catalog = null;
      if (_shuttingDown) return false;
      final session = NotebookSession(
        openCore: () => _openNote(_paths!, _notebookId!, entry.id),
      );
      _session = session;
      await session.initialize();
      if (_shuttingDown) return false;
      if (session.value.editor == null) {
        final openError =
            session.value.error ?? 'The selected note could not open.';
        await session.shutdown();
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
      _retire();
    }
  }

  Future<bool> returnToBrowser(
    NotebookSession session,
    NotebookDisposition disposition,
    EditorSend send,
  ) async {
    if (!identical(_session, session) ||
        disposition == NotebookDisposition.cancel ||
        !_admit()) {
      return false;
    }
    try {
      if (!await session.close(disposition, send) || _shuttingDown) {
        return false;
      }
      await session.shutdown();
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
      _retire();
    }
  }

  Future<NotebookMutationResult?> createNote(String name) => _mutate(
    (catalog, directory) => catalog.createNote(directory.folderId, name),
  );

  Future<NotebookMutationResult?> createFolder(String name) => _mutate(
    (catalog, directory) => catalog.createFolder(directory.folderId, name),
  );

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
    Future<String> Function(CatalogCore, CoreDirectory) operation, {
    CoreEntry? entry,
  }) async {
    if (!value.canMutate ||
        _catalog == null ||
        (entry != null && !_currentEntry(entry)) ||
        !_admit()) {
      return null;
    }
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

  void _checkIdentity(CoreDirectory directory) {
    if (directory.notebookId != _notebookId) {
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

  bool _admit() {
    if (_shuttingDown || _active != null) return false;
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
      busy: _active != null,
      stale: _stale,
      error: _error,
      mutation: _mutation,
    );
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _shuttingDown = true;
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
    await _session?.shutdown();
    await _initialization;
    await _active?.future;
    await _session?.shutdown();
    _session?.dispose();
    _session = null;
    await _catalog?.close();
    _catalog = null;
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
    String? expectedNotebookId,
  ) => CoreNotebook.openCatalog(
    appDataPath: paths.app,
    localDataPath: paths.local,
    notebookPath: paths.notebook,
    notebookName: 'Personal',
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
