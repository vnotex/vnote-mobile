// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:vnote_mobile/services/transfer_worker.dart';
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/managed_notebook_storage.dart';

class _PersistentPaths extends PathProviderPlatform {
  _PersistentPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support/';
  @override
  Future<String?> getTemporaryPath() async => '$root/cache/';
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache/';
}

Future<void> _link(String path, String target) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      path.replaceAll('/', r'\'),
      target.replaceAll('/', r'\'),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } else {
    await Link(path).create(target);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _platformBoundaries();
  late Directory temp;
  late ManagedNotebookStorage storage;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vnote-library-storage-');
    storage = ManagedNotebookStorage(
      app: '${temp.path}/app',
      local: '${temp.path}/local',
      root: Directory('${temp.path}/notebooks').absolute.uri.toFilePath(),
    );
    await Directory(storage.root).create();
  });
  tearDown(() async {
    // Remove owned links first, never walk their external targets during cleanup.
    await for (final entity in Directory(
      storage.root,
    ).list(followLinks: false)) {
      if (entity is Link) await entity.delete();
    }
    await temp.delete(recursive: true);
  });

  test('obtained URI roots admit native transfers on creation and populated reopen', () async {
    final directory = await Directory('.dart_tool').create();
    final owned = await directory.createTemp('persistent-root-');
    final previous = PathProviderPlatform.instance;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('vnote.mobile/document_transfer');
    PathProviderPlatform.instance = _PersistentPaths(await owned.resolveSymbolicLinks());
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    try {
      final obtained = await ManagedNotebookStorage.obtain();
      final keep = File('${obtained.root}/untouched.bin');
      await keep.writeAsBytes([0, 255, 17], flush: true);
      Future<Map<String, Object?>> admit(ManagedNotebookStorage value) async => runTransferStore({
        'op': 'checkSpace', 'scope': 'cohort', 'root': await value.obtainCohortRoot(),
        'notebooksRoot': value.root, 'id': '00000000000000000000000000000000', 'requiredBytes': 0,
      });
      expect((await admit(obtained))['stagedBytes'], 0);
      final reopened = await ManagedNotebookStorage.obtain();
      expect((await admit(reopened))['stagedBytes'], 0);
      expect(await FileSystemEntity.identical(obtained.root, reopened.root), isTrue);
      expect(await keep.readAsBytes(), [0, 255, 17]);
    } finally {
      PathProviderPlatform.instance = previous;
      messenger.setMockMethodCallHandler(channel, null);
      await owned.delete(recursive: true);
    }
  });

  test('export staging is a separate persistent sibling and rejects a linked replacement', () async {
    final exportRoot = await storage.obtainExportRoot();
    expect(
      await FileSystemEntity.identical(
        Directory(exportRoot).parent.path,
        Directory(storage.root).parent.path,
      ),
      isTrue,
    );
    expect(await FileSystemEntity.identical(exportRoot, storage.root), isFalse);
    await Directory(exportRoot).delete();
    final outside = await Directory('${temp.path}/outside-export').create();
    await File('${outside.path}/keep.txt').writeAsString('not export staging');
    await _link(exportRoot, outside.path);
    try {
      await expectLater(storage.obtainExportRoot(), throwsStateError);
      expect(
        await File('${outside.path}/keep.txt').readAsString(),
        'not export staging',
      );
    } finally {
      await Link(exportRoot).delete();
    }
  });

  for (final name in ['cohorts', 'resources']) {
    test(
      '$name staging stays private and refuses linked replacement',
      () async {
        final obtain = name == 'cohorts'
            ? storage.obtainCohortRoot
            : storage.obtainResourceRoot;
        final root = await obtain();
        expect(
          await FileSystemEntity.identical(
            Directory(root).parent.path,
            Directory(storage.root).parent.path,
          ),
          isTrue,
        );
        expect(await FileSystemEntity.identical(root, storage.root), isFalse);
        expect(
          Directory(root).uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last,
          name,
        );
        await File('$root/retained.bin').writeAsBytes([0, 255, 0]);
        expect(await obtain(), root);
        expect(await File('$root/retained.bin').readAsBytes(), [0, 255, 0]);
        await Directory(root).delete(recursive: true);
        final outside = await Directory('${temp.path}/outside-$name').create();
        await File('${outside.path}/keep.txt').writeAsString('untouched');
        await _link(root, outside.path);
        try {
          await expectLater(obtain(), throwsStateError);
          expect(
            await File('${outside.path}/keep.txt').readAsString(),
            'untouched',
          );
        } finally {
          await Link(root).delete();
        }
      },
    );
  }

  test(
    'discovery preserves legacy roots and allocation never creates a notebook',
    () async {
      final legacy = await Directory('${storage.root}/Personal').create();
      final marker = File('${legacy.path}/opaque.txt');
      await marker.writeAsString('untouched');
      await File('${storage.root}/loose.txt').writeAsString('not a notebook');
      final candidates = await storage.candidates();
      expect(candidates.single.label, 'Personal');
      expect(candidates.single.error, isNull);
      expect((await storage.existing(legacy.path)).notebook, legacy.path);
      final next = await storage.allocate();
      expect(
        await FileSystemEntity.identical(
          Directory(next.notebook).parent.path,
          storage.root,
        ),
        isTrue,
      );
      expect(
        Directory(next.notebook).uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last,
        matches(RegExp(r'^nb-[0-9a-f]{32}$')),
      );
      expect(
        await FileSystemEntity.type(next.notebook, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await marker.readAsString(), 'untouched');
      expect(
        await File('${storage.root}/loose.txt').readAsString(),
        'not a notebook',
      );
    },
  );

  test(
    'links and escaped children are not accepted as notebook locations',
    () async {
      final outside = await Directory('${temp.path}/outside').create();
      await File('${outside.path}/keep.txt').writeAsString('external');
      final linked = '${storage.root}/linked';
      await _link(linked, outside.path);
      final candidates = await storage.candidates();
      expect(candidates.single.error, isNotNull);
      await expectLater(storage.existing(linked), throwsStateError);
      await expectLater(storage.existing(outside.path), throwsStateError);
      await expectLater(
        storage.existing('${storage.root}/../outside'),
        throwsStateError,
      );
      expect(await File('${outside.path}/keep.txt').readAsString(), 'external');
    },
  );

  test(
    'candidate cap fails rather than publishing an incomplete library',
    () async {
      for (var i = 0; i < ManagedNotebookStorage.maxNotebooks; i++) {
        await Directory('${storage.root}/entry-$i').create();
      }
      final complete = await storage.candidates();
      expect(complete.map((entry) => entry.label).toSet(), {
        for (var i = 0; i < ManagedNotebookStorage.maxNotebooks; i++)
          'entry-$i',
      });
      await Directory('${storage.root}/over-limit').create();
      await expectLater(storage.candidates(), throwsStateError);
    },
  );
}

void _platformBoundaries() {
  group('scoped document provider boundary', () {
    const channel = MethodChannel('vnote.mobile/document_transfer');
    const platform = MethodChannelDocumentTransferPlatform();
    const id = '0123456789abcdef0123456789abcdef';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    late Future<Object?> Function(MethodCall) respond;

    setUp(() {
      calls.clear();
      respond = (_) async => null;
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return respond(call);
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'file and image capture accepts an opaque empty single file',
      () async {
        respond = (_) async => {
          'status': 'ready',
          'sourceName': '空白 asset.bin',
          'bytes': 0,
          'entries': 1,
        };
        for (final (scope, kind) in [
          (DocumentTransferScope.cohort, DocumentImportKind.file),
          (DocumentTransferScope.resource, DocumentImportKind.file),
          (DocumentTransferScope.resource, DocumentImportKind.image),
        ]) {
          final result = await platform.pickImport(
            operationId: id,
            scope: scope,
            kind: kind,
          );
          expect(result.status, DocumentImportStatus.ready);
          expect(result.bytes, 0);
          expect(result.entries, 1);
          expect(calls.last.method, 'pickImport');
          expect(calls.last.arguments, {
            'operationId': id,
            'scope': scope.name,
            'kind': kind.name,
          });
        }
      },
    );

    test(
      'raw provider results enforce file limits, count and portable basename',
      () async {
        for (final reply in <Map<String, Object>>[
          {'sourceName': 'asset.bin', 'bytes': (256 << 20) + 1, 'entries': 1},
          {'sourceName': 'asset.bin', 'bytes': 0, 'entries': 0},
          {'sourceName': 'asset.bin', 'bytes': 0, 'entries': 2},
          {'sourceName': '../escape.bin', 'bytes': 1, 'entries': 1},
          {'sourceName': 'CON.bin', 'bytes': 1, 'entries': 1},
          {'sourceName': '${'界' * 85}.bin', 'bytes': 1, 'entries': 1},
        ]) {
          respond = (_) async => {'status': 'ready', ...reply};
          final result = await platform.pickImport(
            operationId: id,
            scope: DocumentTransferScope.resource,
            kind: DocumentImportKind.file,
          );
          expect(result.status, DocumentImportStatus.failed, reason: '$reply');
          expect(result.sourceName, isNull);
        }
      },
    );

    test('scope kind mismatches never invoke a provider', () async {
      for (final (scope, kind) in [
        (DocumentTransferScope.notebook, DocumentImportKind.file),
        (DocumentTransferScope.notebook, DocumentImportKind.image),
        (DocumentTransferScope.cohort, DocumentImportKind.image),
        (DocumentTransferScope.resource, DocumentImportKind.zip),
        (DocumentTransferScope.resource, DocumentImportKind.folder),
      ]) {
        expect(
          (await platform.pickImport(
            operationId: id,
            scope: scope,
            kind: kind,
          )).status,
          DocumentImportStatus.failed,
        );
      }
      expect(calls, isEmpty);
    });

    test(
      'resource export sends the exact Unicode filename and scope',
      () async {
        respond = (_) async => {
          'status': 'saved',
          'externalMayBeIncomplete': false,
        };
        const name = '圖像 [draft].png';
        const path = '/private/resources/$id/output/$name';
        final result = await platform.save(
          operationId: id,
          scope: DocumentTransferScope.resource,
          path: path,
          suggestedName: name,
        );
        expect(result.status, DocumentExportStatus.saved);
        expect(calls.single.arguments, {
          'operationId': id,
          'scope': 'resource',
          'path': path,
          'suggestedName': name,
        });
        expect(calls.single.method, 'saveExport');
      },
    );

    test(
      'resource output names cannot escape or alias portable components',
      () async {
        for (final name in [
          '../asset',
          'a/b',
          r'a\b',
          'CON.txt',
          'LPT¹.bin',
          'trailing.',
          'trailing ',
          'control\u0000.bin',
          '界' * 86,
          '\ud800',
        ]) {
          final result = await platform.save(
            operationId: id,
            scope: DocumentTransferScope.resource,
            path: '/private/resources/$id/output/asset',
            suggestedName: name,
          );
          expect(result.status, DocumentExportStatus.failed, reason: name);
        }
        expect(
          (await platform.save(
            operationId: id,
            scope: DocumentTransferScope.cohort,
            path: '/private/cohorts/$id/output/asset',
            suggestedName: 'asset',
          )).status,
          DocumentExportStatus.failed,
        );
        expect(calls, isEmpty);
      },
    );

    test('notebook exports retain their ZIP-only name contract', () async {
      respond = (_) async => {
        'status': 'saved',
        'externalMayBeIncomplete': false,
      };
      expect(
        (await platform.save(
          operationId: id,
          scope: DocumentTransferScope.notebook,
          path: '/private/exports/$id/notebook.zip',
          suggestedName: 'vnote-$id.zip',
        )).status,
        DocumentExportStatus.saved,
      );
      expect(calls.single.arguments['scope'], 'notebook');
      expect(
        (await platform.save(
          operationId: id,
          scope: DocumentTransferScope.notebook,
          path: '/private/exports/$id/notebook.zip',
          suggestedName: 'asset.png',
        )).status,
        DocumentExportStatus.failed,
      );
      expect(calls, hasLength(1));
    });

    test(
      'scoped import cancellation acknowledges without releasing the reader',
      () async {
        final entered = Completer<void>();
        final lease = Completer<Object?>();
        respond = (call) async {
          if (call.method == 'pickImport') {
            entered.complete();
            return lease.future;
          }
          return null;
        };
        var settled = false;
        final picking = platform
            .pickImport(
              operationId: id,
              scope: DocumentTransferScope.resource,
              kind: DocumentImportKind.image,
            )
            .then((value) {
              settled = true;
              return value;
            });
        await entered.future;
        await platform.cancelImport(id, scope: DocumentTransferScope.resource);
        expect(calls.last.method, 'cancelImport');
        expect(calls.last.arguments, {'operationId': id, 'scope': 'resource'});
        expect(settled, isFalse);
        lease.complete({
          'status': 'cancelled',
          'sourceName': null,
          'bytes': 0,
          'entries': 0,
        });
        expect((await picking).status, DocumentImportStatus.cancelled);
      },
    );

    test(
      'scoped save cancellation preserves the external-outcome lease',
      () async {
        final entered = Completer<void>();
        final lease = Completer<Object?>();
        respond = (call) async {
          if (call.method == 'saveExport') {
            entered.complete();
            return lease.future;
          }
          return null;
        };
        var settled = false;
        final saving = platform
            .save(
              operationId: id,
              scope: DocumentTransferScope.resource,
              path: '/private/resources/$id/output/data.bin',
              suggestedName: 'data.bin',
            )
            .then((value) {
              settled = true;
              return value;
            });
        await entered.future;
        await platform.cancel(id, scope: DocumentTransferScope.resource);
        expect(calls.last.method, 'cancelExport');
        expect(calls.last.arguments, {'operationId': id, 'scope': 'resource'});
        expect(settled, isFalse);
        lease.complete({
          'status': 'cancelled',
          'externalMayBeIncomplete': true,
        });
        final result = await saving;
        expect(result.status, DocumentExportStatus.cancelled);
        expect(result.externalMayBeIncomplete, isTrue);
      },
    );
  });
}
