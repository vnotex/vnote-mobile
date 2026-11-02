// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/notebook_export.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Platform implements DocumentTransferPlatform {
  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentImportKind kind,
  }) async => const DocumentImportResult(
    status: DocumentImportStatus.unavailable,
    sourceName: null,
    bytes: 0,
    entries: 0,
  );
  @override
  Future<void> cancelImport(String operationId) async {}

  int preparations = 0;
  int saves = 0;
  int cancellations = 0;
  bool rejectPreparation = false;
  final entered = Completer<void>();
  final results = <DocumentExportResult>[];
  Completer<DocumentExportResult>? pending;
  void Function(String, String, String)? onSave;

  @override
  Future<void> prepareStorage() async {
    preparations++;
    if (rejectPreparation) throw StateError('private/provider/path');
  }

  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required String path,
    required String suggestedName,
  }) async {
    saves++;
    onSave?.call(operationId, path, suggestedName);
    if (!entered.isCompleted) entered.complete();
    if (pending case final gate?) return gate.future;
    return results.removeAt(0);
  }

  @override
  Future<void> cancel(String operationId) async {
    cancellations++;
    // Deliberately does not settle pending: cancel acknowledgement is not a
    // native reader/picker release and must never make discard legal.
  }
}

Future<void> _directoryLink(String path, String target) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      path,
      target,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } else {
    await Link(path).create(target);
  }
}

Future<void> _copyTree(String source, String destination) async {
  await Directory(destination).create();
  await for (final entity in Directory(source).list(followLinks: false)) {
    final target = p.join(destination, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity.path, target);
    } else {
      await File(entity.path).copy(target);
    }
  }
}

void main() {
  late Directory temp;
  late String root;
  late _Platform platform;
  late NotebookExporter exporter;
  String? notebookId;
  const notebookName = '研究 notebook';
  const syntheticId = 'c77e9c39-cdd3-40e6-a944-e57a07d818bd';
  final exporters = <NotebookExporter>[];

  NotebookExporter makeExporter({
    DocumentTransferPlatform? adapter,
    String? location,
  }) {
    final value = NotebookExporter(
      root: location ?? root,
      platform: adapter ?? platform,
    );
    exporters.add(value);
    return value;
  }

  Future<void> makeNotebook() async {
    if (notebookId != null) return;
    for (final parts in [
      const ['core', 'app'],
      const ['core', 'local'],
      const ['notebooks'],
    ]) {
      await Directory(p.joinAll([temp.path, ...parts])).create(recursive: true);
    }
    final catalog = await CoreNotebook.createCatalog(
      appDataPath: p.join(temp.path, 'core', 'app'),
      localDataPath: p.join(temp.path, 'core', 'local'),
      notebookPath: p.join(temp.path, 'notebooks', 'book'),
      notebookName: notebookName,
    );
    try {
      notebookId = catalog.initialDirectory.notebookId;
    } finally {
      await catalog.close();
    }
  }

  Future<CoreExportSnapshot> capture(
    String destination,
    int budget,
    ExportCancellation cancellation,
  ) async {
    final catalog = await CoreNotebook.openExportCatalog(
      appDataPath: p.join(temp.path, 'core', 'app'),
      localDataPath: p.join(temp.path, 'core', 'local'),
      notebookPath: p.join(temp.path, 'notebooks', 'book'),
      expectedNotebookId: notebookId!,
    );
    cancellation.onCancel = catalog.cancelExport;
    try {
      return await catalog.exportSnapshot(
        destination,
        stagingBudgetBytes: budget,
      );
    } finally {
      await catalog.close();
      cancellation.onCancel = null;
    }
  }

  Future<PreparedNotebookExport> prepare() async {
    await makeNotebook();
    await exporter.initialize();
    final ready = await exporter.prepare(
      notebookId: notebookId!,
      notebookName: notebookName,
      capture: capture,
    );
    expect(ready, isNotNull, reason: exporter.value.error);
    return ready!;
  }

  Future<CoreExportSnapshot> syntheticCapture(
    String destination,
    int budget,
    ExportCancellation cancellation,
  ) async {
    cancellation.check();
    await Directory(destination).create();
    await File(p.join(destination, 'opaque.bin')).writeAsBytes([0, 1, 255, 0]);
    return const CoreExportSnapshot(
      notebookId: syntheticId,
      notebookName: notebookName,
      bytes: 4,
      files: 1,
      directories: 0,
      archiveLimit: 8192,
    );
  }

  Future<void> rewriteMarker(
    String path,
    void Function(Map<String, dynamic>) change,
  ) async {
    final file = File(path);
    final marker =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    change(marker);
    await file.writeAsString(jsonEncode(marker), flush: true);
  }

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('vnote-export-');
    temp = Directory(await created.resolveSymbolicLinks());
    root = p.join(temp.path, 'exports');
    platform = _Platform();
    notebookId = null;
    exporter = makeExporter();
  });

  tearDown(() async {
    for (final item in exporters) {
      await item.shutdown();
      item.dispose();
    }
    exporters.clear();
    await temp.delete(recursive: true);
  });

  test('initialize reconciles storage without a platform channel', () async {
    final withoutChannel = NotebookExporter(root: root);
    exporters.add(withoutChannel);
    await withoutChannel.initialize();
    expect(withoutChannel.value.error, isNull);
    expect(withoutChannel.value.busy, isFalse);
    expect(await Directory(root).exists(), isTrue);
    expect(platform.preparations, 0);
  });

  test('real native snapshot preserves raw opaque bytes and empty directories in ZIP', () async {
    await makeNotebook();
    final book = p.join(temp.path, 'notebooks', 'book');
    final config = File(p.join(book, 'vx_notebook', 'config.json'));
    final original = await config.readAsBytes();
    await Directory(p.join(book, '.private', 'empty')).create(recursive: true);
    final opaque = Uint8List.fromList(
      List.generate(700 * 1024, (i) => (i * 37 + i ~/ 251) & 255),
    );
    await File(p.join(book, '.private', 'opaque.bin')).writeAsBytes(opaque);
    var ownerJoined = false;
    exporter.addListener(() {
      if (exporter.value.phase == NotebookExportPhase.archiving) {
        expect(ownerJoined, isTrue);
      }
    });
    await exporter.initialize();
    final ready = await exporter.prepare(
      notebookId: notebookId!,
      notebookName: notebookName,
      capture: (destination, budget, cancellation) async {
        expect(
          await File(p.join(p.dirname(destination), 'request.json')).exists(),
          isTrue,
        );
        expect(await Directory(destination).exists(), isFalse);
        expect(budget, 4 * 1024 * 1024 * 1024 - 128 * 1024);
        final snapshot = await capture(destination, budget, cancellation);
        ownerJoined = true;
        return snapshot;
      },
    );
    expect(ready, isNotNull, reason: exporter.value.error);
    final artifact = ready!;
    expect(artifact.notebookId, notebookId);
    expect(artifact.notebookName, notebookName);
    expect(artifact.id, matches(r'^[0-9a-f]{32}$'));
    expect(artifact.path, p.join(root, artifact.id, 'notebook.zip'));
    expect(
      await Directory(p.join(root, artifact.id, 'snapshot')).exists(),
      isFalse,
    );
    expect(
      await File(p.join(root, artifact.id, 'ready.json')).exists(),
      isTrue,
    );
    expect(await File(artifact.path).length(), artifact.bytes);
    final decoded = ZipDecoder().decodeBytes(
      await File(artifact.path).readAsBytes(),
      verify: true,
    );
    final entries = {for (final entry in decoded) entry.name: entry};
    expect(entries['vx_notebook/config.json']!.content, original);
    expect(entries['.private/opaque.bin']!.content, opaque);
    expect(entries['.private/empty/']!.isDirectory, isTrue);
    expect(entries.keys.any((name) => name.startsWith('snapshot/')), isFalse);
    expect(entries.keys, isNot(contains('request.json')));
    expect(await config.readAsBytes(), original);
    expect(
      await File(p.join(book, '.private', 'opaque.bin')).readAsBytes(),
      opaque,
    );
    platform.onSave = (id, path, name) {
      expect(ownerJoined, isTrue);
      expect(id, artifact.id);
      expect(path, artifact.path);
      expect(name, 'vnote-${artifact.id}.zip');
    };
    platform.results.add(
      const DocumentExportResult(
        status: DocumentExportStatus.saved,
        externalMayBeIncomplete: false,
      ),
    );
    await exporter.save(artifact);
    expect(exporter.value.prepared, isNull);
    expect(exporter.value.error, isNull);
    expect(await Directory(root).list().isEmpty, isTrue);
    expect(platform.preparations, 2);
    expect(await config.readAsBytes(), original);
  });

  test(
    'cancelled, failed and unavailable saves retain the exact ZIP for retry',
    () async {
      final artifact = await prepare();
      final before = await File(artifact.path).readAsBytes();
      for (final status in [
        DocumentExportStatus.cancelled,
        DocumentExportStatus.failed,
        DocumentExportStatus.unavailable,
      ]) {
        platform.results.add(
          DocumentExportResult(status: status, externalMayBeIncomplete: true),
        );
        await exporter.save(artifact);
        expect(identical(exporter.value.prepared, artifact), isTrue);
        expect(exporter.value.busy, isFalse);
        expect(exporter.value.message, contains('incomplete'));
        expect(await File(artifact.path).readAsBytes(), before);
      }
      platform.results.add(
        const DocumentExportResult(
          status: DocumentExportStatus.saved,
          externalMayBeIncomplete: false,
        ),
      );
      await exporter.save(artifact);
      expect(platform.saves, 4);
      expect(exporter.value.prepared, isNull);
      expect(await File(artifact.path).exists(), isFalse);
    },
  );

  test(
    'provider cancellation acknowledgement does not release the source lease',
    () async {
      final artifact = await prepare();
      platform.pending = Completer<DocumentExportResult>();
      final saving = exporter.save(artifact);
      await platform.entered.future;
      exporter.cancel();
      expect(platform.cancellations, 1);
      expect(() => exporter.discard(artifact), throwsStateError);
      var closed = false;
      final closing = exporter.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(await File(artifact.path).exists(), isTrue);
      platform.pending!.complete(
        const DocumentExportResult(
          status: DocumentExportStatus.cancelled,
          externalMayBeIncomplete: true,
        ),
      );
      await saving;
      await closing;
      expect(exporter.value.prepared, same(artifact));
      expect(await File(artifact.path).exists(), isTrue);
      exporter = makeExporter();
      await exporter.initialize();
      expect(exporter.value.prepared!.sha256, artifact.sha256);
      expect(exporter.value.message, contains('previous external copy'));
      await exporter.discard(exporter.value.prepared!);
      expect(await Directory(root).list().isEmpty, isTrue);
    },
  );

  test(
    'success is cleaned only after the provider terminal completion',
    () async {
      final artifact = await prepare();
      platform.pending = Completer<DocumentExportResult>();
      final saving = exporter.save(artifact);
      await platform.entered.future;
      expect(await File(artifact.path).exists(), isTrue);
      exporter.cancel();
      expect(exporter.value.busy, isTrue);
      platform.pending!.complete(
        const DocumentExportResult(
          status: DocumentExportStatus.saved,
          externalMayBeIncomplete: false,
        ),
      );
      await saving;
      expect(await File(artifact.path).exists(), isFalse);
      expect(exporter.value.prepared, isNull);
    },
  );

  test(
    'shutdown joins capture before cleaning its partial or completed snapshot',
    () async {
      await makeNotebook();
      await exporter.initialize();
      final captured = Completer<String>();
      final releaseOwner = Completer<void>();
      var cancellationDelivered = false;
      final preparing = exporter.prepare(
        notebookId: notebookId!,
        notebookName: notebookName,
        capture: (destination, budget, cancellation) async {
          final snapshot = await capture(destination, budget, cancellation);
          captured.complete(destination);
          await releaseOwner.future;
          // A callback installed after cancel still observes the cancellation.
          cancellation.onCancel = () => cancellationDelivered = true;
          return snapshot;
        },
      );
      final snapshot = await captured.future;
      exporter.cancel();
      var closed = false;
      final closing = exporter.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(await Directory(snapshot).exists(), isTrue);
      releaseOwner.complete();
      expect(await preparing, isNull);
      await closing;
      expect(cancellationDelivered, isTrue);
      expect(await Directory(root).list().isEmpty, isTrue);
      expect(
        await Directory(p.join(temp.path, 'notebooks', 'book')).exists(),
        isTrue,
      );
    },
  );

  test('cancel remembered at worker startup closes output and removes interrupted staging', () async {
    await exporter.initialize();
    exporter.addListener(() {
      if (exporter.value.phase == NotebookExportPhase.archiving) {
        exporter.cancel();
      }
    });
    final result = await exporter.prepare(
      notebookId: syntheticId,
      notebookName: notebookName,
      capture: syntheticCapture,
    );
    expect(result, isNull);
    expect(exporter.value.prepared, isNull);
    expect(exporter.value.leftovers, isEmpty);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('late cancellation beats worker completion without deleting a committed ZIP', () async {
    await exporter.initialize();
    exporter.addListener(() {
      if (exporter.value.prepared != null) exporter.cancel();
    });
    final result = await exporter.prepare(
      notebookId: syntheticId,
      notebookName: notebookName,
      capture: syntheticCapture,
    );
    expect(result, isNull);
    final committed = exporter.value.prepared!;
    expect(exporter.value.message, contains('cancelled'));
    expect(exporter.value.message, contains('retained'));
    expect(await File(committed.path).exists(), isTrue);
    expect(
      await File(p.join(p.dirname(committed.path), 'ready.json')).exists(),
      isTrue,
    );
    expect(platform.saves, 0);
  });

  test('cancellation during real streaming closes the current input and partial ZIP', () async {
    await exporter.initialize();
    final allocated = Completer<String>();
    const sourceBytes = 8 * 1024 * 1024;
    final preparing = exporter.prepare(
      notebookId: syntheticId,
      notebookName: notebookName,
      capture: (destination, budget, cancellation) async {
        await Directory(destination).create();
        final input = await File(p.join(destination, 'stream.bin'))
            .open(mode: FileMode.writeOnly);
        try {
          final buffer = Uint8List(64 * 1024);
          var random = 17;
          for (
            var written = 0;
            written < sourceBytes;
            written += buffer.length
          ) {
            for (var i = 0; i < buffer.length; i++) {
              random = (1664525 * random + 1013904223) & 0xffffffff;
              buffer[i] = (random >> 16) & 255;
            }
            await input.writeFrom(buffer);
          }
        } finally {
          await input.close();
        }
        allocated.complete(p.dirname(destination));
        return const CoreExportSnapshot(
          notebookId: syntheticId,
          notebookName: notebookName,
          bytes: sourceBytes,
          files: 1,
          directories: 0,
          archiveLimit: sourceBytes + sourceBytes ~/ 64 + 8192,
        );
      },
    );
    final partial = File(p.join(await allocated.future, 'notebook.zip.part'));
    await (() async {
      while (exporter.value.busy) {
        if (await partial.exists() && await partial.length() >= 64 * 1024) {
          exporter.cancel();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail(
        'The streaming worker finished without exposing its bounded partial output.',
      );
    })().timeout(const Duration(seconds: 20));
    expect(await preparing, isNull);
    expect(exporter.value.prepared, isNull);
    expect(exporter.value.leftovers, isEmpty);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('dispose suppresses late provider notifications without deleting a leased ZIP', () async {
    final artifact = await prepare();
    platform.pending = Completer<DocumentExportResult>();
    var notifications = 0;
    exporter.addListener(() => notifications++);
    final saving = exporter.save(artifact);
    await platform.entered.future;
    final before = notifications;
    exporter.dispose();
    expect(await File(artifact.path).exists(), isTrue);
    platform.pending!.complete(
      const DocumentExportResult(
        status: DocumentExportStatus.cancelled,
        externalMayBeIncomplete: true,
      ),
    );
    await saving;
    await exporter.shutdown();
    expect(notifications, before);
    expect(await File(artifact.path).exists(), isTrue);
  });

  test(
    'ready export survives restart and rejects stale prepared handles',
    () async {
      final artifact = await prepare();
      expect(
        () => exporter.prepare(
          notebookId: notebookId!,
          notebookName: notebookName,
          capture: capture,
        ),
        throwsStateError,
      );
      await exporter.shutdown();
      exporter = makeExporter();
      await exporter.initialize();
      final recovered = exporter.value.prepared!;
      expect(recovered.path, artifact.path);
      expect(recovered.sha256, artifact.sha256);
      expect(recovered.bytes, artifact.bytes);
      expect(() => exporter.save(artifact), throwsStateError);
      expect(() => exporter.discard(artifact), throwsStateError);
      await exporter.discard(recovered);
      expect(exporter.value.prepared, isNull);
    },
  );

  test('same-size archive corruption is refused before provider and remains discardable', () async {
    final artifact = await prepare();
    final damaged = await File(artifact.path).readAsBytes();
    damaged[0] ^= 0xff;
    await File(artifact.path).writeAsBytes(damaged, flush: true);
    await exporter.save(artifact);
    expect(platform.saves, 0);
    expect(exporter.value.error, contains('corrupt'));
    expect(exporter.value.prepared, same(artifact));
    await exporter.shutdown();
    exporter = makeExporter();
    await exporter.initialize();
    expect(exporter.value.prepared, isNotNull);
    expect(exporter.value.error, contains('corrupt'));
    await exporter.discard(exporter.value.prepared!);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('missing ZIP is still explicitly discardable after restart', () async {
    final artifact = await prepare();
    await File(artifact.path).delete();
    await exporter.shutdown();
    exporter = makeExporter();
    await exporter.initialize();
    expect(exporter.value.prepared, isNotNull);
    expect(exporter.value.error, contains('missing or corrupt'));
    await exporter.save(exporter.value.prepared!);
    expect(platform.saves, 0);
    await exporter.discard(exporter.value.prepared!);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test(
    'privacy preparation failure creates no staging and is redacted',
    () async {
      await exporter.initialize();
      platform.rejectPreparation = true;
      var called = false;
      final result = await exporter.prepare(
        notebookId: syntheticId,
        notebookName: notebookName,
        capture: (destination, budget, cancellation) async {
          called = true;
          return syntheticCapture(destination, budget, cancellation);
        },
      );
      expect(result, isNull);
      expect(called, isFalse);
      expect(exporter.value.error, isNot(contains('private/provider/path')));
      expect(await Directory(root).list().isEmpty, isTrue);
      platform.rejectPreparation = false;
      final artifact = await exporter.prepare(
        notebookId: syntheticId,
        notebookName: notebookName,
        capture: syntheticCapture,
      );
      expect(artifact, isNotNull);
      platform.rejectPreparation = true;
      await exporter.save(artifact!);
      expect(platform.saves, 0);
      expect(exporter.value.prepared, same(artifact));
    },
  );

  test('valid interrupted request is cleaned but unmarked and invalid versions are preserved', () async {
    await Directory(root).create();
    const interruptedId = '11111111111111111111111111111111';
    const invalidId = '22222222222222222222222222222222';
    Map<String, Object> request(String id, int version) => {
      'version': version,
      'id': id,
      'notebookId': syntheticId,
      'notebookName': notebookName,
      'snapshot': 'snapshot',
      'archive': 'notebook.zip',
    };
    for (final (id, version) in [(interruptedId, 1), (invalidId, 2)]) {
      final child = p.join(root, id);
      await Directory(p.join(child, 'snapshot')).create(recursive: true);
      await File(p.join(child, 'snapshot', 'partial.bin'))
          .writeAsBytes([1, 2, 3]);
      await File(p.join(child, 'request.json'))
          .writeAsString(jsonEncode(request(id, version)), flush: true);
    }
    final unmarked = p.join(root, 'crash-before-marker');
    await Directory(unmarked).create();
    await File(p.join(unmarked, 'request.json.tmp')).writeAsString('{');
    await exporter.initialize();
    expect(await Directory(p.join(root, interruptedId)).exists(), isFalse);
    expect(await Directory(p.join(root, invalidId)).exists(), isTrue);
    expect(await Directory(unmarked).exists(), isTrue);
    expect(exporter.value.leftovers.length, 2);
    final stale = exporter.value.leftovers.first;
    await exporter.discardLeftover(stale);
    expect(() => exporter.discardLeftover(stale), throwsStateError);
    await exporter.discardLeftover(exporter.value.leftovers.single);
    expect(exporter.value.leftovers, isEmpty);
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test(
    'unexpected transaction entries are not automatically deleted',
    () async {
      final artifact = await prepare();
      final unknown = File(
        p.join(p.dirname(artifact.path), 'unrecognized.txt'),
      );
      await unknown.writeAsString('not assumed owned');
      await exporter.shutdown();
      exporter = makeExporter();
      await exporter.initialize();
      expect(exporter.value.prepared, isNull);
      expect(exporter.value.leftovers, hasLength(1));
      expect(await unknown.readAsString(), 'not assumed owned');
      await exporter.discardLeftover(exporter.value.leftovers.single);
      expect(await Directory(root).list().isEmpty, isTrue);
    },
  );

  test('multiple ready markers are visible and discarding an extra recovers the remaining ZIP', () async {
    final artifact = await prepare();
    const otherId = '33333333333333333333333333333333';
    final other = p.join(root, otherId);
    await _copyTree(p.dirname(artifact.path), other);
    for (final name in ['request.json', 'ready.json']) {
      await rewriteMarker(
        p.join(other, name),
        (marker) => marker['id'] = otherId,
      );
    }
    await exporter.shutdown();
    exporter = makeExporter();
    await exporter.initialize();
    expect(exporter.value.prepared, isNull);
    expect(exporter.value.leftovers, hasLength(2));
    expect(await File(artifact.path).exists(), isTrue);
    await exporter.discardLeftover(
      exporter.value.leftovers.singleWhere((item) => item.label == otherId),
    );
    expect(exporter.value.leftovers, isEmpty);
    expect(exporter.value.prepared!.sha256, artifact.sha256);
    expect(exporter.value.prepared!.path, artifact.path);
  });

  test('explicit cleanup unlinks direct and nested links without touching external data', () async {
    final outside = p.join(temp.path, 'notebooks', 'outside');
    await Directory(outside).create(recursive: true);
    final sentinel = File(p.join(outside, 'sentinel'));
    await sentinel.writeAsString('not export staging');
    await Directory(root).create();
    final direct = p.join(root, 'external-link');
    final unmarked = p.join(root, 'unmarked');
    await Directory(unmarked).create();
    await _directoryLink(direct, outside);
    await _directoryLink(p.join(unmarked, 'nested'), outside);
    await exporter.initialize();
    expect(exporter.value.leftovers, hasLength(2));
    while (exporter.value.leftovers.isNotEmpty) {
      await exporter.discardLeftover(exporter.value.leftovers.first);
      expect(await sentinel.readAsString(), 'not export staging');
    }
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('linked root is refused before marker reads or cleanup', () async {
    final outside = p.join(temp.path, 'notebooks', 'outside');
    await Directory(outside).create(recursive: true);
    final sentinel = File(p.join(outside, 'sentinel'));
    await sentinel.writeAsString('not export staging');
    await _directoryLink(root, outside);
    try {
      await exporter.initialize();
      expect(exporter.value.error, isNotNull);
      expect(exporter.value.leftovers, isEmpty);
      expect(await sentinel.readAsString(), 'not export staging');
    } finally {
      await Link(root).delete();
    }
  });

  test(
    'ready marker path tampering is preserved as an explicit cleanup item',
    () async {
      final artifact = await prepare();
      final readyMarker = p.join(p.dirname(artifact.path), 'ready.json');
      await rewriteMarker(
        readyMarker,
        (marker) => marker['archive'] = '../../notebooks/book',
      );
      await exporter.shutdown();
      exporter = makeExporter();
      await exporter.initialize();
      expect(exporter.value.prepared, isNull);
      expect(exporter.value.leftovers, hasLength(1));
      expect(await File(artifact.path).exists(), isTrue);
      await exporter.discardLeftover(exporter.value.leftovers.single);
      expect(
        await Directory(p.join(temp.path, 'notebooks', 'book')).exists(),
        isTrue,
      );
    },
  );

  test(
    'actual ZIP output limit is enforced and all handles close on error',
    () async {
      await exporter.initialize();
      final result = await exporter.prepare(
        notebookId: syntheticId,
        notebookName: notebookName,
        capture: (destination, budget, cancellation) async {
          await syntheticCapture(destination, budget, cancellation);
          return const CoreExportSnapshot(
            notebookId: syntheticId,
            notebookName: notebookName,
            bytes: 4,
            files: 1,
            directories: 0,
            archiveLimit: 22,
          );
        },
      );
      expect(result, isNull);
      expect(exporter.value.error, contains('reserved output size'));
      expect(exporter.value.leftovers, isEmpty);
      expect(await Directory(root).list().isEmpty, isTrue);
    },
  );

  test('snapshot summary mismatch refuses silent omissions', () async {
    await exporter.initialize();
    final result = await exporter.prepare(
      notebookId: syntheticId,
      notebookName: notebookName,
      capture: (destination, budget, cancellation) async {
        await syntheticCapture(destination, budget, cancellation);
        return const CoreExportSnapshot(
          notebookId: syntheticId,
          notebookName: notebookName,
          bytes: 4,
          files: 2,
          directories: 0,
          archiveLimit: 8192,
        );
      },
    );
    expect(result, isNull);
    expect(exporter.value.error, contains('size summary'));
    expect(await Directory(root).list().isEmpty, isTrue);
  });

  test('worker refuses backslash components rather than letting encoder normalize them', () async {
    await exporter.initialize();
    final result = await exporter.prepare(
      notebookId: syntheticId,
      notebookName: notebookName,
      capture: (destination, budget, cancellation) async {
        await Directory(destination).create();
        await File(p.join(destination, r'bad\name')).writeAsBytes([1]);
        return const CoreExportSnapshot(
          notebookId: syntheticId,
          notebookName: notebookName,
          bytes: 1,
          files: 1,
          directories: 0,
          archiveLimit: 8192,
        );
      },
    );
    expect(result, isNull);
    expect(exporter.value.error, contains('filename'));
    expect(await Directory(root).list().isEmpty, isTrue);
  }, skip: Platform.isWindows);
}
