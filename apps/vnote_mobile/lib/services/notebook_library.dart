// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'managed_notebook_storage.dart';
import 'notebook_export.dart';
import 'notebook_import.dart';
import 'document_transfer_platform.dart';
import 'notebook_workspace.dart';

typedef LibraryOpenCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String? expectedNotebookId,
);
typedef LibraryOpenExportCatalog = Future<CatalogCore> Function(
  ManagedNotebookPaths paths,
  String notebookId,
);
typedef LibraryCreateExporter = NotebookExporter Function(
  String root,
  VoidCallback checkAdmission,
);
typedef LibraryCreateImporter = NotebookImporter Function(
  String root,
  String notebooksRoot,
  VoidCallback checkAdmission,
);
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
    this.importState = const NotebookImportState(),
    this.transferReserved = false,
  });
  final NotebookExportState exportState;
  final NotebookImportState importState;
  final bool transferReserved;
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
    LibraryCreateImporter? createImporter,
  }) : _obtainStorage = obtainStorage ?? ManagedNotebookStorage.obtain,
       _openCatalog = openCatalog ?? _open,
       _createCatalog = createCatalog ?? _create,
       _createWorkspace = createWorkspace ?? _workspaceFor,
       _openExportCatalog = openExportCatalog ?? _openExport,
       _createExporter = createExporter ?? _exporterFor,
       _createImporter = createImporter ?? _importerFor,
       super(const NotebookLibraryState());

  final Future<ManagedNotebookStorage> Function() _obtainStorage;
  final LibraryOpenCatalog _openCatalog;
  final LibraryCreateCatalog _createCatalog;
  final LibraryWorkspaceFactory _createWorkspace;
  final LibraryOpenExportCatalog _openExportCatalog;
  final LibraryCreateExporter _createExporter;
  final LibraryCreateImporter _createImporter;
  NotebookImporter? _importer;
  NotebookImportState _importFallback = const NotebookImportState();
  String? _transferOwner = 'checking';
  String? _transferCall;
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
      importState: _importer?.value ?? _importFallback,
      transferReserved: _transferOwner != null || _transferCall != null,
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

  void _assertTransfer(String owner) {
    if (_transferOwner != owner || _transferCall != owner || _stopping) {
      throw StateError('Another transfer still owns private staging.');
    }
  }

  bool _claimTransfer(String owner, {bool cleanup = false}) {
    if (_stopping ||
        _transferCall != null ||
        _transferOwner == 'checking' ||
        (_transferOwner != null &&
            _transferOwner != owner &&
            !(cleanup && _transferOwner == 'blocked'))) {
      return false;
    }
    _transferCall = owner;
    if (_transferOwner != 'blocked') _transferOwner = owner;
    return true;
  }

  void _settleTransfer() {
    if (_transferCall != null) return;
    if (_exporter?.initialized != true || _importer?.initialized != true) {
      _transferOwner = 'blocked';
      return;
    }
    final export = _exporter!.value;
    final hasExport =
        export.busy || export.prepared != null || export.leftovers.isNotEmpty;
    final hasImport = _importer!.value.busy || _importer!.value.hasStaging;
    _transferOwner = hasExport && hasImport
        ? 'blocked'
        : hasExport
        ? 'export'
        : hasImport
        ? 'import'
        : null;
  }

  void _finishTransferCall() {
    _transferCall = null;
    _settleTransfer();
    _publish();
  }

  void _transferChanged() {
    _settleTransfer();
    _publish();
  }

  Future<void> _ensureImporter() async {
    if (_stopping) return;
    try {
      if (_importer == null) {
        final root = await _storage!.obtainImportRoot();
        if (_stopping) return;
        final importer = _createImporter(
          root,
          p.normalize(_storage!.root),
          () => _assertTransfer('import'),
        );
        _importer = importer;
        importer.addListener(_transferChanged);
      }
      await _importer!.initialize();
    } on Object {
      _importFallback = const NotebookImportState(
        error: 'Private import storage could not be reconciled.',
      );
    }
  }

  Future<void> prepareImport(DocumentImportKind kind) async {
    if (_workspace != null ||
        _active != null ||
        _stale ||
        _importer == null ||
        !_claimTransfer('import')) {
      return;
    }
    try {
      await _importer!.prepare(kind);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> retryImport(ImportAttempt attempt) async {
    if (_workspace != null ||
        _active != null ||
        _importer == null ||
        !_claimTransfer('import')) {
      return;
    }
    try {
      await _importer!.retry(attempt);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> discardImport(ImportAttempt attempt) async {
    if (_importer == null || !_claimTransfer('import', cleanup: true)) return;
    try {
      await _importer!.discard(attempt);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
    if (_workspace == null) await refresh();
  }

  Future<void> discardImportLeftover(ImportLeftover item) async {
    if (_importer == null || !_claimTransfer('import', cleanup: true)) return;
    try {
      await _importer!.discardLeftover(item);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
    if (_workspace == null) await refresh();
  }

  void cancelImport() {
    if (!_stopping) _importer?.cancel();
  }

  Future<void> _verifyImportCore(
    ImportAttempt attempt,
    String location,
    Map<String, Object?> inspection,
    int cancellationAddress, {
    bool committed = false,
  }) async {
    if (!committed && CoreImportStore.queryCancellation(cancellationAddress)) {
      throw StateError('Import cancelled before publication.');
    }
    final importer = _importer!;
    await importer.resetInspection(attempt);
    final base = p.join(importer.root, attempt.id, 'inspection');
    final paths = ManagedNotebookPaths(
      app: p.join(base, 'app'),
      local: p.join(base, 'local'),
      notebook: location,
    );
    final id = inspection['notebookId'] as String;
    final core = await _openExportCatalog(paths, id);
    _temporary = core;
    try {
      if (core.initialDirectory.notebookId != id ||
          core.initialDirectory.notebookName != inspection['notebookName']) {
        throw StateError('Notebook identity changed during import validation.');
      }
      final declared = (inspection['nodeIds'] as List).cast<String>();
      final actual = await core.collectNodeIds();
      if (actual.toSet().length != actual.length ||
          declared.toSet().length != declared.length ||
          !setEquals(actual.toSet(), declared.toSet())) {
        throw StateError(
          'The complete notebook identity walk could not be verified.',
        );
      }
    } finally {
      await _release(core);
    }
  }

  Future<ImportCommitResult?> _checkImportCollisions(
    ImportAttempt attempt,
    Map<String, Object?> incoming,
    int cancellationAddress, {
    String? publishedLocation,
  }) async {
    final candidates = await _storage!.candidates();
    final incomingId = incoming['notebookId'] as String;
    final incomingNodes = (incoming['nodeIds'] as List).cast<String>().toSet();
    String? duplicate;
    var nodeCollision = false;
    final seenBooks = <String>{};
    for (final candidate in candidates) {
      if (publishedLocation != null &&
          p.equals(candidate.paths.notebook, publishedLocation)) {
        continue;
      }
      if (candidate.error != null ||
          _importer!.value.blockedLocations.any(
            (path) => p.equals(path, candidate.paths.notebook),
          )) {
        throw StateError(
          'Resolve unavailable notebooks before importing another copy.',
        );
      }
      final known = _entries
          .where((entry) => p.equals(entry.location, candidate.paths.notebook))
          .toList();
      if (known.any((entry) => !entry.canOpen)) {
        throw StateError(
          'Resolve unavailable notebooks before importing another copy.',
        );
      }
      // Startup recovery may precede discovery. Strict native inspection returns
      // the identity itself; an observed row, when present, additionally pins it.
      final result = await _importer!.runStore({
        'op': 'inspectManaged',
        'id': attempt.id,
        'location': candidate.paths.notebook,
        if (known.isNotEmpty && known.single.notebookId != null)
          'expectedNotebookId': known.single.notebookId!,
      }, cancellationAddress: cancellationAddress);
      await _verifyImportCore(
        attempt,
        candidate.paths.notebook,
        result,
        cancellationAddress,
        committed: publishedLocation != null,
      );
      final id = result['notebookId'] as String;
      if (!seenBooks.add(id)) {
        throw StateError(
          'Existing notebook identities are duplicated. Resolve them before importing.',
        );
      }
      if (id == incomingId) duplicate = id;
      final ids = (result['nodeIds'] as List).cast<String>();
      if (id != incomingId &&
          (ids.any(incomingNodes.contains) ||
              incomingNodes.contains(id) ||
              ids.contains(incomingId))) {
        nodeCollision = true;
      }
    }
    if (duplicate != null) {
      if (publishedLocation != null) {
        throw StateError(
          'A published import now conflicts with another notebook. Both copies were preserved.',
        );
      }
      return ImportCommitResult(
        status: ImportCommitStatus.duplicate,
        notebookId: duplicate,
        message: 'This notebook is already managed. Open the existing copy or discard this import.',
      );
    }
    if (nodeCollision) {
      throw StateError(
        'Imported node identities collide with an existing notebook. No IDs were regenerated.',
      );
    }
    return null;
  }

  Future<ImportCommitResult> _completeImport(
    ImportAttempt attempt,
    int cancellationAddress,
  ) async {
    final importer = _importer!;
    Map<String, Object?> status = await importer.runStore({
      'op': 'recover',
      'id': attempt.id,
    }, cancellationAddress: 0);
    if (status['phase'] == 'committed') {
      return ImportCommitResult(
        status: ImportCommitStatus.imported,
        notebookId: status['notebookId'] as String?,
        notebookName: status['notebookName'] as String?,
        destination: status['destination'] as String?,
      );
    }
    var published = status['phase'] == 'published';
    final Map<String, Object?> inspection;
    if (published) {
      inspection = await importer.runStore({
        'op': 'inspectManaged',
        'id': attempt.id,
        'location': status['destination']!,
        'expectedNotebookId': status['notebookId']!,
      }, cancellationAddress: 0);
    } else {
      if (CoreImportStore.queryCancellation(cancellationAddress)) {
        throw StateError('Import cancelled before publication.');
      }
      inspection = await importer.runStore({
        'op': 'inspect',
        'id': attempt.id,
        'treeRelative': attempt.treeRelative!,
        'inventoryHash': attempt.inventoryHash!,
      }, cancellationAddress: cancellationAddress);
      await _verifyImportCore(
        attempt,
        p.join(importer.root, attempt.id, attempt.treeRelative!),
        inspection,
        cancellationAddress,
      );
    }
    final collision = await _checkImportCollisions(
      attempt,
      inspection,
      published ? 0 : cancellationAddress,
      publishedLocation: published ? status['destination'] as String : null,
    );
    if (collision != null) return collision;
    if (!published) {
      try {
        status = await importer.runStore({
          'op': 'publish',
          'id': attempt.id,
          'treeRelative': attempt.treeRelative!,
          'inventoryHash': attempt.inventoryHash!,
          'notebookId': inspection['notebookId']!,
          'notebookName': inspection['notebookName']!,
        }, cancellationAddress: cancellationAddress);
      } on Object {
        // An error may follow the rename. Recover actual identity/state before
        // deciding whether cancellation or failure left the import unpublished.
        status = await importer.runStore({
          'op': 'recover',
          'id': attempt.id,
        }, cancellationAddress: 0);
        if (status['phase'] != 'published' && status['phase'] != 'committed') {
          rethrow;
        }
      }
      published =
          status['phase'] == 'published' || status['phase'] == 'committed';
      if (!published) {
        throw StateError(
          'Import has not been published; the prepared copy was retained.',
        );
      }
    }
    if (status['phase'] != 'committed') {
      final destination = status['destination'] as String;
      await _verifyImportCore(
        attempt,
        destination,
        inspection,
        0,
        committed: true,
      );
      await importer.runStore({
        'op': 'commit',
        'id': attempt.id,
      }, cancellationAddress: 0);
    }
    return ImportCommitResult(
      status: ImportCommitStatus.imported,
      notebookId: inspection['notebookId'] as String,
      notebookName: inspection['notebookName'] as String,
      destination: status['destination'] as String?,
    );
  }

  Future<void> commitImport(ImportAttempt attempt) async {
    if (_workspace != null ||
        _stale ||
        _importer == null ||
        _active != null ||
        !_claimTransfer('import')) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    try {
      await _importer!.commit(attempt, _completeImport);
      if (!_stopping) await _discover();
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> _recoverPublishedImport() async {
    final current = _importer?.value.current;
    if (current == null ||
        current.phase != NotebookImportPhase.finishing ||
        !_claimTransfer('import')) {
      return;
    }
    try {
      await _importer!.commit(current, _completeImport);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<bool> openExistingImportNotebook() async {
    final id = _importer?.value.existingNotebookId;
    if (id == null) return false;
    final entries = _entries
        .where((entry) => entry.notebookId == id && entry.canOpen)
        .toList();
    if (entries.length != 1) {
      _error = 'The existing notebook is unavailable. Refresh the library before opening it.';
      _publish();
      return false;
    }
    return openNotebook(entries.single);
  }

  Future<void> _ensureExporter() async {
    if (_stopping) return;
    try {
      if (_exporter == null) {
        final root = await _storage!.obtainExportRoot();
        if (_stopping) return;
        final exporter = _createExporter(root, () => _assertTransfer('export'));
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

  void _exportChanged() => _transferChanged();

  Future<void> exportNotebook(
    ManagedNotebookEntry entry, {
    required CoreExportFormat format,
  }) async {
    final exporter = _exporter;
    if (_workspace != null ||
        _stale ||
        !entry.canOpen ||
        exporter == null ||
        exporter.value.busy ||
        exporter.value.prepared != null ||
        exporter.value.leftovers.isNotEmpty ||
        !_entries.any((current) => identical(current, entry))) {
      return;
    }
    if (!_claimTransfer('export')) return;
    if (!_admit()) {
      _finishTransferCall();
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
        format: format,
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
              format: format,
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
      _finishTransferCall();
    }
  }

  Future<void> saveExport(PreparedNotebookExport prepared) async {
    if (!_claimTransfer('export')) return;
    try {
      await _exporter?.save(prepared);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> discardExport(PreparedNotebookExport prepared) async {
    if (!_claimTransfer('export', cleanup: true)) return;
    try {
      await _exporter?.discard(prepared);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> discardExportLeftover(ExportLeftover leftover) async {
    if (!_claimTransfer('export', cleanup: true)) return;
    try {
      await _exporter?.discardLeftover(leftover);
    } finally {
      _finishTransferCall();
    }
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
    await _ensureImporter();
    _settleTransfer();
    if (_stopping) return;
    await _recoverPublishedImport();
    if (_stopping) return;
    final candidates = await _storage!.candidates();
    final entries = <ManagedNotebookEntry>[];
    for (final candidate in candidates) {
      if (_stopping) return;
      String? id;
      var name = candidate.label;
      var failure = candidate.error;
      final previouslyKnown = _entries
          .where(
            (entry) =>
                p.equals(entry.location, candidate.paths.notebook) &&
                entry.canOpen,
          )
          .toList();
      final recoveryUnavailable = _importer?.initialized != true;
      if (recoveryUnavailable && previouslyKnown.length != 1) {
        failure = 'Import recovery storage is unavailable; this root cannot be registered safely.';
      }
      if (_importer?.value.blockedLocations.any(
            (location) => p.equals(location, candidate.paths.notebook),
          ) ==
          true) {
        failure =
            'Import publication requires recovery; this copy is quarantined.';
      }
      CatalogCore? core;
      if (failure == null) {
        try {
          final paths = await _storage!.existing(candidate.paths.notebook);
          if (_stopping) return;
          core = await _openCatalog(
            paths,
            recoveryUnavailable ? previouslyKnown.single.notebookId : null,
          );
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
    _importer?.cancel();
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
        try {
          final exporter = _exporter;
          if (exporter != null) {
            try {
              await exporter.shutdown();
            } finally {
              exporter.removeListener(_exportChanged);
              exporter.dispose();
            }
          }
        } finally {
          final importer = _importer;
          if (importer != null) {
            try {
              await importer.shutdown();
            } finally {
              importer.removeListener(_transferChanged);
              importer.dispose();
            }
          }
          _publish();
        }
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

  static NotebookExporter _exporterFor(String root, VoidCallback admission) =>
      NotebookExporter(root: root, checkAdmission: admission);
  static NotebookImporter _importerFor(
    String root,
    String notebooksRoot,
    VoidCallback admission,
  ) => NotebookImporter(
    root: root,
    notebooksRoot: notebooksRoot,
    checkAdmission: admission,
  );
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
