// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

Matcher get _failure => isA<CoreException>();

Future<Map<String, Object?>> _runTransfer(
  Map<String, Object?> request, {
  int cancellationAddress = 0,
}) => Isolate.run(
  () => CoreImportStore.runTransfer(
    request,
    cancellationAddress: cancellationAddress,
  ),
);

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final owners = <CoreNotebook>[];
  late String notebookId;
  late String parentId;
  late String nodeId;
  int serial = 0;
  int engine = 0;
  String get notebooks => '${root.path}/notebooks';
  String get notebook => '$notebooks/book';
  String get notePath => '$notebook/Note.md';
  String get assetPath => '$notebook/vx_assets/$nodeId';
  String namespace(String scope) =>
      '${root.path}/${scope == 'cohort' ? 'cohorts' : 'resources'}';
  String transaction(String scope, String id) => '${namespace(scope)}/$id';
  String nextId() => (++serial).toRadixString(16).padLeft(32, '0');

  Future<void> start() async {
    await Directory(notebooks).create(recursive: true);
    await Directory(namespace('cohort')).create();
    await Directory(namespace('resource')).create();
    final core = await CoreNotebook.createCatalog(
      appDataPath: '${root.path}/seed/app',
      localDataPath: '${root.path}/seed/local',
      notebookPath: notebook,
      notebookName: 'Original',
    );
    owners.add(core);
    notebookId = core.initialDirectory.notebookId;
    parentId = core.initialDirectory.folderId;
    nodeId = await core.createNote(parentId, 'Note.md');
    await core.close();
    await File(notePath).writeAsString('# Original\r\n', flush: true);
  }

  Future<CoreNotebook> catalog({bool exporting = false}) async {
    final prefix = '${root.path}/engine-${++engine}';
    final core = exporting
        ? await CoreNotebook.openExportCatalog(
            appDataPath: '$prefix/app',
            localDataPath: '$prefix/local',
            notebookPath: notebook,
            expectedNotebookId: notebookId,
          )
        : await CoreNotebook.openCatalog(
            appDataPath: '$prefix/app',
            localDataPath: '$prefix/local',
            notebookPath: notebook,
            expectedNotebookId: notebookId,
          );
    owners.add(core);
    return core;
  }

  Future<CoreNotebook> resources({bool editor = false}) async {
    final prefix = '${root.path}/engine-${++engine}';
    final core = editor
        ? await CoreNotebook.openNote(
            appDataPath: '$prefix/app',
            localDataPath: '$prefix/local',
            notebookPath: notebook,
            notebookId: notebookId,
            nodeId: nodeId,
          )
        : await CoreNotebook.openResources(
            appDataPath: '$prefix/app',
            localDataPath: '$prefix/local',
            notebookPath: notebook,
            notebookId: notebookId,
            nodeId: nodeId,
          );
    owners.add(core);
    return core;
  }

  Future<Map<String, Object?>> run(
    String scope,
    String id,
    String op, [
    Map<String, Object?> fields = const {},
  ]) {
    final request = <String, Object?>{
      'scope': scope,
      'root': namespace(scope),
      'notebooksRoot': notebooks,
      'id': id,
      'op': op,
      ...fields,
    };
    return _runTransfer(request);
  }

  Future<String> allocate(
    String scope, {
    String kind = 'file',
    String folder = 'Imported',
  }) async {
    final id = nextId();
    await run(scope, id, 'allocate', {
      'kind': kind,
      'target': {
        'version': 1,
        'id': id,
        'notebookId': notebookId,
        'notebookRelative': 'book',
        if (scope == 'cohort') ...{
          'parentId': parentId,
          'folderName': folder,
        } else
          'nodeId': nodeId,
      },
    });
    return id;
  }

  Future<void> source(
    String scope,
    String id,
    Map<String, List<int>> files,
  ) async {
    final root = '${transaction(scope, id)}/unpacked';
    await Directory(root).create(recursive: true);
    for (final item in files.entries) {
      final file = File('$root/${item.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(item.value, flush: true);
    }
    final inventory = <Map<String, Object?>>[];
    var bytes = 0;
    await for (final item in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      final path = item.path.substring(root.length + 1).replaceAll('\\', '/');
      final directory = item is Directory;
      expect(directory || item is File, isTrue);
      final size = directory ? 0 : await File(item.path).length();
      bytes += size;
      inventory.add({
        'path': path,
        'type': directory ? 'directory' : 'file',
        'size': size,
        'sha256': directory
            ? ''
            : (await sha256.bind(File(item.path).openRead()).first).toString(),
      });
    }
    inventory.sort((a, b) {
      final left = utf8.encode(a['path']! as String);
      final right = utf8.encode(b['path']! as String);
      for (var i = 0; i < left.length && i < right.length; ++i) {
        if (left[i] != right[i]) return left[i] - right[i];
      }
      return left.length - right.length;
    });
    final accepted = inventory
        .map((item) => jsonEncode({'path': item['path'], 'type': item['type']}))
        .join('\n');
    await File('${transaction(scope, id)}/accepted.jsonl')
        .writeAsString('$accepted\n', flush: true);
    await run(scope, id, 'capture', {
      'sourceName': 'Selected input',
      'bytes': bytes,
      'entries': inventory.length,
    });
    final encoded = '${inventory.map(jsonEncode).join('\n')}\n';
    await File('${transaction(scope, id)}/inventory.jsonl')
        .writeAsString(encoded, flush: true);
    await run(scope, id, 'source', {
      'treeRelative': 'unpacked',
      'inventoryHash': sha256.convert(utf8.encode(encoded)).toString(),
      'bytes': bytes,
      'entries': inventory.length,
    });
  }

  Future<String> intent(
    String operation,
    String name, {
    String? newName,
    List<int>? bytes,
  }) async {
    final id = await allocate(
      'resource',
      kind: operation == 'image' ? 'image' : 'file',
    );
    if (bytes != null) await source('resource', id, {'provider.bin': bytes});
    await run('resource', id, 'writeResourceIntent', {
      'operation': operation,
      'name': name,
      'newName': newName,
    });
    return id;
  }

  Future<void> dispose() async {
    for (final core in owners) {
      await core.close();
    }
    await root.delete(recursive: true);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture(
      await Directory.systemTemp.createTemp('vnote-transfer-'),
    );
    await fixture.start();
  });
  tearDown(() => fixture.dispose());

  test('resource-only open is metadata-only and never creates lazy asset directories', () async {
    const opaque = [255, 0, 254, 17];
    await File(fixture.notePath).writeAsBytes(opaque, flush: true);
    final core = await fixture.resources();
    final listed = await core.listResources();
    expect(listed.notebookId, fixture.notebookId);
    expect(listed.nodeId, fixture.nodeId);
    expect(listed.notePath, 'Note.md');
    expect(listed.entries, isEmpty);
    expect(await Directory(fixture.assetPath).exists(), isFalse);
    await expectLater(core.read(), throwsA(_failure));
    expect(await File(fixture.notePath).readAsBytes(), opaque);
    await core.close();
    await expectLater(core.listResources(), throwsA(_failure));
  });

  test(
    'resource open rejects protected signature without changing bytes',
    () async {
      final protected = [...ascii.encode('VNOTEE1'), 0, 7, 9, 0];
      await File(fixture.notePath).writeAsBytes(protected, flush: true);
      await expectLater(fixture.resources(), throwsA(_failure));
      expect(await File(fixture.notePath).readAsBytes(), protected);
    },
  );

  test('NOTE owner lists tracked, missing and unindexed bytes without a second owner', () async {
    final metadata = File('${fixture.notebook}/vx_notebook/contents/vx.json');
    final config =
        jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
    final note = (config['files'] as List).cast<Map<String, dynamic>>().single;
    note['attachments'] = ['missing.bin', 'kept.bin'];
    await metadata.writeAsString(jsonEncode(config), flush: true);
    await Directory(fixture.assetPath).create(recursive: true);
    await File('${fixture.assetPath}/kept.bin').writeAsBytes([0, 255]);
    await File('${fixture.assetPath}/opaque.bin').writeAsBytes([17, 0, 99]);
    final core = await fixture.resources(editor: true);
    final before = await core.read();
    final listing = await core.listResources();
    final entries = {for (final entry in listing.entries) entry.name: entry};
    expect(
      entries.keys,
      unorderedEquals(['missing.bin', 'kept.bin', 'opaque.bin']),
    );
    expect(entries['missing.bin']!.tracked, isTrue);
    expect(entries['missing.bin']!.exists, isFalse);
    expect(entries['missing.bin']!.bytes, 0);
    expect(entries['kept.bin']!.tracked, isTrue);
    expect(entries['opaque.bin']!.tracked, isFalse);
    expect(
      entries['opaque.bin']!.relativeUrl,
      'vx_assets/${fixture.nodeId}/opaque.bin',
    );
    await expectLater(fixture.resources(), throwsA(_failure));
    expect((await core.read()).baseHash, before.baseHash);
  });

  test('attachment add and recover are exact once, then track/untrack/rename/remove preserve source', () async {
    const bytes = [0, 255, 17, 0, 33];
    final id = await fixture.intent('add', '附件.bin', bytes: bytes);
    final core = await fixture.resources();
    final transaction = fixture.transaction('resource', id);
    final added = await core.applyResource(transaction);
    expect(added.committed, isTrue);
    expect(added.name, '附件.bin');
    expect((await core.recoverResource(transaction)).committed, isTrue);
    expect(await File('${fixture.assetPath}/附件.bin').readAsBytes(), bytes);
    expect((await core.listResources()).entries.single.tracked, isTrue);
    await fixture.run('resource', id, 'finishResource');
    await fixture.run('resource', id, 'discard');
    for (final operation in ['untrack', 'track', 'rename', 'remove']) {
      final name = operation == 'remove' ? 'renamed.bin' : '附件.bin';
      final next = await fixture.intent(
        operation,
        name,
        newName: operation == 'rename' ? 'renamed.bin' : null,
      );
      final outcome = await core.applyResource(
        fixture.transaction('resource', next),
      );
      expect(outcome.committed, isTrue);
      expect(
        (await core.recoverResource(fixture.transaction('resource', next)))
            .committed,
        isTrue,
      );
      final listing = await core.listResources();
      if (operation == 'remove') {
        expect(listing.entries, isEmpty);
      } else {
        final entry = listing.entries.single;
        expect(entry.name, operation == 'rename' ? 'renamed.bin' : '附件.bin');
        expect(entry.tracked, operation != 'untrack');
        expect(
          await File('${fixture.assetPath}/${entry.name}').readAsBytes(),
          bytes,
        );
      }
      await fixture.run('resource', next, 'finishResource');
      await fixture.run('resource', next, 'discard');
    }
    expect(await File(fixture.notePath).readAsString(), '# Original\r\n');
  });

  test('resource collision retains private source and never accepts a suffixed name', () async {
    const original = [9, 8, 7];
    await Directory(fixture.assetPath).create(recursive: true);
    await File('${fixture.assetPath}/kept.bin').writeAsBytes(original);
    final id = await fixture.intent('add', 'kept.bin', bytes: [1, 2, 3]);
    final core = await fixture.resources();
    await expectLater(
      core.applyResource(fixture.transaction('resource', id)),
      throwsA(_failure),
    );
    expect(await File('${fixture.assetPath}/kept.bin').readAsBytes(), original);
    expect((await core.listResources()).entries.map((entry) => entry.name), [
      'kept.bin',
    ]);
    expect(
      await File('${fixture.transaction('resource', id)}/unpacked/provider.bin')
          .readAsBytes(),
      [1, 2, 3],
    );
  });

  test('export snapshot survives owner close and verify refuses changed private bytes', () async {
    const bytes = [0, 255, 13, 10, 0];
    await Directory(fixture.assetPath).create(recursive: true);
    await File('${fixture.assetPath}/opaque.bin').writeAsBytes(bytes);
    final id = await fixture.intent('export', 'opaque.bin');
    final core = await fixture.resources();
    final snapshot = await core.exportResource(
      'opaque.bin',
      fixture.transaction('resource', id),
    );
    expect(snapshot.bytes, bytes.length);
    expect(snapshot.sha256, sha256.convert(bytes).toString());
    await core.close();
    expect(await File(snapshot.path).readAsBytes(), bytes);
    expect(
      (await fixture.run('resource', id, 'verifyExport'))['sha256'],
      snapshot.sha256,
    );
    await File(snapshot.path).writeAsBytes([1, 2, 3], flush: true);
    await expectLater(
      fixture.run('resource', id, 'verifyExport'),
      throwsA(_failure),
    );
    expect(await File('${fixture.assetPath}/opaque.bin').readAsBytes(), bytes);
  });

  test('cohort private build preserves raw wrapper layout and sealed IDs across apply/recovery', () async {
    final id = await fixture.allocate('cohort', kind: 'folder');
    final files = <String, List<int>>{
      'wrapper/Hello.md': utf8.encode('# Hello\r\n[asset](assets/深い.bin)\r\n'),
      'wrapper/assets/深い.bin': [0, 255, 17, 0, 99],
      '.hidden': [128, 0, 55],
    };
    await fixture.source('cohort', id, files);
    final transaction = fixture.transaction('cohort', id);
    final builder = await CoreNotebook.createCohortBuilder(transaction);
    fixture.owners.add(builder);
    final built = await builder.build();
    expect(built.privateNotebookId, isNot(fixture.notebookId));
    expect(await Directory('${fixture.notebook}/Imported').exists(), isFalse);
    await builder.close();
    await fixture.run('cohort', id, 'sealCohort');
    final core = await fixture.catalog();
    final applied = await core.applyCohort(transaction);
    expect(applied.status, CoreCohortStatus.committed);
    expect(applied.cohortId, built.cohortId);
    expect((await core.recoverCohort(transaction)).cohortId, built.cohortId);
    expect(
      (await core.list()).entries
          .where((entry) => entry.id == built.cohortId)
          .length,
      1,
    );
    for (final file in files.entries) {
      expect(
        await File('${fixture.notebook}/Imported/${file.key}').readAsBytes(),
        file.value,
      );
    }
    expect(await File(fixture.notePath).readAsString(), '# Original\r\n');
    await core.close();
    // Receipt authorizes private cleanup even after legitimate live changes;
    // recovery must never replay old prepared source over an edited cohort.
    await File('${fixture.notebook}/Imported/wrapper/Hello.md')
        .writeAsString('legitimate edit');
    final reopened = await fixture.catalog();
    expect((await reopened.recoverCohort(transaction)).committed, isTrue);
    expect(
      await File('${fixture.notebook}/Imported/wrapper/Hello.md')
          .readAsString(),
      'legitimate edit',
    );
    await fixture.run('cohort', id, 'discard');
    expect(await Directory('${fixture.notebook}/Imported').exists(), isTrue);
  });

  test(
    'missing Markdown sibling refuses before workbook IDs and live publication',
    () async {
      final id = await fixture.allocate('cohort');
      await fixture.source('cohort', id, {
        'only.md': utf8.encode('![missing](missing.png)'),
      });
      final transaction = fixture.transaction('cohort', id);
      await expectLater(
        CoreNotebook.createCohortBuilder(transaction),
        throwsA(_failure),
      );
      expect(await Directory('$transaction/workbook').exists(), isFalse);
      expect(await Directory('${fixture.notebook}/Imported').exists(), isFalse);
      expect(
        await File('$transaction/unpacked/only.md').readAsString(),
        '![missing](missing.png)',
      );
    },
  );

  test(
    'export-only owner never admits cohort apply or resource work',
    () async {
      final core = await fixture.catalog(exporting: true);
      await expectLater(
        core.applyCohort(fixture.transaction('cohort', fixture.nextId())),
        throwsA(_failure),
      );
      await expectLater(core.listResources(), throwsA(_failure));
      expect(await File(fixture.notePath).readAsString(), '# Original\r\n');
    },
  );

  test(
    'moved cohort attempts remain charged before parent publication',
    () async {
      final id = await fixture.allocate('cohort', kind: 'folder');
      await fixture.source('cohort', id, {'note.md': utf8.encode('# input\n')});
      final transaction = fixture.transaction('cohort', id);
      final builder = await CoreNotebook.createCohortBuilder(transaction);
      fixture.owners.add(builder);
      await builder.build();
      await builder.close();
      await fixture.run('cohort', id, 'sealCohort');
      await fixture.run('cohort', id, 'prepareAttempt');
      final intent = jsonDecode(
        await File('$transaction/intent.json').readAsString(),
      ) as Map<String, dynamic>;
      var attemptBytes = 0;
      await for (final entity in Directory(
        '$transaction/attempt',
      ).list(recursive: true, followLinks: false)) {
        if (entity is File) attemptBytes += await entity.length();
      }
      final before = await fixture.run('cohort', id, 'checkSpace', {
        'requiredBytes': 0,
      });
      final moved = '${fixture.notebook}/vx_notebook/vx_import/vnote-$id';
      await Directory(moved).parent.create(recursive: true);
      await Directory('$transaction/attempt').rename(moved);
      final outside = await fixture.run('cohort', id, 'checkSpace', {
        'requiredBytes': 0,
      });
      expect(
        outside['stagedBytes'],
        (before['stagedBytes']! as int) -
            attemptBytes +
            (intent['charge'] as int),
      );
      expect(
        outside['remainingBytes'],
        lessThan(before['remainingBytes']! as int),
      );
      await Directory('$moved/content').rename('${fixture.notebook}/Imported');
      await Directory('$moved/metadata')
          .rename('${fixture.notebook}/vx_notebook/contents/Imported');
      final partial = await fixture.run('cohort', id, 'checkSpace', {
        'requiredBytes': 0,
      });
      expect(partial['stagedBytes'], outside['stagedBytes']);
      await expectLater(
        fixture.run('cohort', id, 'checkSpace', {
          'requiredBytes': (partial['remainingBytes']! as int) + 1,
        }),
        throwsA(_failure),
      );
      await expectLater(
        fixture.run('cohort', id, 'discard'),
        throwsA(_failure),
      );
      expect(
        await File('${fixture.notebook}/Imported/note.md').readAsString(),
        '# input\n',
      );
      await Directory(moved).rename('$moved-original');
      await Directory(moved).create();
      await expectLater(
        fixture.run('cohort', id, 'checkSpace', {'requiredBytes': 0}),
        throwsA(_failure),
      );
    },
  );

  test('controlled suffix outcome is retained across restart without recopy or link success', () async {
    const bytes = [0x89, 0x50, 0x4e, 0x47, 0, 255];
    final id = await fixture.intent('image', 'wanted.png', bytes: bytes);
    final transaction = fixture.transaction('resource', id);
    final core = await fixture.resources();
    expect((await core.applyResource(transaction)).committed, isTrue);
    await core.close();
    // Model interruption after a suffixing core result but before the mobile
    // outcome receipt: retain the real dispatch, source, object identity and bytes.
    await File('$transaction/committed.json').delete();
    await File('$transaction/outcome.json').delete();
    await File('${fixture.assetPath}/wanted.png')
        .rename('${fixture.assetPath}/wanted_1.png');
    final returnedFile = File('$transaction/returned.json');
    final returned =
        jsonDecode(await returnedFile.readAsString()) as Map<String, dynamic>;
    final oldPath = returned['actual'] as String;
    returned['actual'] =
        '${oldPath.substring(0, oldPath.length - 'wanted.png'.length)}wanted_1.png';
    returned['actualName'] = 'wanted_1.png';
    await returnedFile.writeAsString(jsonEncode(returned), flush: true);
    final reopened = await fixture.resources();
    await expectLater(reopened.recoverResource(transaction), throwsA(_failure));
    await expectLater(reopened.applyResource(transaction), throwsA(_failure));
    final entries = (await reopened.listResources()).entries;
    expect(entries.map((entry) => entry.name), ['wanted_1.png']);
    expect(
      await File('${fixture.assetPath}/wanted_1.png').readAsBytes(),
      bytes,
    );
    expect(await File(fixture.notePath).readAsString(), '# Original\r\n');
    await expectLater(
      fixture.run('resource', id, 'discard'),
      throwsA(_failure),
    );
    await fixture.run('resource', id, 'discard', {'abandon': true});
    expect(
      await File('${fixture.assetPath}/wanted_1.png').readAsBytes(),
      bytes,
    );
    expect(await File('${fixture.assetPath}/wanted.png').exists(), isFalse);
  });

  test(
    'closed transfer schemas and cancellation use the shared bounded transport',
    () async {
      await expectLater(
        fixture.run('cohort', fixture.nextId(), 'scan', {'unknown': true}),
        throwsA(_failure),
      );
      expect(
        () => CoreImportStore.runTransfer({'op': 'x' * 16385}),
        throwsA(_failure),
      );
      expect(
        () => CoreImportStore.runTransfer({}, cancellationAddress: -1),
        throwsA(_failure),
      );
      final token = CoreImportStore.createCancellation();
      try {
        CoreImportStore.requestCancellation(token);
        final request = <String, Object?>{
          'scope': 'cohort',
          'root': fixture.namespace('cohort'),
          'notebooksRoot': fixture.notebooks,
          'id': fixture.nextId(),
          'op': 'scan',
        };
        await expectLater(
          _runTransfer(request, cancellationAddress: token),
          throwsA(_failure),
        );
      } finally {
        CoreImportStore.freeCancellation(token);
      }
    },
  );
}
