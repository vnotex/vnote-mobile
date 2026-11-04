// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'managed_notebook_storage.dart';
import 'editor_drafts.dart';
import 'notebook_export.dart';
import 'notebook_import.dart';
import 'document_transfer_platform.dart';
import 'notebook_workspace.dart';
import 'sync_credentials.dart';
import 'notebook_session.dart';
import 'cohort_import.dart';
import 'resource_transfer.dart';
import 'transfer_worker.dart';
import 'share_inbox.dart';

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
typedef LibraryCreateCohortImporter = CohortImporter Function(
  String root,
  String notebooksRoot,
  void Function(Object) reserve,
  void Function(Object) release,
);
typedef LibraryCreateResourceTransfer = ResourceTransfer Function(
  String root,
  String notebooksRoot,
  void Function(Object) reserve,
  void Function(Object) release,
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
    this.cohortState = const CohortImportState(),
    this.resourceState = const ResourceTransferState(),
    this.transferReserved = false,
    this.draftState = const EditorDraftsState(),
    this.shareState = const ShareInboxState(),
    this.inboxReady = false,
  });
  final NotebookExportState exportState;
  final NotebookImportState importState;
  final CohortImportState cohortState;
  final ResourceTransferState resourceState;
  final bool transferReserved;
  final EditorDraftsState draftState;
  final ShareInboxState shareState;
  final bool inboxReady;
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
    LibraryCreateCohortImporter? createCohortImporter,
    LibraryCreateResourceTransfer? createResourceTransfer,
    EditorDrafts Function(String root)? createDrafts,
    SyncCredentials? syncCredentials,
    ShareInbox? shareInbox,
  }) : _obtainStorage = obtainStorage ?? ManagedNotebookStorage.obtain,
       _openCatalog = openCatalog ?? _open,
       _createCatalog = createCatalog ?? _create,
       _createWorkspace = createWorkspace ?? _workspaceFor,
       _openExportCatalog = openExportCatalog ?? _openExport,
       _createExporter = createExporter ?? _exporterFor,
       _createImporter = createImporter ?? _importerFor,
       _createCohortImporter = createCohortImporter ?? _cohortImporterFor,
       _createResourceTransfer = createResourceTransfer ?? _resourceTransferFor,
       _createDrafts = createDrafts ?? _draftsFor,
       syncCredentials = syncCredentials ?? SyncCredentials(),
       _shareInbox = shareInbox ?? ShareInbox(),
       super(const NotebookLibraryState());

  final SyncCredentials syncCredentials;
  bool _foreground = true;
  final ShareInbox _shareInbox;
  int _foregroundEpoch = 0;
  bool _inboxReady = false;
  bool _inboxScanning = false;
  Future<void>? _resumeFuture;
  final Future<ManagedNotebookStorage> Function() _obtainStorage;
  final LibraryOpenCatalog _openCatalog;
  final LibraryCreateCatalog _createCatalog;
  final LibraryWorkspaceFactory _createWorkspace;
  final LibraryOpenExportCatalog _openExportCatalog;
  final LibraryCreateExporter _createExporter;
  final LibraryCreateImporter _createImporter;
  final LibraryCreateCohortImporter _createCohortImporter;
  final LibraryCreateResourceTransfer _createResourceTransfer;
  final EditorDrafts Function(String root) _createDrafts;
  EditorDrafts? _drafts;
  EditorDrafts? get drafts => _drafts;
  CohortImporter? _cohortImporter;
  ResourceTransfer? _resourceTransfer;
  CohortImportState _cohortFallback = const CohortImportState();
  ResourceTransferState _resourceFallback = const ResourceTransferState();
  bool _scanningTransfers = true;
  ResourceCore? _temporaryResource;
  Completer<void>? _transferLease;
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

  void setForeground(bool foreground) {
    _foreground = foreground;
    final epoch = ++_foregroundEpoch;
    _workspace?.setForeground(false);
    if (!foreground || _stopping) return;
    _inboxReady = false;
    _inboxScanning = true;
    final barrier = _workspace?.beginInboxBarrier() ?? Future<void>.value();
    final previous = _resumeFuture;
    _publish();
    _resumeFuture = _resumeInbox(epoch, barrier, previous);
  }

  Future<void> _resumeInbox(int epoch, Future<void> barrier, Future<void>? previous) async {
    Future<void>? attachment;
    try {
      await previous;
      await barrier;
      await _active?.future;
      await _transferLease?.future;
      if (_stopping || epoch != _foregroundEpoch || !_foreground) return;
      if (_storage == null) {
        await _discover();
      } else {
        final scanning = _scanningTransfers;
        _scanningTransfers = true;
        try {
          await _scanInbox();
          await _cohortImporter?.rescan();
          await _reconcileInbox();
        } finally {
          _scanningTransfers = scanning;
        }
      }
      _transferChanged();
      if (!_shareInbox.value.initialized) return;
      if (!_stopping && epoch == _foregroundEpoch && _foreground) {
        _inboxReady = true;
        _workspace?.endInboxBarrier(foreground: true);
        attachment = _workspace?.settleSyncAttachment();
      }
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      if (epoch == _foregroundEpoch) _inboxScanning = false;
      _settleTransfer();
      _publish();
    }
    // Clear the external scan exclusion before joining readiness: attaching
    // may itself need the normal sync lifecycle reservation after quarantine.
    // No foreground state is changed after this await by an obsolete epoch.
    await attachment;
  }

  Future<void> refreshInbox() {
    if (_stopping) return Future.value();
    setForeground(_foreground);
    return _resumeFuture ?? Future.value();
  }

  Future<void> initialize() =>
      _stopping ? Future<void>.value() : _initialization ??= _initialize();
  Future<void> _initialize() async {
    await refresh();
  }

  bool _admit() {
    if (_stopping || _active != null || _inboxScanning) return false;
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
    _workspace?.setExternalTransferBusy(_scanningTransfers || _inboxScanning || _transferCall != null);
    value = NotebookLibraryState(
      entries: _entries,
      workspace: _workspace,
      busy: _active != null || _inboxScanning,
      stale: _stale || _stopping,
      closed: _stopping,
      error: _error,
      exportState: _exporter?.value ?? _exportFallback,
      importState: _importer?.value ?? _importFallback,
      cohortState: _cohortImporter?.value ?? _cohortFallback,
      resourceState: _resourceTransfer?.value ?? _resourceFallback,
      transferReserved: _transferOwner != null || _transferCall != null || _inboxScanning,
      draftState: _drafts?.value ?? const EditorDraftsState(),
      shareState: _shareInbox.value,
      inboxReady: _inboxReady,
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
    if ((_transferOwner != owner && _transferOwner != 'blocked') ||
        _transferCall != owner ||
        _stopping) {
      throw StateError('Another transfer still owns private staging.');
    }
  }

  bool _claimTransfer(String owner, {bool cleanup = false}) {
    if (_stopping ||
        (!cleanup && (_workspace?.synchronization.value.busy ?? false)) ||
        _scanningTransfers ||
        _inboxScanning ||
        _transferCall != null ||
        _transferOwner == 'checking' ||
        (_transferOwner != null &&
            _transferOwner != owner &&
            !(cleanup && (_transferOwner == 'blocked' || owner == 'inbox')))) {
      return false;
    }
    _transferCall = owner;
    _transferLease = Completer<void>();
    if (_transferOwner != 'blocked') _transferOwner = owner;
    _publish();
    return true;
  }

  void _settleTransfer() {
    if (_transferCall != null) return;
    if (_scanningTransfers ||
        _inboxScanning ||
        _exporter?.initialized != true ||
        _importer?.initialized != true ||
        _cohortImporter?.initialized != true ||
        _resourceTransfer?.initialized != true) {
      _transferOwner = 'blocked';
      return;
    }
    final export = _exporter!.value;
    final owners = <String>[
      if (export.busy || export.prepared != null || export.leftovers.isNotEmpty)
        'export',
      if (_importer!.value.busy || _importer!.value.hasStaging) 'import',
      if (_cohortImporter!.value.busy || _cohortImporter!.value.hasStaging)
        'cohort',
      if (_resourceTransfer!.value.busy || _resourceTransfer!.value.hasStaging)
        'resource',
    ];
    _transferOwner =
        owners.length > 1 ||
            _cohortImporter!.value.attempts.length > 1 ||
            _resourceTransfer!.value.attempts.length > 1
        ? 'blocked'
        : owners.firstOrNull;
  }

  void _finishTransferCall() {
    _transferCall = null;
    final lease = _transferLease;
    _transferLease = null;
    lease?.complete();
    _settleTransfer();
    _publish();
  }

  void _transferChanged() {
    _settleTransfer();
    final workspace = _workspace;
    if (workspace != null) {
      workspace.setTransferBlock(
        _blockedNotebook(workspace.notebookLocation)
            ? 'A retained transfer needs recovery. Return to Notebooks to resolve it.'
            : null,
      );
    }
    _publish();
  }

  void _reserveController(Object owner) {
    final domain = identical(owner, _cohortImporter)
        ? 'cohort'
        : identical(owner, _resourceTransfer)
        ? 'resource'
        : null;
    if (domain == null) throw StateError('Unknown transfer owner.');
    if (_scanningTransfers) return;
    _assertTransfer(domain);
  }

  void _releaseController(Object owner) => _transferChanged();

  static EditorDrafts _draftsFor(String root) => EditorDrafts(root: root);

  Future<void> _ensureDrafts() async {
    if (_drafts == null) {
      final root = await _storage!.obtainDraftRoot();
      _drafts = _createDrafts(root)..addListener(_publish);
    }
    await _drafts!.initialize(reconcile: _reconcileDraft);
  }

  Future<CoreDraftInspection> _reconcileDraft(DraftRecoveryEntry entry) async {
    final relative = entry.notebookRelative;
    if (relative == null || entry.notebookId == null || entry.nodeId == null ||
        relative != p.basename(relative) || relative == '.' || relative == '..' ||
        relative.contains('/') || relative.contains('\\')) {
      throw StateError('The retained draft has no safe notebook identity.');
    }
    if (!_shareInbox.value.initialized || _shareInbox.value.records.any((item) =>
        item.status == ShareInboxStatus.importing &&
        (item.target?.notebookRelative == relative || item.target?.notebookId == entry.notebookId))) {
      throw StateError('A shared item must be reconciled before this notebook can be opened.');
    }
    final paths = await _storage!.existing(p.join(_storage!.root, relative));
    // Inspection runtimes never live under the journal quota/authority tree and
    // never reuse an old native buffer namespace after a crash.
    final runtime = newTransferId();
    final core = await CoreNotebook.openResources(
      appDataPath: p.join(paths.app, 'draft-recovery', runtime),
      localDataPath: p.join(paths.local, 'draft-recovery', runtime),
      notebookPath: paths.notebook,
      notebookId: entry.notebookId!, nodeId: entry.nodeId!);
    _temporaryResource = core;
    try {
      return await core.reconcileDraft(draftsRoot: _drafts!.root,
        documentKey: entry.documentKey, token: entry.token);
    } finally {
      await core.close();
      if (identical(_temporaryResource, core)) _temporaryResource = null;
    }
  }

  Future<DraftRecoveryInspection?> inspectDraft(DraftRecoveryEntry entry) async {
    if (_workspace != null || _drafts == null || !_admit()) return null;
    try { return await _drafts!.inspect(entry, _reconcileDraft); }
    finally { _retire(); }
  }

  Future<bool> restoreDraft(DraftRecoveryEntry entry) async {
    if (_workspace != null || _drafts == null || !_admit()) return false;
    try {
      final matches = _entries.where((item) => item.notebookId == entry.notebookId).toList();
      if (_stale || matches.length != 1 || !matches.single.canOpen ||
          p.basename(matches.single.location) != entry.notebookRelative ||
          _blockedNotebook(matches.single.location)) {
        throw StateError('The managed notebook identity is unavailable or quarantined. The private draft remains retained.');
      }
      final inspection = await _drafts!.inspect(entry, _reconcileDraft);
      if (!inspection.canRestore) {
        throw StateError(inspection.error ?? 'Current disk and private source conflict; neither was overwritten.');
      }
      final checkpoint = await _drafts!.rebase(inspection.entry, newTransferId());
      final proof = await _reconcileDraft(DraftRecoveryEntry(checkpoint));
      if (proof.record['outcome'] == 'conflict') {
        throw StateError('Disk changed during restoration. Both private captures are retained.');
      }
      final paths = await _storage!.existing(p.join(_storage!.root, entry.notebookRelative!));
      if (!await _select(paths, entry.notebookId!)) return false;
      return await _workspace!.openRecovered(entry.nodeId!, proof.record);
    } on Object catch (error) { _error = _describe(error); return false; }
    finally { _retire(); }
  }

  Future<void> discardDraft(DraftRecoveryEntry entry) async {
    if (_workspace != null || _drafts == null || !_admit()) return;
    try { await _drafts!.discard(entry); }
    on Object catch (error) { _error = _describe(error); }
    finally { _retire(); }
  }

  Future<void> exportDraft(DraftRecoveryEntry entry, {bool raw = false}) async {
    if (_workspace != null || _drafts == null || _resourceTransfer == null ||
        _active != null || !_claimTransfer('resource')) {
      return;
    }
    if (!_admit()) { _finishTransferCall(); return; }
    Map<String, Object?>? pinned;
    try {
      final binding = await _drafts!.prepareExport(entry, raw: raw);
      pinned = binding;
      final detachedArchive = entry.notebookId == null || entry.nodeId == null ||
          entry.notebookRelative == null;
      if (detachedArchive && !raw) {
        throw StateError('Only a raw archive can export an unidentifiable journal.');
      }
      final attempt = await _resourceTransfer!.start(
        target: detachedArchive
          ? ResourceTarget(notebookId: 'private-draft', nodeId: entry.documentKey,
              notebookRelative: 'private-draft')
          : ResourceTarget(notebookId: entry.notebookId!, nodeId: entry.nodeId!,
              notebookRelative: entry.notebookRelative!),
        operation: ResourceOperation.export,
        name: raw ? 'draft-journal.bin' : 'recovered-draft.md',
        origin: ResourceExportOrigin.draft, binding: binding);
      if (attempt != null) {
        await _resourceTransfer!.prepareExport(attempt, _exportRetainedResource);
        final ready = _resourceTransfer!.value.current;
        if (!_stopping && ready?.stage == TransferStage.exportReady) {
          await _resourceTransfer!.save(ready!);
        }
      }
    } on Object catch (error) { _error = _describe(error); }
    finally {
      if (pinned != null && !_resourceTransfer!.value.attempts.any((attempt) =>
          attempt.origin == ResourceExportOrigin.draft &&
          attempt.binding?['candidateId'] == pinned!['candidateId'])) {
        try {
          await runDraftStore({'op': 'releaseExport', 'draftsRoot': _drafts!.root,
            'documentKey': entry.documentKey, 'token': entry.token,
            'candidateId': pinned['candidateId']});
        } on Object catch (error) { _error = _describe(error); }
      }
      _retire(); _finishTransferCall();
    }
  }

  Future<void> exportPreview(NotebookWorkspace workspace, NotebookSession session,
      CorePreviewSnapshot snapshot, String fileHandle) async {
    await workspace.settleSyncAttachment();
    final target = resourceTarget(workspace, session);
    if (_resourceTransfer == null || !_claimTransfer('resource')) return;
    final requestId = newTransferId();
    var pinned = false;
    try {
      final captured = await runPreviewStore({...snapshot.command('prepareExport'),
        'handle': fileHandle, 'leaseId': requestId});
      pinned = true;
      final attempt = await _resourceTransfer!.start(target: target,
        operation: ResourceOperation.export, requestId: requestId,
        name: captured['name'] as String,
        origin: ResourceExportOrigin.previewFile,
        binding: Map<String, Object?>.from(captured['binding'] as Map));
      if (attempt != null) {
        await _resourceTransfer!.prepareExport(attempt, _exportRetainedResource);
        final ready = _resourceTransfer!.value.current;
        if (!_stopping && ready?.stage == TransferStage.exportReady) {
          await _resourceTransfer!.save(ready!);
        }
      }
    } on Object catch (error) { _error = _describe(error); }
    finally {
      if (pinned && !_resourceTransfer!.value.attempts.any((attempt) => attempt.id == requestId)) {
        try {
          await runPreviewStore({...snapshot.command('releaseExport'),
            'transactionRoot': p.join(_resourceTransfer!.root, requestId)});
        } on Object catch (error) { _error = _describe(error); }
      }
      _finishTransferCall();
    }
  }

  ShareInboxRecord? _shareForOperation(String id) => _shareInbox.value.records
    .where((item) => item.operationId == id).firstOrNull;

  Future<void> _scanInbox() async {
    await _shareInbox.refresh();
    _publish();
    if (!_shareInbox.value.available || _storage == null || _stopping) return;
    final root = await _storage!.obtainCohortRoot();
    try {
      final quota = await runTransferStore({'op': 'checkSpace', 'scope': 'cohort',
        'root': root, 'notebooksRoot': _storage!.root,
        'id': '00000000000000000000000000000000', 'requiredBytes': 0});
      // Activation repeats this proof natively under the common admission lock.
      // Historical over-cap staging is retained, not evicted to enable capture.
      if (quota['stagedBytes'] is int && (quota['stagedBytes'] as int) <= (3 << 30)) {
        await _shareInbox.activate();
      } else {
        _error = 'Incoming sharing is paused until retained staging is at most 3 GiB. Existing work is preserved.';
      }
    } on Object catch (error) {
      _error = error is TransferFailure ? error.message
        : error is StateError || error is CoreException ? _describe(error)
        : 'Receiving shared items is unavailable until private staging can be reconciled.';
    }
  }

  Future<void> _authorizeCohortDiscard(CohortAttempt attempt) async {
    final record = _shareForOperation(attempt.id);
    if (record == null || record.settled) return;
    if (attempt.stage == TransferStage.committed) {
      final cohortId = attempt.cohortId;
      if (cohortId == null) throw StateError('The committed shared item has no receipt.');
      await _shareInbox.consume(record, cohortId);
    } else {
      await _shareInbox.discard(record);
    }
    // A lost list result after successful tombstoning still holds private proof.
    await _shareInbox.refresh();
    if (_shareForOperation(attempt.id)?.settled != true) {
      throw StateError('The shared item disposition is not yet durable.');
    }
  }

  Future<void> _consumeSharedCohort(ShareInboxRecord record, CohortAttempt attempt) async {
    if (attempt.stage != TransferStage.committed || attempt.cohortId == null) return;
    // Native consume validates committed == outcome plus intent/target; it does
    // not open a notebook, so a later user-deleted destination never reimports.
    await _shareInbox.consume(record, attempt.cohortId!);
    await _shareInbox.refresh();
    if (_shareForOperation(attempt.id)?.status != ShareInboxStatus.consumed) {
      throw StateError('The shared item receipt could not be settled.');
    }
    _cohortImporter!.select(attempt);
    await _cohortImporter!.discard(attempt, recover: _applyCohort);
  }

  Future<void> _reconcileInbox() async {
    final importer = _cohortImporter;
    if (importer == null || !importer.initialized || !_shareInbox.value.initialized) return;
    final scanning = _scanningTransfers;
    _scanningTransfers = true;
    try {
      for (final record in List<ShareInboxRecord>.of(_shareInbox.value.records)) {
        if (_stopping) return;
        final operationId = record.operationId;
        if (operationId == null) continue;
        var attempt = importer.value.attempts.where((item) => item.id == operationId).firstOrNull;
        try {
          if (record.settled) {
            // Kill after tombstone, before cleanup: never allocate another copy.
            if (attempt != null || importer.value.leftovers.any((item) =>
                const ['done-', 'inbox-'].any((prefix) =>
                  p.basename(item.location) == '$prefix$operationId' ||
                  p.basename(item.location) == '$prefix$operationId.json' ||
                  p.basename(item.location) == '$prefix$operationId.json.tmp'))) {
              await importer.discardSettledInbox(operationId, record.id);
            }
            continue;
          }
          if (record.status != ShareInboxStatus.importing) continue;
          if (attempt == null || !attempt.allocationComplete) {
            attempt = await importer.allocateInbox(inboxId: record.id,
              operationId: operationId, target: record.target!);
          }
          if (attempt == null) continue;
          if (attempt.stage == TransferStage.committed) {
            await _consumeSharedCohort(record, attempt);
          } else if (_workspace == null && (attempt.stage == TransferStage.intent ||
              attempt.stage == TransferStage.quarantined)) {
            importer.select(attempt);
            await importer.recover(attempt, _applyCohort);
            final recovered = importer.value.attempts.where((item) => item.id == operationId).firstOrNull;
            if (recovered != null) await _consumeSharedCohort(record, recovered);
          }
        } on Object catch (error) {
          _error = _describe(error);
        }
      }
    } finally {
      _scanningTransfers = scanning;
      _transferChanged();
    }
  }

  /// Target names/identities are never inferred from an incoming file name.
  Future<CohortTarget?> shareTarget({ManagedNotebookEntry? notebook,
      required String folderName, bool currentFolder = false}) async {
    if (!ShareInbox.validName(folderName) || _stopping || _active != null || _inboxScanning) return null;
    final workspace = _workspace;
    CohortTarget? target;
    if (workspace != null) {
      final directory = workspace.value.directory;
      if (workspace.value.session != null || directory == null || !workspace.value.canMutate) {
        _error = 'Close the selected note before importing shared items.';
        _publish();
        return null;
      }
      if (currentFolder) {
        target = CohortTarget(notebookId: directory.notebookId,
          parentId: directory.folderId, notebookRelative: p.basename(workspace.notebookLocation),
          folderName: folderName);
      }
      if (!await returnToLibrary(workspace)) return null;
      if (target != null) return target;
    }
    if (notebook == null || notebook.notebookId == null || _stale ||
        _blockedNotebook(notebook.location) || !_admit()) {
      return null;
    }
    CatalogCore? core;
    try {
      final matches = _entries.where((item) => item.notebookId == notebook.notebookId &&
        p.equals(item.location, notebook.location) && item.canOpen).toList();
      if (matches.length != 1) return null;
      final paths = await _storage!.existing(notebook.location);
      core = await _openCatalog(paths, notebook.notebookId);
      _temporary = core;
      final directory = core.initialDirectory;
      return CohortTarget(notebookId: directory.notebookId, parentId: directory.folderId,
        notebookRelative: p.basename(notebook.location), folderName: folderName);
    } on Object catch (error) {
      _error = _describe(error);
      return null;
    } finally {
      if (core != null) await _release(core);
      _retire();
    }
  }

  Future<void> importShare(ShareInboxRecord record, {CohortTarget? target}) async {
    if (_workspace != null || _active != null || _cohortImporter == null ||
        !_claimTransfer('cohort', cleanup: record.status == ShareInboxStatus.importing)) {
      return;
    }
    if (!_admit()) { _finishTransferCall(); return; }
    try {
      await _shareInbox.refresh();
      var current = _shareInbox.value.records.where((item) => item.id == record.id).firstOrNull;
      if (current == null || current.settled) return;
      if (current.status == ShareInboxStatus.ready) {
        if (_cohortImporter!.hasStaging) {
          throw StateError('Resolve the retained cohort staging first.');
        }
        if (target == null) throw StateError('Choose a notebook and child folder first.');
        current = await _shareInbox.claim(current, operationId: newTransferId(), target: target);
        // The claim is durable before mkdir. A lost reply can only be resumed
        // with that exact operation ID, never with a newly generated one.
        await _shareInbox.refresh();
      }
      if (current.status != ShareInboxStatus.importing) return;
      final claimed = current;
      _transferChanged();
      final importer = _cohortImporter!;
      var attempt = importer.value.attempts.where((item) => item.id == claimed.operationId).firstOrNull;
      if (attempt == null || !attempt.allocationComplete) {
        attempt = await importer.allocateInbox(inboxId: claimed.id,
          operationId: claimed.operationId!, target: claimed.target!);
      }
      // Each existing state machine step advances immutable retained work. An
      // unchanged phase/error stops immediately instead of replaying a failure.
      for (var step = 0; step < 6 && attempt != null && !_stopping; step++) {
        if (attempt.stage == TransferStage.committed) {
          await _consumeSharedCohort(claimed, attempt);
          break;
        }
        importer.select(attempt);
        final before = attempt;
        attempt = await importer.retry(attempt, build: _buildCohort, apply: _applyCohort,
          retained: () async {
            await importer.store('checkSpace', arguments: {'requiredBytes': claimed.bytes + (128 << 10)});
            return _shareInbox.stage(claimed);
          });
        if (importer.value.error != null || attempt == null ||
            attempt.stage == before.stage && attempt.built == before.built) {
          break;
        }
      }
      if (!_stopping) await _discover();
    } on Object catch (error) {
      _error = _describe(error);
      try { await _shareInbox.refresh(); } on Object { /* Retain quarantine. */ }
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> _inboxAction(Future<void> Function() action, {bool cohort = false}) async {
    if (_active != null || _inboxScanning || _stopping ||
        !_claimTransfer(cohort ? 'cohort' : 'inbox', cleanup: true)) {
      return;
    }
    if (!_admit()) { _finishTransferCall(); return; }
    try {
      await action();
      await _shareInbox.refresh();
      _transferChanged();
      if (_workspace == null) await _discover();
    } on Object catch (error) { _error = _describe(error); }
    finally { _retire(); _finishTransferCall(); }
  }

  Future<void> discardShare(ShareInboxRecord record) => _inboxAction(() async {
    final attempt = _cohortImporter?.value.attempts
      .where((item) => item.id == record.operationId).firstOrNull;
    if (attempt != null) {
      if (_workspace != null) throw StateError('Return to Notebooks before resolving this shared item.');
      _cohortImporter!.select(attempt);
      await _cohortImporter!.discard(attempt, recover: _applyCohort);
    } else {
      await _shareInbox.discard(record);
    }
  }, cohort: record.operationId != null);

  Future<void> anotherShareCopy(ShareInboxRecord record) => _inboxAction(() async {
    await _shareInbox.anotherCopy(record);
  });
  Future<void> dismissShareDuplicate(ShareInboxRecord record) =>
    _inboxAction(() => _shareInbox.dismissDuplicate(record));
  Future<void> forgetShareHistory() => _inboxAction(_shareInbox.forgetHistory);
  Future<void> cleanupSharedExports() => _inboxAction(_shareInbox.cleanupExports);
  Future<void> exportShare(ShareInboxRecord record) => _inboxAction(() async {
    _shareInbox.reportShare(await _shareInbox.export(record));
  });

  Future<void> _ensureOfflineTransfers() async {
    try {
      if (_cohortImporter == null) {
        final root = await _storage!.obtainCohortRoot();
        if (_stopping) return;
        _cohortImporter = _createCohortImporter(
          root,
          p.normalize(_storage!.root),
          _reserveController,
          _releaseController,
        );
        _cohortImporter!.addListener(_transferChanged);
        _cohortImporter!.authorizeDiscard = _authorizeCohortDiscard;
      }
      await _cohortImporter!.initialize();
    } on Object catch (error) {
      _cohortFallback = CohortImportState(error: _describe(error));
    }
    try {
      if (_resourceTransfer == null) {
        final root = await _storage!.obtainResourceRoot();
        if (_stopping) return;
        _resourceTransfer = _createResourceTransfer(
          root,
          p.normalize(_storage!.root),
          _reserveController,
          _releaseController,
        );
        _resourceTransfer!.addListener(_transferChanged);
      }
      await _resourceTransfer!.initialize();
    } on Object catch (error) {
      _resourceFallback = ResourceTransferState(error: _describe(error));
    }
  }

  bool get _unknownTransferTarget =>
      !_shareInbox.value.initialized ||
      _cohortImporter?.initialized != true ||
      _resourceTransfer?.initialized != true ||
      _cohortImporter!.value.blocksAllNotebooks ||
      _resourceTransfer!.value.blocksAllNotebooks;

  bool _blockedNotebook(String location) {
    if (_unknownTransferTarget) return true;
    final relative = p.basename(location);
    return _shareInbox.value.records.any((item) =>
        item.status == ShareInboxStatus.importing && item.target?.notebookRelative == relative) ||
        _cohortImporter!.value.blockedNotebookRelatives.contains(relative) ||
        _resourceTransfer!.value.blockedNotebookRelatives.contains(relative);
  }

  Future<void> _recoverOfflineTransfers() async {
    final cohorts = _cohortImporter;
    if (cohorts != null && cohorts.initialized) {
      for (final id in cohorts.value.attempts.map((item) => item.id).toList()) {
        final attempt = cohorts.value.attempts
            .where((item) => item.id == id)
            .firstOrNull;
        if (attempt == null) continue;
        if (_stopping) return;
        if (_shareForOperation(id) != null) continue;
        if (attempt.stage != TransferStage.intent &&
            attempt.stage != TransferStage.quarantined) {
          continue;
        }
        if (!_claimTransfer('cohort', cleanup: true)) continue;
        try {
          cohorts.select(attempt);
          await cohorts.recover(attempt, _applyCohort);
        } on Object catch (error) {
          _error = _describe(error);
        } finally {
          _finishTransferCall();
        }
      }
    }
    final resources = _resourceTransfer;
    if (resources != null && resources.initialized) {
      for (final id
          in resources.value.attempts.map((item) => item.id).toList()) {
        final attempt = resources.value.attempts
            .where((item) => item.id == id)
            .firstOrNull;
        if (attempt == null) continue;
        if (_stopping) return;
        if (attempt.stage != TransferStage.intent &&
            attempt.stage != TransferStage.quarantined) {
          continue;
        }
        if (!_claimTransfer('resource', cleanup: true)) continue;
        try {
          resources.select(attempt);
          await resources.recover(attempt, _applyRetainedResource);
        } on Object catch (error) {
          _error = _describe(error);
        } finally {
          _finishTransferCall();
        }
      }
    }
  }

  Future<ManagedNotebookPaths> _transferPaths(
    String relative,
    String transactionRoot,
  ) async {
    if (relative != p.basename(relative) ||
        relative == '.' ||
        relative == '..' ||
        relative.contains('/') ||
        relative.contains('\\')) {
      throw StateError('The retained notebook location is invalid.');
    }
    final existing = await _storage!.existing(p.join(_storage!.root, relative));
    final engine = p.join(transactionRoot, 'recovery', newTransferId());
    return ManagedNotebookPaths(
      app: p.join(engine, 'app'),
      local: p.join(engine, 'local'),
      notebook: existing.notebook,
    );
  }

  Future<CoreCohortBuildResult> _buildCohort(
    CohortAttempt attempt,
    TransferCancellation cancellation,
  ) async {
    cancellation.check();
    final core = await CoreNotebook.createCohortBuilder(
      attempt.transactionRoot,
    );
    try {
      cancellation.onCancel = core.cancel;
      cancellation.check();
      return await core.build();
    } finally {
      cancellation.onCancel = null;
      await core.close();
    }
  }

  Future<CoreCohortOutcome> _applyCohort(
    CohortAttempt attempt,
    TransferCancellation cancellation,
    bool recover,
  ) async {
    if (_drafts?.value.initialized != true) {
      throw StateError('Private draft recovery must finish before admitting notebook mutations.');
    }
    if (_workspace != null) {
      throw StateError('Return to Notebooks before applying files.');
    }
    if (!recover) cancellation.check();
    final paths = await _transferPaths(
      attempt.target.notebookRelative,
      attempt.transactionRoot,
    );
    final core = await _openCatalog(paths, attempt.target.notebookId);
    _temporary = core;
    try {
      if (!recover) cancellation.check();
      return recover
          ? await core.recoverCohort(attempt.transactionRoot)
          : await core.applyCohort(attempt.transactionRoot);
    } finally {
      await _release(core);
    }
  }

  Future<CoreResourceResult> _applyRetainedResource(
    ResourceAttempt attempt,
    TransferCancellation cancellation,
    bool recover,
  ) async {
    if (_drafts?.value.initialized != true) {
      throw StateError('Private draft recovery must finish before admitting resource mutations.');
    }
    if (_workspace != null) {
      throw StateError('Return to Notebooks before recovering resources.');
    }
    if (!recover) cancellation.check();
    final paths = await _transferPaths(
      attempt.target.notebookRelative,
      attempt.transactionRoot,
    );
    final core = await CoreNotebook.openResources(
      appDataPath: paths.app,
      localDataPath: paths.local,
      notebookPath: paths.notebook,
      notebookId: attempt.target.notebookId,
      nodeId: attempt.target.nodeId,
    );
    _temporaryResource = core;
    try {
      return await _applyResourceOnCore(core, attempt, cancellation, recover);
    } finally {
      await core.close();
      if (identical(_temporaryResource, core)) _temporaryResource = null;
    }
  }

  Future<void> _refreshResourceListing(
    ResourceCore core,
    ResourceTarget target,
  ) async {
    _resourceTransfer!.clearListing(target);
    try {
      _resourceTransfer!.setListing(target, await core.listResources());
    } on Object catch (error) {
      _error = 'Resource listing could not be refreshed: ${_describe(error)}';
    }
  }

  Future<CoreResourceResult> _applyResourceOnCore(
    ResourceCore core,
    ResourceAttempt attempt,
    TransferCancellation cancellation,
    bool recover,
  ) async {
    _resourceTransfer!.clearListing(attempt.target);
    try {
      if (!recover) cancellation.check();
      return recover
          ? await core.recoverResource(attempt.transactionRoot)
          : await core.applyResource(attempt.transactionRoot);
    } finally {
      // Errors may follow physical/membership changes. Inspect the actual
      // state before releasing this SAME owner, never infer rollback.
      await _refreshResourceListing(core, attempt.target);
    }
  }

  Future<CoreResourceExport> _exportResourceOnCore(
    ResourceCore core,
    ResourceAttempt attempt,
    TransferCancellation cancellation,
  ) async {
    if (attempt.origin != ResourceExportOrigin.asset) {
      return _exportRetainedResource(attempt, cancellation);
    }
    cancellation.onCancel = core.cancelResourceRead;
    try {
      cancellation.check();
      return await core.exportResource(attempt.name, attempt.transactionRoot);
    } finally {
      cancellation.onCancel = null;
    }
  }

  Future<CoreResourceExport> _exportRetainedResource(
    ResourceAttempt attempt,
    TransferCancellation cancellation,
  ) async {
    cancellation.check();
    switch (attempt.origin) {
      case ResourceExportOrigin.draft:
        final binding = attempt.binding!;
        if (_drafts == null) throw StateError('Private draft storage is unavailable; the export remains retained.');
        final snapshot = await _drafts!.export(DraftRecoveryEntry(binding), binding, attempt.transactionRoot);
        await _releaseExportSource(attempt);
        return snapshot;
      case ResourceExportOrigin.previewFile:
        final binding = attempt.binding!;
        final result = await runPreviewStore({
          'op': 'export', 'previewRoot': await _storage!.obtainPreviewRoot(),
          'previewId': binding['previewId'], 'renderId': binding['renderId'],
          'transactionRoot': attempt.transactionRoot,
        });
        await _releaseExportSource(attempt);
        return CoreResourceExport(name: result['name'] as String,
          path: result['path'] as String, bytes: result['bytes'] as int,
          sha256: result['sha256'] as String);
      case null:
        throw StateError('The original export source is unavailable. The request remains retained.');
      case ResourceExportOrigin.asset:
        break;
    }
    final paths = await _transferPaths(
      attempt.target.notebookRelative,
      attempt.transactionRoot,
    );
    final core = await CoreNotebook.openResources(
      appDataPath: paths.app,
      localDataPath: paths.local,
      notebookPath: paths.notebook,
      notebookId: attempt.target.notebookId,
      nodeId: attempt.target.nodeId,
    );
    _temporaryResource = core;
    try {
      return await _exportResourceOnCore(core, attempt, cancellation);
    } finally {
      await core.close();
      if (identical(_temporaryResource, core)) _temporaryResource = null;
    }
  }

  Future<void> _releaseExportSource(ResourceAttempt attempt) async {
    final binding = attempt.binding;
    if (binding == null) return;
    switch (attempt.origin) {
      case ResourceExportOrigin.draft:
        if (_drafts == null) throw StateError('The draft export pin remains retained.');
        await runDraftStore({'op': 'releaseExport', 'draftsRoot': _drafts!.root,
          'documentKey': binding['documentKey'], 'token': binding['token'],
          'candidateId': binding['candidateId']});
      case ResourceExportOrigin.previewFile:
        await runPreviewStore({'op': 'releaseExport',
          'previewRoot': await _storage!.obtainPreviewRoot(),
          'previewId': binding['previewId'], 'renderId': binding['renderId'],
          'transactionRoot': attempt.transactionRoot});
      case ResourceExportOrigin.asset:
      case null:
        return;
    }
  }

  Future<void> inspectResource(ResourceAttempt attempt) async {
    if (_workspace != null ||
        _active != null ||
        _resourceTransfer == null ||
        !_claimTransfer('resource', cleanup: true)) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    try {
      _resourceTransfer!.select(attempt);
      await _resourceTransfer!.refresh(attempt.target, (
        target,
        cancellation,
      ) async {
        final paths = await _transferPaths(
          target.notebookRelative,
          attempt.transactionRoot,
        );
        final core = await CoreNotebook.openResources(
          appDataPath: paths.app,
          localDataPath: paths.local,
          notebookPath: paths.notebook,
          notebookId: target.notebookId,
          nodeId: target.nodeId,
        );
        _temporaryResource = core;
        cancellation.onCancel = core.cancelResourceRead;
        try {
          cancellation.check();
          return await core.listResources();
        } finally {
          cancellation.onCancel = null;
          await core.close();
          if (identical(_temporaryResource, core)) _temporaryResource = null;
        }
      });
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> importFiles(
    NotebookWorkspace workspace,
    CoreDirectory directory,
    DocumentImportKind kind,
    String folderName,
  ) async {
    if (!identical(_workspace, workspace) ||
        !identical(workspace.value.directory, directory) ||
        !workspace.value.canMutate ||
        _active != null ||
        _cohortImporter == null ||
        !_claimTransfer('cohort')) {
      return;
    }
    final target = CohortTarget(
      notebookId: directory.notebookId,
      parentId: directory.folderId,
      notebookRelative: p.basename(workspace.notebookLocation),
      folderName: folderName,
    );
    try {
      // Join the browser owner before any picker/build. Provider work then
      // permits opening other notebooks, but applying requires library admission.
      if (!await returnToLibrary(workspace) || _stopping) return;
      await _cohortImporter!.start(target: target, kind: kind);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> retryCohort(CohortAttempt attempt) async {
    final share = _shareForOperation(attempt.id);
    if (share != null && !share.settled) {
      await importShare(share);
      return;
    }
    if (_transferOwner == 'blocked' &&
        attempt.stage != TransferStage.intent &&
        attempt.stage != TransferStage.quarantined) {
      _error = 'Resolve conflicting retained transfers before preparing or applying a new copy.';
      _publish();
      return;
    }
    if (_workspace != null ||
        _active != null ||
        _cohortImporter == null ||
        !_claimTransfer('cohort', cleanup: true)) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    try {
      _cohortImporter!.select(attempt);
      await _cohortImporter!.retry(
        attempt,
        build: _buildCohort,
        apply: _applyCohort,
      );
      if (!_stopping) await _discover();
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> discardCohort(CohortAttempt attempt) async {
    if (_workspace != null ||
        _active != null ||
        _cohortImporter == null ||
        !_claimTransfer('cohort', cleanup: true)) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    try {
      _cohortImporter!.select(attempt);
      await _cohortImporter!.discard(attempt, recover: _applyCohort);
      if (!_stopping) await _discover();
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> renameCohortTarget(CohortAttempt attempt, String name) async {
    if (_shareForOperation(attempt.id) != null) {
      _error = 'The destination of a claimed shared item is immutable.';
      _publish();
      return;
    }
    if (_workspace != null ||
        _active != null ||
        _cohortImporter == null ||
        !_claimTransfer('cohort')) {
      return;
    }
    try {
      _cohortImporter!.select(attempt);
      await _cohortImporter!.setFolderName(attempt, name);
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  void cancelCohort() => _cohortImporter?.cancel();
  void cancelResource() => _resourceTransfer?.cancel();

  ResourceTarget resourceTarget(
    NotebookWorkspace workspace,
    NotebookSession session,
  ) {
    final note = session.value.note;
    if (!identical(_workspace, workspace) ||
        !identical(workspace.value.session, session) ||
        note == null ||
        _stopping) {
      throw StateError('The selected note has changed.');
    }
    return ResourceTarget(
      notebookId: note.notebookId,
      nodeId: note.nodeId,
      notebookRelative: p.basename(workspace.notebookLocation),
    );
  }

  Future<void> refreshResources(
    NotebookWorkspace workspace,
    NotebookSession session,
  ) async {
    await workspace.settleSyncAttachment();
    final target = resourceTarget(workspace, session);
    if (_resourceTransfer == null || !_claimTransfer('resource', cleanup: true)) {
      return;
    }
    try {
      await session.withResources(
        (core) =>
            _resourceTransfer!.refresh(target, (target, cancellation) async {
              cancellation.onCancel = core.cancelResourceRead;
              try {
                cancellation.check();
                return await core.listResources();
              } finally {
                cancellation.onCancel = null;
              }
            }),
      );
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> changeResource(
    NotebookWorkspace workspace,
    NotebookSession session,
    ResourceOperation operation,
    String name, {
    String? newName,
  }) async {
    await workspace.settleSyncAttachment();
    final target = resourceTarget(workspace, session);
    if (_resourceTransfer == null || !_claimTransfer('resource')) return;
    try {
      await session.withResources((core) async {
        final attempt = await _resourceTransfer!.start(
          target: target,
          operation: operation,
          name: name,
          newName: newName,
          origin: operation == ResourceOperation.export ? ResourceExportOrigin.asset : null,
          binding: operation == ResourceOperation.export ? {'name': name} : null,
        );
        if (attempt == null ||
            attempt.target.notebookId != target.notebookId ||
            attempt.target.nodeId != target.nodeId ||
            _stopping) {
          return;
        }
        if (operation == ResourceOperation.export) {
          await _resourceTransfer!.prepareExport(
            attempt,
            (attempt, cancellation) =>
                _exportResourceOnCore(core, attempt, cancellation),
          );
        } else {
          if (attempt.stage == TransferStage.source ||
              attempt.stage == TransferStage.prepared) {
            await _resourceTransfer!.apply(
              attempt,
              (attempt, cancellation, recover) =>
                  _applyResourceOnCore(core, attempt, cancellation, recover),
            );
          }
        }
        if (operation == ResourceOperation.export ||
            (attempt.stage != TransferStage.source &&
                attempt.stage != TransferStage.prepared)) {
          await _refreshResourceListing(core, target);
        }
        final ready = _resourceTransfer!.value.current;
        if (!_stopping &&
            operation == ResourceOperation.export &&
            ready?.stage == TransferStage.exportReady) {
          await _resourceTransfer!.save(ready!);
        }
      });
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> resolveSessionResource(
    NotebookWorkspace workspace,
    NotebookSession session,
    ResourceAttempt attempt, {
    bool discard = false,
    bool abandon = false,
  }) async {
    await workspace.settleSyncAttachment();
    final target = resourceTarget(workspace, session);
    if (attempt.target.notebookId != target.notebookId ||
        attempt.target.nodeId != target.nodeId ||
        _resourceTransfer == null ||
        !_claimTransfer('resource', cleanup: true)) {
      return;
    }
    try {
      await session.withResources((core) async {
        _resourceTransfer!.select(attempt);
        var inspected = false;
        Future<CoreResourceResult> apply(
          ResourceAttempt current,
          TransferCancellation cancellation,
          bool recover,
        ) async {
          try {
            return await _applyResourceOnCore(
              core,
              current,
              cancellation,
              recover,
            );
          } finally {
            inspected = true;
          }
        }

        if (discard) {
          await _resourceTransfer!.discard(
            attempt,
            recover: apply,
            abandon: abandon,
          );
          if (!_resourceTransfer!.value.attempts.any((item) => item.id == attempt.id)) {
            await _releaseExportSource(attempt);
          }
        } else if (attempt.operation == ResourceOperation.export) {
          if (attempt.stage != TransferStage.exportReady) {
            await _resourceTransfer!.prepareExport(
              attempt,
              (attempt, cancellation) =>
                  _exportResourceOnCore(core, attempt, cancellation),
            );
          }
        } else {
          await _resourceTransfer!.retry(attempt, apply);
        }
        if (!inspected) await _refreshResourceListing(core, target);
        final current = _resourceTransfer!.value.current;
        if (!discard &&
            !_stopping &&
            current?.stage == TransferStage.exportReady) {
          await _resourceTransfer!.save(current!);
        }
      });
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
  }

  Future<void> shareResource(ResourceAttempt attempt) async {
    if (_resourceTransfer == null || !_claimTransfer('resource')) return;
    try {
      _resourceTransfer!.select(attempt);
      await _resourceTransfer!.share(attempt, _shareInbox);
    } on Object catch (error) { _error = _describe(error); }
    finally { _finishTransferCall(); }
  }

  Future<void> retryResource(ResourceAttempt attempt) async {
    if (_transferOwner == 'blocked' &&
        attempt.stage != TransferStage.intent &&
        attempt.stage != TransferStage.quarantined &&
        attempt.stage != TransferStage.exportReady) {
      _error =
          'Resolve conflicting retained transfers before applying a resource.';
      _publish();
      return;
    }
    if (_workspace != null ||
        _active != null ||
        _resourceTransfer == null ||
        !_claimTransfer('resource', cleanup: true)) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    final admission = _active!;
    void releaseAdmission() {
      if (identical(_active, admission)) _retire();
    }

    try {
      _resourceTransfer!.select(attempt);
      if (attempt.operation == ResourceOperation.export) {
        if (attempt.stage != TransferStage.exportReady) {
          await _resourceTransfer!.prepareExport(
            attempt,
            _exportRetainedResource,
          );
        }
        final ready = _resourceTransfer!.value.current;
        releaseAdmission();
        if (!_stopping && ready?.stage == TransferStage.exportReady) {
          await _resourceTransfer!.save(ready!);
        }
      } else {
        await _resourceTransfer!.retry(attempt, _applyRetainedResource);
        if (!_stopping) await _discover();
      }
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      releaseAdmission();
      _finishTransferCall();
    }
  }

  Future<void> discardResource(
    ResourceAttempt attempt, {
    bool abandon = false,
  }) async {
    if (_workspace != null ||
        _active != null ||
        _resourceTransfer == null ||
        !_claimTransfer('resource', cleanup: true)) {
      return;
    }
    if (!_admit()) {
      _finishTransferCall();
      return;
    }
    try {
      _resourceTransfer!.select(attempt);
      await _resourceTransfer!.discard(
        attempt,
        recover: _applyRetainedResource,
        abandon: abandon,
      );
      if (!_resourceTransfer!.value.attempts.any((item) => item.id == attempt.id)) {
        await _releaseExportSource(attempt);
      }
      if (!_stopping) await _discover();
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _retire();
      _finishTransferCall();
    }
  }

  Future<void> discardOfflineLeftover(
    TransferLeftover item, {
    required bool cohort,
  }) async {
    if (_workspace != null ||
        _active != null ||
        !item.canDiscard ||
        !_claimTransfer(cohort ? 'cohort' : 'resource', cleanup: true)) {
      return;
    }
    try {
      if (cohort) {
        await _cohortImporter!.discardLeftover(item);
      } else {
        await _resourceTransfer!.discardLeftover(item);
      }
    } on Object catch (error) {
      _error = _describe(error);
    } finally {
      _finishTransferCall();
    }
    if (!_stopping) await refresh();
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

  Future<void> connectWebDav({required String endpoint, required String username,
      required String password, bool autoSyncEnabled = false}) async {
    if (_workspace != null || _active != null || _stale || _importer == null ||
        !_claimTransfer('import')) { return; }
    try {
      final canonical = canonicalSyncEndpoint(endpoint);
      if (!await syncCredentials.vault.trustAvailable()) {
        throw StateError('The native HTTPS trust provider is unavailable.');
      }
      final operation = newSyncOperationId();
      await _importer!.prepareWebDav(operationId: operation,
        configuration: CoreSyncConfiguration(endpoint: canonical, autoSyncEnabled: autoSyncEnabled),
        loadCredentials: (attempt) async {
          final staged = await syncCredentials.stageClone(operationId: operation,
            endpoint: canonical, username: username, password: password,
            autoSyncEnabled: autoSyncEnabled);
          return syncCredentials.cloneCredentials(staged);
        });
    } on SyncVaultException {
      _error = 'Secure credential storage is unavailable or changed. Connection staging is retained.';
    } on Object catch (error) {
      _error = _describe(error);
    } finally { _finishTransferCall(); }
  }

  Future<CoreSyncCloneReceipt> _cloneReceipt(ImportAttempt attempt) async {
    if (!attempt.isWebDavClone || attempt.operationId == null) {
      throw StateError('The WebDAV clone identity is unavailable.');
    }
    final record = await _importer!.runStore({'op': 'inspectClone', 'id': attempt.id,
      'operationId': attempt.operationId!}, cancellationAddress: 0);
    return CoreSyncCloneReceipt.fromJson(record);
  }

  Future<SyncClonePublicationReceipt> _clonePublication(ImportAttempt attempt,
      SyncCloneCredentials clone, {bool requireCommitted = false}) async {
    final actual = await _importer!.runStore({'op': 'recover', 'id': attempt.id}, cancellationAddress: 0);
    if (actual['origin'] != 'webdavClone' || actual['operationId'] != clone.operationId ||
        actual['id'] != attempt.id) { throw StateError('The clone publication identity changed.'); }
    final phase = actual['phase'];
    if (phase != 'staged' && phase != 'published' && phase != 'committed') {
      throw StateError('Clone publication is unresolved.');
    }
    if (requireCommitted && phase != 'committed') throw StateError('The final import receipt is unavailable.');
    final published = phase == 'published' || phase == 'committed';
    if (published && actual['notebookId'] != clone.notebookId) {
      throw StateError('The published clone notebook identity changed.');
    }
    return SyncClonePublicationReceipt(operationId: clone.operationId,
      importId: attempt.id, notebookId: published ? actual['notebookId'] as String? : clone.notebookId,
      endpoint: clone.provisionalScope.endpoint, published: published);
  }

  Future<void> _stageCloneRekey(ImportAttempt attempt) async {
    if (!attempt.isWebDavClone) return;
    final receipt = await _cloneReceipt(attempt);
    final clone = await syncCredentials.recoverClone(receipt.endpoint, receipt.operationId);
    await syncCredentials.rekeyClone(clone, notebookId: receipt.notebookId,
      importId: receipt.importId, cloneReceipt: receipt);
  }

  Future<void> _finishCloneCredentials(ImportAttempt attempt,
      Map<String, Object?> publication) async {
    if (!attempt.isWebDavClone || publication['credentialsSettled'] == true) return;
    if (publication['phase'] != 'committed') throw StateError('Clone credentials require a committed import receipt.');
    final receipt = await _cloneReceipt(attempt);
    final clone = await syncCredentials.findClone(receipt.operationId);
    final targetScope = SyncCredentialScope.notebook(receipt.endpoint, receipt.notebookId);
    if (clone != null && clone.notebookId != receipt.notebookId) {
      throw StateError('Clone credential rekey has not been proved.');
    }
    // Configure routing only AFTER native publication. There is deliberately no
    // network or claim of current authentication here; workspace reconcile owns it.
    final destination = publication['destination'] as String;
    final paths = await _storage!.existing(destination);
    final core = await _openCatalog(paths, receipt.notebookId);
    _temporary = core;
    try {
      final result = await core.sync(CoreSyncCommand(action: CoreSyncAction.configure,
        operationId: receipt.operationId, cloneImportId: attempt.id,
        configuration: CoreSyncConfiguration(
          endpoint: receipt.endpoint, autoSyncEnabled: receipt.autoSyncEnabled)));
      if (!result.success) throw StateError('Imported notebook routing still requires recovery.');
    } finally { await _release(core); }
    if (clone != null) {
      await syncCredentials.promoteClone(clone,
        readPublicationReceipt: () => _clonePublication(attempt, clone, requireCommitted: true));
    } else {
      // A promotion may have removed provisional storage before its reply was
      // lost. Read the actual destination; never overwrite a later generation.
      final target = await syncCredentials.read(targetScope);
      if (!target.present || target.pending || !target.hasUsableCredentials) {
        throw StateError('The imported notebook is retained while credential promotion is unresolved.');
      }
    }
    await _importer!.runStore({'op': 'finishCloneCredentials', 'id': attempt.id,
      'operationId': receipt.operationId}, cancellationAddress: 0);
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
      if (attempt.isWebDavClone) {
        final actual = await _importer!.runStore({'op': 'recover', 'id': attempt.id}, cancellationAddress: 0);
        if (actual['phase'] != 'staged') {
          throw StateError('Finish published clone credential recovery before discarding its private receipt.');
        }
        final clone = await syncCredentials.findClone(attempt.operationId!);
        if (clone != null) {
          await syncCredentials.abandonClone(clone,
            readPublicationReceipt: () => _clonePublication(attempt, clone));
        }
      }
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
          _blockedNotebook(candidate.paths.notebook) ||
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
      await _finishCloneCredentials(attempt, status);
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
    if (!published) await _stageCloneRekey(attempt);
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
    if (attempt.isWebDavClone) {
      final committed = await importer.runStore({'op': 'recover', 'id': attempt.id}, cancellationAddress: 0);
      await _finishCloneCredentials(attempt, committed);
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
        !_claimTransfer('import', cleanup: true)) {
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
          final ledger = await runTransferStore({
            'op': 'checkSpace',
            'scope': 'cohort',
            'root': _cohortImporter!.root,
            'notebooksRoot': p.normalize(_storage!.root),
            'id': '00000000000000000000000000000000',
            'requiredBytes': 0,
          });
          cancellation.check();
          final remaining = (ledger['remainingBytes'] as int) - 128 * 1024;
          final captureBudget = remaining < budget ? remaining : budget;
          if (captureBudget <= 0) {
            throw StateError('Private transfer staging is full.');
          }
          final core = await _openExportCatalog(paths, entry.notebookId!);
          _temporary = core;
          try {
            cancellation.onCancel = core.cancelExport;
            cancellation.check();
            if (_stopping) throw StateError('The notebook library is closing.');
            return await core.exportSnapshot(
              destination,
              stagingBudgetBytes: captureBudget,
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

  Future<void> shareExport(PreparedNotebookExport prepared) async {
    if (_exporter == null || !_claimTransfer('export')) return;
    try { await _exporter!.share(prepared, _shareInbox); }
    on Object catch (error) { _error = _describe(error); }
    finally { _finishTransferCall(); }
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
    // Platform claims quarantine their targets before even metadata discovery.
    await _scanInbox();
    // Reconcile all acknowledged source prefixes before admitting ordinary
    // catalog/body writers or transfer recovery mutations.
    Object? draftFailure;
    try { await _ensureDrafts(); } on Object catch (error) { draftFailure = error; }
    if (_stopping) return;
    _scanningTransfers = true;
    try {
      await _ensureExporter();
      await _ensureImporter();
      await _ensureOfflineTransfers();
    } finally {
      _scanningTransfers = false;
    }
    _settleTransfer();
    // A verified ready export owns its own bytes. Keep its scan/Save As visible
    // even if the original draft namespace is unavailable; no writer is admitted.
    if (draftFailure != null) throw draftFailure;
    if (_stopping) return;
    await _reconcileInbox();
    await _recoverOfflineTransfers();
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
      if (_blockedNotebook(candidate.paths.notebook)) {
        failure = 'A retained file/resource transfer requires recovery; this notebook is quarantined.';
      }
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
    _inboxReady = _shareInbox.value.initialized && !_inboxScanning;
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
    workspace.attachDrafts(_drafts!);
    workspace.attachSyncCredentials(syncCredentials);
    workspace.setForeground(_foreground && _inboxReady && !_inboxScanning);
    _workspace = workspace;
    await workspace.initialize();
    if (_stopping) return false;
    if (workspace.value.directory == null ||
        (workspace.value.stale && !workspace.value.syncRecoveryRequired)) {
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
        _blockedNotebook(entry.location) ||
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
    if (_workspace != null || _stale || _unknownTransferTarget || !_admit()) {
      return false;
    }
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
        workspace.value.session != null || workspace.value.busy || workspace.value.closed ||
        !_admit()) {
      return false;
    }
    String? closeError;
    try {
      try {
        final cleanup = await workspace.synchronization.closeNotebook();
        if (!cleanup.success) closeError = cleanup.error ?? 'Credential cleanup remains pending for this notebook.';
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
    ++_foregroundEpoch;
    _exporter?.cancel();
    _importer?.cancel();
    _cohortImporter?.cancel();
    _resourceTransfer?.cancel();
    _publish();
    // Providers and native transfer workers must release every lease before
    // their borrowed NOTE owner or a selected workspace can be retired.
    try {
      await Future.wait<void>([
        if (_cohortImporter != null) _cohortImporter!.shutdown(),
        if (_resourceTransfer != null) _resourceTransfer!.shutdown(),
        if (_exporter != null) _exporter!.shutdown(),
        if (_importer != null) _importer!.shutdown(),
      ]);
    } on Object catch (error) {
      _error = _describe(error);
    }
    await _transferLease?.future;
    await _active?.future;
    await _resumeFuture;
    try {
      await _workspace?.shutdown();
    } finally {
      _workspace?.dispose();
      _workspace = null;
      try {
        final core = _temporary;
        if (core != null) await _release(core);
        await _temporaryResource?.close();
        _temporaryResource = null;
        await _drafts?.shutdown();
        _drafts?.removeListener(_publish);
        _drafts?.dispose();
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
          _cohortImporter?.removeListener(_transferChanged);
          _cohortImporter?.dispose();
          _resourceTransfer?.removeListener(_transferChanged);
          _shareInbox.dispose();
          _resourceTransfer?.dispose();
        }
      }
    }
  }

  static CohortImporter _cohortImporterFor(
    String root,
    String notebooksRoot,
    void Function(Object) reserve,
    void Function(Object) release,
  ) => CohortImporter(
    root: root,
    notebooksRoot: notebooksRoot,
    reserveTransfer: reserve,
    releaseTransfer: release,
  );

  static ResourceTransfer _resourceTransferFor(
    String root,
    String notebooksRoot,
    void Function(Object) reserve,
    void Function(Object) release,
  ) => ResourceTransfer(
    root: root,
    notebooksRoot: notebooksRoot,
    reserveTransfer: reserve,
    releaseTransfer: release,
  );

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
