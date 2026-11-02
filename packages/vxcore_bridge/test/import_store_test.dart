// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _book = '10000000-0000-4000-8000-000000000001';
const _root = '20000000-0000-4000-8000-000000000002';
const _note = '30000000-0000-4000-8000-000000000003';
const _folder = '40000000-0000-4000-8000-000000000004';
const _nested = '50000000-0000-4000-8000-000000000005';
Matcher get _failure => isA<CoreException>();

final class _StoreFixture {
  _StoreFixture(this.root);
  final Directory root;
  String get imports => '${root.path}/imports';
  String get notebooks => '${root.path}/notebooks';
  String get transaction => '$imports/$_id';
  String get destination => '$notebooks/nb-$_id';
  String treeRelative = 'unpacked';
  String get tree => '$transaction/$treeRelative';
  String? inventoryHash;
  int bytes = 0;
  int entries = 0;
  int inspections = 0;

  Future<Map<String, Object?>> run(
    String op, [
    Map<String, Object?> extra = const {},
    int cancellationAddress = 0,
  ]) async {
    final request = <String, Object?>{
      'op': op,
      'importsRoot': imports,
      'notebooksRoot': notebooks,
      'id': _id,
      ...extra,
    };
    return Isolate.run(
      () => CoreImportStore.run(
        request,
        cancellationAddress: cancellationAddress,
      ),
    );
  }

  Future<void> put(String relative, Object data) async {
    final file = File('$tree/$relative');
    await file.parent.create(recursive: true);
    if (data is List<int>) {
      await file.writeAsBytes(data, flush: true);
    } else {
      await file.writeAsString(
        data is String ? data : jsonEncode(data),
        flush: true,
      );
    }
  }

  Future<Map<String, dynamic>> json(String relative) async =>
      jsonDecode(await File('$tree/$relative').readAsString())
          as Map<String, dynamic>;

  Future<void> start({bool wrapper = false}) async {
    await Directory(transaction).create(recursive: true);
    await Directory(notebooks).create(recursive: true);
    await run('writeMarker', {
      'marker': 'request',
      'data': {'version': 1, 'id': _id, 'kind': 'folder'},
    });
    if (wrapper) treeRelative = 'unpacked/Exported notebook';
    await put('vx_notebook/config.json', {
      'id': _book,
      'name': 'Imported / 研究',
      'assetsFolder': 'vx_assets',
      'recycleBinFolder': 'vx_notebook/recycle_bin',
      'metadata': {
        'opaqueFuture': [1, 'kept'],
      },
      'tags': <Object>[],
      'tagsModifiedUtc': 0,
      'syncEnabled': true,
      'autoSyncEnabled': true,
    });
    await put('vx_notebook/contents/vx.json', {
      'id': _root,
      'name': 'Exported notebook',
      'metadata': <String, Object>{},
      'folders': ['Nested'],
      'files': [
        {
          'id': _note,
          'name': 'Hello.md',
          'metadata': <String, Object>{},
          'attachments': ['opaque.bin'],
        },
      ],
    });
    await put('vx_notebook/contents/Nested/vx.json', {
      'id': _folder,
      'name': 'Nested',
      'metadata': <String, Object>{},
      'folders': <Object>[],
      'files': [
        {'id': _nested, 'name': 'nested.md', 'metadata': <String, Object>{}},
      ],
    });
    await put('Hello.md', '# Preserved\r\n');
    await put('Nested/nested.md', 'nested bytes\n');
    await put('vx_assets/$_note/opaque.bin', [0, 255, 17, 0, 33]);
    await put('vx_notebook/recycle_bin/opaque.dat', [128, 0, 99]);
    await put('future/opaque.unknown', [44, 0, 55]);
  }

  Future<void> prepare({String Function(String)? inventoryTransform}) async {
    final unpacked = '$transaction/unpacked';
    final physical = await Directory(unpacked)
        .list(recursive: true, followLinks: false)
        .toList();
    final records = <Map<String, Object?>>[];
    for (final entity in physical) {
      final path = entity.path
          .substring(unpacked.length + 1)
          .replaceAll('\\', '/');
      final directory = entity is Directory;
      expect(entity is Directory || entity is File, isTrue);
      final size = directory ? 0 : await File(entity.path).length();
      final hash = directory
          ? ''
          : (await sha256.bind(File(entity.path).openRead()).first).toString();
      records.add({
        'path': path,
        'type': directory ? 'directory' : 'file',
        'size': size,
        'sha256': hash,
      });
      bytes += size;
    }
    records.sort((a, b) {
      final left = utf8.encode(a['path']! as String);
      final right = utf8.encode(b['path']! as String);
      for (var i = 0; i < left.length && i < right.length; i++) {
        final difference = left[i] - right[i];
        if (difference != 0) return difference;
      }
      return left.length - right.length;
    });
    entries = records.length;
    await run('writeMarker', {
      'marker': 'captured',
      'data': {
        'version': 1,
        'id': _id,
        'kind': 'folder',
        'sourceName': 'original',
        'bytes': bytes,
        'entries': entries,
      },
    });
    final original = '${records.map(jsonEncode).join('\n')}\n';
    final raw = inventoryTransform == null
        ? original
        : inventoryTransform(original);
    await File('$transaction/inventory.jsonl').writeAsString(raw, flush: true);
    inventoryHash = sha256.convert(utf8.encode(raw)).toString();
    await run('writeMarker', {
      'marker': 'prepared',
      'data': {
        'version': 1,
        'id': _id,
        'kind': 'folder',
        'treeRelative': treeRelative,
        'inventoryHash': inventoryHash,
        'bytes': bytes,
        'entries': entries,
      },
    });
  }

  Map<String, Object?> get prepared => {
    'treeRelative': treeRelative,
    'inventoryHash': inventoryHash,
  };
  Future<Map<String, Object?>> inspect() => run('inspect', prepared);
  Future<Map<String, Object?>> publish() => run('publish', {
    ...prepared,
    'notebookId': _book,
    'notebookName': 'Imported / 研究',
  });
  Future<void> guard(String location) async {
    final inspection = '$transaction/inspection/${++inspections}';
    final core = await CoreNotebook.openExportCatalog(
      appDataPath: '$inspection/app',
      localDataPath: '$inspection/local',
      notebookPath: location,
      expectedNotebookId: _book,
    );
    try {
      expect(
        await core.collectNodeIds(),
        unorderedEquals([_root, _note, _folder, _nested]),
      );
    } finally {
      await core.close();
    }
  }
}

void main() {
  late _StoreFixture fixture;
  setUp(
    () async => fixture = _StoreFixture(
      await Directory.systemTemp.createTemp('vnote-import-store-'),
    ),
  );
  tearDown(() async {
    if (await fixture.root.exists()) await fixture.root.delete(recursive: true);
  });

  test('pure keys use full Unicode folding and both canonical forms', () {
    final composed = CoreImportStore.pathKeys('Straße/É/Σ/\u{10400}');
    final decomposed = CoreImportStore.pathKeys('STRASSE/E\u0301/ς/\u{10428}');
    expect(composed, decomposed);
    expect(composed.nfc, 'strasse/é/σ/\u{10428}');
    expect(composed.nfd, 'strasse/e\u0301/σ/\u{10428}');
    expect(CoreImportStore.pathKeys(''), (nfc: '', nfd: ''));
    for (final invalid in ['\u0000', '\ud800', '\udc00', 'a' * 1025]) {
      expect(() => CoreImportStore.pathKeys(invalid), throwsA(_failure));
    }
  });

  test(
    'bounded cancellation is shared with a worker, never a core context',
    () async {
      await fixture.start();
      final address = CoreImportStore.createCancellation();
      try {
        expect(CoreImportStore.queryCancellation(address), isFalse);
        CoreImportStore.requestCancellation(address);
        expect(
          await Isolate.run(() => CoreImportStore.queryCancellation(address)),
          isTrue,
        );
        await expectLater(
          fixture.run('recover', const {}, address),
          throwsA(_failure),
        );
        expect((await fixture.run('recover'))['phase'], 'staged');
      } finally {
        CoreImportStore.freeCancellation(address);
      }
    },
  );

  test(
    'request-only state and idempotent marker reject changed binding',
    () async {
      await fixture.start();
      final state = await fixture.run('recover');
      expect(state['phase'], 'staged');
      expect(state['captured'], false);
      expect(state['prepared'], false);
      expect(state['destination'], isNull);
      await expectLater(
        fixture.run('writeMarker', {
          'marker': 'request',
          'data': {'version': 1, 'id': _id, 'kind': 'zip'},
        }),
        throwsA(_failure),
      );
      await expectLater(
        fixture.run('recover', {'unexpected': true}),
        throwsA(_failure),
      );
      await expectLater(
        fixture.run('checkSpace', {'requiredBytes': 4 * 1024 * 1024 * 1024}),
        throwsA(_failure),
      );
      expect(
        (await fixture.run('checkSpace', {
          'requiredBytes': 0,
        }))['availableBytes'],
        isA<int>(),
      );
    },
  );

  for (final wrapper in [false, true]) {
    test(
      'strict import preserves opaque bytes and IDs, wrapper=$wrapper',
      () async {
        await fixture.start(wrapper: wrapper);
        await fixture.prepare();
        final originalConfig = await File(
          '${fixture.tree}/vx_notebook/config.json',
        ).readAsBytes();
        final inspected = await fixture.inspect();
        expect(inspected['notebookId'], _book);
        expect(
          inspected['nodeIds'],
          unorderedEquals([_root, _note, _folder, _nested]),
        );
        await fixture.guard(fixture.tree);
        final published = await fixture.publish();
        expect(published['phase'], 'published');
        expect(
          (published['destination']! as String).replaceAll('\\', '/'),
          fixture.destination.replaceAll('\\', '/'),
        );
        expect(await Directory(fixture.tree).exists(), isFalse);
        expect(
          await File('${fixture.destination}/vx_notebook/config.json')
              .readAsBytes(),
          originalConfig,
        );
        expect(
          await File('${fixture.destination}/vx_assets/$_note/opaque.bin')
              .readAsBytes(),
          [0, 255, 17, 0, 33],
        );
        expect(
          await File('${fixture.destination}/future/opaque.unknown')
              .readAsBytes(),
          [44, 0, 55],
        );
        expect((await fixture.run('recover'))['phase'], 'published');
        await expectLater(fixture.run('discard'), throwsA(_failure));
        await fixture.guard(fixture.destination);
        final cancelled = CoreImportStore.createCancellation();
        CoreImportStore.requestCancellation(cancelled);
        try {
          expect(
            (await fixture.run('commit', const {}, cancelled))['phase'],
            'committed',
          );
        } finally {
          CoreImportStore.freeCancellation(cancelled);
        }
        await File('${fixture.destination}/Hello.md')
            .writeAsString('legitimate later edit', flush: true);
        expect((await fixture.run('recover'))['phase'], 'committed');
        expect((await fixture.run('discard'))['discarded'], true);
        expect(await Directory(fixture.transaction).exists(), false);
        expect(
          await File('${fixture.destination}/Hello.md').readAsString(),
          'legitimate later edit',
        );
      },
    );
  }

  for (final defect in [
    'missing-metadata',
    'duplicate-id',
    'empty-id',
    'unsafe-child',
    'wrong-name',
    'orphan',
    'missing-body',
    'credentials',
    'recovery',
    'sync-runtime',
    'asset-escape',
    'attachment-escape',
    'duplicate-json-key',
  ]) {
    test('strict inspection refuses $defect before core open', () async {
      await fixture.start();
      final root = await fixture.json('vx_notebook/contents/vx.json');
      final config = await fixture.json('vx_notebook/config.json');
      switch (defect) {
        case 'missing-metadata':
          await File('${fixture.tree}/vx_notebook/contents/Nested/vx.json')
              .delete();
        case 'duplicate-id':
          (root['files'] as List).first['id'] = _root;
          await fixture.put('vx_notebook/contents/vx.json', root);
        case 'empty-id':
          (root['files'] as List).first['id'] = '';
          await fixture.put('vx_notebook/contents/vx.json', root);
        case 'unsafe-child':
          root['folders'] = ['../escape'];
          await fixture.put('vx_notebook/contents/vx.json', root);
        case 'wrong-name':
          final child = await fixture.json(
            'vx_notebook/contents/Nested/vx.json',
          );
          child['name'] = 'Different';
          await fixture.put('vx_notebook/contents/Nested/vx.json', child);
        case 'orphan':
          await fixture.put('vx_notebook/contents/Orphan/vx.json', {
            'id': 'unreachable',
            'name': 'Orphan',
            'files': <Object>[],
            'folders': <Object>[],
          });
        case 'missing-body':
          await File('${fixture.tree}/Hello.md').delete();
        case 'credentials':
          config['metadata'] = {'password': 'secret must never reach error'};
          await fixture.put('vx_notebook/config.json', config);
        case 'recovery':
          await fixture.put(
            'vx_notebook/vx_transfer/pending/journal.json',
            '{}',
          );
        case 'sync-runtime':
          await fixture.put('vx_notebook/vx_sync/state.json', '{}');
        case 'asset-escape':
          config['assetsFolder'] = '../outside';
          await fixture.put('vx_notebook/config.json', config);
        case 'attachment-escape':
          (root['files'] as List).first['attachments'] = ['../secret'];
          await fixture.put('vx_notebook/contents/vx.json', root);
        case 'duplicate-json-key':
          await fixture.put(
            'vx_notebook/config.json',
            '{"id":"$_book","id":"other","name":"ambiguous"}',
          );
      }
      await fixture.prepare();
      await expectLater(fixture.inspect(), throwsA(_failure));
      expect(await Directory(fixture.destination).exists(), false);
      expect((await fixture.run('recover'))['phase'], 'staged');
    });
  }

  test(
    'managed strict walk permits missing bodies, never missing metadata',
    () async {
      await fixture.start();
      await fixture.prepare();
      await fixture.publish();
      await File('${fixture.destination}/Hello.md').delete();
      final inspected = await fixture.run('inspectManaged', {
        'location': fixture.destination,
      });
      expect(
        inspected['nodeIds'],
        unorderedEquals([_root, _note, _folder, _nested]),
      );
      final body = await File('${fixture.destination}/Hello.md')
          .open(mode: FileMode.write);
      try {
        await body.truncate(300 * 1024 * 1024);
      } finally {
        await body.close();
      }
      expect(
        (await fixture.run('inspectManaged', {
          'location': fixture.destination,
        }))['nodeIds'],
        inspected['nodeIds'],
      );
      await expectLater(
        fixture.run('inspectManaged', {
          'location': fixture.destination,
          'expectedNotebookId': 'other',
        }),
        throwsA(_failure),
      );
      await File('${fixture.destination}/vx_notebook/contents/Nested/vx.json')
          .delete();
      await expectLater(
        fixture.run('inspectManaged', {
          'location': fixture.destination,
          'expectedNotebookId': _book,
        }),
        throwsA(_failure),
      );
    },
  );

  for (final defect in [
    'changed-file',
    'extra-file',
    'missing-file',
    'inventory-change',
  ]) {
    test(
      'streamed inventory catches $defect immediately before publish',
      () async {
        await fixture.start();
        await fixture.prepare();
        if (defect == 'changed-file')
          await fixture.put('Hello.md', 'different');
        if (defect == 'extra-file') await fixture.put('unlisted.dat', [7]);
        if (defect == 'missing-file')
          await File('${fixture.tree}/Hello.md').delete();
        if (defect == 'inventory-change')
          await File('${fixture.transaction}/inventory.jsonl')
              .writeAsString('\n', mode: FileMode.append);
        await expectLater(fixture.publish(), throwsA(_failure));
        expect(await Directory(fixture.destination).exists(), false);
        expect(
          await File('${fixture.transaction}/publication.json').exists(),
          false,
        );
      },
    );
  }

  test('intent is not phase: same staging identity retries exactly the fixed target', () async {
    await fixture.start(wrapper: true);
    await fixture.prepare();
    await fixture.publish();
    await Directory(fixture.destination).rename(fixture.tree);
    final staged = await fixture.run('recover');
    expect(staged['phase'], 'staged');
    expect(
      (staged['destination']! as String).replaceAll('\\', '/'),
      fixture.destination.replaceAll('\\', '/'),
    );
    expect((await fixture.publish())['phase'], 'published');
    expect(
      (await fixture.run('discard', {'allowPublished': true}))['discarded'],
      true,
    );
    expect(await Directory(fixture.destination).exists(), false);
  });

  for (final defect in [
    'both-present',
    'both-absent',
    'foreign-target',
    'foreign-stage',
  ]) {
    test(
      'identity truth table refuses $defect without deleting anything',
      () async {
        await fixture.start();
        await fixture.prepare();
        await fixture.publish();
        if (defect == 'both-present') {
          await Directory(fixture.tree).create(recursive: true);
          await File('${fixture.tree}/foreign').writeAsString('untouched');
        } else {
          await Directory(fixture.destination)
              .rename('${fixture.root.path}/saved-original');
          if (defect == 'foreign-target') {
            await Directory(fixture.destination).create();
            await File('${fixture.destination}/foreign')
                .writeAsString('untouched');
          }
          if (defect == 'foreign-stage') {
            await Directory(fixture.tree).create(recursive: true);
            await File('${fixture.tree}/foreign').writeAsString('untouched');
          }
        }
        await expectLater(fixture.run('recover'), throwsA(_failure));
        await expectLater(
          fixture.run('discard', {'allowPublished': true}),
          throwsA(_failure),
        );
        expect(
          await File('${fixture.transaction}/publication.json').exists(),
          true,
        );
        if (defect == 'foreign-target')
          expect(
            await File('${fixture.destination}/foreign').readAsString(),
            'untouched',
          );
        if (defect == 'both-present')
          expect(
            await File('${fixture.tree}/foreign').readAsString(),
            'untouched',
          );
      },
    );
  }

  test('missing committed root never replays input and only private cleanup is allowed', () async {
    await fixture.start();
    await fixture.prepare();
    await fixture.publish();
    await fixture.guard(fixture.destination);
    await fixture.run('commit');
    await Directory(fixture.destination)
        .rename('${fixture.root.path}/legitimately-moved');
    await expectLater(fixture.run('recover'), throwsA(_failure));
    await expectLater(fixture.publish(), throwsA(_failure));
    expect((await fixture.run('discard'))['discarded'], true);
    expect(
      await Directory('${fixture.root.path}/legitimately-moved').exists(),
      true,
    );
    expect(await Directory(fixture.destination).exists(), false);
  });

  test('preexisting destination is never replaced and cancellation publishes nothing', () async {
    await fixture.start();
    await fixture.prepare();
    await Directory(fixture.destination).create();
    await File('${fixture.destination}/foreign').writeAsString('original');
    await expectLater(fixture.publish(), throwsA(_failure));
    expect(
      await File('${fixture.destination}/foreign').readAsString(),
      'original',
    );
    await Directory(fixture.destination).delete(recursive: true);
    final token = CoreImportStore.createCancellation();
    CoreImportStore.requestCancellation(token);
    try {
      await expectLater(
        fixture.run('publish', {
          ...fixture.prepared,
          'notebookId': _book,
          'notebookName': 'Imported / 研究',
        }, token),
        throwsA(_failure),
      );
    } finally {
      CoreImportStore.freeCancellation(token);
    }
    expect(await Directory(fixture.tree).exists(), true);
    expect(await Directory(fixture.destination).exists(), false);
    expect((await fixture.run('recover'))['phase'], 'staged');
  });

  for (final defect in [
    'duplicate',
    'unsorted',
    'unsafe-path',
    'wrong-type',
    'missing-parent',
    'oversized-line',
    'unterminated',
  ]) {
    test(
      'bounded inventory records reject $defect before preparation',
      () async {
        await fixture.start();
        await expectLater(
          fixture.prepare(
            inventoryTransform: (raw) {
              final lines = raw.trimRight().split('\n');
              if (defect == 'duplicate') return '${lines.first}\n$raw';
              if (defect == 'unsorted') return '${lines.reversed.join('\n')}\n';
              if (defect == 'missing-parent') {
                final index = lines.indexWhere(
                  (line) => (jsonDecode(line) as Map)['type'] == 'directory',
                );
                lines.removeAt(index);
                return '${lines.join('\n')}\n';
              }
              if (defect == 'oversized-line') return '${' ' * 8193}$raw';
              if (defect == 'unterminated')
                return raw.substring(0, raw.length - 1);
              final record = jsonDecode(lines.first) as Map<String, dynamic>;
              if (defect == 'unsafe-path') record['path'] = '../escape';
              if (defect == 'wrong-type') record['type'] = 'symlink';
              lines[0] = jsonEncode(record);
              return '${lines.join('\n')}\n';
            },
          ),
          throwsA(_failure),
        );
        expect(
          await File('${fixture.transaction}/prepared.json').exists(),
          false,
        );
        expect(await Directory(fixture.destination).exists(), false);
      },
    );
  }

  test(
    'physical aliases cannot satisfy a differently spelled metadata edge',
    () async {
      await fixture.start();
      final root = await fixture.json('vx_notebook/contents/vx.json');
      (root['files'] as List).first['name'] = 'hello.md';
      await fixture.put('vx_notebook/contents/vx.json', root);
      await fixture.prepare();
      await expectLater(fixture.inspect(), throwsA(_failure));
    },
  );

  test(
    'excessive metadata nesting fails before a core owner is created',
    () async {
      await fixture.start();
      final config = await fixture.json('vx_notebook/config.json');
      Object nested = 'value';
      for (var i = 0; i < 40; i++) nested = {'next': nested};
      config['future'] = nested;
      await fixture.put('vx_notebook/config.json', config);
      await fixture.prepare();
      await expectLater(fixture.inspect(), throwsA(_failure));
    },
  );

  test('malformed receipt cannot authorize deleting a live root', () async {
    await fixture.start();
    await fixture.prepare();
    await fixture.publish();
    await File('${fixture.transaction}/committed.json')
        .writeAsString('{"version":2}', flush: true);
    await expectLater(fixture.run('recover'), throwsA(_failure));
    await expectLater(
      fixture.run('discard', {'allowPublished': true}),
      throwsA(_failure),
    );
    expect(
      await File('${fixture.destination}/Hello.md').readAsString(),
      '# Preserved\r\n',
    );
  });

  test('capacity preflight rejects hardlinks before any parser opens provider bytes', () async {
    await fixture.start();
    final source = '${fixture.tree}/Hello.md';
    final target = '${fixture.tree}/hardlink.md';
    final result = Platform.isWindows
        ? await Process.run('cmd', [
            '/c',
            'mklink',
            '/H',
            target.replaceAll('/', '\\'),
            source.replaceAll('/', '\\'),
          ])
        : await Process.run('ln', [source, target]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    await expectLater(
      fixture.run('checkSpace', {'requiredBytes': 0}),
      throwsA(_failure),
    );
  });
}
