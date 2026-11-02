// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/notebook_import.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Provider implements DocumentTransferPlatform {
  int preparations = 0;
  int picks = 0;
  int cancellations = 0;
  bool rejectPreparation = false;
  final entered = Completer<void>();
  late Future<DocumentImportResult> Function(String, DocumentImportKind) copy;
  Future<DocumentImportResult> Function(String, DocumentImportKind)? outcome;
  Completer<void>? cancellationReply;

  @override
  Future<void> prepareStorage() async {
    preparations++;
    if (rejectPreparation) throw StateError('secret/provider/location');
  }

  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentImportKind kind,
  }) async {
    picks++;
    if (!entered.isCompleted) entered.complete();
    return (outcome ?? copy)(operationId, kind);
  }

  @override
  Future<void> cancelImport(String operationId) async {
    cancellations++;
    // An advisory acknowledgement deliberately does not settle the copy lease.
    await cancellationReply?.future;
  }

  @override
  Future<void> cancel(String operationId) async =>
      throw StateError('Export is not part of this provider fixture.');

  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required String path,
    required String suggestedName,
  }) async => throw StateError('Export is not part of this provider fixture.');
}

const _cancelled = DocumentImportResult(
  status: DocumentImportStatus.cancelled,
  sourceName: null,
  bytes: 0,
  entries: 0,
);

Future<Map<String, List<int>>> _snapshot(String root) async {
  final files = <String, List<int>>{};
  await for (final entity in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (entity is File) {
      files[p.relative(entity.path, from: root).replaceAll('\\', '/')] =
          await entity.readAsBytes();
    }
  }
  return files;
}

void main() {
  late Directory temp;
  late String root;
  late String notebooksRoot;
  late String source;
  late String notebookId;
  late String noteId;
  late _Provider provider;
  late NotebookImporter importer;
  final importers = <NotebookImporter>[];
  const name = '研究 notebook';

  NotebookImporter makeImporter({
    String? importsRoot,
    DocumentTransferPlatform? platform,
    void Function()? checkAdmission,
  }) {
    final instance = NotebookImporter(
      root: importsRoot ?? root,
      notebooksRoot: notebooksRoot,
      platform: platform ?? provider,
      checkAdmission: checkAdmission,
    );
    importers.add(instance);
    return instance;
  }

  Future<DocumentImportResult> copySource(
    String id,
    DocumentImportKind kind, {
    String? importsRoot,
  }) async {
    final transaction = p.join(importsRoot ?? root, id);
    final request = jsonDecode(
      await File(p.join(transaction, 'request.json')).readAsString(),
    );
    expect(request, {'version': 1, 'id': id, 'kind': kind.name});
    expect(await File(p.join(transaction, 'captured.json')).exists(), isFalse);
    final entries = <Map<String, Object?>>[];
    final archive = Archive();
    var bytes = 0;
    final destination = p.join(transaction, 'unpacked');
    if (kind == DocumentImportKind.folder) {
      await Directory(destination).create();
    }
    Future<void> visit(String directory) async {
      final children = await Directory(directory)
          .list(followLinks: false)
          .toList();
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        final relative = p
            .relative(entity.path, from: source)
            .replaceAll('\\', '/');
        final target = p.joinAll([destination, ...relative.split('/')]);
        if (entity is Directory) {
          entries.add({'path': relative, 'type': 'directory'});
          if (kind == DocumentImportKind.folder) {
            await Directory(target).create();
          } else {
            archive.addFile(ArchiveFile.directory('$relative/'));
          }
          await visit(entity.path);
        } else {
          final data = await File(entity.path).readAsBytes();
          bytes += data.length;
          entries.add({'path': relative, 'type': 'file'});
          if (kind == DocumentImportKind.folder) {
            await File(target).writeAsBytes(data, flush: true);
          } else {
            archive.addFile(ArchiveFile(relative, data.length, data));
          }
        }
      }
    }

    await visit(source);
    if (kind == DocumentImportKind.folder) {
      await File(p.join(transaction, 'accepted.jsonl')).writeAsString(
        entries.map(jsonEncode).map((line) => '$line\n').join(),
        flush: true,
      );
    } else {
      final zip = ZipEncoder().encode(archive, level: 0);
      await File(p.join(transaction, 'input.zip'))
          .writeAsBytes(zip, flush: true);
      bytes = zip.length;
    }
    return DocumentImportResult(
      status: DocumentImportStatus.ready,
      sourceName: kind == DocumentImportKind.folder
          ? 'Provider folder'
          : 'Provider notebook.zip',
      bytes: bytes,
      entries: kind == DocumentImportKind.folder ? entries.length : 1,
    );
  }

  Future<ImportAttempt> prepare([
    DocumentImportKind kind = DocumentImportKind.folder,
  ]) async {
    await importer.initialize();
    final attempt = await importer.prepare(kind);
    expect(importer.value.error, isNull);
    expect(attempt, isNotNull);
    expect(attempt!.phase, NotebookImportPhase.prepared);
    return attempt;
  }

  Future<Map<String, Object?>> inspect(
    ImportAttempt attempt,
    int cancellation,
  ) => importer.runStore({
    'op': 'inspect',
    'id': attempt.id,
    'treeRelative': attempt.treeRelative,
    'inventoryHash': attempt.inventoryHash,
  }, cancellationAddress: cancellation);

  Future<void> openAndCompare(
    ImportAttempt attempt,
    String location,
    Map<String, Object?> strict, {
    bool admitted = true,
  }) async {
    final inspection = p.join(root, attempt.id, 'inspection');
    if (admitted) {
      await importer.resetInspection(attempt);
    } else {
      if (await Directory(inspection).exists()) {
        await Directory(inspection).delete(recursive: true);
      }
      await Directory(p.join(inspection, 'app')).create(recursive: true);
      await Directory(p.join(inspection, 'local')).create(recursive: true);
    }
    final catalog = await CoreNotebook.openExportCatalog(
      appDataPath: p.join(inspection, 'app'),
      localDataPath: p.join(inspection, 'local'),
      notebookPath: location,
      expectedNotebookId: strict['notebookId'] as String,
    );
    try {
      expect(catalog.initialDirectory.notebookId, strict['notebookId']);
      final ids = await catalog.collectNodeIds();
      expect(ids.toSet().length, ids.length);
      expect(
        ids.toSet(),
        (strict['nodeIds'] as List<Object?>).cast<String>().toSet(),
      );
      expect(ids, contains(noteId));
    } finally {
      await catalog.close();
    }
  }

  Future<Map<String, Object?>> publish(
    ImportAttempt attempt,
    int cancellation, {
    bool admitted = true,
  }) async {
    final strict = await inspect(attempt, cancellation);
    await openAndCompare(
      attempt,
      p.joinAll([root, attempt.id, ...attempt.treeRelative!.split('/')]),
      strict,
      admitted: admitted,
    );
    return importer.runStore({
      'op': 'publish',
      'id': attempt.id,
      'treeRelative': attempt.treeRelative,
      'inventoryHash': attempt.inventoryHash,
      'notebookId': strict['notebookId'],
      'notebookName': strict['notebookName'],
    }, cancellationAddress: cancellation);
  }

  Future<ImportCommitResult> finish(
    ImportAttempt attempt, {
    bool admitted = true,
  }) async {
    final recovery = await importer.runStore({
      'op': 'recover',
      'id': attempt.id,
    }, cancellationAddress: 0);
    expect(recovery['phase'], 'published');
    final strict = await importer.runStore({
      'op': 'inspectManaged',
      'id': attempt.id,
      'location': recovery['destination'],
      'expectedNotebookId': recovery['notebookId'],
    }, cancellationAddress: 0);
    await openAndCompare(
      attempt,
      recovery['destination'] as String,
      strict,
      admitted: admitted,
    );
    final committed = await importer.runStore({
      'op': 'commit',
      'id': attempt.id,
    }, cancellationAddress: 0);
    expect(committed['phase'], 'committed');
    return ImportCommitResult(
      status: ImportCommitStatus.imported,
      notebookId: committed['notebookId'] as String,
      notebookName: committed['notebookName'] as String,
      destination: committed['destination'] as String,
    );
  }

  Future<NotebookImporter> restart() async {
    await importer.shutdown();
    importer = makeImporter();
    await importer.initialize();
    return importer;
  }

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('vnote-import-');
    temp = Directory(await created.resolveSymbolicLinks());
    root = p.join(temp.path, 'imports');
    notebooksRoot = p.join(temp.path, 'notebooks');
    source = p.join(temp.path, 'provider-source');
    await Directory(notebooksRoot).create();
    final app = p.join(temp.path, 'fixture', 'app');
    final local = p.join(temp.path, 'fixture', 'local');
    await Directory(app).create(recursive: true);
    await Directory(local).create();
    final catalog = await CoreNotebook.createCatalog(
      appDataPath: app,
      localDataPath: local,
      notebookPath: source,
      notebookName: name,
    );
    try {
      notebookId = catalog.initialDirectory.notebookId;
      noteId = await catalog.createNote(
        catalog.initialDirectory.folderId,
        'kept.md',
      );
    } finally {
      await catalog.close();
    }
    await File(p.join(source, 'kept.md'))
        .writeAsString('Opaque note body\n', flush: true);
    await Directory(p.join(source, '.opaque', 'empty')).create(recursive: true);
    await File(p.join(source, '.opaque', 'asset.bin'))
        .writeAsBytes([0, 255, 0, 1, 128]);
    provider = _Provider();
    provider.copy = (id, kind) => copySource(id, kind);
    importer = makeImporter();
  });

  tearDown(() async {
    for (final item in importers) {
      await item.shutdown();
      item.dispose();
    }
    importers.clear();
    await temp.delete(recursive: true);
  });

  test('startup creates private storage without invoking a provider', () async {
    expect(importer.initialized, isFalse);
    await importer.initialize();
    expect(importer.initialized, isTrue);
    expect(importer.value.hasStaging, isFalse);
    expect(importer.value.busy, isFalse);
    expect(provider.preparations, 0);
    expect(provider.picks, 0);
    expect(await Directory(root).exists(), isTrue);
  });

  test(
    'folder preparation durably binds exact bytes but never publishes',
    () async {
      final original = await _snapshot(source);
      final attempt = await prepare();
      final transaction = p.join(root, attempt.id);
      final captured = jsonDecode(
        await File(p.join(transaction, 'captured.json')).readAsString(),
      );
      final prepared = jsonDecode(
        await File(p.join(transaction, 'prepared.json')).readAsString(),
      );
      final inventory = await File(p.join(transaction, 'inventory.jsonl'))
          .readAsBytes();
      expect(captured['sourceName'], 'Provider folder');
      expect(prepared, {
        'version': 1,
        'id': attempt.id,
        'kind': 'folder',
        'treeRelative': attempt.treeRelative,
        'inventoryHash': crypto.sha256.convert(inventory).toString(),
        'bytes': attempt.bytes,
        'entries': attempt.entries,
      });
      expect(await _snapshot(p.join(transaction, 'unpacked')), original);
      expect(await _snapshot(source), original);
      expect(
        await Directory(p.join(transaction, 'unpacked', '.opaque', 'empty'))
            .exists(),
        isTrue,
      );
      expect(
        await File(p.join(transaction, 'publication.json')).exists(),
        isFalse,
      );
      expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
      expect(importer.value.busy, isFalse);
      expect(importer.value.hasStaging, isTrue);
      expect(importer.value.phase, NotebookImportPhase.prepared);
      final strict = await inspect(attempt, 0);
      expect(strict['notebookId'], notebookId);
      expect(strict['nodeIds'], contains(noteId));
    },
  );

  test(
    'ZIP worker preparation preserves opaque source bytes and identities',
    () async {
      final original = await _snapshot(source);
      final attempt = await prepare(DocumentImportKind.zip);
      expect(await _snapshot(p.join(root, attempt.id, 'unpacked')), original);
      expect(
        await File(p.join(root, attempt.id, 'input.zip')).exists(),
        isTrue,
      );
      expect((await inspect(attempt, 0))['notebookId'], notebookId);
      expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    },
  );

  test(
    'transfer admission rejects synchronously before allocating staging',
    () async {
      final guarded = makeImporter(
        checkAdmission: () => throw StateError('Export owns staging.'),
      );
      await guarded.initialize();
      expect(
        () => guarded.prepare(DocumentImportKind.folder),
        throwsStateError,
      );
      expect(await Directory(root).list().isEmpty, isTrue);
      expect(provider.picks, 0);
    },
  );

  test('a failed storage prerequisite retains the durable request and redacts paths', () async {
    provider.rejectPreparation = true;
    await importer.initialize();
    await importer.prepare(DocumentImportKind.folder);
    expect(importer.initialized, isTrue);
    expect(importer.value.current!.phase, NotebookImportPhase.receiving);
    expect(importer.value.error, isNot(contains('secret/provider/location')));
    expect(provider.picks, 0);
    expect(
      await File(p.join(root, importer.value.current!.id, 'request.json'))
          .exists(),
      isTrue,
    );
    await importer.discard(importer.value.current!);
    expect(importer.value.hasStaging, isFalse);
  });

  test(
    'unacknowledged partial copy is reselected only after its lease settles',
    () async {
      final gate = Completer<DocumentImportResult>();
      final copied = Completer<void>();
      provider.outcome = (id, kind) async {
        await Directory(p.join(root, id, 'unpacked')).create();
        await File(p.join(root, id, 'unpacked', 'partial'))
            .writeAsString('partial');
        copied.complete();
        return gate.future;
      };
      await importer.initialize();
      final pending = importer.prepare(DocumentImportKind.folder);
      await copied.future;
      final original = importer.value.current!;
      importer.cancel();
      expect(provider.cancellations, 1);
      expect(importer.value.busy, isTrue);
      expect(() => importer.discard(original), throwsStateError);
      expect(() => importer.retry(original), throwsStateError);
      gate.complete(_cancelled);
      await pending;
      expect(importer.value.current!.phase, NotebookImportPhase.receiving);
      expect(
        await File(p.join(root, original.id, 'captured.json')).exists(),
        isFalse,
      );
      provider.outcome = null;
      final ready = await importer.retry(importer.value.current!);
      expect(ready!.id, original.id);
      expect(ready.phase, NotebookImportPhase.prepared);
      expect(provider.picks, 2);
      expect(
        await File(p.join(root, original.id, 'unpacked', 'partial')).exists(),
        isFalse,
      );
    },
  );

  test(
    'late cancellation retains an acknowledged source and retry skips picker',
    () async {
      final gate = Completer<void>();
      final copied = Completer<void>();
      provider.outcome = (id, kind) async {
        final result = await copySource(id, kind);
        copied.complete();
        await gate.future;
        return result;
      };
      await importer.initialize();
      final pending = importer.prepare(DocumentImportKind.folder);
      await copied.future;
      importer.cancel();
      gate.complete();
      await pending;
      final captured = importer.value.current!;
      expect(captured.phase, NotebookImportPhase.validating);
      expect(
        await File(p.join(root, captured.id, 'captured.json')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(root, captured.id, 'prepared.json')).exists(),
        isFalse,
      );
      expect(provider.picks, 1);
      final ready = await importer.retry(captured);
      expect(ready!.phase, NotebookImportPhase.prepared);
      expect(provider.picks, 1);
      expect(() => importer.discard(captured), throwsStateError);
      final forged = ImportAttempt(
        id: ready.id,
        kind: ready.kind,
        phase: ready.phase,
      );
      expect(() => importer.discard(forged), throwsStateError);
    },
  );

  test(
    'shutdown cancels but does not release a pending provider lease',
    () async {
      final result = Completer<DocumentImportResult>();
      provider.outcome = (_, _) => result.future;
      await importer.initialize();
      final preparation = importer.prepare(DocumentImportKind.zip);
      await provider.entered.future;
      var closed = false;
      final shutdown = importer.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(provider.cancellations, 1);
      expect(importer.value.busy, isTrue);
      result.complete(_cancelled);
      await preparation;
      await shutdown;
      expect(closed, isTrue);
      expect(
        await File(p.join(root, importer.value.current!.id, 'request.json'))
            .exists(),
        isTrue,
      );
      expect(() => importer.retry(importer.value.current!), throwsStateError);
    },
  );

  test('a delayed cancellation transport drains before the transaction ID can be retried', () async {
    final result = Completer<DocumentImportResult>();
    provider.cancellationReply = Completer<void>();
    provider.outcome = (_, _) => result.future;
    await importer.initialize();
    var settled = false;
    final preparation = importer
        .prepare(DocumentImportKind.folder)
        .then((_) => settled = true);
    await provider.entered.future;
    final token = importer.value.current!;
    importer.cancel();
    result.complete(_cancelled);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(importer.value.busy, isTrue);
    expect(() => importer.retry(token), throwsStateError);
    provider.cancellationReply!.complete();
    await preparation;
    provider.outcome = null;
    final prepared = await importer.retry(importer.value.current!);
    expect(prepared!.phase, NotebookImportPhase.prepared);
    expect(provider.picks, 2);
    expect(provider.cancellations, 1);
  });

  for (final status in [
    DocumentImportStatus.failed,
    DocumentImportStatus.unavailable,
  ]) {
    test(
      'provider ${status.name} retains an unacknowledged request for retry',
      () async {
        provider.outcome = (_, _) async => DocumentImportResult(
          status: status,
          sourceName: null,
          bytes: 0,
          entries: 0,
        );
        await importer.initialize();
        await importer.prepare(DocumentImportKind.folder);
        final retained = importer.value.current!;
        expect(retained.phase, NotebookImportPhase.receiving);
        expect(importer.value.error, isNotNull);
        expect(
          await File(p.join(root, retained.id, 'captured.json')).exists(),
          isFalse,
        );
        provider.outcome = null;
        final prepared = await importer.retry(retained);
        expect(prepared!.phase, NotebookImportPhase.prepared);
        expect(prepared.id, retained.id);
        expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
      },
    );
  }

  test('malformed captured ZIP remains discardable without publishing partial output', () async {
    provider.outcome = (id, _) async {
      await File(p.join(root, id, 'input.zip')).writeAsBytes([80, 75, 3, 4, 0]);
      return const DocumentImportResult(
        status: DocumentImportStatus.ready,
        sourceName: 'broken.zip',
        bytes: 5,
        entries: 1,
      );
    };
    await importer.initialize();
    await importer.prepare(DocumentImportKind.zip);
    expect(importer.value.error, isNotNull);
    expect(importer.value.current!.phase, NotebookImportPhase.validating);
    await importer.retry(importer.value.current!);
    expect(provider.picks, 1);
    expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    await importer.discard(importer.value.current!);
    expect(importer.value.hasStaging, isFalse);
  });

  test(
    'restart retains prepared state and retry never invokes publication',
    () async {
      final ready = await prepare();
      await restart();
      expect(importer.value.current!.id, ready.id);
      expect(importer.value.current!.phase, NotebookImportPhase.prepared);
      expect(importer.value.blockedLocations, isEmpty);
      await importer.retry(importer.value.current!);
      expect(provider.picks, 1);
      expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
      expect(
        await File(p.join(root, ready.id, 'publication.json')).exists(),
        isFalse,
      );
    },
  );

  test('native publication failure is reconciled as quarantined then finished after restart', () async {
    final original = await _snapshot(source);
    final ready = await prepare();
    final result = await importer.commit(ready, (attempt, cancellation) async {
      await publish(attempt, cancellation);
      throw StateError('Interrupted after the directory rename.');
    });
    final target = p.join(notebooksRoot, 'nb-${ready.id}');
    expect(result!.status, ImportCommitStatus.quarantined);
    expect(importer.value.current!.phase, NotebookImportPhase.finishing);
    expect(importer.value.blockedLocations, [target]);
    expect(await Directory(target).exists(), isTrue);
    expect(
      await Directory(p.join(root, ready.id, 'unpacked')).exists(),
      isFalse,
    );
    await restart();
    expect(importer.value.current!.phase, NotebookImportPhase.finishing);
    expect(importer.value.blockedLocations, [target]);
    final imported = await importer.commit(
      importer.value.current!,
      (attempt, _) => finish(attempt),
    );
    expect(imported!.status, ImportCommitStatus.imported);
    expect(imported.notebookId, notebookId);
    expect(importer.value.hasStaging, isFalse);
    expect(await Directory(p.join(root, ready.id)).exists(), isFalse);
    expect(await _snapshot(target), original);
    expect(await _snapshot(source), original);
  });

  test('cancellation and dispose after rename drain real open and receipt before freeing token', () async {
    final ready = await prepare();
    final renamed = Completer<int>();
    final finishGate = Completer<void>();
    final committing = importer.commit(ready, (attempt, cancellation) async {
      await publish(attempt, cancellation);
      renamed.complete(cancellation);
      await finishGate.future;
      expect(CoreImportStore.queryCancellation(cancellation), isTrue);
      return finish(attempt);
    });
    final token = await renamed.future;
    var settled = false;
    final shutdown = importer.shutdown().then((_) => settled = true);
    importer.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(CoreImportStore.queryCancellation(token), isTrue);
    expect(
      await Directory(p.join(notebooksRoot, 'nb-${ready.id}')).exists(),
      isTrue,
    );
    finishGate.complete();
    final result = await committing;
    await shutdown;
    expect(result!.status, ImportCommitStatus.imported);
    expect(settled, isTrue);
    expect(await Directory(p.join(root, ready.id)).exists(), isFalse);
    expect(
      await File(p.join(notebooksRoot, 'nb-${ready.id}', 'kept.md'))
          .readAsString(),
      'Opaque note body\n',
    );
  });

  test(
    'cancellation before native rename leaves the prepared tree private',
    () async {
      final ready = await prepare();
      final entered = Completer<void>();
      final gate = Completer<void>();
      final committing = importer.commit(ready, (attempt, cancellation) async {
        final strict = await inspect(attempt, cancellation);
        entered.complete();
        await gate.future;
        await importer.runStore({
          'op': 'publish',
          'id': attempt.id,
          'treeRelative': attempt.treeRelative,
          'inventoryHash': attempt.inventoryHash,
          'notebookId': strict['notebookId'],
          'notebookName': strict['notebookName'],
        }, cancellationAddress: cancellation);
        return finish(attempt);
      });
      await entered.future;
      importer.cancel();
      gate.complete();
      final result = await committing;
      expect(result!.status, ImportCommitStatus.quarantined);
      expect(importer.value.current!.phase, NotebookImportPhase.prepared);
      expect(importer.value.blockedLocations, isEmpty);
      expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    },
  );

  test('journal intent with the matching source still present is staged, not published', () async {
    final ready = await prepare();
    final published = await publish(ready, 0, admitted: false);
    final target = published['destination'] as String;
    await Directory(target).rename(p.join(root, ready.id, 'unpacked'));
    await restart();
    expect(importer.value.current!.phase, NotebookImportPhase.prepared);
    expect(importer.value.current!.destination, target);
    expect(importer.value.blockedLocations, isEmpty);
    expect(await Directory(target).exists(), isFalse);
    await importer.retry(importer.value.current!);
    expect(await Directory(target).exists(), isFalse);
    await importer.discard(importer.value.current!);
    expect(importer.value.hasStaging, isFalse);
  });

  test('ambiguous source and target retain durable quarantine through explicit cleanup and restart', () async {
    final ready = await prepare();
    final published = await publish(ready, 0, admitted: false);
    final target = published['destination'] as String;
    final before = await _snapshot(target);
    await Directory(p.join(root, ready.id, 'unpacked')).create();
    await restart();
    expect(importer.value.current, isNull);
    expect(importer.value.leftovers, hasLength(1));
    expect(importer.value.blockedLocations, [target]);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.error, contains('unresolved live destination'));
    expect(await _snapshot(target), before);
    expect(
      await File(p.join(root, ready.id, 'publication.json')).exists(),
      isTrue,
    );
    await restart();
    expect(importer.value.blockedLocations, [target]);
    expect(importer.value.leftovers, hasLength(1));
  });

  test('explicit published discard removes only an identity-verified unregistered target', () async {
    final ready = await prepare();
    await publish(ready, 0, admitted: false);
    await restart();
    expect(importer.value.current!.phase, NotebookImportPhase.finishing);
    await importer.discard(importer.value.current!);
    expect(importer.value.error, isNull);
    expect(importer.value.hasStaging, isFalse);
    expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    expect(
      await File(p.join(source, 'kept.md')).readAsString(),
      'Opaque note body\n',
    );
  });

  test('committed recovery cleans private staging without hashing or deleting edited notebook data', () async {
    final ready = await prepare();
    await publish(ready, 0, admitted: false);
    await finish(ready, admitted: false);
    final target = p.join(notebooksRoot, 'nb-${ready.id}');
    await File(p.join(target, 'kept.md'))
        .writeAsString('Legitimate later edit\n', flush: true);
    await restart();
    expect(importer.value.hasStaging, isFalse);
    expect(importer.value.error, isNull);
    expect(await Directory(p.join(root, ready.id)).exists(), isFalse);
    expect(
      await File(p.join(target, 'kept.md')).readAsString(),
      'Legitimate later edit\n',
    );
  });

  test('interrupted cleanup after retirement exposes only private debris, never a live-root discard', () async {
    final ready = await prepare();
    await publish(ready, 0, admitted: false);
    await finish(ready, admitted: false);
    final target = p.join(notebooksRoot, 'nb-${ready.id}');
    final original = await _snapshot(target);
    final retired = p.join(root, 'done-${ready.id}');
    await Directory(p.join(root, ready.id)).rename(retired);
    await restart();
    expect(importer.value.current, isNull);
    expect(importer.value.blockedLocations, isEmpty);
    expect(importer.value.leftovers.single.location, retired);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.hasStaging, isFalse);
    expect(await Directory(retired).exists(), isFalse);
    expect(await _snapshot(target), original);
  });

  test('missing committed destination is never replayed and receipt permits private-only cleanup', () async {
    final ready = await prepare();
    await publish(ready, 0, admitted: false);
    await finish(ready, admitted: false);
    final target = p.join(notebooksRoot, 'nb-${ready.id}');
    final moved = p.join(temp.path, 'moved-committed-notebook');
    await Directory(target).rename(moved);
    await restart();
    expect(importer.value.current, isNull);
    expect(importer.value.leftovers, hasLength(1));
    expect(await Directory(target).exists(), isFalse);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.hasStaging, isFalse);
    expect(await Directory(target).exists(), isFalse);
    expect(
      await File(p.join(moved, 'kept.md')).readAsString(),
      'Opaque note body\n',
    );
  });

  test('duplicate result is offered only after actual strict managed and core identity checks', () async {
    final ready = await prepare();
    final existing = p.join(notebooksRoot, 'existing');
    Future<void> copyDirectory(String from, String to) async {
      await Directory(to).create();
      await for (final entity in Directory(from).list(followLinks: false)) {
        final destination = p.join(to, p.basename(entity.path));
        if (entity is Directory) {
          await copyDirectory(entity.path, destination);
        } else {
          await File(entity.path).copy(destination);
        }
      }
    }

    await copyDirectory(source, existing);
    final result = await importer.commit(ready, (attempt, cancellation) async {
      final incoming = await inspect(attempt, cancellation);
      final managed = await importer.runStore({
        'op': 'inspectManaged',
        'id': attempt.id,
        'location': existing,
        'expectedNotebookId': notebookId,
      }, cancellationAddress: cancellation);
      await openAndCompare(attempt, existing, managed);
      expect(incoming['notebookId'], managed['notebookId']);
      return ImportCommitResult(
        status: ImportCommitStatus.duplicate,
        notebookId: managed['notebookId'] as String,
        notebookName: managed['notebookName'] as String,
        destination: existing,
      );
    });
    expect(result!.status, ImportCommitStatus.duplicate);
    expect(importer.value.existingNotebookId, notebookId);
    expect(importer.value.current!.phase, NotebookImportPhase.prepared);
    expect(await Directory(notebooksRoot).list().length, 1);
    expect(
      await File(p.join(root, ready.id, 'publication.json')).exists(),
      isFalse,
    );
  });

  test('multiple recovered preparations expose one current token and promote the next without publishing', () async {
    final first = await prepare();
    final secondId = first.id == '00000000000000000000000000000000'
        ? '11111111111111111111111111111111'
        : '00000000000000000000000000000000';
    await Directory(p.join(root, secondId)).create();
    await importer.runStore({
      'op': 'writeMarker',
      'id': secondId,
      'marker': 'request',
      'data': {'version': 1, 'id': secondId, 'kind': 'folder'},
    }, cancellationAddress: 0);
    final copied = await copySource(secondId, DocumentImportKind.folder);
    await importer.runStore({
      'op': 'writeMarker',
      'id': secondId,
      'marker': 'captured',
      'data': {
        'version': 1,
        'id': secondId,
        'kind': 'folder',
        'sourceName': copied.sourceName,
        'bytes': copied.bytes,
        'entries': copied.entries,
      },
    }, cancellationAddress: 0);
    await File(p.join(root, first.id, 'inventory.jsonl'))
        .copy(p.join(root, secondId, 'inventory.jsonl'));
    await importer.runStore({
      'op': 'writeMarker',
      'id': secondId,
      'marker': 'prepared',
      'data': {
        'version': 1,
        'id': secondId,
        'kind': 'folder',
        'treeRelative': first.treeRelative,
        'inventoryHash': first.inventoryHash,
        'bytes': first.bytes,
        'entries': first.entries,
      },
    }, cancellationAddress: 0);
    await restart();
    expect(importer.value.current, isNotNull);
    expect(importer.value.leftovers, hasLength(1));
    final next = importer.value.leftovers.single;
    expect(() => importer.prepare(DocumentImportKind.folder), throwsStateError);
    await importer.discard(importer.value.current!);
    expect(importer.value.current!.id, next.label);
    expect(importer.value.leftovers, isEmpty);
    expect(() => importer.discardLeftover(next), throwsStateError);
    expect(provider.picks, 1);
    expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    await importer.discard(importer.value.current!);
    expect(importer.value.hasStaging, isFalse);
  });

  test('strict native metadata rejection retains the prepared bytes without publication', () async {
    await File(p.join(source, 'vx_notebook', 'config.json'))
        .writeAsString('{invalid');
    final ready = await prepare();
    final result = await importer.commit(ready, (attempt, cancellation) async {
      await publish(attempt, cancellation);
      return finish(attempt);
    });
    expect(result!.status, ImportCommitStatus.quarantined);
    expect(importer.value.error, isNotNull);
    expect(importer.value.current!.phase, NotebookImportPhase.prepared);
    expect(
      await File(
        p.join(root, ready.id, 'unpacked', 'vx_notebook', 'config.json'),
      ).readAsString(),
      '{invalid',
    );
    expect(await Directory(notebooksRoot).list().isEmpty, isTrue);
    await importer.discard(importer.value.current!);
    expect(importer.value.hasStaging, isFalse);
  });

  test('a valid journal never authorizes deleting a replacement destination identity', () async {
    final ready = await prepare();
    final published = await publish(ready, 0, admitted: false);
    final target = published['destination'] as String;
    final original = p.join(temp.path, 'original-published-directory');
    await Directory(target).rename(original);
    await Directory(target).create();
    await File(p.join(target, 'foreign'))
        .writeAsString('A different directory.');
    await restart();
    expect(importer.value.current, isNull);
    expect(importer.value.blockedLocations, [target]);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.error, contains('unresolved live destination'));
    expect(
      await File(p.join(target, 'foreign')).readAsString(),
      'A different directory.',
    );
    expect(
      await File(p.join(original, 'kept.md')).readAsString(),
      'Opaque note body\n',
    );
    await restart();
    expect(importer.value.blockedLocations, [target]);
  });

  test('unknown and invalid-version private leftovers require current cleanup tokens', () async {
    await Directory(root).create();
    await File(p.join(root, 'unrecognized-file'))
        .writeAsString('private residue');
    const invalidId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await Directory(p.join(root, invalidId)).create();
    await File(p.join(root, invalidId, 'request.json')).writeAsString(
      jsonEncode({'version': 999, 'id': invalidId, 'kind': 'zip'}),
    );
    await importer.initialize();
    expect(importer.value.current, isNull);
    expect(importer.value.leftovers, hasLength(2));
    final first = importer.value.leftovers.first;
    final stale = importer.value.leftovers.last;
    await importer.discardLeftover(first);
    expect(() => importer.discardLeftover(stale), throwsStateError);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.hasStaging, isFalse);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('corrupt private markers cannot delete or unblock a foreign live destination', () async {
    const id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final transaction = p.join(root, id);
    final target = p.join(notebooksRoot, 'nb-$id');
    await Directory(transaction).create(recursive: true);
    await File(p.join(transaction, 'request.json')).writeAsString('{broken');
    await Directory(target).create();
    await File(p.join(target, 'foreign')).writeAsString('Do not delete.');
    await importer.initialize();
    expect(importer.value.blockedLocations, [target]);
    await importer.discardLeftover(importer.value.leftovers.single);
    expect(importer.value.error, contains('unresolved live destination'));
    expect(
      await File(p.join(target, 'foreign')).readAsString(),
      'Do not delete.',
    );
    expect(await File(p.join(transaction, 'request.json')).exists(), isTrue);
    await restart();
    expect(importer.value.blockedLocations, [target]);
  });

  test(
    'unscannable root never becomes initialized or admits allocation',
    () async {
      await File(root).writeAsString('not a directory');
      await importer.initialize();
      expect(importer.initialized, isFalse);
      expect(importer.value.error, isNotNull);
      expect(
        () => importer.prepare(DocumentImportKind.folder),
        throwsStateError,
      );
      expect(provider.picks, 0);
    },
  );
}
