// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/cohort_import.dart';
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/transfer_worker.dart'
    show runTransferStore;
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Provider implements DocumentTransferPlatform {
  late Future<DocumentImportResult> Function(String, DocumentImportKind) copy;
  final entered = Completer<void>();
  int picks = 0;
  int cancellations = 0;
  @override
  Future<void> prepareStorage() async {}
  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  }) {
    expect(scope, DocumentTransferScope.cohort);
    picks++;
    if (!entered.isCompleted) entered.complete();
    return copy(operationId, kind);
  }

  @override
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    expect(scope, DocumentTransferScope.cohort);
    cancellations++;
  }

  @override
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  }) async => throw StateError('Unexpected export.');
  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  }) async => throw StateError('Unexpected export.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String notebooks;
  late String root;
  late String book;
  late CohortTarget target;
  late String originalId;
  late _Provider provider;
  late CohortImporter importer;
  final controllers = <CohortImporter>[];
  final reservations = <Object>{};
  var opens = 0;
  var builds = 0;

  CohortImporter controller() {
    final instance = CohortImporter(
      root: root,
      notebooksRoot: notebooks,
      platform: provider,
      reserveTransfer: reservations.add,
      releaseTransfer: reservations.remove,
    );
    controllers.add(instance);
    return instance;
  }

  Future<CoreCohortBuildResult> build(
    CohortAttempt attempt,
    TransferCancellation cancel,
  ) async {
    builds++;
    cancel.check();
    final owner = await CoreNotebook.createCohortBuilder(
      attempt.transactionRoot,
    );
    cancel.onCancel = owner.cancel;
    try {
      return await owner.build();
    } finally {
      cancel.onCancel = null;
      await owner.close();
    }
  }

  Future<CoreCohortOutcome> apply(
    CohortAttempt attempt,
    TransferCancellation cancel,
    bool recover,
  ) async {
    final engine = p.join(attempt.transactionRoot, 'recovery-${opens++}');
    final owner = await CoreNotebook.openCatalog(
      appDataPath: p.join(engine, 'app'),
      localDataPath: p.join(engine, 'local'),
      notebookPath: book,
      expectedNotebookId: attempt.target.notebookId,
    );
    try {
      if (!recover) cancel.check();
      return recover
          ? await owner.recoverCohort(attempt.transactionRoot)
          : await owner.applyCohort(attempt.transactionRoot);
    } finally {
      await owner.close();
    }
  }

  Future<DocumentImportResult> copy(String id, DocumentImportKind kind) async {
    expect(kind, DocumentImportKind.folder);
    final transaction = p.join(root, id);
    expect(
      jsonDecode(
        await File(p.join(transaction, 'request.json')).readAsString(),
      ),
      {'version': 2, 'id': id, 'scope': 'cohort', 'kind': 'folder'},
    );
    final entries = <String, List<int>?>{
      'Wrapper': null,
      'Wrapper/note.md': utf8.encode('![picture](assets/图.png)\n'),
      'Wrapper/assets': null,
      'Wrapper/assets/图.png': [0, 255, 128, 42],
      'Wrapper/.hidden.bin': [0, 7, 255],
      'Wrapper/empty': null,
    };
    await Directory(p.join(transaction, 'unpacked')).create();
    var bytes = 0;
    for (final entry in entries.entries) {
      final path = p.joinAll([
        transaction,
        'unpacked',
        ...entry.key.split('/'),
      ]);
      if (entry.value == null) {
        await Directory(path).create();
      } else {
        await File(path).writeAsBytes(entry.value!, flush: true);
        bytes += entry.value!.length;
      }
    }
    await File(p.join(transaction, 'accepted.jsonl')).writeAsString(
      entries.entries
          .map(
            (entry) =>
                '${jsonEncode({'path': entry.key, 'type': entry.value == null ? 'directory' : 'file'})}\n',
          )
          .join(),
      flush: true,
    );
    return DocumentImportResult(
      status: DocumentImportStatus.ready,
      sourceName: 'Raw folder',
      bytes: bytes,
      entries: entries.length,
    );
  }

  Future<CohortAttempt> source() async {
    await importer.initialize();
    final attempt = await importer.start(
      target: target,
      kind: DocumentImportKind.folder,
    );
    expect(importer.value.error, isNull);
    expect(attempt?.stage, TransferStage.source);
    return attempt!;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cohort-controller-');
    notebooks = p.join(temp.path, 'notebooks');
    root = p.join(temp.path, 'cohorts');
    for (final path in [
      notebooks,
      root,
      p.join(temp.path, 'imports'),
      p.join(temp.path, 'exports'),
      p.join(temp.path, 'resources'),
    ]) {
      await Directory(path).create();
    }
    book = p.join(notebooks, 'fixture');
    final owner = await CoreNotebook.createCatalog(
      appDataPath: p.join(temp.path, 'app'),
      localDataPath: p.join(temp.path, 'local'),
      notebookPath: book,
      notebookName: 'Original',
    );
    target = CohortTarget(
      notebookId: owner.initialDirectory.notebookId,
      parentId: owner.initialDirectory.folderId,
      notebookRelative: 'fixture',
      folderName: 'Imported',
    );
    originalId = await owner.createNote(target.parentId, 'Original.md');
    await owner.close();
    provider = _Provider()..copy = copy;
    builds = 0;
    opens = 0;
    importer = controller();
  });

  tearDown(() async {
    for (final instance in controllers) {
      await instance.shutdown();
      instance.dispose();
    }
    controllers.clear();
    reservations.clear();
    await temp.delete(recursive: true);
  });

  test('real raw cohort retains full layout and sealed IDs across restart and commit', () async {
    final captured = await source();
    final prepared = await importer.prepare(captured, build);
    expect(importer.value.error, isNull);
    expect(prepared?.stage, TransferStage.prepared);
    expect(builds, 1);
    final plannedId = prepared!.cohortId;
    final sealed = await File(p.join(prepared.transactionRoot, 'prepared.json'))
        .readAsBytes();
    expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
    await importer.shutdown();
    importer = controller();
    await importer.initialize();
    expect(importer.value.current?.cohortId, plannedId);
    expect(
      await File(p.join(prepared.transactionRoot, 'prepared.json'))
          .readAsBytes(),
      sealed,
    );
    final result = await importer.apply(importer.value.current!, apply);
    expect(importer.value.error, isNull);
    expect(result?.committed, isTrue);
    expect(builds, 1);
    expect(
      await File(p.join(book, 'Imported/Wrapper/.hidden.bin')).readAsBytes(),
      [0, 7, 255],
    );
    expect(
      await File(p.join(book, 'Imported/Wrapper/assets/图.png')).readAsBytes(),
      [0, 255, 128, 42],
    );
    expect(
      await File(p.join(book, 'Imported/Wrapper/note.md')).readAsString(),
      '![picture](assets/图.png)\n',
    );
    final inspect = await CoreNotebook.openCatalog(
      appDataPath: p.join(temp.path, 'inspect-app'),
      localDataPath: p.join(temp.path, 'inspect-local'),
      notebookPath: book,
      expectedNotebookId: target.notebookId,
    );
    try {
      final ids = await inspect.collectNodeIds();
      expect(ids, containsAll([originalId, plannedId]));
      expect(ids.toSet().length, ids.length);
      expect(
        (await inspect.list()).entries.where(
          (entry) => entry.name == 'Imported',
        ),
        hasLength(1),
      );
    } finally {
      await inspect.close();
    }
    await importer.discard(importer.value.current!, recover: apply);
    expect(importer.value.hasStaging, isFalse);
    expect(
      await File(p.join(book, 'Imported/Wrapper/.hidden.bin')).readAsBytes(),
      [0, 7, 255],
    );
  });

  test('post-dispatch callback loss reconciles actual commit without replay or new IDs', () async {
    await importer.prepare(await source(), build);
    var dispatches = 0;
    var recoveries = 0;
    final result = await importer.apply(importer.value.current!, (
      attempt,
      cancel,
      recover,
    ) async {
      if (recover) {
        recoveries++;
        return apply(attempt, cancel, true);
      }
      dispatches++;
      await apply(attempt, cancel, false);
      throw StateError('Lost completion after native commit');
    });
    expect(result?.committed, isTrue);
    expect(importer.value.current?.stage, TransferStage.committed);
    expect(dispatches, 1);
    expect(recoveries, 1);
    expect(builds, 1);
    await importer.recover(importer.value.current!, apply);
    expect(builds, 1);
    expect(
      await Directory(book)
          .list()
          .where((entry) => p.basename(entry.path) == 'Imported')
          .length,
      1,
    );
  });

  test('startup reconciles private intent as absent before an explicit same-ID retry', () async {
    final prepared = await importer.prepare(await source(), build);
    final id = prepared!.cohortId;
    await runTransferStore({
      'op': 'prepareAttempt',
      'scope': 'cohort',
      'root': root,
      'notebooksRoot': notebooks,
      'id': prepared.id,
    });
    await importer.shutdown();
    importer = controller();
    await importer.initialize();
    expect(importer.value.current?.stage, TransferStage.intent);
    expect(importer.value.current?.canApply, isFalse);
    expect(importer.value.blockedNotebookIds, contains(target.notebookId));
    expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
    final recovered = await importer.recover(importer.value.current!, apply);
    expect(importer.value.error, isNull);
    expect(recovered?.committed, isFalse);
    expect(importer.value.current?.stage, TransferStage.prepared);
    expect(importer.value.current?.canApply, isTrue);
    expect(importer.value.current?.cohortId, id);
    expect(
      (await importer.apply(importer.value.current!, apply))?.committed,
      isTrue,
    );
    expect(builds, 1);
  });

  test(
    'receipt recovery never recreates a legitimately deleted committed folder',
    () async {
      final prepared = await importer.prepare(await source(), build);
      expect((await importer.apply(prepared!, apply))?.committed, isTrue);
      final core = await CoreNotebook.openCatalog(
        appDataPath: p.join(temp.path, 'delete-app'),
        localDataPath: p.join(temp.path, 'delete-local'),
        notebookPath: book,
        expectedNotebookId: target.notebookId,
      );
      try {
        await core.delete(prepared.cohortId!);
      } finally {
        await core.close();
      }
      expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
      await importer.shutdown();
      importer = controller();
      await importer.initialize();
      expect(
        (await importer.recover(importer.value.current!, apply))?.committed,
        isTrue,
      );
      expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
      await importer.discard(importer.value.current!, recover: apply);
      expect(importer.value.hasStaging, isFalse);
      expect(await File(p.join(book, 'Original.md')).exists(), isTrue);
    },
  );

  test('provider cancellation and shutdown join the lease before retaining a ready source', () async {
    final gate = Completer<DocumentImportResult>();
    final copied = Completer<void>();
    provider.copy = (id, kind) async {
      final result = await copy(id, kind);
      copied.complete();
      return gate.future.then((_) => result);
    };
    await importer.initialize();
    final pending = importer.start(
      target: target,
      kind: DocumentImportKind.folder,
    );
    expect(reservations, contains(importer));
    await copied.future;
    final old = importer.value.current!;
    importer.cancel();
    var closed = false;
    final closing = importer.shutdown().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(() => importer.discard(old, recover: apply), throwsStateError);
    gate.complete(
      const DocumentImportResult(
        status: DocumentImportStatus.cancelled,
        sourceName: null,
        bytes: 0,
        entries: 0,
      ),
    );
    await pending;
    await closing;
    expect(provider.cancellations, 1);
    expect(importer.value.current?.stage, TransferStage.captured);
    expect(
      await File(p.join(old.transactionRoot, 'unpacked/Wrapper/.hidden.bin'))
          .readAsBytes(),
      [0, 7, 255],
    );
    expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
    importer = controller();
    await importer.initialize();
    await importer.capture(importer.value.current!);
    expect(importer.value.current?.stage, TransferStage.source);
    expect(provider.picks, 1);
  });

  test('global reservation refusal is synchronous and precedes provider or allocation', () async {
    final denied = CohortImporter(
      root: root,
      notebooksRoot: notebooks,
      platform: provider,
      reserveTransfer: (_) => throw StateError('Another domain owns staging.'),
      releaseTransfer: (_) {},
    );
    controllers.add(denied);
    await denied.initialize();
    expect(
      () => denied.start(target: target, kind: DocumentImportKind.folder),
      throwsStateError,
    );
    expect(provider.picks, 0);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test(
    'missing local Markdown reference is refused from an untampered raw source',
    () async {
      provider.copy = (id, kind) async {
        final result = await copy(id, kind);
        final text = utf8.encode('[missing](assets/missing.bin)\n');
        await File(p.join(root, id, 'unpacked/Wrapper/note.md'))
            .writeAsBytes(text);
        return DocumentImportResult(
          status: result.status,
          sourceName: result.sourceName,
          bytes:
              result.bytes -
              utf8.encode('![picture](assets/图.png)\n').length +
              text.length,
          entries: result.entries,
        );
      };
      final captured = await source();
      await importer.prepare(captured, build);
      expect(importer.value.error, isNotNull);
      expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
      expect(
        await File(p.join(captured.transactionRoot, 'prepared.json')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(captured.transactionRoot, 'unpacked/Wrapper/note.md'))
            .readAsString(),
        '[missing](assets/missing.bin)\n',
      );
    },
  );

  test(
    'stale attempt cannot prepare or discard a newer source token',
    () async {
      final old = await source();
      await importer.setFolderName(old, 'Chosen name');
      expect(() => importer.prepare(old, build), throwsStateError);
      expect(() => importer.discard(old, recover: apply), throwsStateError);
      expect(importer.value.current?.target.folderName, 'Chosen name');
      await importer.prepare(importer.value.current!, build);
      expect(importer.value.current?.stage, TransferStage.prepared);
      expect(
        () => importer.setFolderName(
          importer.value.current!,
          'Changed after seal',
        ),
        throwsStateError,
      );
    },
  );

  test('changed source inventory refuses private build without live publication', () async {
    final attempt = await source();
    // Change the captured source after its sealed inventory: native must detect
    // this, never trust the Dart source stage or publish an incomplete graph.
    await File(p.join(attempt.transactionRoot, 'unpacked/Wrapper/note.md'))
        .writeAsString('[escape](../../missing.md)\n');
    await importer.prepare(attempt, build);
    expect(importer.value.error, isNotNull);
    expect(await Directory(p.join(book, 'Imported')).exists(), isFalse);
    expect(
      await File(p.join(attempt.transactionRoot, 'prepared.json')).exists(),
      isFalse,
    );
    expect(
      await File(p.join(attempt.transactionRoot, 'unpacked/Wrapper/note.md'))
          .readAsString(),
      '[escape](../../missing.md)\n',
    );
  });

  test(
    'malformed ownership is visible quarantine, not a forgettable cleanup row',
    () async {
      const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final path = p.join(root, id);
      await Directory(path).create();
      await File(p.join(path, 'request.json')).writeAsString('{invalid');
      await File(p.join(path, 'keep.bin')).writeAsBytes([1, 0, 255]);
      await importer.initialize();
      expect(importer.value.blocksAllNotebooks, isTrue);
      expect(importer.value.leftovers, hasLength(1));
      expect(importer.value.leftovers.single.canDiscard, isFalse);
      expect(
        () => importer.start(target: target, kind: DocumentImportKind.file),
        throwsStateError,
      );
      expect(
        () => importer.discardLeftover(importer.value.leftovers.single),
        throwsStateError,
      );
      expect(await File(p.join(path, 'keep.bin')).readAsBytes(), [1, 0, 255]);
    },
  );
}
