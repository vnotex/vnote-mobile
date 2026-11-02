// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/resource_transfer.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Provider implements DocumentTransferPlatform {
  late String root;
  List<int> bytes = [0, 255, 128, 42, 0, 7];
  int picks = 0;
  int saves = 0;
  int cancellations = 0;
  final saving = Completer<void>();
  Completer<DocumentExportResult>? saved;
  @override
  Future<void> prepareStorage() async {}
  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  }) async {
    expect(scope, DocumentTransferScope.resource);
    picks++;
    final transaction = p.join(root, operationId);
    final request = jsonDecode(
      await File(p.join(transaction, 'request.json')).readAsString(),
    );
    expect(request, {
      'version': 2,
      'id': operationId,
      'scope': 'resource',
      'kind': kind.name,
    });
    // Requested operation survives interruption before provider completion.
    expect(await File(p.join(transaction, 'resource.json')).exists(), isTrue);
    await Directory(p.join(transaction, 'unpacked')).create();
    await File(p.join(transaction, 'unpacked/provider-name.bin'))
        .writeAsBytes(bytes, flush: true);
    await File(p.join(transaction, 'accepted.jsonl')).writeAsString(
      '${jsonEncode({'path': 'provider-name.bin', 'type': 'file'})}\n',
      flush: true,
    );
    return DocumentImportResult(
      status: DocumentImportStatus.ready,
      sourceName: 'Provider input',
      bytes: bytes.length,
      entries: 1,
    );
  }

  @override
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    cancellations++;
  }

  @override
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    expect(scope, DocumentTransferScope.resource);
    cancellations++;
  }

  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  }) async {
    expect(scope, DocumentTransferScope.resource);
    expect(path, p.join(root, operationId, 'output', suggestedName));
    saves++;
    if (!saving.isCompleted) saving.complete();
    return saved == null
        ? const DocumentExportResult(
            status: DocumentExportStatus.saved,
            externalMayBeIncomplete: false,
          )
        : saved!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String notebooks;
  late String root;
  late String book;
  late ResourceTarget target;
  late _Provider provider;
  late ResourceTransfer transfer;
  final controllers = <ResourceTransfer>[];
  final reservations = <Object>{};
  var opens = 0;

  ResourceTransfer controller() {
    final instance = ResourceTransfer(
      root: root,
      notebooksRoot: notebooks,
      platform: provider,
      reserveTransfer: reservations.add,
      releaseTransfer: reservations.remove,
    );
    controllers.add(instance);
    return instance;
  }

  Future<CoreNotebook> owner([ResourceAttempt? attempt]) {
    final engine = attempt == null
        ? p.join(temp.path, 'listing-${opens++}')
        : p.join(attempt.transactionRoot, 'recovery-${opens++}');
    return CoreNotebook.openResources(
      appDataPath: p.join(engine, 'app'),
      localDataPath: p.join(engine, 'local'),
      notebookPath: book,
      notebookId: target.notebookId,
      nodeId: target.nodeId,
    );
  }

  Future<CoreResourceResult> apply(
    ResourceAttempt attempt,
    TransferCancellation cancel,
    bool recover,
  ) async {
    transfer.clearListing(attempt.target);
    final core = await owner(attempt);
    try {
      if (!recover) cancel.check();
      return recover
          ? await core.recoverResource(attempt.transactionRoot)
          : await core.applyResource(attempt.transactionRoot);
    } finally {
      try {
        transfer.setListing(attempt.target, await core.listResources());
      } finally {
        await core.close();
      }
    }
  }

  Future<CoreResourceListing> list(
    ResourceTarget target,
    TransferCancellation cancel,
  ) async {
    cancel.check();
    final core = await owner();
    cancel.onCancel = core.cancelResourceRead;
    try {
      return await core.listResources();
    } finally {
      cancel.onCancel = null;
      await core.close();
    }
  }

  Future<CoreResourceExport> snapshot(
    ResourceAttempt attempt,
    TransferCancellation cancel,
  ) async {
    cancel.check();
    final core = await owner(attempt);
    cancel.onCancel = core.cancelResourceRead;
    try {
      return await core.exportResource(attempt.name, attempt.transactionRoot);
    } finally {
      cancel.onCancel = null;
      await core.close();
    }
  }

  Future<CoreResourceResult> add({
    ResourceOperation operation = ResourceOperation.add,
    String name = 'chosen.bin',
  }) async {
    await transfer.initialize();
    final attempt = await transfer.start(
      target: target,
      operation: operation,
      name: name,
    );
    expect(transfer.value.error, isNull);
    expect(attempt?.stage, TransferStage.source);
    final result = await transfer.apply(attempt!, apply);
    expect(transfer.value.error, isNull);
    expect(result?.committed, isTrue);
    return result!;
  }

  Future<void> discard() =>
      transfer.discard(transfer.value.current!, recover: apply);

  String livePath(String relativeUrl) =>
      p.normalize(p.join(book, Uri.decodeComponent(relativeUrl)));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('resource-controller-');
    notebooks = p.join(temp.path, 'notebooks');
    root = p.join(temp.path, 'resources');
    for (final path in [
      notebooks,
      root,
      p.join(temp.path, 'imports'),
      p.join(temp.path, 'exports'),
      p.join(temp.path, 'cohorts'),
    ]) {
      await Directory(path).create();
    }
    book = p.join(notebooks, 'fixture');
    final core = await CoreNotebook.createCatalog(
      appDataPath: p.join(temp.path, 'app'),
      localDataPath: p.join(temp.path, 'local'),
      notebookPath: book,
      notebookName: 'Original',
    );
    final id = await core.createNote(
      core.initialDirectory.folderId,
      'Original.md',
    );
    target = ResourceTarget(
      notebookId: core.initialDirectory.notebookId,
      nodeId: id,
      notebookRelative: 'fixture',
    );
    await core.close();
    provider = _Provider()..root = root;
    opens = 0;
    transfer = controller();
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

  test('real add preserves opaque bytes and exact chosen name without editing the body', () async {
    final body = await File(p.join(book, 'Original.md')).readAsBytes();
    final result = await add();
    expect(result.name, 'chosen.bin');
    expect(
      await File(livePath(result.relativeUrl!)).readAsBytes(),
      provider.bytes,
    );
    expect(
      transfer.value.listing!.entries
          .where((entry) => entry.name == 'chosen.bin')
          .single
          .tracked,
      isTrue,
    );
    expect(
      transfer.value.listing!.entries
          .where((entry) => entry.name == 'chosen.bin')
          .single
          .exists,
      isTrue,
    );
    expect(await File(p.join(book, 'Original.md')).readAsBytes(), body);
    expect(transfer.value.lastResult?.relativeUrl, result.relativeUrl);
    expect(provider.picks, 1);
    final captured = await File(
      p.join(
        transfer.value.current!.transactionRoot,
        'unpacked/provider-name.bin',
      ),
    ).readAsBytes();
    expect(captured, provider.bytes);
  });

  test(
    'track, untrack, exact rename and remove preserve unrelated nested assets',
    () async {
      final added = await add();
      final path = livePath(added.relativeUrl!);
      final nested = File(p.join(p.dirname(path), 'nested/keep.bin'));
      await nested.parent.create();
      await nested.writeAsBytes([0, 9, 255]);
      await discard();
      var attempt = await transfer.start(
        target: target,
        operation: ResourceOperation.untrack,
        name: 'chosen.bin',
      );
      expect((await transfer.apply(attempt!, apply))?.committed, isTrue);
      expect(
        transfer.value.listing!.entries
            .singleWhere((entry) => entry.name == 'chosen.bin')
            .tracked,
        isFalse,
      );
      expect(await File(path).readAsBytes(), provider.bytes);
      await discard();
      attempt = await transfer.start(
        target: target,
        operation: ResourceOperation.track,
        name: 'chosen.bin',
      );
      expect((await transfer.apply(attempt!, apply))?.committed, isTrue);
      await discard();
      attempt = await transfer.start(
        target: target,
        operation: ResourceOperation.rename,
        name: 'chosen.bin',
        newName: 'renamed.bin',
      );
      final renamed = await transfer.apply(attempt!, apply);
      expect(renamed?.committed, isTrue);
      expect(renamed?.name, 'renamed.bin');
      expect(await File(path).exists(), isFalse);
      expect(
        await File(livePath(renamed!.relativeUrl!)).readAsBytes(),
        provider.bytes,
      );
      expect(
        transfer.value.listing!.entries
            .singleWhere((entry) => entry.name == 'renamed.bin')
            .tracked,
        isTrue,
      );
      await discard();
      attempt = await transfer.start(
        target: target,
        operation: ResourceOperation.remove,
        name: 'renamed.bin',
      );
      expect((await transfer.apply(attempt!, apply))?.committed, isTrue);
      expect(await File(livePath(renamed.relativeUrl!)).exists(), isFalse);
      expect(await nested.readAsBytes(), [0, 9, 255]);
    },
  );

  test(
    'listing distinguishes missing membership from untracked bytes',
    () async {
      final added = await add();
      final path = livePath(added.relativeUrl!);
      await discard();
      await File(path).delete();
      await File(p.join(p.dirname(path), 'untracked.bin'))
          .writeAsBytes([1, 0, 2]);
      final listing = await transfer.refresh(target, list);
      expect(transfer.value.error, isNull);
      final missing = listing!.entries.singleWhere(
        (entry) => entry.name == 'chosen.bin',
      );
      final untracked = listing.entries.singleWhere(
        (entry) => entry.name == 'untracked.bin',
      );
      expect(missing.tracked, isTrue);
      expect(missing.exists, isFalse);
      expect(untracked.tracked, isFalse);
      expect(untracked.exists, isTrue);
      expect(untracked.bytes, 3);
    },
  );

  test('reported failure after actual native add reconciles one copy without replay', () async {
    await transfer.initialize();
    final attempt = await transfer.start(
      target: target,
      operation: ResourceOperation.add,
      name: 'chosen.bin',
    );
    var dispatched = 0;
    var recovered = 0;
    final result = await transfer.apply(attempt!, (
      attempt,
      cancel,
      recover,
    ) async {
      if (recover) {
        recovered++;
        return apply(attempt, cancel, true);
      }
      dispatched++;
      await apply(attempt, cancel, false);
      throw StateError('Completion transport lost');
    });
    expect(result?.committed, isTrue);
    expect(dispatched, 1);
    expect(recovered, 1);
    expect(
      transfer.value.listing!.entries.where((entry) => entry.exists),
      hasLength(1),
    );
    expect(transfer.value.current?.stage, TransferStage.committed);
    await transfer.recover(transfer.value.current!, apply);
    expect(provider.picks, 1);
    expect(
      transfer.value.listing!.entries.where((entry) => entry.exists),
      hasLength(1),
    );
  });

  test('committed receipt survives later legitimate byte changes and private discard', () async {
    final result = await add();
    final path = livePath(result.relativeUrl!);
    await File(path).writeAsBytes([9, 8, 7]);
    await transfer.shutdown();
    transfer = controller();
    await transfer.initialize();
    expect(transfer.value.current?.stage, TransferStage.committed);
    final recovered = await transfer.recover(transfer.value.current!, apply);
    expect(recovered?.committed, isTrue);
    await discard();
    expect(transfer.value.hasStaging, isFalse);
    expect(await File(path).readAsBytes(), [9, 8, 7]);
    expect(provider.picks, 1);
  });

  test('export owner releases before provider IO; shutdown joins and restart retains ambiguity', () async {
    final added = await add();
    await discard();
    final attempt = await transfer.start(
      target: target,
      operation: ResourceOperation.export,
      name: 'chosen.bin',
    );
    expect(attempt?.operation, ResourceOperation.export);
    final ready = await transfer.prepareExport(attempt!, snapshot);
    expect(transfer.value.error, isNull);
    expect(await File(ready!.path).readAsBytes(), provider.bytes);
    provider.saved = Completer<DocumentExportResult>();
    final saving = transfer.save(transfer.value.current!);
    await provider.saving.future;
    // Competing owner would be refused if snapshot capture still held its host.
    final readOwner = await owner();
    await readOwner.close();
    var closed = false;
    final closing = transfer.shutdown().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(
      () => transfer.discard(transfer.value.current!, recover: apply),
      throwsStateError,
    );
    provider.saved!.complete(
      const DocumentExportResult(
        status: DocumentExportStatus.failed,
        externalMayBeIncomplete: true,
      ),
    );
    await saving;
    await closing;
    expect(transfer.value.externalMayBeIncomplete, isTrue);
    expect(await File(ready.path).readAsBytes(), provider.bytes);
    expect(
      await File(livePath(added.relativeUrl!)).readAsBytes(),
      provider.bytes,
    );
    transfer = controller();
    await transfer.initialize();
    expect(transfer.value.current?.stage, TransferStage.exportReady);
    expect(transfer.value.externalMayBeIncomplete, isTrue);
    await File(ready.path).writeAsBytes([0, 1]);
    expect(await transfer.save(transfer.value.current!), isNull);
    expect(transfer.value.error, isNotNull);
    expect(provider.saves, 1);
  });

  test('known name collision preserves original bytes and never accepts a suffixed copy', () async {
    final original = await add();
    final path = livePath(original.relativeUrl!);
    final originalBytes = List<int>.of(provider.bytes);
    await discard();
    provider.bytes = [9, 8, 7, 6];
    final attempt = await transfer.start(
      target: target,
      operation: ResourceOperation.add,
      name: 'chosen.bin',
    );
    expect(await transfer.apply(attempt!, apply), isNull);
    expect(transfer.value.error, isNotNull);
    expect(await File(path).readAsBytes(), originalBytes);
    expect(
      transfer.value.listing!.entries.where((entry) => entry.exists),
      hasLength(1),
    );
    expect(
      await File(p.join(attempt.transactionRoot, 'unpacked/provider-name.bin'))
          .readAsBytes(),
      provider.bytes,
    );
  });

  test('missing receipt and unexpected live identity cannot authorize another binary copy', () async {
    final added = await add();
    final attempt = transfer.value.current!;
    final requested = livePath(added.relativeUrl!);
    final unexpected = p.join(p.dirname(requested), 'unexpected.bin');
    // Controlled crash boundary: the real native dispatch and bytes exist, but
    // completion receipts are lost and the live name no longer proves success.
    await File(p.join(attempt.transactionRoot, 'committed.json')).delete();
    await File(p.join(attempt.transactionRoot, 'outcome.json')).delete();
    await File(requested).rename(unexpected);
    await transfer.shutdown();
    transfer = controller();
    await transfer.initialize();
    expect(transfer.value.current?.stage, TransferStage.intent);
    await transfer.retry(transfer.value.current!, apply);
    expect(transfer.value.error, isNotNull);
    expect(transfer.value.lastResult?.committed, isNot(true));
    await transfer.retry(transfer.value.current!, apply);
    expect(await File(requested).exists(), isFalse);
    expect(await File(unexpected).readAsBytes(), provider.bytes);
    expect(provider.picks, 1);
    await transfer.discard(
      transfer.value.current!,
      recover: apply,
      abandon: true,
    );
    expect(transfer.value.hasStaging, isFalse);
    expect(await File(unexpected).readAsBytes(), provider.bytes);
  });

  test(
    'image asset commits bytes independently of a later editor link insertion',
    () async {
      final body = await File(p.join(book, 'Original.md')).readAsBytes();
      final image = await add(
        operation: ResourceOperation.image,
        name: 'picture.png',
      );
      expect(image.relativeUrl, isNotNull);
      expect(
        await File(livePath(image.relativeUrl!)).readAsBytes(),
        provider.bytes,
      );
      expect(await File(p.join(book, 'Original.md')).readAsBytes(), body);
      await discard();
      expect(
        await File(livePath(image.relativeUrl!)).readAsBytes(),
        provider.bytes,
      );
    },
  );

  test(
    'stale resource tokens cannot apply, export or discard current work',
    () async {
      await transfer.initialize();
      final old = await transfer.start(
        target: target,
        operation: ResourceOperation.add,
        name: 'chosen.bin',
      );
      await transfer.apply(old!, apply);
      expect(() => transfer.apply(old, apply), throwsStateError);
      expect(() => transfer.discard(old, recover: apply), throwsStateError);
      expect(transfer.value.lastResult?.committed, isTrue);
      transfer.clearListing(target);
      expect(transfer.value.listing, isNull);
      expect(transfer.value.lastResult?.committed, isTrue);
    },
  );

  test('unknown staging blocks writers and explicit discard cannot delete foreign bytes', () async {
    final unknown = Directory(p.join(root, 'foreign'));
    await unknown.create();
    await File(p.join(unknown.path, 'keep.bin')).writeAsBytes([1, 0, 255]);
    await transfer.initialize();
    expect(transfer.value.blocksAllNotebooks, isTrue);
    expect(transfer.value.leftovers, hasLength(1));
    expect(transfer.value.leftovers.single.canDiscard, isFalse);
    expect(
      () => transfer.discardLeftover(transfer.value.leftovers.single),
      throwsStateError,
    );
    expect(await File(p.join(unknown.path, 'keep.bin')).readAsBytes(), [
      1,
      0,
      255,
    ]);
  });
}
