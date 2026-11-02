// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/managed_notebook_storage.dart';
import 'package:vnote_mobile/services/notebook_library.dart';
import 'package:vnote_mobile/services/notebook_export.dart';
import 'package:vnote_mobile/services/notebook_import.dart';
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/notebook_workspace.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';
import 'package:vnote_mobile/services/cohort_import.dart';
import 'package:vnote_mobile/services/resource_transfer.dart';
import 'package:vnote_mobile/services/notebook_session.dart';

import 'notebook_session_test.dart' as protocol show ready, insert, answer;

class _Owners {
  int active = 0;
  int maximum = 0;
  Completer<void>? closeGate;
  Completer<void>? closeEntered;
  Completer<void>? openingGate;
  bool failClose = false;
  void acquire() {
    active++;
    if (active > maximum) maximum = active;
    expect(active, 1);
  }

  Future<CatalogCore> open(ManagedNotebookPaths paths, String? id) async {
    acquire();
    try {
      await openingGate?.future;
      return _Catalog(
        await CoreNotebook.openCatalog(
          appDataPath: paths.app,
          localDataPath: paths.local,
          notebookPath: paths.notebook,
          expectedNotebookId: id,
        ),
        this,
      );
    } catch (_) {
      active--;
      rethrow;
    }
  }

  Future<CatalogCore> openExport(ManagedNotebookPaths paths, String id) async {
    acquire();
    try {
      return _Catalog(
        await CoreNotebook.openExportCatalog(
          appDataPath: paths.app,
          localDataPath: paths.local,
          notebookPath: paths.notebook,
          expectedNotebookId: id,
        ),
        this,
      );
    } catch (_) {
      active--;
      rethrow;
    }
  }

  Future<CatalogCore> create(ManagedNotebookPaths paths, String name) async {
    acquire();
    try {
      return _Catalog(
        await CoreNotebook.createCatalog(
          appDataPath: paths.app,
          localDataPath: paths.local,
          notebookPath: paths.notebook,
          notebookName: name,
        ),
        this,
      );
    } catch (_) {
      active--;
      rethrow;
    }
  }
}

class _Catalog implements CatalogCore {
  _Catalog(this.core, this.owners);
  final CatalogCore core;
  final _Owners owners;
  Future<void>? closing;
  @override
  CoreDirectory get initialDirectory => core.initialDirectory;
  @override
  String get nativeNotices => core.nativeNotices;
  @override
  Future<CoreDirectory> list([String? id]) => core.list(id);
  @override
  Future<String> createNote(String id, String name) =>
      core.createNote(id, name);
  @override
  Future<String> createFolder(String id, String name) =>
      core.createFolder(id, name);
  @override
  Future<void> rename(String id, String name) => core.rename(id, name);
  @override
  Future<void> renameNotebook(String name) => core.renameNotebook(name);
  @override
  Future<void> move(String id, String to) => core.move(id, to);
  @override
  Future<void> delete(String id) => core.delete(id);
  @override
  Future<CoreSearchResult> search(
    String text, {
    String? tag,
    bool caseSensitive = false,
  }) => core.search(text, tag: tag, caseSensitive: caseSensitive);
  @override
  Future<CoreTags> tags([String? id]) => core.tags(id);
  @override
  Future<void> createTag(String name) => core.createTag(name);
  @override
  Future<void> setTags(String id, List<String> tags) => core.setTags(id, tags);
  @override
  void cancelSearch() => core.cancelSearch();
  @override
  Future<List<String>> collectNodeIds() => core.collectNodeIds();
  @override
  Future<CoreExportSnapshot> exportSnapshot(
    String destination, {
    required int stagingBudgetBytes,
    required CoreExportFormat format,
  }) => core.exportSnapshot(
    destination,
    stagingBudgetBytes: stagingBudgetBytes,
    format: format,
  );
  @override
  void cancelExport() => core.cancelExport();
  @override
  Future<CoreCohortOutcome> applyCohort(String root) => core.applyCohort(root);
  @override
  Future<CoreCohortOutcome> recoverCohort(String root) =>
      core.recoverCohort(root);
  @override
  Future<void> close() => closing ??= _close();
  Future<void> _close() async {
    final gate = owners.closeGate;
    owners.closeGate = null;
    final entered = owners.closeEntered;
    owners.closeEntered = null;
    if (entered != null && !entered.isCompleted) entered.complete();
    await gate?.future;
    try {
      await core.close();
    } finally {
      owners.active--;
    }
    if (owners.failClose) {
      owners.failClose = false;
      throw StateError('Close reported an error after join.');
    }
  }
}

class _ExportProvider implements DocumentTransferPlatform {
  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  }) async => const DocumentImportResult(
    status: DocumentImportStatus.unavailable,
    sourceName: null,
    bytes: 0,
    entries: 0,
  );
  @override
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {}

  final entered = Completer<String>();
  final result = Completer<DocumentExportResult>();
  int saves = 0;
  @override
  Future<void> prepareStorage() async {}
  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  }) async {
    saves++;
    final reader = await File(path).open();
    try {
      entered.complete(path);
      return await result.future;
    } finally {
      await reader.close();
    }
  }

  @override
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    if (!result.isCompleted) {
      result.complete(
        const DocumentExportResult(
          status: DocumentExportStatus.cancelled,
          externalMayBeIncomplete: true,
        ),
      );
    }
  }
}

class _ImportProvider implements DocumentTransferPlatform {
  _ImportProvider(this.source, this.importsRoot);
  final String source;
  final String importsRoot;
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<void> prepareStorage() async {}
  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  }) async => const DocumentExportResult(
    status: DocumentExportStatus.unavailable,
    externalMayBeIncomplete: false,
  );
  @override
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {}
  @override
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {}
  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  }) async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await gate?.future;
    final transaction = p.join(importsRoot, operationId);
    final target = p.join(transaction, 'unpacked');
    await _copyTree(Directory(source), Directory(target));
    final accepted = <Map<String, Object>>[];
    var bytes = 0;
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      final path = p.relative(entity.path, from: source).replaceAll('\\', '/');
      accepted.add({
        'path': path,
        'type': entity is Directory ? 'directory' : 'file',
      });
      if (entity is File) bytes += await entity.length();
    }
    await File(p.join(transaction, 'accepted.jsonl'))
        .writeAsString('${accepted.map(jsonEncode).join('\n')}\n', flush: true);
    return DocumentImportResult(
      status: DocumentImportStatus.ready,
      sourceName: 'Desktop fixture',
      bytes: bytes,
      entries: accepted.length,
    );
  }
}

Future<void> _copyTree(Directory source, Directory target) async {
  await target.create();
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final suffix = entity.path.substring(source.path.length);
    if (entity is Directory) {
      await Directory('${target.path}$suffix').create(recursive: true);
    }
    if (entity is File) {
      final copy = File('${target.path}$suffix');
      await copy.parent.create(recursive: true);
      await entity.copy(copy.path);
    }
  }
}

void main() {
  late Directory temp;
  late ManagedNotebookStorage storage;
  late _Owners owners;
  late NotebookLibrary library;
  NotebookLibrary makeLibrary({
    LibraryCreateCatalog? create,
    DocumentTransferPlatform? exportPlatform,
    DocumentTransferPlatform? importPlatform,
    DocumentTransferPlatform? cohortPlatform,
    DocumentTransferPlatform? resourcePlatform,
  }) => NotebookLibrary(
    obtainStorage: () async => storage,
    openCatalog: owners.open,
    openExportCatalog: owners.openExport,
    createExporter: (root, admission) => NotebookExporter(
      root: root,
      platform: exportPlatform,
      checkAdmission: admission,
    ),
    createImporter: (root, notebooksRoot, admission) => NotebookImporter(
      root: root,
      notebooksRoot: notebooksRoot,
      platform: importPlatform,
      checkAdmission: admission,
    ),
    createCohortImporter: (root, notebooksRoot, reserve, release) =>
        CohortImporter(
          root: root,
          notebooksRoot: notebooksRoot,
          platform: cohortPlatform,
          reserveTransfer: reserve,
          releaseTransfer: release,
        ),
    createResourceTransfer: (root, notebooksRoot, reserve, release) =>
        ResourceTransfer(
          root: root,
          notebooksRoot: notebooksRoot,
          platform: resourcePlatform,
          reserveTransfer: reserve,
          releaseTransfer: release,
        ),
    createCatalog: create ?? owners.create,
    createWorkspace: (paths, id) => NotebookWorkspace(
      paths: paths,
      notebookId: id,
      openCatalog: owners.open,
    ),
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vnote-library-');
    storage = ManagedNotebookStorage(
      app: '${temp.path}/app',
      local: '${temp.path}/local',
      root: Directory('${temp.path}/notebooks').absolute.uri.toFilePath(),
    );
    await Directory(storage.root).create();
    owners = _Owners();
    library = makeLibrary();
  });
  tearDown(() async {
    await library.shutdown();
    library.dispose();
    expect(owners.active, 0);
    await temp.delete(recursive: true);
  });

  test('browser cohort groups raw assets, seals stable IDs, and leaves original nodes unchanged', () async {
    await library.shutdown();
    library.dispose();
    final source = await Directory(p.join(temp.path, 'raw-source')).create();
    final noteBytes = utf8.encode('# Imported\r\n[asset](image.bin)\r\n');
    await File(p.join(source.path, 'note.md')).writeAsBytes(noteBytes);
    await File(p.join(source.path, 'image.bin')).writeAsBytes([0, 255, 7]);
    await File(p.join(source.path, '.opaque')).writeAsBytes([3, 0, 9]);
    library = makeLibrary(
      cohortPlatform: _ImportProvider(
        source.path,
        p.join(temp.path, 'cohorts'),
      ),
    );
    await library.initialize();
    expect(await library.createNotebook('Destination'), isTrue);
    final workspace = library.value.workspace!;
    await workspace.createNote('original.md');
    final directory = workspace.value.directory!;
    final originalId = directory.entries.single.id;
    final location = workspace.notebookLocation;
    await library.importFiles(
      workspace,
      directory,
      DocumentImportKind.folder,
      'Grouped',
    );
    expect(library.value.workspace, isNull);
    expect(library.value.cohortState.current!.stage, TransferStage.source);
    expect(await Directory(p.join(location, 'Grouped')).exists(), isFalse);
    await library.retryCohort(library.value.cohortState.current!);
    final prepared = library.value.cohortState.current!;
    expect(prepared.stage, TransferStage.prepared);
    expect(prepared.cohortId, isNotNull);
    expect(await Directory(p.join(location, 'Grouped')).exists(), isFalse);
    await library.retryCohort(prepared);
    final committed = library.value.cohortState.current!;
    expect(committed.stage, TransferStage.committed);
    expect(committed.cohortId, prepared.cohortId);
    expect(
      await File(p.join(location, 'Grouped', 'note.md')).readAsBytes(),
      noteBytes,
    );
    expect(await File(p.join(location, 'Grouped', 'image.bin')).readAsBytes(), [
      0,
      255,
      7,
    ]);
    expect(await File(p.join(location, 'Grouped', '.opaque')).readAsBytes(), [
      3,
      0,
      9,
    ]);
    await library.discardCohort(committed);
    expect(library.value.transferReserved, isFalse);
    expect(await library.openNotebook(library.value.entries.single), isTrue);
    final entries = library.value.workspace!.value.directory!.entries;
    expect(
      entries.singleWhere((entry) => entry.name == 'original.md').id,
      originalId,
    );
    expect(
      entries.singleWhere((entry) => entry.name == 'Grouped').id,
      prepared.cohortId,
    );
  });

  test(
    'resource operations reuse a dirty NOTE owner and never write its source',
    () async {
      await library.shutdown();
      library.dispose();
      final source = await Directory(p.join(temp.path, 'resource-source'))
          .create();
      final bytes = [0x89, 0x50, 0x4e, 0x47, 0, 255];
      await File(p.join(source.path, 'provider.png')).writeAsBytes(bytes);
      library = makeLibrary(
        resourcePlatform: _ImportProvider(
          source.path,
          p.join(temp.path, 'resources'),
        ),
      );
      await library.initialize();
      expect(await library.createNotebook('Resources'), isTrue);
      final workspace = library.value.workspace!;
      await workspace.createNote('note.md');
      await workspace.openNote(workspace.value.directory!.entries.single);
      final session = workspace.value.session!;
      final editor = session.value.editor!;
      protocol.ready(editor);
      protocol.insert(editor, 'unsaved text');
      final sourcePath = p.join(
        workspace.notebookLocation,
        session.value.note!.path,
      );
      final savedBefore = await File(sourcePath).readAsBytes();
      await library.changeResource(
        workspace,
        session,
        ResourceOperation.image,
        'chosen.png',
      );
      expect(
        library.value.resourceState.current!.stage,
        TransferStage.committed,
        reason: '${library.value.error}; ${library.value.resourceState.error}',
      );
      final added = library.value.resourceState.listing!.entries.single;
      expect(added.name, 'chosen.png');
      expect(added.tracked, isFalse);
      final asset = File(
        p.joinAll([p.dirname(sourcePath), ...added.relativeUrl.split('/')]),
      );
      expect(await asset.readAsBytes(), bytes);
      expect(await File(sourcePath).readAsBytes(), savedBefore);
      expect(editor.value.text, 'unsaved text');
      expect(session.value.onDiskRevision, 0);
      await library.resolveSessionResource(
        workspace,
        session,
        library.value.resourceState.current!,
        discard: true,
      );
      await library.changeResource(
        workspace,
        session,
        ResourceOperation.track,
        'chosen.png',
      );
      expect(
        library.value.resourceState.listing!.entries.single.tracked,
        isTrue,
      );
      await library.resolveSessionResource(
        workspace,
        session,
        library.value.resourceState.current!,
        discard: true,
      );
      await library.changeResource(
        workspace,
        session,
        ResourceOperation.rename,
        'chosen.png',
        newName: 'renamed.png',
      );
      expect(
        library.value.resourceState.listing!.entries.single.name,
        'renamed.png',
      );
      await library.resolveSessionResource(
        workspace,
        session,
        library.value.resourceState.current!,
        discard: true,
      );
      await library.changeResource(
        workspace,
        session,
        ResourceOperation.untrack,
        'renamed.png',
      );
      expect(
        library.value.resourceState.listing!.entries.single.tracked,
        isFalse,
      );
      expect(await File(sourcePath).readAsBytes(), savedBefore);
      expect(session.value.editor, same(editor));
      expect(session.value.dirty, isTrue);
      await library.resolveSessionResource(
        workspace,
        session,
        library.value.resourceState.current!,
        discard: true,
      );
      await workspace.returnToBrowser(
        session,
        NotebookDisposition.discard,
        (message) => protocol.answer(editor, message),
      );
    },
  );

  test('cohort provider reservation blocks notebook transfers but other notebooks stay usable', () async {
    await library.shutdown();
    library.dispose();
    final source = await Directory(p.join(temp.path, 'cohort-provider'))
        .create();
    await File(p.join(source.path, 'note.md')).writeAsString('# One');
    final provider = _ImportProvider(source.path, p.join(temp.path, 'cohorts'));
    final gate = Completer<void>();
    final entered = Completer<void>();
    provider.gate = gate;
    provider.entered = entered;
    library = makeLibrary(cohortPlatform: provider);
    await library.initialize();
    await library.createNotebook('Other');
    await library.returnToLibrary(library.value.workspace!);
    final otherId = library.value.entries.single.notebookId;
    await library.createNotebook('Target');
    final target = library.value.workspace!;
    final importing = library.importFiles(
      target,
      target.value.directory!,
      DocumentImportKind.folder,
      'Batch',
    );
    try {
      await Future.any([
        entered.future,
        importing.then<void>((_) => throw StateError('Provider not entered')),
      ]);
      expect(library.value.transferReserved, isTrue);
      final other = library.value.entries.singleWhere(
        (entry) => entry.notebookId == otherId,
      );
      await library.exportNotebook(other, format: CoreExportFormat.notebook);
      await library.prepareImport(DocumentImportKind.folder);
      expect(
        await Directory(await storage.obtainExportRoot()).list().isEmpty,
        isTrue,
      );
      expect(
        await Directory(await storage.obtainImportRoot()).list().isEmpty,
        isTrue,
      );
      expect(await library.openNotebook(other), isTrue);
      library.cancelCohort();
    } finally {
      gate.complete();
    }
    await importing;
    expect(library.value.workspace!.notebookId, otherId);
    await library.returnToLibrary(library.value.workspace!);
    await library.discardCohort(library.value.cohortState.current!);
  });

  test('unknown resource residue is scanned before notebook writers and never silently deleted', () async {
    await library.initialize();
    await library.createNotebook('Existing');
    await library.returnToLibrary(library.value.workspace!);
    final location = library.value.entries.single.location;
    final config = File(p.join(location, 'vx_notebook', 'config.json'));
    final before = await config.readAsBytes();
    await library.shutdown();
    library.dispose();
    final residue = await Directory(
      p.join(await storage.obtainResourceRoot(), 'f' * 32),
    ).create();
    final marker = File(p.join(residue.path, 'intent.json'));
    await marker.writeAsString('{broken ownership');
    library = makeLibrary();
    final starting = library.initialize();
    expect(await library.createNotebook('Too early'), isFalse);
    await starting;
    expect(library.value.resourceState.blocksAllNotebooks, isTrue);
    expect(library.value.entries.single.canOpen, isFalse);
    expect(await library.createNotebook('Blocked by unknown target'), isFalse);
    expect(await marker.readAsString(), '{broken ownership');
    expect(await config.readAsBytes(), before);
  });

  test('shutdown and discard wait for a resource provider lease before retiring NOTE', () async {
    await library.shutdown();
    library.dispose();
    final source = await Directory(p.join(temp.path, 'pending-resource'))
        .create();
    await File(p.join(source.path, 'blob.bin')).writeAsBytes([0, 1, 2]);
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final entered = Completer<void>();
    final provider =
        _ImportProvider(source.path, p.join(temp.path, 'resources'))
          ..gate = gate
          ..entered = entered;
    library = makeLibrary(resourcePlatform: provider);
    await library.initialize();
    await library.createNotebook('Lease');
    final workspace = library.value.workspace!;
    await workspace.createNote('note.md');
    await workspace.openNote(workspace.value.directory!.entries.single);
    final session = workspace.value.session!;
    final copying = library.changeResource(
      workspace,
      session,
      ResourceOperation.add,
      'blob.bin',
    );
    await Future.any([
      entered.future,
      copying.then<void>((_) => throw StateError('Provider not entered')),
    ]);
    expect(session.value.resourcesBusy, isTrue);
    final attempt = library.value.resourceState.current!;
    await library.resolveSessionResource(
      workspace,
      session,
      attempt,
      discard: true,
    );
    expect(await Directory(attempt.transactionRoot).exists(), isTrue);
    var stopped = false;
    final closing = library.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    expect(session.value.resourcesBusy, isTrue);
    gate.complete();
    await copying;
    await closing;
    expect(stopped, isTrue);
    expect(await Directory(attempt.transactionRoot).exists(), isTrue);
  });

  test('import reservation prevents a racing export while provider lease is pending', () async {
    await library.shutdown();
    library.dispose();
    final source = await Directory(p.join(temp.path, 'provider')).create();
    await File(p.join(source.path, 'opaque')).writeAsString('not published');
    final provider = _ImportProvider(source.path, p.join(temp.path, 'imports'));
    final gate = Completer<void>();
    final entered = Completer<void>();
    provider.gate = gate;
    provider.entered = entered;
    library = makeLibrary(importPlatform: provider);
    await library.initialize();
    await library.createNotebook('Existing');
    await library.returnToLibrary(library.value.workspace!);
    final existing = library.value.entries.single;
    final preparing = library.prepareImport(DocumentImportKind.folder);
    try {
      await Future.any([
        entered.future,
        preparing.then<void>(
          (_) => throw StateError(
            library.value.importState.error ?? 'Provider not entered.',
          ),
        ),
      ]);
      await library.exportNotebook(existing, format: CoreExportFormat.notebook);
      expect(
        await Directory(await storage.obtainExportRoot()).list().isEmpty,
        isTrue,
      );
      expect(library.value.transferReserved, isTrue);
      library.cancelImport();
      expect(library.value.importState.busy, isTrue);
    } finally {
      gate.complete();
    }
    await preparing;
    expect((await storage.candidates()).length, 1);
    expect(library.value.entries.single.notebookId, existing.notebookId);
    final retained = library.value.importState.current;
    if (retained != null) await library.discardImport(retained);
  });

  test('whole folder import preserves desktop bytes and duplicate UUID never creates another root', () async {
    await library.shutdown();
    library.dispose();
    final fixture = jsonDecode(
      await File(
        '../../packages/vxcore_bridge/test/fixtures/desktop_notebook.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    final source = Directory(p.join(temp.path, 'provider-book'));
    await source.create();
    final expected = <String, List<int>>{};
    for (final item in fixture['files'] as List) {
      final path = item['path'] as String;
      final bytes = base64Decode(item['base64'] as String);
      expected[path] = bytes;
      final file = File(p.join(source.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    final provider = _ImportProvider(source.path, p.join(temp.path, 'imports'));
    library = makeLibrary(importPlatform: provider);
    await library.initialize();
    await library.prepareImport(DocumentImportKind.folder);
    final attempt = library.value.importState.current;
    expect(attempt, isNotNull, reason: library.value.importState.error);
    expect(
      attempt!.treeRelative,
      isNotNull,
      reason: library.value.importState.error,
    );
    expect(library.value.entries, isEmpty);
    expect(library.value.transferReserved, isTrue);
    await library.commitImport(attempt);
    expect(
      library.value.entries.single.notebookId,
      fixture['notebookId'],
      reason: library.value.importState.error ?? library.value.error,
    );
    final imported = library.value.entries.single;
    for (final item in expected.entries) {
      expect(
        await File(p.join(imported.location, item.key)).readAsBytes(),
        item.value,
      );
      expect(
        await File(p.join(source.path, item.key)).readAsBytes(),
        item.value,
      );
    }
    expect(owners.maximum, 1);
    await library.prepareImport(DocumentImportKind.folder);
    final duplicate = library.value.importState.current!;
    await library.commitImport(duplicate);
    expect(library.value.importState.existingNotebookId, fixture['notebookId']);
    expect((await storage.candidates()).length, 1);
    expect(await library.openExistingImportNotebook(), isTrue);
    expect(
      library.value.workspace!.value.directory!.notebookId,
      fixture['notebookId'],
    );
    await library.returnToLibrary(library.value.workspace!);
    await library.discardImport(library.value.importState.current!);
    expect(library.value.entries.single.notebookId, fixture['notebookId']);
    expect(library.value.transferReserved, isFalse);
  });

  test('export releases native owner before provider IO and never retires a newer library operation', () async {
    await library.shutdown();
    library.dispose();
    final provider = _ExportProvider();
    library = makeLibrary(exportPlatform: provider);
    await library.initialize();
    await library.createNotebook('Export source');
    await library.returnToLibrary(library.value.workspace!);
    final entry = library.value.entries.single;
    final exporting = library.exportNotebook(
      entry,
      format: CoreExportFormat.notebook,
    );
    final archive = await Future.any([
      provider.entered.future,
      exporting.then<String>(
        (_) => throw StateError(
          library.value.exportState.error ??
              'Export ended before provider entry.',
        ),
      ),
    ]);
    expect(await File(archive).exists(), isTrue);
    expect(owners.active, 0);
    expect(library.value.busy, isFalse);
    final gate = Completer<void>();
    owners.openingGate = gate;
    final opening = library.openNotebook(entry);
    try {
      expect(library.value.busy, isTrue);
      provider.result.complete(
        const DocumentExportResult(
          status: DocumentExportStatus.saved,
          externalMayBeIncomplete: false,
        ),
      );
      await exporting;
      expect(
        library.value.busy,
        isTrue,
        reason: 'Export completion must not retire the newer open.',
      );
      expect(await File(archive).exists(), isFalse);
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
    expect(await opening, isTrue);
    expect(
      library.value.workspace!.value.directory!.notebookId,
      entry.notebookId,
    );
    expect(owners.maximum, 1);
  });

  test(
    'cancel after snapshot waits for join and never starts the provider',
    () async {
      await library.shutdown();
      library.dispose();
      final provider = _ExportProvider();
      library = makeLibrary(exportPlatform: provider);
      await library.initialize();
      await library.createNotebook('Cancel source');
      await library.returnToLibrary(library.value.workspace!);
      final gate = Completer<void>();
      final entered = Completer<void>();
      owners.closeGate = gate;
      owners.closeEntered = entered;
      final exporting = library.exportNotebook(
        library.value.entries.single,
        format: CoreExportFormat.notebook,
      );
      try {
        await Future.any([
          entered.future,
          exporting.then<void>(
            (_) => throw StateError(
              library.value.exportState.error ??
                  'Export ended before owner close.',
            ),
          ),
        ]);
        library.cancelExport();
        expect(library.value.busy, isTrue);
        expect(owners.active, 1);
        expect(provider.saves, 0);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
      await exporting;
      expect(library.value.exportState.prepared, isNull);
      expect(library.value.exportState.busy, isFalse);
      expect(provider.saves, 0);
      expect(owners.active, 0);
      expect(await library.openNotebook(library.value.entries.single), isTrue);
    },
  );

  test(
    'create, rename, switch and restart preserve independent notebook data',
    () async {
      await library.initialize();
      expect(library.value.entries, isEmpty);
      expect(await Directory('${storage.root}/Personal').exists(), isFalse);
      expect(await library.createNotebook('Research'), isTrue);
      var workspace = library.value.workspace!;
      final firstId = workspace.value.directory!.notebookId;
      final created = await workspace.createNote('same.md');
      final firstNode = created!.nodeId!;
      final renamed = await workspace.renameNotebook('研究 notebook');
      expect(renamed!.applied, isTrue);
      expect(workspace.value.directory!.notebookName, '研究 notebook');
      expect(await library.returnToLibrary(workspace), isTrue);
      final first = library.value.entries.single;
      expect(first.notebookId, firstId);
      expect(await library.createNotebook('Other'), isTrue);
      workspace = library.value.workspace!;
      final secondId = workspace.value.directory!.notebookId;
      expect(secondId, isNot(firstId));
      final secondNode = (await workspace.createNote('same.md'))!.nodeId!;
      expect(secondNode, isNot(firstNode));
      expect(await library.returnToLibrary(workspace), isTrue);
      final second = library.value.entries.singleWhere(
        (entry) => entry.notebookId == secondId,
      );
      // Use real native editors between library owners, preserving the same basename.
      for (final item in [
        (first, firstNode, 'research body'),
        (second, secondNode, 'other body'),
      ]) {
        final core = await CoreNotebook.openNote(
          appDataPath: storage.app,
          localDataPath: storage.local,
          notebookPath: item.$1.location,
          notebookId: item.$1.notebookId!,
          nodeId: item.$2,
        );
        final before = await core.read();
        await core.write(item.$3, revision: 1, baseHash: before.baseHash);
        await core.close();
      }
      await library.shutdown();
      library.dispose();
      library = makeLibrary();
      await library.initialize();
      expect(library.value.entries.map((entry) => entry.notebookId).toSet(), {
        firstId,
        secondId,
      });
      for (final item in [
        (firstId, 'research body'),
        (secondId, 'other body'),
      ]) {
        final entry = library.value.entries.singleWhere(
          (entry) => entry.notebookId == item.$1,
        );
        expect(await library.openNotebook(entry), isTrue);
        workspace = library.value.workspace!;
        expect(workspace.value.directory!.entries.single.name, 'same.md');
        expect(await workspace.search(item.$2), isTrue);
        expect(
          workspace.value.search!.matches.single.id,
          item.$1 == firstId ? firstNode : secondNode,
        );
        expect(
          await workspace.search(
            item.$1 == firstId ? 'other body' : 'research body',
          ),
          isTrue,
        );
        expect(workspace.value.search!.matches, isEmpty);
        await library.returnToLibrary(workspace);
      }
      expect(owners.maximum, 1);
    },
  );

  test(
    'legacy Personal is discovered without moving or regenerating identities',
    () async {
      final paths = ManagedNotebookPaths(
        app: storage.app,
        local: storage.local,
        notebook: Directory('${storage.root}/Personal').absolute.uri
            .toFilePath(),
      );
      final catalog = await owners.create(paths, 'Personal');
      final id = catalog.initialDirectory.notebookId;
      await catalog.createNote(catalog.initialDirectory.folderId, 'keep.md');
      await catalog.close();
      final config = File('${paths.notebook}/vx_notebook/config.json');
      final before = await config.readAsBytes();
      await library.initialize();
      expect(
        await FileSystemEntity.identical(
          library.value.entries.single.location,
          paths.notebook,
        ),
        isTrue,
      );
      expect(library.value.entries.single.notebookId, id);
      expect(await config.readAsBytes(), before);
      expect(await library.openNotebook(library.value.entries.single), isTrue);
      expect(
        library.value.workspace!.value.directory!.entries.single.name,
        'keep.md',
      );
    },
  );

  test('stale entries and missing roots never open replacements or recreate notebooks', () async {
    await library.initialize();
    await library.createNotebook('Keep');
    await library.returnToLibrary(library.value.workspace!);
    final stale = library.value.entries.single;
    await library.refresh();
    expect(await library.openNotebook(stale), isFalse);
    final current = library.value.entries.single;
    await Directory(current.location).rename('${temp.path}/removed');
    expect(await library.openNotebook(current), isFalse);
    expect(library.value.workspace, isNull);
    expect(library.value.error, isNotNull);
    expect(await Directory(current.location).exists(), isFalse);
    expect(library.value.entries, isEmpty);
  });

  test('library return never discards an open editor', () async {
    await library.initialize();
    await library.createNotebook('Editing');
    final workspace = library.value.workspace!;
    await workspace.createNote('keep.md');
    expect(
      await workspace.openNote(workspace.value.directory!.entries.single),
      isTrue,
    );
    final session = workspace.value.session;
    expect(await library.returnToLibrary(workspace), isFalse);
    expect(library.value.workspace, same(workspace));
    expect(workspace.value.session, same(session));
    expect(session!.value.closed, isFalse);
  });

  test(
    'a replaced root cannot substitute a different notebook for a current row',
    () async {
      await library.initialize();
      await library.createNotebook('First');
      await library.returnToLibrary(library.value.workspace!);
      final first = library.value.entries.single;
      await library.createNotebook('Second');
      await library.returnToLibrary(library.value.workspace!);
      final selected = library.value.entries.singleWhere(
        (entry) => entry.notebookId == first.notebookId,
      );
      final replacement = library.value.entries.singleWhere(
        (entry) => entry.notebookId != first.notebookId,
      );
      await Directory(selected.location).rename('${temp.path}/original');
      await Directory(replacement.location).rename(selected.location);
      expect(await library.openNotebook(selected), isFalse);
      expect(library.value.workspace, isNull);
      expect(library.value.error, isNotNull);
      final config = jsonDecode(
        await File('${selected.location}/vx_notebook/config.json')
            .readAsString(),
      );
      expect(config['id'], replacement.notebookId);
      expect(config['name'], 'Second');
      expect(library.value.entries.single.notebookId, replacement.notebookId);
    },
  );

  test(
    'duplicate UUID roots remain unchanged and neither can be selected',
    () async {
      await library.initialize();
      await library.createNotebook('Original');
      await library.returnToLibrary(library.value.workspace!);
      final original = library.value.entries.single;
      final copy = Directory('${storage.root}/duplicate');
      await _copyTree(Directory(original.location), copy);
      final before = await File('${copy.path}/vx_notebook/config.json')
          .readAsBytes();
      await library.refresh();
      expect(library.value.entries.map((entry) => entry.notebookId).toSet(), {
        original.notebookId,
      });
      expect(
        library.value.entries.every(
          (entry) => !entry.canOpen && entry.error != null,
        ),
        isTrue,
      );
      for (final entry in library.value.entries) {
        expect(await library.openNotebook(entry), isFalse);
      }
      expect(
        await File('${copy.path}/vx_notebook/config.json').readAsBytes(),
        before,
      );
      expect(
        jsonDecode(
          await File('${original.location}/vx_notebook/config.json')
              .readAsString(),
        )['id'],
        original.notebookId,
      );
    },
  );

  test('return waits for owner join and retired workspace callbacks cannot switch again', () async {
    await library.initialize();
    await library.createNotebook('Joined');
    final workspace = library.value.workspace!;
    final gate = Completer<void>();
    owners.closeGate = gate;
    final returning = library.returnToLibrary(workspace);
    await Future<void>.delayed(Duration.zero);
    expect(library.value.busy, isTrue);
    expect(await library.refresh(), isFalse);
    expect(await library.createNotebook('Forbidden overlap'), isFalse);
    expect(owners.active, 1);
    gate.complete();
    expect(await returning, isTrue);
    expect(owners.active, 0);
    await library.openNotebook(library.value.entries.single);
    expect(await library.returnToLibrary(workspace), isFalse);
    expect(library.value.workspace, isNot(same(workspace)));
    expect(owners.maximum, 1);
  });

  test(
    'close error after join returns to recoverable library with explicit error',
    () async {
      await library.initialize();
      await library.createNotebook('Close error');
      owners.failClose = true;
      expect(await library.returnToLibrary(library.value.workspace!), isTrue);
      expect(library.value.workspace, isNull);
      expect(library.value.error, contains('after join'));
      expect(library.value.entries.single.canOpen, isTrue);
      expect(owners.active, 0);
      expect(await library.openNotebook(library.value.entries.single), isTrue);
    },
  );

  test(
    'failed creation exposes its partial root without repairing or deleting it',
    () async {
      await library.shutdown();
      library.dispose();
      String? failedPath;
      library = makeLibrary(
        create: (paths, name) async {
          failedPath = paths.notebook;
          await Directory(paths.notebook).create();
          await File('${paths.notebook}/opaque')
              .writeAsString('partial creation');
          throw StateError('Creation failed before metadata publication.');
        },
      );
      await library.initialize();
      expect(await library.createNotebook('Failure'), isFalse);
      expect(library.value.error, contains('Creation failed'));
      expect(library.value.entries.single.canOpen, isFalse);
      expect(
        await File('$failedPath/opaque').readAsString(),
        'partial creation',
      );
      expect(
        await File('$failedPath/vx_notebook/config.json').exists(),
        isFalse,
      );
    },
  );

  test('shutdown during discovery drains the pending owner without publishing selection', () async {
    final paths = await storage.allocate();
    final core = await owners.create(paths, 'Delayed');
    await core.close();
    final gate = Completer<void>();
    owners.openingGate = gate;
    final starting = library.initialize();
    while (owners.active == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final closing = library.shutdown();
    expect(await library.createNotebook('After shutdown'), isFalse);
    gate.complete();
    await starting;
    await closing;
    expect(library.value.closed, isTrue);
    expect(library.value.workspace, isNull);
    expect(owners.active, 0);
  });
}
