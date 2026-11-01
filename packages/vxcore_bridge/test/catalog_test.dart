// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final hosts = <CoreNotebook>[];
  String? notebookId;
  String path(String relative) =>
      '${root.path}/${relative.replaceAll('/', Platform.pathSeparator)}';
  File file(String relative) => File(path('book/$relative'));

  Future<CoreNotebook> catalog({String? expected}) async {
    final core = await CoreNotebook.openCatalog(
      appDataPath: path('app'),
      localDataPath: path('local'),
      notebookPath: path('book'),
      notebookName: 'Personal',
      expectedNotebookId: expected ?? notebookId,
    );
    hosts.add(core);
    notebookId = core.initialDirectory.notebookId;
    return core;
  }

  Future<CoreNotebook> note(String id) async {
    final core = await CoreNotebook.openNote(
      appDataPath: path('app'),
      localDataPath: path('local'),
      notebookPath: path('book'),
      notebookId: notebookId!,
      nodeId: id,
    );
    hosts.add(core);
    return core;
  }

  Future<void> seed(String id, String text) async {
    final editor = await note(id);
    try {
      final before = await editor.read();
      await editor.write(text, revision: 1, baseHash: before.baseHash);
    } finally {
      await editor.close();
    }
  }

  Future<Map<String, dynamic>> desktop() async {
    var source = File('test/fixtures/desktop_notebook.json');
    if (!await source.exists()) {
      source = File(
        'packages/vxcore_bridge/test/fixtures/desktop_notebook.json',
      );
    }
    final fixture =
        jsonDecode(await source.readAsString()) as Map<String, dynamic>;
    for (final item in fixture['files'] as List<dynamic>) {
      final entry = item as Map<String, dynamic>;
      final relative = entry['path'] as String;
      expect(relative, isNot(startsWith('/')));
      expect(relative.split('/'), isNot(contains('..')));
      final target = file(relative);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        base64Decode(entry['base64'] as String),
        flush: true,
      );
    }
    notebookId = fixture['notebookId'] as String;
    return fixture;
  }

  Future<Map<String, dynamic>> json(String relative) async =>
      jsonDecode(await file(relative).readAsString()) as Map<String, dynamic>;

  Future<void> putJson(String relative, Map<String, dynamic> value) async {
    await file(relative).writeAsString(jsonEncode(value), flush: true);
  }

  Future<Map<String, dynamic>> record(String folder, String id) async {
    final location = folder.isEmpty ? '' : '$folder/';
    final config = await json('vx_notebook/contents/${location}vx.json');
    return (config['files'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['id'] == id);
  }

  Future<void> dispose() async {
    for (final core in hosts) {
      await core.close();
    }
    await root.delete(recursive: true);
  }
}

Matcher get _failure =>
    isA<CoreException>().having((e) => e.code, 'core error', isNot(0));
Matcher _code(int value) =>
    isA<CoreException>().having((e) => e.code, 'core error', value);

Future<void> _directoryLink(String link, String target) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      link.replaceAll('/', '\\'),
      target.replaceAll('/', '\\'),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } else {
    await Link(link).create(target);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture(await Directory.systemTemp.createTemp('vnote-catalog-'));
  });
  tearDown(() => fixture.dispose());

  test(
    'empty startup and nested Unicode CRUD preserve stable identities',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory;
      expect(root.entries, isEmpty);
      expect(root.notebookName, 'Personal');
      expect(root.path, '.');
      expect(root.parentId, isNull);
      expect(await fixture.file('Welcome.md').exists(), isFalse);
      expect(
        () => root.entries.add(
          const CoreEntry(
            id: 'x',
            name: 'x',
            isFolder: false,
            exists: true,
            encrypted: false,
          ),
        ),
        throwsUnsupportedError,
      );
      final folder = await catalog.createFolder(root.folderId, '研究');
      final nested = await catalog.createFolder(folder, '日本語 😀');
      final id = await catalog.createNote(nested, 'مرحبا.md');
      var directory = await catalog.list(nested);
      expect(directory.path, '研究/日本語 😀');
      expect(directory.parentId, folder);
      expect(directory.entries.single.id, id);
      expect(directory.entries.single.exists, isTrue);
      expect(
        directory.entries.single.encrypted,
        isFalse,
      ); // absent metadata marker
      await catalog.rename(id, '新しい.txt');
      await catalog.move(id, root.folderId);
      await catalog.rename(folder, '資料');
      directory = await catalog.list(nested);
      expect(directory.path, '資料/日本語 😀');
      expect(directory.entries, isEmpty);
      expect(
        (await catalog.list()).entries.singleWhere((e) => e.id == id).name,
        '新しい.txt',
      );
      await catalog.close();
      final editor = await fixture.note(id);
      var note = await editor.read();
      expect(note.path, '新しい.txt');
      expect(note.editorType, CoreEditorType.text);
      const source = '\ufeff# literal *text* <tag>\r\n日本語\r\n';
      await editor.write(source, revision: 1, baseHash: note.baseHash);
      note = await editor.read();
      expect(note.text, source);
      await editor.close();
      final restored = await fixture.catalog();
      expect(restored.initialDirectory.notebookId, root.notebookId);
      await restored.delete(id);
      expect(await fixture.file('新しい.txt').exists(), isFalse);
      expect((await restored.list()).entries.any((e) => e.id == id), isFalse);
      await restored.delete(folder);
      expect((await restored.list()).entries, isEmpty);
      // Ordinary core deletion really uses its configured recycler when available.
      final recycled = Directory(fixture.path('book/vx_notebook/recycle_bin'));
      expect(await recycled.exists(), isTrue);
      expect(
        await recycled.list(recursive: true).any((entry) => entry is File),
        isTrue,
      );
    },
  );

  test('desktop-generated note retains UUID, tags, custom metadata and asset bytes', () async {
    final desktop = await fixture.desktop();
    final noteId = desktop['noteId'] as String;
    final folderId = desktop['folderId'] as String;
    final assetPath = desktop['assetPath'] as String;
    final asset = await fixture.file(assetPath).readAsBytes();
    final body = await fixture
        .file(desktop['notePath'] as String)
        .readAsBytes();
    final opaque = await fixture.file('opaque.bin').readAsBytes();
    final before = await fixture.record('研究', noteId);
    final notebookBefore = await fixture.json('vx_notebook/config.json');
    final catalog = await fixture.catalog();
    expect(catalog.initialDirectory.notebookName, 'Desktop fixture');
    expect(
      catalog.initialDirectory.entries
          .singleWhere((e) => e.id == desktop['opaqueId'])
          .exists,
      isTrue,
    );
    expect((await catalog.list(folderId)).entries.single.id, noteId);
    final destination = await catalog.createFolder(
      catalog.initialDirectory.folderId,
      '移動先',
    );
    await catalog.rename(noteId, '改名.md');
    await catalog.move(noteId, destination);
    await catalog.rename(destination, '保存先');
    expect((await catalog.list(destination)).entries.single.id, noteId);
    await catalog.close();
    final after = await fixture.record('保存先', noteId);
    expect(after['id'], before['id']);
    expect(after['tags'], before['tags']);
    expect(after['metadata'], before['metadata']);
    expect(after['attachments'], before['attachments']);
    final assetSuffix = assetPath.substring('研究/'.length);
    expect(await fixture.file('保存先/$assetSuffix').readAsBytes(), asset);
    expect(await fixture.file('保存先/改名.md').readAsBytes(), body);
    expect(await fixture.file('opaque.bin').readAsBytes(), opaque);
    final notebookAfter = await fixture.json('vx_notebook/config.json');
    expect(notebookAfter['metadata'], notebookBefore['metadata']);
    expect(notebookAfter['tags'], notebookBefore['tags']);
    final editor = await fixture.note(noteId);
    final note = await editor.read();
    expect(note.nodeId, noteId);
    expect(note.notebookId, desktop['notebookId']);
    expect(note.path, '保存先/改名.md');
    expect(note.editorType, CoreEditorType.markdown);
    expect(utf8.encode(note.text), body);
  });

  test('legacy sibling names do not prevent another stable ID from opening or mutating', () async {
    final desktop = await fixture.desktop();
    final root = await fixture.json('vx_notebook/contents/vx.json');
    final legacy =
        Map<String, dynamic>.from((root['files'] as List).first as Map)
          ..['id'] = 'legacy-unportable-sibling'
          ..['name'] = 'legacy.';
    (root['files'] as List).add(legacy);
    await fixture.putJson('vx_notebook/contents/vx.json', root);
    final before = await fixture
        .file(desktop['notePath'] as String)
        .readAsBytes();
    final editor = await fixture.note(desktop['noteId'] as String);
    final note = await editor.read();
    expect(note.nodeId, desktop['noteId']);
    expect(utf8.encode(note.text), before);
    await editor.close();
    final catalog = await fixture.catalog();
    expect(
      catalog.initialDirectory.entries
          .singleWhere((entry) => entry.id == legacy['id'])
          .name,
      'legacy.',
    );
    await catalog.rename(desktop['noteId'] as String, 'safe.md');
    expect(
      (await catalog.list(desktop['folderId'] as String)).entries.single.id,
      desktop['noteId'],
    );
    expect(await fixture.file('研究/safe.md').readAsBytes(), before);
    final retained = await fixture.json('vx_notebook/contents/vx.json');
    expect(
      (retained['files'] as List).cast<Map<String, dynamic>>().singleWhere(
        (entry) => entry['id'] == legacy['id'],
      ),
      legacy,
    );
  });

  test(
    'desktop plaintext is literal and opaque content never becomes editable',
    () async {
      final desktop = await fixture.desktop();
      final editor = await fixture.note(desktop['textId'] as String);
      final note = await editor.read();
      expect(note.editorType, CoreEditorType.text);
      expect(note.text, '\ufeff# Not a heading\r\n*literal* <tag>\r\n');
      expect(note.path, 'Plain.txt');
      await editor.close();
      final before = await fixture.file('opaque.bin').readAsBytes();
      await expectLater(
        fixture.note(desktop['opaqueId'] as String),
        throwsA(_code(14)),
      );
      expect(await fixture.file('opaque.bin').readAsBytes(), before);
      final catalog = await fixture.catalog();
      expect(
        catalog.initialDirectory.entries.any(
          (e) => e.id == desktop['opaqueId'],
        ),
        isTrue,
      );
    },
  );

  test(
    'expected notebook and stale node IDs never recreate or substitute nodes',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final id = await catalog.createNote(root, 'keep.md');
      await expectLater(catalog.list('stale-folder'), throwsA(_failure));
      await expectLater(
        catalog.rename('stale-node', 'new.md'),
        throwsA(_failure),
      );
      await expectLater(
        catalog.move(id, 'stale-destination'),
        throwsA(_failure),
      );
      await expectLater(catalog.delete('stale-node'), throwsA(_failure));
      expect((await catalog.list()).entries.single.id, id);
      await catalog.close();
      await expectLater(fixture.note('stale-node'), throwsA(_failure));
      await expectLater(
        fixture.catalog(expected: 'another-notebook'),
        throwsA(_code(18)),
      );
      final original = Directory(fixture.path('book'));
      await original.rename(fixture.path('saved-book'));
      await expectLater(fixture.catalog(), throwsA(_failure));
      await expectLater(fixture.note(id), throwsA(_failure));
      expect(await original.exists(), isFalse);
    },
  );

  test('invalid basenames, collisions, reserved resources and descendant moves fail', () async {
    final catalog = await fixture.catalog();
    final root = catalog.initialDirectory.folderId;
    final folder = await catalog.createFolder(root, 'parent');
    final child = await catalog.createFolder(folder, 'child');
    final id = await catalog.createNote(folder, 'keep.md');
    final peer = await catalog.createNote(child, 'keep.md');
    for (final name in [
      '',
      '.',
      '..',
      '../escape.md',
      'a/b.md',
      'a\\b.md',
      'bad:part.md',
      'bad?.md',
      'bad*.md',
      'bad|.md',
      'bad<.md',
      'bad>.md',
      'bad".md',
      'bad\u0000.md',
      'bad\n.md',
      'bad\u0085.md',
      'trail.md ',
      'trail.md.',
      'CON.md',
      'CON .md',
      'NUL.txt',
      'AUX.md',
      'COM1.md',
      'LPT9.txt',
      'COM¹.md',
      'x' * 256,
    ]) {
      await expectLater(
        catalog.createNote(folder, name),
        throwsA(_failure),
        reason: name,
      );
      await expectLater(
        catalog.rename(id, name),
        throwsA(_failure),
        reason: name,
      );
    }
    await expectLater(catalog.createNote(folder, 'keep.md'), throwsA(_failure));
    await expectLater(catalog.move(id, child), throwsA(_failure));
    await expectLater(catalog.move(folder, child), throwsA(_failure));
    await expectLater(catalog.move(folder, folder), throwsA(_failure));
    await expectLater(catalog.rename(root, 'root'), throwsA(_failure));
    await expectLater(catalog.delete(root), throwsA(_failure));
    for (final reserved in ['vx_assets', 'VX_ASSETS', 'vx_notebook']) {
      await expectLater(
        catalog.createFolder(root, reserved),
        throwsA(_code(14)),
      );
      await expectLater(
        catalog.createFolder(child, reserved),
        throwsA(_code(14)),
      );
    }
    for (final name in ['unknown.bin', 'document.pdf', 'without-suffix']) {
      await expectLater(catalog.createNote(folder, name), throwsA(_code(14)));
    }
    expect(
      (await catalog.list(folder)).entries.where((e) => !e.isFolder).single.id,
      id,
    );
    expect((await catalog.list(child)).entries.single.id, peer);
  });

  test('create verifies physical publication and exposes partial metadata on failure', () async {
    final catalog = await fixture.catalog();
    final folder = await catalog.createFolder(
      catalog.initialDirectory.folderId,
      'restricted',
    );
    final path = fixture
        .path('book/restricted')
        .replaceAll('/', Platform.pathSeparator);
    Future<void> permission(bool deny) async {
      final result = Platform.isWindows
          ? await Process.run('icacls.exe', [
              path,
              deny ? '/deny' : '/remove:d',
              deny ? '*S-1-1-0:(WD)' : '*S-1-1-0',
            ])
          : await Process.run('chmod', [deny ? '500' : '700', path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    await permission(true);
    try {
      await expectLater(
        catalog.createNote(folder, 'partial.md'),
        throwsA(_failure),
      );
      expect(await fixture.file('restricted/partial.md').exists(), isFalse);
    } finally {
      await permission(false);
    }
    final listing = await catalog.list(folder);
    expect(listing.entries.single.name, 'partial.md');
    expect(listing.entries.single.exists, isFalse);
    final phantom = listing.entries.single.id;
    await catalog.close();
    await expectLater(fixture.note(phantom), throwsA(_failure));
    final restored = await fixture.catalog();
    await restored.delete(phantom);
    expect((await restored.list(folder)).entries, isEmpty);
  });

  test(
    'catalog and editor modes are isolated and close drains all admitted work',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      await expectLater(catalog.read(), throwsA(_code(10)));
      await expectLater(
        catalog.write('no', revision: 1, baseHash: '0' * 64),
        throwsA(_code(10)),
      );
      final id = await catalog.createNote(root, 'selected.md');
      await expectLater(fixture.note(id), throwsA(_code(10)));
      await expectLater(fixture.catalog(), throwsA(_code(10)));
      expect((await catalog.list()).entries.single.id, id);
      await catalog.close();
      final editor = await fixture.note(id);
      await expectLater(editor.list(), throwsA(_code(10)));
      await expectLater(editor.delete(id), throwsA(_code(10)));
      await expectLater(
        editor.createNote(root, 'forbidden.md'),
        throwsA(_code(10)),
      );
      await expectLater(fixture.catalog(), throwsA(_code(10)));
      await editor.close();
      final fresh = await fixture.catalog();
      final outcomes = <Future<Object>>[];
      for (var i = 0; i < 80; i++) {
        outcomes.add(
          fresh
              .createFolder(root, 'queued-$i')
              .then<Object>((value) => value, onError: (Object error) => error),
        );
      }
      final closing = fresh.close();
      expect(identical(closing, fresh.close()), isTrue);
      final results = await Future.wait(outcomes);
      await closing;
      expect(results, hasLength(80));
      expect(results.every((e) => e is String || e is CoreException), isTrue);
      await expectLater(fresh.list(), throwsA(_code(10)));
      final restored = await fixture.catalog();
      for (final id in results.whereType<String>()) {
        expect(
          restored.initialDirectory.entries.any((e) => e.id == id),
          isTrue,
        );
      }
      expect(await fixture.file('forbidden.md').exists(), isFalse);
    },
  );

  test('unsafe resource configuration is rejected, not rewritten', () async {
    final catalog = await fixture.catalog();
    final root = catalog.initialDirectory.folderId;
    await catalog.close();
    final original = await fixture.json('vx_notebook/config.json');
    for (final key in ['assetsFolder', 'recycleBinFolder']) {
      for (final value in [
        '../outside',
        '/absolute',
        'folder/../outside',
        'C:\\outside',
      ]) {
        final changed = Map<String, dynamic>.from(original)..[key] = value;
        await fixture.putJson('vx_notebook/config.json', changed);
        final fresh = await fixture.catalog();
        await expectLater(
          fresh.createNote(root, 'unsafe.md'),
          throwsA(_code(14)),
        );
        await fresh.close();
        expect((await fixture.json('vx_notebook/config.json'))[key], value);
        expect(await fixture.file('unsafe.md').exists(), isFalse);
      }
    }
    await fixture.putJson('vx_notebook/config.json', original);
  });

  test(
    'multi-component assets reserve first component in every content directory',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final child = await catalog.createFolder(root, 'child');
      await catalog.close();
      final config = await fixture.json('vx_notebook/config.json');
      config['assetsFolder'] = 'resources/assets';
      config['recycleBinFolder'] = 'recycler/items';
      await fixture.putJson('vx_notebook/config.json', config);
      final fresh = await fixture.catalog();
      await expectLater(
        fresh.createFolder(root, 'resources'),
        throwsA(_code(14)),
      );
      await expectLater(
        fresh.createFolder(child, 'resources'),
        throwsA(_code(14)),
      );
      await expectLater(
        fresh.createFolder(root, 'recycler'),
        throwsA(_code(14)),
      );
      expect(await fresh.createFolder(child, 'recycler'), isNotEmpty);
      expect(await fresh.createNote(child, 'ordinary.md'), isNotEmpty);
    },
  );

  test(
    'linked content, subtrees and configured resources cannot be mutated',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final folder = await catalog.createFolder(root, 'linked');
      final target = Directory(fixture.path('outside'));
      await target.create();
      final sentinel = File('${target.path}/sentinel.txt');
      await sentinel.writeAsString('outside remains untouched');
      await Directory(fixture.path('book/linked')).delete();
      await _directoryLink(fixture.path('book/linked'), target.path);
      await expectLater(catalog.list(folder), throwsA(_code(14)));
      await expectLater(catalog.rename(folder, 'renamed'), throwsA(_code(14)));
      await expectLater(catalog.delete(folder), throwsA(_code(14)));
      await Link(fixture.path('book/linked')).delete();
      await Directory(fixture.path('book/linked')).create();
      await _directoryLink(
        fixture.path('book/linked/hidden-link'),
        target.path,
      );
      await expectLater(catalog.rename(folder, 'renamed'), throwsA(_code(14)));
      await expectLater(catalog.delete(folder), throwsA(_code(14)));
      await Link(fixture.path('book/linked/hidden-link')).delete();
      await _directoryLink(fixture.path('book/linked/vx_assets'), target.path);
      await expectLater(
        catalog.createNote(folder, 'blocked.md'),
        throwsA(_code(14)),
      );
      expect(await sentinel.readAsString(), 'outside remains untouched');
      await Link(fixture.path('book/linked/vx_assets')).delete();
    },
  );

  test(
    'safe unindexed Markdown resources move with the selected note',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final source = await catalog.createFolder(root, 'source');
      final destination = await catalog.createFolder(root, 'destination');
      final id = await catalog.createNote(source, 'note.md');
      await catalog.close();
      await fixture.seed(
        id,
        '![resource](picture.png)\n[web](https://example.invalid/)\n',
      );
      final bytes = [0, 1, 255, 7, 42];
      await fixture.file('source/picture.png').writeAsBytes(bytes, flush: true);
      final fresh = await fixture.catalog();
      await fresh.move(id, destination);
      expect(await fixture.file('source/picture.png').exists(), isFalse);
      expect(
        await fixture.file('destination/picture.png').readAsBytes(),
        bytes,
      );
      expect((await fresh.list(destination)).entries.single.id, id);
      expect((await fresh.list(source)).entries, isEmpty);
    },
  );

  test('implicit resource moves never overwrite destinations or orphan indexed nodes', () async {
    final catalog = await fixture.catalog();
    final root = catalog.initialDirectory.folderId;
    final source = await catalog.createFolder(root, 'source');
    final destination = await catalog.createFolder(root, 'destination');
    final id = await catalog.createNote(source, 'note.md');
    final peer = await catalog.createNote(source, 'indexed.md');
    await catalog.close();
    await fixture.seed(id, '[indexed](indexed.md)\n');
    await fixture.seed(peer, 'independently indexed content');
    var fresh = await fixture.catalog();
    await expectLater(fresh.move(id, destination), throwsA(_failure));
    expect(
      await fixture.file('source/indexed.md').readAsString(),
      'independently indexed content',
    );
    expect(
      (await fresh.list(source)).entries.map((e) => e.id),
      containsAll([id, peer]),
    );
    await fresh.close();
    await fixture.seed(id, '![unindexed](picture.png)\n');
    await fixture
        .file('source/picture.png')
        .writeAsString('source resource', flush: true);
    await fixture
        .file('destination/picture.png')
        .writeAsString('destination must survive', flush: true);
    fresh = await fixture.catalog();
    await expectLater(fresh.move(id, destination), throwsA(_failure));
    expect(
      await fixture.file('source/picture.png').readAsString(),
      'source resource',
    );
    expect(
      await fixture.file('destination/picture.png').readAsString(),
      'destination must survive',
    );
    expect(await fixture.file('source/note.md').exists(), isTrue);
  });

  test('implicit linked and reserved resource targets are rejected before note move', () async {
    final catalog = await fixture.catalog();
    final root = catalog.initialDirectory.folderId;
    final source = await catalog.createFolder(root, 'source');
    final destination = await catalog.createFolder(root, 'destination');
    final id = await catalog.createNote(source, 'note.md');
    await catalog.close();
    final outside = Directory(fixture.path('outside'));
    await outside.create();
    final sentinel = File('${outside.path}/pixel.png');
    await sentinel.writeAsString('outside resource');
    await _directoryLink(fixture.path('book/source/linked'), outside.path);
    await fixture.seed(id, '![link](linked/pixel.png)\n');
    var fresh = await fixture.catalog();
    await expectLater(fresh.move(id, destination), throwsA(_failure));
    expect(await sentinel.readAsString(), 'outside resource');
    await fresh.close();
    await Link(fixture.path('book/source/linked')).delete();
    await fixture.seed(id, '[metadata](vx_notebook/config.json)\n');
    final reserved = fixture.file('source/vx_notebook/config.json');
    await reserved.parent.create(recursive: true);
    await reserved.writeAsString('not an ordinary resource');
    fresh = await fixture.catalog();
    await expectLater(fresh.move(id, destination), throwsA(_failure));
    expect(await reserved.readAsString(), 'not an ordinary resource');
    expect(await fixture.file('source/note.md').exists(), isTrue);
  });

  test('implicit resources reject non-directory destination parents', () async {
    final catalog = await fixture.catalog();
    final root = catalog.initialDirectory.folderId;
    final source = await catalog.createFolder(root, 'source');
    final destination = await catalog.createFolder(root, 'destination');
    final id = await catalog.createNote(source, 'note.md');
    await catalog.close();
    await fixture.seed(id, '![resource](nested/picture.png)\n');
    final resource = fixture.file('source/nested/picture.png');
    await resource.parent.create(recursive: true);
    await resource.writeAsString('source resource');
    await fixture.file('destination/nested').writeAsString('not a directory');
    final fresh = await fixture.catalog();
    await expectLater(fresh.move(id, destination), throwsA(_failure));
    expect(await resource.readAsString(), 'source resource');
    expect(
      await fixture.file('destination/nested').readAsString(),
      'not a directory',
    );
    expect(await fixture.file('source/note.md').exists(), isTrue);
  });

  test(
    'plain text punctuation never triggers Markdown resource movement',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final source = await catalog.createFolder(root, 'source');
      final destination = await catalog.createFolder(root, 'destination');
      final id = await catalog.createNote(source, 'literal.txt');
      final peer = await catalog.createNote(source, 'indexed.md');
      await catalog.close();
      await fixture.seed(id, '[literal](indexed.md)\n');
      await fixture.seed(peer, 'independent');
      final fresh = await fixture.catalog();
      await fresh.move(id, destination);
      expect(
        await fixture.file('source/indexed.md').readAsString(),
        'independent',
      );
      expect((await fresh.list(source)).entries.single.id, peer);
      expect((await fresh.list(destination)).entries.single.id, id);
    },
  );

  test(
    'NUL-truncated, malformed, oversized and drive-relative move sources fail',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final source = await catalog.createFolder(root, 'source');
      final destination = await catalog.createFolder(root, 'destination');
      final id = await catalog.createNote(source, 'note.md');
      await catalog.close();
      for (final bytes in <List<int>>[
        utf8.encode('prefix\u0000[hidden](resource.png)'),
        [0xff, 0xfe, 0x61],
        List.filled(4 * 1024 * 1024 + 1, 120),
        utf8.encode('[drive](C:/outside.png)'),
        utf8.encode('[escape](../../outside.png)'),
      ]) {
        await fixture.file('source/note.md').writeAsBytes(bytes, flush: true);
        final fresh = await fixture.catalog();
        await expectLater(fresh.move(id, destination), throwsA(_failure));
        expect(await fixture.file('source/note.md').readAsBytes(), bytes);
        expect((await fresh.list(destination)).entries, isEmpty);
        await fresh.close();
      }
    },
  );

  test(
    'up-level links retain a shared target or reject a changed existing target',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final source = await catalog.createFolder(root, 'source');
      final nested = await catalog.createFolder(source, 'nested');
      final destination = await catalog.createFolder(root, 'destination');
      final safe = await catalog.createNote(source, 'safe.md');
      final unsafe = await catalog.createNote(nested, 'unsafe.md');
      await catalog.close();
      await fixture.seed(safe, '[shared](../shared.png)\n');
      await fixture.seed(unsafe, '[changed](../shared.png)\n');
      await fixture.file('shared.png').writeAsString('shared root resource');
      await fixture
          .file('source/shared.png')
          .writeAsString('source-relative resource');
      final fresh = await fixture.catalog();
      await fresh.move(safe, destination);
      await expectLater(fresh.move(unsafe, destination), throwsA(_failure));
      expect(
        await fixture.file('shared.png').readAsString(),
        'shared root resource',
      );
      expect(
        await fixture.file('source/shared.png').readAsString(),
        'source-relative resource',
      );
      expect((await fresh.list(destination)).entries.single.id, safe);
      expect((await fresh.list(nested)).entries.single.id, unsafe);
    },
  );

  test(
    'managed asset collisions do not become silently successful note moves',
    () async {
      final desktop = await fixture.desktop();
      final catalog = await fixture.catalog();
      final destination = await catalog.createFolder(
        catalog.initialDirectory.folderId,
        'destination',
      );
      final id = desktop['noteId'] as String;
      final before = await fixture
          .file(desktop['assetPath'] as String)
          .readAsBytes();
      final collision = fixture.file('destination/vx_assets/$id/pixel.png');
      await collision.parent.create(recursive: true);
      await collision.writeAsString('destination resource must survive');
      await expectLater(catalog.move(id, destination), throwsA(_failure));
      expect(
        await fixture.file(desktop['assetPath'] as String).readAsBytes(),
        before,
      );
      expect(
        await collision.readAsString(),
        'destination resource must survive',
      );
      expect(
        await fixture.file(desktop['notePath'] as String).exists(),
        isTrue,
      );
    },
  );

  test(
    'readonly metadata errors remain failures with existing bytes preserved',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      final id = await catalog.createNote(root, 'keep.md');
      final metadata = fixture.file('vx_notebook/contents/vx.json');
      final before = await metadata.readAsBytes();
      final locked = await Process.run('attrib', ['+R', metadata.path]);
      expect(locked.exitCode, 0);
      try {
        await expectLater(catalog.rename(id, 'blocked.md'), throwsA(_failure));
        expect(await metadata.readAsBytes(), before);
      } finally {
        final unlocked = await Process.run('attrib', ['-R', metadata.path]);
        expect(unlocked.exitCode, 0);
      }
      // Core structural errors may be partial; never assert a fictitious rollback.
      await catalog.list();
    },
    skip: !Platform.isWindows,
  );

  test('malformed encrypted metadata fails explicitly rather than an empty listing', () async {
    final desktop = await fixture.desktop();
    final config = await fixture.json('vx_notebook/contents/研究/vx.json');
    final entry =
        (config['files'] as List<dynamic>).single as Map<String, dynamic>;
    (entry['metadata'] as Map<String, dynamic>)['encrypted'] = 'not-a-boolean';
    await fixture.putJson('vx_notebook/contents/研究/vx.json', config);
    try {
      final catalog = await fixture.catalog();
      await expectLater(
        catalog.list(desktop['folderId'] as String),
        throwsA(_failure),
      );
    } on CoreException catch (error) {
      expect(error.code, isNot(0));
    }
  });

  test(
    'encrypted entries remain visible but never install editable source',
    () async {
      final desktop = await fixture.desktop();
      final config = await fixture.json('vx_notebook/contents/研究/vx.json');
      final entry =
          (config['files'] as List<dynamic>).single as Map<String, dynamic>;
      entry['name'] = 'locked.md.vne';
      final metadata = entry['metadata'] as Map<String, dynamic>;
      metadata['encrypted'] = true;
      metadata['editorType'] = 'markdown';
      await fixture
          .file(desktop['notePath'] as String)
          .rename(fixture.file('研究/locked.md.vne').path);
      await fixture.putJson('vx_notebook/contents/研究/vx.json', config);
      final catalog = await fixture.catalog();
      final listing = await catalog.list(desktop['folderId'] as String);
      expect(listing.entries.single.encrypted, isTrue);
      expect(listing.entries.single.exists, isTrue);
      await catalog.close();
      final before = await fixture.file('研究/locked.md.vne').readAsBytes();
      await expectLater(
        fixture.note(desktop['noteId'] as String),
        throwsA(_failure),
      );
      expect(await fixture.file('研究/locked.md.vne').readAsBytes(), before);
    },
  );

  test(
    'oversized selected source is rejected before an editor is installed',
    () async {
      final catalog = await fixture.catalog();
      final id = await catalog.createNote(
        catalog.initialDirectory.folderId,
        'large.md',
      );
      await catalog.close();
      await fixture
          .file('large.md')
          .writeAsString('x' * (4 * 1024 * 1024 + 1), flush: true);
      await expectLater(fixture.note(id), throwsA(_code(14)));
      expect(await fixture.file('large.md').length(), 4 * 1024 * 1024 + 1);
      final restored = await fixture.catalog();
      expect(restored.initialDirectory.entries.single.id, id);
    },
  );

  test(
    'direct-child limit is inclusive and oversized or malformed listings fail',
    () async {
      final catalog = await fixture.catalog();
      final root = catalog.initialDirectory.folderId;
      await catalog.createNote(root, 'template.md');
      await catalog.close();
      final original = await fixture.json('vx_notebook/contents/vx.json');
      final template = Map<String, dynamic>.from(
        (original['files'] as List<dynamic>).single as Map,
      );
      original['files'] = List.generate(
        10000,
        (i) => Map<String, dynamic>.from(template)
          ..['id'] = 'catalog-boundary-$i'
          ..['name'] = 'entry-$i.md',
      );
      await fixture.putJson('vx_notebook/contents/vx.json', original);
      final atLimit = await fixture.catalog();
      expect(
        atLimit.initialDirectory.entries.map((entry) => entry.id).toSet(),
        {for (var i = 0; i < 10000; i++) 'catalog-boundary-$i'},
      );
      await atLimit.close();
      (original['files'] as List).add(
        Map<String, dynamic>.from(template)
          ..['id'] = 'catalog-boundary-10000'
          ..['name'] = 'entry-10000.md',
      );
      await fixture.putJson('vx_notebook/contents/vx.json', original);
      await expectLater(fixture.catalog(), throwsA(_failure));
      original['files'] = [Map<String, dynamic>.from(template)..['id'] = ''];
      await fixture.putJson('vx_notebook/contents/vx.json', original);
      await expectLater(fixture.catalog(), throwsA(_failure));
    },
  );
}
