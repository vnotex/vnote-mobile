// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/features/library/notebook_browser.dart';
import 'package:vnote_mobile/services/notebook_session.dart';
import 'package:vnote_mobile/services/notebook_workspace.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

// Reuse the existing protocol driver, not a second editor implementation.
import 'notebook_session_test.dart'
    as protocol
    show ControlledCore, answer, insert, ready, reply, turn;

const _note = CoreEntry(
  id: 'note-id',
  name: '研究.md',
  isFolder: false,
  exists: true,
  encrypted: false,
);
const _folder = CoreEntry(
  id: 'folder-id',
  name: 'Research',
  isFolder: true,
  exists: true,
  encrypted: false,
);

CoreDirectory _directory({
  String id = 'root-id',
  String path = '.',
  String? parentId,
  List<CoreEntry> entries = const [_folder, _note],
}) => CoreDirectory(
  notebookId: 'book-identity',
  notebookName: 'Personal',
  folderId: id,
  path: path,
  parentId: parentId,
  entries: entries,
);

CoreSearchResult _searchResult({
  String notebookId = 'book-identity',
  List<CoreSearchHit> matches = const [
    CoreSearchHit(
      id: 'nested-note',
      path: 'Research/旧名.md',
      line: 7,
      snippet: 'Saved needle 😀',
    ),
  ],
  bool limited = false,
  int skipped = 0,
}) => CoreSearchResult(
  notebookId: notebookId,
  matches: matches,
  limited: limited,
  skipped: skipped,
);

CoreTags _tagSnapshot({
  List<CoreTag> tags = const [
    CoreTag(name: 'Topics', parent: ''),
    CoreTag(name: 'Research', parent: 'Topics'),
  ],
  List<String> assigned = const ['orphan'],
}) => CoreTags(notebookId: 'book-identity', tags: tags, assigned: assigned);

// These presentation doubles control completion order only. Persistence and
// stable IDs are exercised through the real native factories below.
class _Owners {
  int active = 0;
  int maximum = 0;

  void acquire() {
    expect(active, 0, reason: 'A new native owner must follow the old join.');
    active++;
    if (active > maximum) maximum = active;
  }

  void release() => active--;
}

class _Catalog implements CatalogCore {
  _Catalog(this.owners, this.initialDirectory) {
    owners.acquire();
  }

  final _Owners owners;
  @override
  final CoreDirectory initialDirectory;
  final lists = <String?>[];
  final changes = <List<String>>[];
  Future<CoreDirectory> Function(String?)? onList;
  Future<String> Function()? onMutation;
  final searches = <(String, String?, bool)>[];
  final tagQueries = <String?>[];
  final tagChanges = <List<String>>[];
  Future<CoreSearchResult> Function(String, String?, bool)? onSearch;
  Future<CoreTags> Function(String?)? onTags;
  Future<void> Function()? onTagMutation;
  int searchCancellations = 0;
  Completer<void>? closeGate;
  int closes = 0;
  Future<void>? _closing;

  @override
  String get nativeNotices => 'Catalog notices';

  @override
  Future<CoreDirectory> list([String? folderId]) async {
    lists.add(folderId);
    return onList == null ? initialDirectory : await onList!(folderId);
  }

  @override
  Future<CoreSearchResult> search(
    String text, {
    String? tag,
    bool caseSensitive = false,
  }) async {
    searches.add((text, tag, caseSensitive));
    return onSearch == null
        ? _searchResult()
        : await onSearch!(text, tag, caseSensitive);
  }

  @override
  void cancelSearch() => searchCancellations++;

  @override
  Future<CoreTags> tags([String? nodeId]) async {
    tagQueries.add(nodeId);
    return onTags == null ? _tagSnapshot() : await onTags!(nodeId);
  }

  @override
  Future<void> createTag(String name) async {
    tagChanges.add(['createTag', name]);
    await onTagMutation?.call();
  }

  @override
  Future<void> setTags(String nodeId, List<String> tags) async {
    tagChanges.add(['setTags', nodeId, ...tags]);
    await onTagMutation?.call();
  }

  Future<String> _change(List<String> arguments) async {
    changes.add(arguments);
    return onMutation == null ? 'new-node' : await onMutation!();
  }

  @override
  Future<String> createNote(String folderId, String name) =>
      _change(['note', folderId, name]);
  @override
  Future<String> createFolder(String folderId, String name) =>
      _change(['folder', folderId, name]);
  @override
  Future<void> rename(String nodeId, String name) async {
    await _change(['rename', nodeId, name]);
  }

  @override
  Future<void> move(String nodeId, String destinationFolderId) async {
    await _change(['move', nodeId, destinationFolderId]);
  }

  @override
  Future<void> delete(String nodeId) async {
    await _change(['delete', nodeId]);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    closes++;
    await closeGate?.future;
    owners.release();
  }
}

class _Note implements NotebookCore {
  _Note(this.owners) {
    owners.acquire();
  }
  final _Owners owners;
  final core = protocol.ControlledCore();
  Future<void>? _closing;

  @override
  String get nativeNotices => core.nativeNotices;
  @override
  Future<CoreNote> read() => core.read();
  @override
  Future<CoreWriteResult> write(
    String text, {
    required int revision,
    required String baseHash,
  }) => core.write(text, revision: revision, baseHash: baseHash);
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await core.close();
    owners.release();
  }
}

class _Harness {
  _Harness({bool widgetTest = false}) {
    workspace = NotebookWorkspace(
      obtainPaths: () async => const ManagedNotebookPaths(
        app: 'app',
        local: 'local',
        notebook: 'notebook',
      ),
      openCatalog: (paths, expected) async {
        expectedIds.add(expected);
        if (catalogFactory != null) return catalogFactory!(expected);
        final catalog = _Catalog(owners, _directory());
        catalogs.add(catalog);
        return catalog;
      },
      openNote: (paths, notebookId, nodeId) async {
        noteIds.add([notebookId, nodeId]);
        if (noteFactory != null) return noteFactory!();
        final note = _Note(owners);
        notes.add(note);
        return note;
      },
    );
    void verifyCleanup() {
      workspace.dispose();
      expect(owners.active, 0);
      expect(owners.maximum, lessThanOrEqualTo(1));
    }

    if (widgetTest) {
      // A completed future from the fake clock must not be awaited later from
      // the outer runner's teardown zone. Widget bodies await shutdown first.
      addTearDown(() {
        expect(workspace.value.closed, isTrue);
        verifyCleanup();
      });
    } else {
      addTearDown(() async {
        await workspace.shutdown();
        verifyCleanup();
      });
    }
  }

  final owners = _Owners();
  final catalogs = <_Catalog>[];
  final notes = <_Note>[];
  final expectedIds = <String?>[];
  final noteIds = <List<String>>[];
  Future<CatalogCore> Function(String?)? catalogFactory;
  Future<NotebookCore> Function()? noteFactory;
  late final NotebookWorkspace workspace;

  Future<NotebookSession> edit() async {
    await workspace.initialize();
    expect(await workspace.openNote(_note), isTrue);
    final session = workspace.value.session!;
    protocol.ready(session.value.editor!);
    return session;
  }
}

void main() {
  test('native nested create, write, reopen, move and return preserve notebook and node identities', () async {
    final root = await Directory.systemTemp.createTemp('vnote-workspace-');
    final paths = ManagedNotebookPaths(
      app: '${root.path}/app',
      local: '${root.path}/local',
      notebook: '${root.path}/book',
    );
    final expectedIds = <String?>[];
    final workspace = NotebookWorkspace(
      obtainPaths: () async => paths,
      openCatalog: (paths, expected) {
        expectedIds.add(expected);
        return CoreNotebook.openCatalog(
          appDataPath: paths.app,
          localDataPath: paths.local,
          notebookPath: paths.notebook,
          notebookName: 'Personal',
          expectedNotebookId: expected,
        );
      },
    );
    addTearDown(() async {
      await workspace.shutdown();
      workspace.dispose();
      await root.delete(recursive: true);
    });
    await workspace.initialize();
    expect(workspace.value.error, isNull);
    final notebookId = workspace.value.directory!.notebookId;
    final rootId = workspace.value.directory!.folderId;
    expect(workspace.value.directory!.entries, isEmpty);
    final folder = await workspace.createFolder('研究');
    expect(folder!.applied, isTrue);
    expect(await workspace.navigate(folder.nodeId), isTrue);
    final created = await workspace.createNote('笔记.md');
    expect(created!.applied, isTrue);
    final entry = workspace.value.directory!.entries.single;
    expect(entry.id, created.nodeId);
    expect(await workspace.openNote(entry), isTrue);
    final session = workspace.value.session!;
    final editor = session.value.editor!;
    protocol.ready(editor);
    expect(session.value.note!.path, '研究/笔记.md');
    expect(session.value.note!.editorType, CoreEditorType.markdown);
    final ending = switch (session.value.note!.lineEnding) {
      2 => '\r\n',
      3 => '\r',
      _ => '\n',
    };
    final storedText = '# 研究😀${ending}Persistent source.';
    protocol.insert(editor, '# 研究😀\nPersistent source.');
    expect(
      await session.write((message) => protocol.answer(editor, message)),
      isTrue,
    );
    expect(
      await session.reopen(
        NotebookDisposition.discard,
        (message) => protocol.answer(editor, message),
      ),
      isTrue,
    );
    final reopened = session.value.editor!;
    protocol.ready(reopened);
    expect(reopened.generation, isNot(editor.generation));
    expect(reopened.value.revision, 0);
    expect(reopened.value.text, storedText);
    protocol.insert(reopened, '\nSecond host.');
    expect(
      await workspace.returnToBrowser(
        session,
        NotebookDisposition.write,
        (message) => protocol.answer(reopened, message),
      ),
      isTrue,
    );
    expect(workspace.value.directory!.folderId, folder.nodeId);
    expect(workspace.value.directory!.notebookId, notebookId);
    expect(workspace.value.directory!.entries.single.id, entry.id);
    final renamed = await workspace.rename(
      workspace.value.directory!.entries.single,
      'Renamed.md',
    );
    expect(renamed!.applied, isTrue);
    expect(
      (await workspace.move(
        workspace.value.directory!.entries.single,
        rootId,
      ))!.applied,
      isTrue,
    );
    expect(workspace.value.directory!.entries, isEmpty);
    expect(await workspace.navigate(rootId), isTrue);
    final moved = workspace.value.directory!.entries.singleWhere(
      (item) => item.id == entry.id,
    );
    expect(moved.name, 'Renamed.md');
    expect(
      await File('${paths.notebook}/Renamed.md').readAsString(),
      '$storedText${ending}Second host.',
    );
    expect(await workspace.openNote(moved), isTrue);
    final movedSession = workspace.value.session!;
    protocol.ready(movedSession.value.editor!);
    expect(movedSession.value.note!.nodeId, entry.id);
    expect(movedSession.value.note!.path, 'Renamed.md');
    expect(
      await workspace.returnToBrowser(
        movedSession,
        NotebookDisposition.discard,
        (message) => protocol.answer(movedSession.value.editor!, message),
      ),
      isTrue,
    );
    final textCreated = await workspace.createNote('Plain.txt');
    expect(textCreated!.applied, isTrue);
    final textEntry = workspace.value.directory!.entries.singleWhere(
      (item) => item.id == textCreated.nodeId,
    );
    expect(await workspace.openNote(textEntry), isTrue);
    final textSession = workspace.value.session!;
    final textEditor = textSession.value.editor!;
    final load = textEditor.beginLoad()!;
    expect(load['language'], 'text');
    expect(textSession.value.note!.editorType, CoreEditorType.text);
    textEditor.receive(
      jsonEncode(
        protocol.reply(textEditor, 'ready', load['requestId']! as String, {
          'textLength': textEditor.value.text.length,
        }),
      ),
    );
    protocol.insert(textEditor, '# literal text, not Markdown 😀');
    expect(
      await workspace.returnToBrowser(
        textSession,
        NotebookDisposition.write,
        (message) => protocol.answer(textEditor, message),
      ),
      isTrue,
    );
    expect(
      await File('${paths.notebook}/Plain.txt').readAsString(),
      '# literal text, not Markdown 😀',
    );
    final deleting = workspace.value.directory!.entries.singleWhere(
      (item) => item.id == entry.id,
    );
    expect((await workspace.delete(deleting))!.applied, isTrue);
    expect(
      workspace.value.directory!.entries.any((item) => item.id == entry.id),
      isFalse,
    );
    expect(expectedIds.first, isNull);
    expect(expectedIds.skip(1), everyElement(notebookId));
  });

  test(
    'native restore and retry refuse to recreate a missing observed notebook',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'vnote-workspace-missing-',
      );
      final paths = ManagedNotebookPaths(
        app: '${root.path}/app',
        local: '${root.path}/local',
        notebook: '${root.path}/book',
      );
      final expectedIds = <String?>[];
      var removeBeforeOpen = false;
      final workspace = NotebookWorkspace(
        obtainPaths: () async => paths,
        openCatalog: (paths, expected) async {
          expectedIds.add(expected);
          if (removeBeforeOpen) {
            removeBeforeOpen = false;
            await Directory(paths.notebook).rename('${root.path}/removed');
          }
          return CoreNotebook.openCatalog(
            appDataPath: paths.app,
            localDataPath: paths.local,
            notebookPath: paths.notebook,
            notebookName: 'Personal',
            expectedNotebookId: expected,
          );
        },
      );
      addTearDown(() async {
        await workspace.shutdown();
        workspace.dispose();
        await root.delete(recursive: true);
      });
      await workspace.initialize();
      final notebookId = workspace.value.directory!.notebookId;
      await workspace.createNote('Existing.md');
      await workspace.openNote(workspace.value.directory!.entries.single);
      final session = workspace.value.session!;
      protocol.ready(session.value.editor!);
      removeBeforeOpen = true;
      expect(
        await workspace.returnToBrowser(
          session,
          NotebookDisposition.discard,
          (message) => protocol.answer(session.value.editor!, message),
        ),
        isTrue,
      );
      expect(workspace.value.session, isNull);
      expect(workspace.value.error, contains('Core error'));
      expect(workspace.value.stale, isTrue);
      expect(await workspace.refresh(), isFalse);
      expect(await Directory(paths.notebook).exists(), isFalse);
      expect(expectedIds.skip(1), everyElement(notebookId));
      await Directory('${root.path}/removed').rename(paths.notebook);
      expect(await workspace.refresh(), isTrue);
      expect(workspace.value.directory!.notebookId, notebookId);
    },
  );

  test('failed note admission restores the same catalog identity without hiding its error', () async {
    final harness = _Harness();
    harness.noteFactory = () async {
      throw const CoreException(16, 'Encrypted content cannot be edited');
    };
    await harness.workspace.initialize();
    expect(await harness.workspace.openNote(_note), isFalse);
    expect(harness.workspace.value.session, isNull);
    expect(harness.workspace.value.error, contains('16'));
    expect(harness.workspace.value.error, contains('Encrypted'));
    expect(harness.workspace.value.stale, isFalse);
    expect(harness.expectedIds, [null, 'book-identity']);
    expect(harness.catalogs.first.closes, 1);
    expect(harness.owners.active, 1);
  });

  test(
    'cancel and failed writes retain dirty editor and never open a catalog',
    () async {
      final harness = _Harness();
      final session = await harness.edit();
      final editor = session.value.editor!;
      protocol.insert(editor, 'unsaved');
      expect(
        await harness.workspace.returnToBrowser(
          session,
          NotebookDisposition.cancel,
          (_) => fail('Cancel sends nothing'),
        ),
        isFalse,
      );
      final returning = harness.workspace.returnToBrowser(
        session,
        NotebookDisposition.write,
        (message) => protocol.answer(editor, message),
      );
      await protocol.turn();
      harness.notes.single.core.writes.single.completion.completeError(
        const CoreException(18, 'Disk conflict'),
      );
      expect(await returning, isFalse);
      expect(harness.workspace.value.session, same(session));
      expect(editor.value.text, 'base\r\nunsaved');
      expect(session.value.dirty, isTrue);
      expect(session.value.error, contains('18'));
      expect(harness.notes.single.core.closes, 0);
      expect(harness.expectedIds, [null]);
    },
  );

  test('a rejected close barrier preserves pending input instead of returning to the browser', () async {
    final harness = _Harness();
    final session = await harness.edit();
    final editor = session.value.editor!;
    final returned = await harness.workspace.returnToBrowser(
      session,
      NotebookDisposition.write,
      (message) {
        if (message['type'] == 'save') {
          protocol.answer(editor, message);
        } else {
          protocol.insert(editor, 'last input');
          editor.receive(
            jsonEncode(
              protocol.reply(editor, 'ack', message['requestId']! as String, {
                'stage': 'rejected',
                'throughRevision': editor.value.revision,
                'error': 'Newer revision',
              }),
            ),
          );
        }
      },
    );
    expect(returned, isFalse);
    expect(harness.workspace.value.session, same(session));
    expect(editor.value.text, 'base\r\nlast input');
    expect(editor.value.ready, isTrue);
    expect(session.value.dirty, isTrue);
    expect(harness.notes.single.core.closes, 0);
    expect(harness.expectedIds, [null]);
  });

  test('shutdown cancels a pending editor barrier and joins without reopening the catalog', () async {
    final harness = _Harness();
    final session = await harness.edit();
    final requested = Completer<void>();
    final returning = harness.workspace.returnToBrowser(
      session,
      NotebookDisposition.write,
      (_) => requested.complete(),
    );
    await requested.future;
    final closing = harness.workspace.shutdown();
    expect(await returning, isFalse);
    await closing;
    expect(harness.notes.single.core.closes, 1);
    expect(harness.expectedIds, [null]);
  });

  test('shutdown drains an admitted native write before releasing the selected owner', () async {
    final harness = _Harness();
    final session = await harness.edit();
    final editor = session.value.editor!;
    protocol.insert(editor, 'write in flight');
    final writing = session.write(
      (message) => protocol.answer(editor, message),
    );
    await protocol.turn();
    final core = harness.notes.single.core;
    final closing = harness.workspace.shutdown();
    expect(core.closes, 0);
    core.writes.single.completion.complete(
      CoreWriteResult(revision: 1, baseHash: 'b' * 64),
    );
    expect(await writing, isTrue);
    await closing;
    expect(core.closes, 1);
    expect(harness.expectedIds, [null]);
  });

  test(
    'failed mutations refresh and retain both native and listing failures',
    () async {
      final harness = _Harness();
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      final snapshot = harness.workspace.value.directory;
      catalog.onMutation = () async {
        throw const CoreException(
          6,
          'Partial create failed physical-size check',
        );
      };
      catalog.onList = (_) async {
        throw const CoreException(8, 'Malformed folder metadata');
      };
      final result = await harness.workspace.createNote('Partial.md');
      expect(result!.applied, isFalse);
      expect(result.error, contains('6'));
      expect(result.refreshError, contains('8'));
      expect(catalog.lists, ['root-id']);
      expect(harness.workspace.value.directory, same(snapshot));
      expect(harness.workspace.value.stale, isTrue);
      expect(harness.workspace.value.canMutate, isFalse);
      expect(await harness.workspace.delete(_note), isNull);
      expect(catalog.changes.length, 1);
      catalog.onList = null;
      expect(await harness.workspace.refresh(), isTrue);
      expect(harness.workspace.value.canMutate, isTrue);
      final failedButRefreshed = await harness.workspace.createNote(
        'StillFails.md',
      );
      expect(failedButRefreshed!.applied, isFalse);
      expect(failedButRefreshed.refreshError, isNull);
      expect(harness.workspace.value.stale, isFalse);
    },
  );

  test(
    'successful mutation plus failed refresh is not reported as rollback',
    () async {
      final harness = _Harness();
      await harness.workspace.initialize();
      harness.catalogs.single.onList = (_) async {
        throw const CoreException(6, 'Read failed after rename');
      };
      final result = await harness.workspace.rename(_note, 'New.md');
      expect(result!.applied, isTrue);
      expect(result.error, isNull);
      expect(result.refreshError, contains('Read failed'));
      expect(harness.workspace.value.mutation, same(result));
      expect(harness.workspace.value.stale, isTrue);
      expect(harness.catalogs.single.lists, ['root-id']);
    },
  );

  test('an admitted mutation drains and refreshes before shutdown closes the owner', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    final mutation = Completer<String>();
    final listing = Completer<CoreDirectory>();
    catalog.onMutation = () => mutation.future;
    catalog.onList = (_) => listing.future;
    final changing = harness.workspace.createFolder('Pending');
    expect(await harness.workspace.refresh(), isFalse);
    expect(await harness.workspace.createNote('Concurrent.md'), isNull);
    final closing = harness.workspace.shutdown();
    expect(catalog.closes, 0);
    mutation.complete('created-folder');
    await protocol.turn();
    expect(catalog.lists, ['root-id']);
    expect(catalog.closes, 0);
    listing.complete(_directory(entries: const []));
    expect((await changing)!.applied, isTrue);
    await closing;
    expect(catalog.closes, 1);
    expect(harness.workspace.value.closed, isTrue);
    expect(harness.workspace.value.directory!.entries, contains(_note));
  });

  test('disposal waits for catalog initialization and prevents late state installation', () async {
    final harness = _Harness();
    final opening = Completer<CatalogCore>();
    harness.catalogFactory = (_) => opening.future;
    final states = <NotebookWorkspaceState>[];
    harness.workspace.addListener(() => states.add(harness.workspace.value));
    final initializing = harness.workspace.initialize();
    await protocol.turn();
    harness.workspace.dispose();
    final catalog = _Catalog(harness.owners, _directory())
      ..closeGate = Completer<void>();
    opening.complete(catalog);
    await initializing;
    await protocol.turn();
    expect(catalog.closes, 1);
    expect(harness.owners.active, 1);
    catalog.closeGate!.complete();
    await harness.workspace.shutdown();
    await harness.workspace.initialize();
    expect(harness.expectedIds, [null]);
    expect(
      states.every((state) => state.directory == null && state.session == null),
      isTrue,
    );
  });

  test(
    'shutdown during catalog join prevents opening a replacement editor',
    () async {
      final harness = _Harness();
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single..closeGate = Completer<void>();
      final opening = harness.workspace.openNote(_note);
      await protocol.turn();
      final closing = harness.workspace.shutdown();
      expect(harness.noteIds, isEmpty);
      expect(harness.owners.active, 1);
      catalog.closeGate!.complete();
      expect(await opening, isFalse);
      await closing;
      expect(harness.noteIds, isEmpty);
    },
  );

  test('shutdown during selected-note open closes the late host without reading it', () async {
    final harness = _Harness();
    final pending = Completer<NotebookCore>();
    harness.noteFactory = () => pending.future;
    await harness.workspace.initialize();
    final opening = harness.workspace.openNote(_note);
    await protocol.turn();
    final closing = harness.workspace.shutdown();
    final note = _Note(harness.owners);
    pending.complete(note);
    expect(await opening, isFalse);
    await closing;
    expect(note.core.reads, 0);
    expect(note.core.closes, 1);
    expect(harness.workspace.value.session, isNull);
  });

  test('return waits for native close; stale editor callbacks cannot close the next note', () async {
    final harness = _Harness();
    final first = await harness.edit();
    final firstEditor = first.value.editor!;
    final note = harness.notes.single;
    note.core.closeGate = Completer<void>();
    final returning = harness.workspace.returnToBrowser(
      first,
      NotebookDisposition.discard,
      (message) => protocol.answer(firstEditor, message),
    );
    await protocol.turn();
    expect(harness.expectedIds, [null]);
    expect(await harness.workspace.openNote(_note), isFalse);
    expect(harness.owners.active, 1);
    note.core.closeGate!.complete();
    expect(await returning, isTrue);
    expect(harness.expectedIds, [null, 'book-identity']);
    expect(await harness.workspace.openNote(_note), isTrue);
    final next = harness.workspace.value.session!;
    expect(
      await harness.workspace.returnToBrowser(
        first,
        NotebookDisposition.discard,
        (_) => fail('Stale callback'),
      ),
      isFalse,
    );
    expect(harness.workspace.value.session, same(next));
    expect(next.value.editor!.generation, isNot(firstEditor.generation));
    expect(harness.notes.last.core.closes, 0);
  });

  test('failed refresh rejects stale entry callbacks and a later listing replaces identity tokens', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    catalog.onList = (_) async {
      throw const CoreException(6, 'Read failed');
    };
    expect(await harness.workspace.refresh(), isFalse);
    expect(await harness.workspace.openNote(_note), isFalse);
    catalog.onList = (_) async => _directory(
      entries: [
        CoreEntry(
          id: _note.id,
          name: 'Renamed externally.md',
          isFolder: false,
          exists: true,
          encrypted: false,
        ),
      ],
    );
    expect(await harness.workspace.refresh(), isTrue);
    expect(await harness.workspace.rename(_note, 'Stale.md'), isNull);
    expect(catalog.changes, isEmpty);
    expect(
      await harness.workspace.openNote(
        harness.workspace.value.directory!.entries.single,
      ),
      isTrue,
    );
  });

  test('folder picker queries preserve current location and missing return folder offers root recovery', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final nested = _directory(
      id: _folder.id,
      path: 'Research',
      parentId: 'root-id',
      entries: const [_note],
    );
    harness.catalogs.single.onList = (id) async =>
        id == _folder.id ? nested : _directory();
    expect(await harness.workspace.navigate(_folder.id), isTrue);
    expect((await harness.workspace.listDestination()).folderId, 'root-id');
    expect(harness.workspace.value.directory, same(nested));
    expect(await harness.workspace.openNote(_note), isTrue);
    final session = harness.workspace.value.session!;
    protocol.ready(session.value.editor!);
    harness.catalogFactory = (_) async {
      final catalog = _Catalog(harness.owners, _directory());
      catalog.onList = (id) async {
        if (id == _folder.id) {
          throw const CoreException(10, 'Folder no longer exists');
        }
        return _directory();
      };
      return catalog;
    };
    expect(
      await harness.workspace.returnToBrowser(
        session,
        NotebookDisposition.discard,
        (message) => protocol.answer(session.value.editor!, message),
      ),
      isTrue,
    );
    expect(harness.workspace.value.stale, isTrue);
    expect(harness.workspace.value.directory, same(nested));
    expect(harness.workspace.value.error, contains('Folder no longer exists'));
    expect(await harness.workspace.navigate(null), isTrue);
    expect(harness.workspace.value.directory!.path, '.');
  });

  test(
    'search forwards saved-text filters and exposes complete result status',
    () async {
      final harness = _Harness();
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      final result = _searchResult(limited: true, skipped: 3);
      catalog.onSearch = (_, _, _) async => result;
      expect(
        await harness.workspace.search(
          'needle',
          tag: 'Research',
          caseSensitive: true,
        ),
        isTrue,
      );
      expect(catalog.searches, [('needle', 'Research', true)]);
      expect(harness.workspace.value.search, same(result));
      expect(harness.workspace.value.search!.limited, isTrue);
      expect(harness.workspace.value.search!.skipped, 3);
      expect(
        harness.workspace.value.search!.matches.single.snippet,
        contains('😀'),
      );
      expect(await harness.workspace.search('', tag: 'Research'), isTrue);
      expect(catalog.searches.last, ('', 'Research', false));
      expect(await harness.workspace.search(''), isFalse);
      expect(harness.workspace.value.search, isNull);
      expect(
        harness.workspace.value.searchError,
        contains('Enter search text'),
      );
      catalog.onSearch = (_, _, _) async =>
          _searchResult(notebookId: 'replacement-book');
      expect(await harness.workspace.search('needle'), isFalse);
      expect(harness.workspace.value.searchError, contains('identity changed'));
      expect(harness.workspace.value.search, isNull);
      expect(harness.workspace.value.canMutate, isTrue);
    },
  );

  test('query changes and cancellation discard late hits without releasing the catalog early', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    final first = Completer<CoreSearchResult>();
    catalog.onSearch = (_, _, _) => first.future;
    final searching = harness.workspace.search('first');
    expect(harness.workspace.value.searching, isTrue);
    harness.workspace.clearSearch();
    expect(catalog.searchCancellations, 1);
    expect(await harness.workspace.search('second'), isFalse);
    first.complete(_searchResult());
    expect(await searching, isFalse);
    expect(harness.workspace.value.search, isNull);
    expect(harness.workspace.value.searchError, isNull);
    final second = Completer<CoreSearchResult>();
    catalog.onSearch = (_, _, _) => second.future;
    final cancelling = harness.workspace.search('second');
    harness.workspace.cancelSearch();
    harness.workspace.cancelSearch();
    expect(catalog.searchCancellations, 2);
    expect(harness.workspace.value.searchCancelled, isTrue);
    second.completeError(const CoreException(12, 'Cancelled'));
    expect(await cancelling, isFalse);
    expect(harness.workspace.value.searchError, isNull);
    expect(harness.workspace.value.busy, isFalse);
    expect(catalog.closes, 0);
  });

  test('only current result and hit identities navigate, and edits and refresh invalidate both', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    await harness.workspace.search('needle');
    final result = harness.workspace.value.search!;
    final hit = result.matches.single;
    final forged = CoreSearchHit(
      id: hit.id,
      path: hit.path,
      line: hit.line,
      snippet: hit.snippet,
    );
    expect(await harness.workspace.openSearchHit(result, forged), isFalse);
    expect(
      await harness.workspace.openSearchHit(_searchResult(), hit),
      isFalse,
    );
    harness.workspace.clearSearch();
    expect(await harness.workspace.openSearchHit(result, hit), isFalse);
    await harness.workspace.search('needle');
    final beforeRefresh = harness.workspace.value.search!;
    await harness.workspace.refresh();
    expect(
      await harness.workspace.openSearchHit(
        beforeRefresh,
        beforeRefresh.matches.single,
      ),
      isFalse,
    );
    await harness.workspace.search('needle');
    final beforeEdit = harness.workspace.value.search!;
    await harness.workspace.rename(_note, 'Renamed.md');
    expect(
      await harness.workspace.openSearchHit(
        beforeEdit,
        beforeEdit.matches.single,
      ),
      isFalse,
    );
    expect(harness.noteIds, isEmpty);
    expect(harness.catalogs.single.closes, 0);
  });

  test('search hit opening joins the catalog and resolves ID rather than its old path', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    await harness.workspace.search('needle');
    final result = harness.workspace.value.search!;
    final catalog = harness.catalogs.single..closeGate = Completer<void>();
    final opening = harness.workspace.openSearchHit(
      result,
      result.matches.single,
    );
    expect(harness.workspace.value.search, isNull);
    expect(harness.noteIds, isEmpty);
    expect(harness.owners.active, 1);
    catalog.closeGate!.complete();
    expect(await opening, isTrue);
    expect(harness.noteIds, [
      ['book-identity', 'nested-note'],
    ]);
    final session = harness.workspace.value.session!;
    protocol.ready(session.value.editor!);
    expect(
      await harness.workspace.returnToBrowser(
        session,
        NotebookDisposition.discard,
        (message) => protocol.answer(session.value.editor!, message),
      ),
      isTrue,
    );
    expect(harness.expectedIds, [null, 'book-identity']);
    expect(harness.workspace.value.search, isNull);
    expect(
      await harness.workspace.openSearchHit(result, result.matches.single),
      isFalse,
    );
    expect(harness.owners.maximum, 1);
  });

  test('failed hit open restores the same notebook and leaves stale callbacks rejected', () async {
    final harness = _Harness();
    harness.noteFactory = () async =>
        throw const CoreException(10, 'Selected note was deleted');
    await harness.workspace.initialize();
    await harness.workspace.search('needle');
    final result = harness.workspace.value.search!;
    expect(
      await harness.workspace.openSearchHit(result, result.matches.single),
      isFalse,
    );
    expect(harness.workspace.value.session, isNull);
    expect(harness.workspace.value.error, contains('deleted'));
    expect(harness.workspace.value.canMutate, isTrue);
    expect(
      await harness.workspace.openSearchHit(result, result.matches.single),
      isFalse,
    );
    expect(harness.expectedIds, [null, 'book-identity']);
  });

  test('shutdown cancels search but waits for its terminal before closing the owner', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    final pending = Completer<CoreSearchResult>();
    catalog.onSearch = (_, _, _) => pending.future;
    final searching = harness.workspace.search('needle');
    final closing = harness.workspace.shutdown();
    expect(catalog.searchCancellations, 1);
    expect(catalog.closes, 0);
    expect(harness.workspace.value.closed, isTrue);
    pending.complete(_searchResult());
    expect(await searching, isFalse);
    await closing;
    expect(catalog.closes, 1);
    expect(harness.workspace.value.search, isNull);
    expect(harness.noteIds, isEmpty);
  });

  test('shutdown during hit join never opens the selected note', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    await harness.workspace.search('needle');
    final result = harness.workspace.value.search!;
    final catalog = harness.catalogs.single..closeGate = Completer<void>();
    final opening = harness.workspace.openSearchHit(
      result,
      result.matches.single,
    );
    final closing = harness.workspace.shutdown();
    expect(harness.noteIds, isEmpty);
    catalog.closeGate!.complete();
    expect(await opening, isFalse);
    await closing;
    expect(harness.noteIds, isEmpty);
    expect(catalog.closes, 1);
  });

  test('tag writes preserve orphan assignments and return a refreshed authoritative snapshot', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    final original = await harness.workspace.loadTags(_note);
    expect(original.assigned, ['orphan']);
    expect(original.tags.last.parent, 'Topics');
    catalog.onTags = (_) async =>
        _tagSnapshot(assigned: ['orphan', 'Research']);
    final result = (await harness.workspace.setTags(_note, original, [
      'orphan',
      'Research',
    ]))!;
    expect(result.applied, isTrue);
    expect(result.tags!.assigned, ['orphan', 'Research']);
    expect(catalog.tagQueries, [_note.id, _note.id]);
    expect(catalog.tagChanges.single, [
      'setTags',
      _note.id,
      'orphan',
      'Research',
    ]);
    expect(await harness.workspace.setTags(_note, original, []), isNull);
    final created = (await harness.workspace.createTag(
      _note,
      result.tags!,
      'New tag',
    ))!;
    expect(created.applied, isTrue);
    expect(catalog.tagChanges.last, ['createTag', 'New tag']);
    expect(catalog.tagQueries.length, 3);
    await harness.workspace.refresh();
    expect(await harness.workspace.setTags(_note, created.tags!, []), isNull);
  });

  test('tag write success is not erased by failed refresh and saving requires reloading', () async {
    final harness = _Harness();
    await harness.workspace.initialize();
    final catalog = harness.catalogs.single;
    final snapshot = await harness.workspace.loadTags(_note);
    catalog.onTags = (_) async =>
        throw const CoreException(6, 'Tag refresh unavailable');
    final result = (await harness.workspace.setTags(_note, snapshot, [
      'orphan',
    ]))!;
    expect(result.applied, isTrue);
    expect(result.error, isNull);
    expect(result.refreshError, contains('Tag refresh unavailable'));
    expect(result.tags, isNull);
    expect(await harness.workspace.setTags(_note, snapshot, []), isNull);
    await expectLater(
      harness.workspace.loadTags(_note),
      throwsA(isA<CoreException>()),
    );
    catalog.onTags = null;
    final fresh = await harness.workspace.loadTags(_note);
    catalog.onTagMutation = () async =>
        throw const CoreException(6, 'Write failed');
    final failed = (await harness.workspace.setTags(_note, fresh, []))!;
    expect(failed.applied, isFalse);
    expect(failed.error, contains('Write failed'));
    expect(failed.refreshError, isNull);
    expect(failed.tags!.assigned, ['orphan']);
  });

  test(
    'shutdown drains tag writes and their refresh without cancelling them',
    () async {
      final harness = _Harness();
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      final snapshot = await harness.workspace.loadTags(_note);
      final writing = Completer<void>();
      final refreshed = Completer<CoreTags>();
      catalog.onTagMutation = () => writing.future;
      catalog.onTags = (_) => refreshed.future;
      final saving = harness.workspace.setTags(_note, snapshot, ['orphan']);
      final closing = harness.workspace.shutdown();
      expect(catalog.searchCancellations, 0);
      expect(catalog.closes, 0);
      writing.complete();
      await protocol.turn();
      expect(catalog.tagQueries.length, 2);
      expect(catalog.closes, 0);
      refreshed.complete(_tagSnapshot());
      expect((await saving)!.applied, isTrue);
      await closing;
      expect(catalog.closes, 1);
      expect(catalog.searchCancellations, 0);
    },
  );

  testWidgets(
    'browser search exposes filters, partial results, errors and stale hit rejection',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      catalog.onSearch = (_, _, _) async =>
          _searchResult(limited: true, skipped: 2);
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Search notebook'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Unsaved editor changes are not searched'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'Saved needle');
      await tester.tap(find.text('Case sensitive'));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research (parent: Topics)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await tester.pumpAndSettle();
      expect(catalog.searches.single, ('Saved needle', 'Research', true));
      expect(find.textContaining('Results are incomplete'), findsOneWidget);
      expect(
        find.text('2 unsupported or unavailable notes were skipped.'),
        findsOneWidget,
      );
      final row = find.byKey(const ValueKey('search-nested-note'));
      await tester.ensureVisible(row);
      final staleTap = tester.widget<ListTile>(row).onTap!;
      expect(find.text('Research/旧名.md'), findsOneWidget);
      expect(find.textContaining('Line 7: Saved needle 😀'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Changed query');
      await tester.pump();
      staleTap();
      await tester.pumpAndSettle();
      expect(harness.noteIds, isEmpty);
      expect(find.byKey(const ValueKey('search-nested-note')), findsNothing);
      catalog.onSearch = (_, _, _) async =>
          throw const CoreException(6, 'Search storage failure');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Search'));
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Search failed: Core error 6: Search storage failure',
        ),
        findsOneWidget,
      );
      catalog.onSearch = (_, _, _) async => _searchResult(matches: []);
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await tester.pumpAndSettle();
      expect(find.text('No matching notes.'), findsOneWidget);
      expect(find.textContaining('Search failed:'), findsNothing);
      await tester.tap(find.text('Back to folders'));
      await tester.pumpAndSettle();
      expect(find.text(_note.name), findsOneWidget);
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'browser cancel search remains pending until native completion and then permits retry',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      final pending = Completer<CoreSearchResult>();
      catalog.onSearch = (_, _, _) => pending.future;
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Search notebook'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await tester.pump();
      await tester.tap(find.text('Cancel search'));
      await tester.pump();
      expect(catalog.searchCancellations, 1);
      expect(find.text('Cancelling search…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
            .onPressed,
        isNull,
      );
      pending.complete(_searchResult());
      await tester.pumpAndSettle();
      expect(find.text('Search cancelled.'), findsOneWidget);
      expect(find.text('Research/旧名.md'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
            .onPressed,
        isNotNull,
      );
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'tag picker preserves orphan names, creates tags and separates saved writes from refresh failure',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      final definitions = _tagSnapshot().tags.toList();
      var assigned = ['orphan'];
      var failRefresh = false;
      catalog.onTags = (_) async {
        if (failRefresh) {
          throw const CoreException(6, 'Tag metadata unavailable');
        }
        return _tagSnapshot(tags: definitions, assigned: assigned);
      };
      catalog.onTagMutation = () async {
        final change = catalog.tagChanges.last;
        if (change.first == 'createTag') {
          definitions.add(CoreTag(name: change[1], parent: ''));
        } else {
          assigned = change.skip(2).toList();
        }
      };
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Actions for ${_note.name}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tags'));
      await tester.pumpAndSettle();
      expect(find.text('Parent: Topics'), findsOneWidget);
      expect(
        find.textContaining('Existing assignment without a definition'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'orphan'),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.text('Create tag'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'New tag');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(catalog.tagChanges.single, ['createTag', 'New tag']);
      expect(catalog.tagQueries, [_note.id, _note.id]);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'New tag'),
            )
            .value,
        isTrue,
      );
      failRefresh = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(assigned, unorderedEquals(['orphan', 'New tag']));
      expect(
        find.textContaining('Tags saved, but tags could not be refreshed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The change was not rolled back.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      failRefresh = false;
      await tester.tap(find.text('Reload tags'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Tags saved.'), findsOneWidget);
      expect(find.text('Tags for “${_note.name}”'), findsNothing);
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'incomplete tag loading disables replacement until a complete reload and Cancel never writes',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      await harness.workspace.initialize();
      final catalog = harness.catalogs.single;
      catalog.onTags = (_) async => throw const CoreException(
        6,
        'Assignments exceed the complete response limit',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Actions for ${_note.name}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tags'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Assignments exceed the complete response limit'),
        findsOneWidget,
      );
      expect(
        find.text('Complete tag data is required before saving.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      catalog.onTags = null;
      await tester.tap(find.text('Reload tags'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(catalog.tagChanges, isEmpty);
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'browser submits entered names and lists missing and encrypted content without exposing IDs',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      harness.catalogFactory = (_) async {
        final catalog = _Catalog(
          harness.owners,
          _directory(
            entries: const [
              _folder,
              CoreEntry(
                id: 'hidden-missing-id',
                name: 'Missing.bin',
                isFolder: false,
                exists: false,
                encrypted: false,
              ),
              CoreEntry(
                id: 'hidden-secret-id',
                name: 'Secret.md',
                isFolder: false,
                exists: true,
                encrypted: true,
              ),
            ],
          ),
        );
        harness.catalogs.add(catalog);
        return catalog;
      };
      await harness.workspace.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      expect(find.text('Missing.bin'), findsOneWidget);
      expect(find.text('Missing content'), findsOneWidget);
      expect(find.text('Encrypted'), findsOneWidget);
      expect(find.text('hidden-missing-id'), findsNothing);
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await tester.enterText(find.byType(TextFormField), '用户.txt');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(harness.catalogs.single.changes, [
        ['note', 'root-id', '用户.txt'],
      ]);
      expect(harness.catalogs.single.lists, ['root-id']);
      // Finish async ownership cleanup while the widget-test clock is active.
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'move traverses actual destination listings and excludes the source subtree',
    (tester) async {
      final harness = _Harness(widgetTest: true);
      const destination = CoreEntry(
        id: 'destination-id',
        name: 'Destination',
        isFolder: true,
        exists: true,
        encrypted: false,
      );
      final rootDirectory = _directory(entries: const [_folder, destination]);
      final destinationDirectory = _directory(
        id: destination.id,
        path: destination.name,
        parentId: 'root-id',
        entries: const [],
      );
      harness.catalogFactory = (_) async {
        final catalog = _Catalog(harness.owners, rootDirectory);
        catalog.onList = (id) async =>
            id == destination.id ? destinationDirectory : rootDirectory;
        harness.catalogs.add(catalog);
        return catalog;
      };
      await harness.workspace.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: NotebookBrowser(
            workspace: harness.workspace,
            dark: false,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Actions for Research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final sourceTile = find.ancestor(
        of: find.descendant(of: dialog, matching: find.text('Research')),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(sourceTile).onTap, isNull);
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Destination')),
      );
      await tester.pumpAndSettle();
      expect(harness.catalogs.single.lists, [null, destination.id]);
      expect(harness.workspace.value.directory, same(rootDirectory));
      await tester.tap(find.text('Move here'));
      await tester.pumpAndSettle();
      expect(harness.catalogs.single.changes, [
        ['move', _folder.id, destination.id],
      ]);
      expect(harness.catalogs.single.lists.last, 'root-id');
      // Finish async ownership cleanup while the widget-test clock is active.
      await harness.workspace.shutdown();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
