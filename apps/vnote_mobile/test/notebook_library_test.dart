// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/managed_notebook_storage.dart';
import 'package:vnote_mobile/services/notebook_library.dart';
import 'package:vnote_mobile/services/notebook_workspace.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Owners {
  int active = 0;
  int maximum = 0;
  Completer<void>? closeGate;
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
  Future<void> close() => closing ??= _close();
  Future<void> _close() async {
    final gate = owners.closeGate;
    owners.closeGate = null;
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
  NotebookLibrary makeLibrary({LibraryCreateCatalog? create}) =>
      NotebookLibrary(
        obtainStorage: () async => storage,
        openCatalog: owners.open,
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
