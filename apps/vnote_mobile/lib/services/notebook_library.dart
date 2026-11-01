// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'managed_notebook_storage.dart';
import 'notebook_export.dart';
import 'notebook_workspace.dart';

typedef LibraryOpenCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String? expectedNotebookId,
);
typedef LibraryOpenExportCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String notebookId,
);
typedef LibraryCreateExporter = NotebookExporter Function(String root);
typedef LibraryCreateCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String name,
);
typedef LibraryWorkspaceFactory = NotebookWorkspace Function(
  ManagedNotebookPaths paths,
  String notebookId,
);

@immutable
class ManagedNotebookEntry {
  const ManagedNotebookEntry({
    required this.location,
    required this.name,
    this.notebookId,
    this.error,
  });
  final String location;
  final String name;
  final String? notebookId;
  final String? error;
  bool get canOpen => notebookId != null && error == null;
}

@immutable
class NotebookLibraryState {
  const NotebookLibraryState({
    this.entries = const [],
    this.workspace,
    this.busy = false,
    this.stale = true,
    this.closed = false,
    this.error,
    this.exportState = const NotebookExportState(),
  });
  final NotebookExportState exportState;
  final List<ManagedNotebookEntry> entries;
  final NotebookWorkspace? workspace;
  final bool busy;
  final bool stale;
  final bool closed;
  final String? error;
}

/// One discovery/create owner OR one selected workspace, never both.
class NotebookLibrary extends ValueNotifier<NotebookLibraryState> {
  NotebookLibrary({
    Future<ManagedNotebookStorage> Function()? obtainStorage,
    LibraryOpenCatalog? openCatalog,
    LibraryCreateCatalog? createCatalog,
    LibraryWorkspaceFactory? createWorkspace,
    LibraryOpenExportCatalog? openExportCatalog,
    LibraryCreateExporter? createExporter,
  }) : _obtainStorage = obtainStorage ?? ManagedNotebookStorage.obtain,
       _openCatalog = openCatalog ?? _open,
       _createCatalog = createCatalog ?? _create,
       _createWorkspace = createWorkspace ?? _workspaceFor,
       _openExportCatalog = openExportCatalog ?? _openExport,
       _createExporter = createExporter ?? _exporterFor,
       super(const NotebookLibraryState());

  final Future<ManagedNotebookStorage> Function() _obtainStorage;
  final LibraryOpenCatalog _openCatalog;
  final LibraryCreateCatalog _createCatalog;
  final LibraryWorkspaceFactory _createWorkspace;
  final LibraryOpenExportCatalog _openExportCatalog;
  final LibraryCreateExporter _createExporter;
  NotebookExporter? _exporter;
  NotebookExportState _exportFallback = const NotebookExportState();
  ManagedNotebookStorage? _storage;
  CatalogCore? _temporary;
  NotebookWorkspace? _workspace;
  List<ManagedNotebookEntry> _entries = const [];
  bool _stale = true;
  bool _stopping = false;
  bool _disposed = false;
  String? _error;
  Completer<void>? _active;
  Future<void>? _initialization;
  Future<void>? _shutdownFuture;

  Future<void> initialize() =>
      _stopping ? Future<void>.value() : _initialization ??= _initialize();
  Future<void> _initialize() async {
    await refresh();
  }

  bool _admit() {
    if (_stopping || _active != null) return false;
    _active = Completer<void>();
    _error = null;
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
    if (_disposed) return;
    value = NotebookLibraryState(
      entries: _entries,
      workspace: _workspace,
      busy: _active != null,
      stale: _stale || _stopping,
      closed: _stopping,
      error: _error,
      exportState: _exporter?.value ?? _exportFallback,
    );
  }

  static String _describe(Object error) => error is CoreException
      ? NotebookWorkspace.describeError(error)
      : error is StateError
      ? error.message.toString()
      : 'Notebook operation failed.';

  Future<void> _release(CatalogCore core) async {
    try {
      await core.close();
    } finally {
      if (identical(_temporary, core)) _temporary = null;
    }
  }

  Future<void> _ensureExporter() async {
    if (_stopping) return;
    try {
      if (_exporter == null) {
        final root = await _storage!.obtainExportRoot();
        if (_stopping) return;
        final exporter = _createExporter(root);
        _exporter = exporter;
        exporter.addListener(_exportChanged);
      }
      await _exporter!.initialize();
    } on Object {
      _exportFallback = const NotebookExportState(
        error: 'Private export storage could not be prepared.',
      );
    }
  }

  void _exportChanged() => _publish();

  Future<void> exportNotebook(ManagedNotebookEntry entry) async {
    final exporter = _exporter;
    if (_workspace != null ||
        _stale ||
        !entry.canOpen ||
        exporter == null ||
        exporter.value.busy ||
        exporter.value.prepared != null ||
        exporter.value.leftovers.isNotEmpty ||
        !_entries.any((current) => identical(current, entry)) ||
        !_admit()) {
      return;
    }
    final admission = _active!;
    void releaseAdmission() {
      if (identical(_active, admission)) _retire();
    }

    try {
      final paths = await _storage!.existing(entry.location);
      if (_stopping) return;
      final prepared = await exporter.prepare(
        notebookId: entry.notebookId!,
        notebookName: entry.name,
        capture: (destination, budget, cancellation) async {
          cancellation.check();
          if (_stopping) throw StateError('The notebook library is closing.');
          final core = await _openExportCatalog(paths, entry.notebookId!);
          _temporary = core;
          try {
            cancellation.onCancel = core.cancelExport;
            cancellation.check();
            if (_stopping) throw StateError('The notebook library is closing.');
            return await core.exportSnapshot(
              destination,
              stagingBudgetBytes: budget,
            );
          } finally {
            cancellation.onCancel = null;
            try {
              await _release(core);
            } finally {
              releaseAdmission();
            }
          }
        },
      );
      // ZIP/provider work operates only on the owned snapshot. A newer library
      // operation may already be active; never retire its admission token.
      releaseAdmission();
      if (prepared != null && !_stopping) await exporter.save(prepared);
    } on Object catch (error) {
      _error = _describe(error);
      _publish();
    } finally {
      releaseAdmission();
    }
  }

  Future<void> saveExport(PreparedNotebookExport prepared) async {
    if (!_stopping) await _exporter?.save(prepared);
  }

  Future<void> discardExport(PreparedNotebookExport prepared) async {
    if (!_stopping) await _exporter?.discard(prepared);
  }

  Future<void> discardExportLeftover(ExportLeftover leftover) async {
    if (!_stopping) await _exporter?.discardLeftover(leftover);
  }

  void cancelExport() {
    if (!_stopping) _exporter?.cancel();
  }

  Future<void> _discover() async {
    if (_workspace != null) {
      throw StateError('Close the selected notebook first.');
    }
    _stale = true;
    _storage ??= await _obtainStorage();
    if (_stopping) return;
    await _ensureExporter();
    if (_stopping) return;
    final candidates = await _storage!.candidates();
    final entries = <ManagedNotebookEntry>[];
    for (final candidate in candidates) {
      if (_stopping) return;
      String? id;
      var name = candidate.label;
      var failure = candidate.error;
      CatalogCore? core;
      if (failure == null) {
        try {
          final paths = await _storage!.existing(candidate.paths.notebook);
          if (_stopping) return;
          core = await _openCatalog(paths, null);
          _temporary = core;
          if (!_stopping) {
            id = core.initialDirectory.notebookId;
            name = core.initialDirectory.notebookName;
          }
        } on Object catch (error) {
          failure = _describe(error);
        } finally {
          if (core != null) {
            try {
              await _release(core);
            } on Object catch (error) {
              failure = _describe(error);
            }
          }
        }
      }
      if (_stopping) return;
      entries.add(
        ManagedNotebookEntry(
          location: candidate.paths.notebook,
          notebookId: id,
          name: name,
          error: failure,
        ),
      );
    }
    final counts = <String, int>{};
    for (final entry in entries) {
      final id = entry.notebookId;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.notebookId != null && counts[entry.notebookId]! > 1) {
        entries[i] = ManagedNotebookEntry(
          location: entry.location,
          notebookId: entry.notebookId,
          name: entry.name,
          error: 'Duplicate notebook identity. Neither copy can be opened from this library.',
        );
      }
    }
    entries.sort((a, b) {
      final names = a.name.compareTo(b.name);
      return names == 0 ? a.location.compareTo(b.location) : names;
    });
    _entries = List.unmodifiable(entries);
    _stale = false;
  }

  Future<bool> refresh() async {
    if (_workspace != null || !_admit()) return false;
    try {
      await _discover();
      return !_stopping;
    } on Object catch (error) {
      _error = _describe(error);
      _stale = true;
      return false;
    } finally {
      _retire();
    }
  }

  Future<void> _recoverDiscovery(Object error) async {
    final message = _describe(error);
    try {
      await _discover();
      _error = message;
    } on Object catch (refreshError) {
      _stale = true;
      _error = '$message\nLibrary refresh failed: ${_describe(refreshError)}';
    }
  }

  Future<bool> _select(ManagedNotebookPaths paths, String id) async {
    if (_stopping) return false;
    final workspace = _createWorkspace(paths, id);
    _workspace = workspace;
    await workspace.initialize();
    if (_stopping) return false;
    if (workspace.value.directory == null || workspace.value.stale) {
      final message = workspace.value.error ?? 'The notebook could not open.';
      try {
        await workspace.shutdown();
      } finally {
        workspace.dispose();
        _workspace = null;
      }
      throw StateError(message);
    }
    return true;
  }

  Future<bool> openNotebook(ManagedNotebookEntry entry) async {
    if (_workspace != null ||
        _stale ||
        !entry.canOpen ||
        !_entries.any((current) => identical(current, entry)) ||
        !_admit()) {
      return false;
    }
    try {
      final paths = await _storage!.existing(entry.location);
      return await _select(paths, entry.notebookId!);
    } on Object catch (error) {
      await _recoverDiscovery(error);
      return false;
    } finally {
      _retire();
    }
  }

  Future<bool> createNotebook(String name) async {
    if (_workspace != null || _stale || !_admit()) return false;
    try {
      final paths = await _storage!.allocate();
      if (_stopping) return false;
      final core = await _createCatalog(paths, name);
      _temporary = core;
      final String id;
      try {
        id = core.initialDirectory.notebookId;
      } finally {
        await _release(core);
      }
      if (_stopping) return false;
      return await _select(paths, id);
    } on Object catch (error) {
      await _recoverDiscovery(error);
      return false;
    } finally {
      _retire();
    }
  }

  Future<bool> returnToLibrary(NotebookWorkspace workspace) async {
    if (!identical(_workspace, workspace) ||
        !workspace.value.canBrowse ||
        !_admit()) {
      return false;
    }
    String? closeError;
    try {
      try {
        await workspace.shutdown();
      } on Object catch (error) {
        closeError = _describe(error);
      } finally {
        workspace.dispose();
        _workspace = null;
      }
      if (_stopping) return false;
      try {
        await _discover();
      } on Object catch (error) {
        _stale = true;
        _error = _describe(error);
      }
      if (closeError != null) {
        _error = _error == null ? closeError : '$closeError\n$_error';
      }
      return true;
    } finally {
      _retire();
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    _stopping = true;
    _exporter?.cancel();
    _publish();
    await _active?.future;
    try {
      await _workspace?.shutdown();
    } finally {
      _workspace?.dispose();
      _workspace = null;
      try {
        final core = _temporary;
        if (core != null) await _release(core);
      } finally {
        final exporter = _exporter;
        if (exporter != null) {
          try {
            await exporter.shutdown();
          } finally {
            exporter.removeListener(_exportChanged);
            exporter.dispose();
          }
        }
        _publish();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(shutdown().catchError((Object _) {}));
    _disposed = true;
    super.dispose();
  }

  static NotebookExporter _exporterFor(String root) =>
      NotebookExporter(root: root);
  static Future<CatalogCore> _openExport(
    ManagedNotebookPaths paths,
    String id,
  ) => CoreNotebook.openExportCatalog(
    appDataPath: paths.app,
    localDataPath: paths.local,
    notebookPath: paths.notebook,
    expectedNotebookId: id,
  );

  static Future<CatalogCore> _open(
    ManagedNotebookPaths paths,
    String? expected,
  ) => CoreNotebook.openCatalog(
    appDataPath: paths.app,
    localDataPath: paths.local,
    notebookPath: paths.notebook,
    expectedNotebookId: expected,
  );
  static Future<CatalogCore> _create(ManagedNotebookPaths paths, String name) =>
      CoreNotebook.createCatalog(
        appDataPath: paths.app,
        localDataPath: paths.local,
        notebookPath: paths.notebook,
        notebookName: name,
      );
  static NotebookWorkspace _workspaceFor(
    ManagedNotebookPaths paths,
    String id,
  ) => NotebookWorkspace(paths: paths, notebookId: id);
}
