// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/editor_session.dart';
import 'package:vnote_mobile/services/notebook_session.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

// These fakes exercise coordinator transitions only. They are not storage proof;
// real FFI create/write/read/identity evidence belongs to the bridge tests.
final firstHash = 'a' * 64;
final secondHash = 'b' * 64;
final thirdHash = 'c' * 64;

CoreNote note({String text = 'base\r\n', String? hash}) => CoreNote(
  notebookId: 'book-identity',
  nodeId: 'node-identity',
  text: text,
  baseHash: hash ?? firstHash,
  coreVersion: '1.0.0',
  lineEnding: 0,
);

class PendingWrite {
  PendingWrite(this.text, this.revision, this.baseHash);
  final String text;
  final int revision;
  final String baseHash;
  final completion = Completer<CoreWriteResult>();
}

class ControlledCore implements NotebookCore {
  CoreNote nextRead = note();
  Object? readError;
  int reads = 0;
  int closes = 0;
  Completer<void>? closeGate;
  Future<void>? _closing;
  final writes = <PendingWrite>[];

  @override
  String get nativeNotices => 'Native license fixture';

  @override
  Future<CoreNote> read() async {
    reads++;
    if (readError != null) throw readError!;
    return nextRead;
  }

  @override
  Future<CoreWriteResult> write(
    String text, {
    required int revision,
    required String baseHash,
  }) {
    final pending = PendingWrite(text, revision, baseHash);
    writes.add(pending);
    return pending.completion.future;
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    closes++;
    await closeGate?.future;
  }
}

Map<String, Object?> reply(
  EditorSession editor,
  String type,
  String requestId,
  Map<String, Object?> fields, {
  int? revision,
}) => {
  'v': 1,
  'type': type,
  'documentId': editor.documentId,
  'generation': editor.generation,
  'revision': revision ?? editor.value.revision,
  'requestId': requestId,
  ...fields,
};

void ready(EditorSession editor) {
  final request = editor.beginLoad()!;
  editor.receive(
    jsonEncode(
      reply(editor, 'ready', request['requestId']! as String, {
        'textLength': editor.value.text.length,
      }),
    ),
  );
}

void insert(EditorSession editor, String text) {
  final revision = editor.value.revision;
  final end = editor.value.text.length;
  editor.receive(
    jsonEncode(
      reply(editor, 'edit', 'editor-${revision + 1}', {
        'baseRevision': revision,
        'changes': [
          {'from': end, 'to': end, 'insert': text},
        ],
        'selection': {'anchor': end + text.length, 'head': end + text.length},
      }, revision: revision + 1),
    ),
  );
}

void answer(EditorSession editor, Map<String, Object?> request) {
  if (request['type'] == 'save') {
    editor.receive(
      jsonEncode(
        reply(editor, 'save', request['requestId']! as String, {
          'mode': 'snapshot',
          'text': editor.value.text,
        }),
      ),
    );
  } else if (request['type'] == 'close') {
    editor.receive(
      jsonEncode(
        reply(editor, 'close', request['requestId']! as String, {
          'mode': 'ready',
          'disposition': request['disposition'],
        }),
      ),
    );
  }
}

Future<NotebookSession> start(ControlledCore core) async {
  final session = NotebookSession(openCore: () async => core);
  addTearDown(() async {
    await session.shutdown();
    session.dispose();
  });
  await session.initialize();
  ready(session.value.editor!);
  return session;
}

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a reopened editor can write revision one through the real core',
    () async {
      final root = await Directory.systemTemp.createTemp('vnote-coordinator-');
      final session = NotebookSession(
        openCore: () => CoreNotebook.open(
          appDataPath: '${root.path}/app',
          localDataPath: '${root.path}/local',
          notebookPath: '${root.path}/book',
          notebookName: 'Personal',
          notePath: 'Welcome.md',
          initialText: 'original\r\n',
        ),
      );
      addTearDown(() async {
        await session.shutdown();
        session.dispose();
        await root.delete(recursive: true);
      });
      await session.initialize();
      final first = session.value.editor!;
      ready(first);
      insert(first, 'one');
      insert(first, 'two');
      expect(await session.write((message) => answer(first, message)), isTrue);
      final id = session.value.note!.nodeId;
      expect(
        await session.reopen(
          NotebookDisposition.discard,
          (message) => answer(first, message),
        ),
        isTrue,
      );
      final reopened = session.value.editor!;
      ready(reopened);
      insert(reopened, 'three');
      expect(
        await session.write((message) => answer(reopened, message)),
        isTrue,
      );
      expect(session.value.onDiskRevision, 1);
      expect(session.value.note!.nodeId, id);
      expect(
        await File('${root.path}/book/Welcome.md').readAsString(),
        'original\r\nonetwothree',
      );
    },
  );

  test(
    'failed native startup never manufactures an editor or hides its code',
    () async {
      final session = NotebookSession(
        openCore: () async {
          throw const CoreException(8, 'Invalid existing notebook metadata');
        },
      );
      await session.initialize();
      expect(session.value.editor, isNull);
      expect(session.value.note, isNull);
      expect(session.value.error, contains('8'));
      expect(session.value.loading, isFalse);
      await session.shutdown();
      session.dispose();
    },
  );

  test(
    'retry opens through the native factory rather than recreating editor data',
    () async {
      final core = ControlledCore();
      var attempts = 0;
      final session = NotebookSession(
        openCore: () async {
          if (++attempts == 1) throw const CoreException(6, 'Open failed');
          return core;
        },
      );
      await session.initialize();
      await session.retryOpen();
      expect(attempts, 2);
      expect(session.value.note!.nodeId, core.nextRead.nodeId);
      expect(session.value.error, isNull);
      await session.shutdown();
      session.dispose();
    },
  );

  test('disposal during startup waits for native open then closes without installing a view', () async {
    final pending = Completer<NotebookCore>();
    final core = ControlledCore();
    final session = NotebookSession(openCore: () => pending.future);
    final opening = session.initialize();
    session.dispose();
    pending.complete(core);
    await opening;
    await session.shutdown();
    expect(core.reads, 0);
    expect(core.closes, 1);
  });

  test('only the captured revision advances on disk; next write uses returned disk hash', () async {
    final core = ControlledCore();
    final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'first😀');
    final writing = session.write((request) => answer(editor, request));
    await turn();
    expect(core.writes.single.text, 'base\r\nfirst😀');
    expect(core.writes.single.baseHash, firstHash);
    insert(editor, 'second');
    expect(
      await session.write((_) => fail('A second write must not be admitted')),
      isFalse,
    );
    expect(
      await session.reopen(
        NotebookDisposition.discard,
        (_) => fail('Busy reopen'),
      ),
      isFalse,
    );
    core.writes.single.completion.complete(
      CoreWriteResult(revision: 1, baseHash: secondHash),
    );
    expect(await writing, isTrue);
    expect(session.value.onDiskRevision, 1);
    expect(session.value.editor!.value.revision, 2);
    expect(session.value.dirty, isTrue);
    final second = session.write((request) => answer(editor, request));
    await turn();
    expect(core.writes.last.baseHash, secondHash);
    expect(core.writes.last.revision, 2);
    core.writes.last.completion.complete(
      CoreWriteResult(revision: 2, baseHash: thirdHash),
    );
    expect(await second, isTrue);
    expect(session.value.dirty, isFalse);
    expect(session.value.editor, same(editor));
  });

  test(
    'wrong native receipt cannot mark current or future text on disk',
    () async {
      final core = ControlledCore();
      final session = await start(core);
      final editor = session.value.editor!;
      insert(editor, 'pending');
      final writing = session.write((request) => answer(editor, request));
      await turn();
      core.writes.single.completion.complete(
        CoreWriteResult(revision: 2, baseHash: secondHash),
      );
      expect(await writing, isFalse);
      expect(session.value.onDiskRevision, 0);
      expect(session.value.dirty, isTrue);
      expect(editor.value.text, 'base\r\npending');
    },
  );

  test(
    'write failure blocks write-and-reopen and retains copyable source',
    () async {
      final core = ControlledCore();
      final session = await start(core);
      final editor = session.value.editor!;
      insert(editor, 'unwritten');
      final reopening = session.reopen(
        NotebookDisposition.write,
        (request) => answer(editor, request),
      );
      await turn();
      core.writes.single.completion.completeError(
        const CoreException(18, 'Disk base changed'),
      );
      expect(await reopening, isFalse);
      expect(core.reads, 1);
      expect(core.closes, 0);
      expect(session.value.editor, same(editor));
      expect(editor.value.text, 'base\r\nunwritten');
      expect(editor.value.closed, isFalse);
      expect(session.value.error, contains('18'));
      expect(session.value.dirty, isTrue);
    },
  );

  test('unchanged Write still flushes a snapshot but does not rewrite source policy', () async {
    final core = ControlledCore();
    final session = await start(core);
    var snapshots = 0;
    expect(
      await session.write((request) {
        snapshots++;
        answer(session.value.editor!, request);
      }),
      isTrue,
    );
    expect(snapshots, 1);
    expect(core.writes, isEmpty);
    expect(session.value.onDiskRevision, 0);
  });

  test('cancel never sends a barrier or discards dirty source', () async {
    final core = ControlledCore();
    final session = await start(core);
    insert(session.value.editor!, 'unsaved');
    expect(
      await session.reopen(
        NotebookDisposition.cancel,
        (_) => fail('No barrier'),
      ),
      isFalse,
    );
    expect(
      await session.close(
        NotebookDisposition.cancel,
        (_) => fail('No barrier'),
      ),
      isFalse,
    );
    expect(core.reads, 1);
    expect(core.closes, 0);
    expect(session.value.dirty, isTrue);
  });

  test('discard reopen installs a fresh generation only after barrier and read success', () async {
    final core = ControlledCore();
    final session = await start(core);
    final previous = session.value.editor!;
    insert(previous, 'discarded');
    core.readError = const CoreException(6, 'Read failed');
    expect(
      await session.reopen(
        NotebookDisposition.discard,
        (request) => answer(previous, request),
      ),
      isFalse,
    );
    expect(session.value.editor, same(previous));
    expect(previous.value.text, 'base\r\ndiscarded');
    core.readError = null;
    core.nextRead = note(text: 'reopened\r\n', hash: secondHash);
    expect(
      await session.reopen(
        NotebookDisposition.discard,
        (request) => answer(previous, request),
      ),
      isTrue,
    );
    final next = session.value.editor!;
    expect(next, isNot(same(previous)));
    expect(next.generation, isNot(previous.generation));
    expect(next.documentId, previous.documentId);
    expect(next.value.text, 'reopened\r\n');
    expect(session.value.onDiskRevision, 0);
    expect(session.value.dirty, isFalse);
    ready(next);
    final before = next.value;
    next.receive(
      jsonEncode(
        reply(previous, 'edit', 'editor-2', {
          'baseRevision': 1,
          'changes': [],
          'selection': {'anchor': 0, 'head': 0},
        }, revision: 2),
      ),
    );
    expect(next.value, same(before));
  });

  test('newer edits during write prevent close even after a successful captured write', () async {
    final core = ControlledCore();
    final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'one');
    final closing = session.close(
      NotebookDisposition.write,
      (request) => answer(editor, request),
    );
    await turn();
    insert(editor, 'two');
    core.writes.single.completion.complete(
      CoreWriteResult(revision: 1, baseHash: secondHash),
    );
    expect(await closing, isFalse);
    expect(core.closes, 0);
    expect(session.value.onDiskRevision, 1);
    expect(session.value.dirty, isTrue);
    expect(editor.value.closed, isFalse);
  });

  test(
    'pending JS input at a written-close barrier cannot be discarded as clean',
    () async {
      final core = ControlledCore();
      final session = await start(core);
      final editor = session.value.editor!;
      final completed = await session.close(NotebookDisposition.write, (
        request,
      ) {
        if (request['type'] == 'save') {
          answer(editor, request);
        } else {
          insert(editor, 'last composition');
          editor.receive(
            jsonEncode(
              reply(editor, 'ack', request['requestId']! as String, {
                'stage': 'rejected',
                'throughRevision': editor.value.revision,
                'error': 'Newer editor revision',
              }),
            ),
          );
        }
      });
      expect(completed, isFalse);
      expect(core.closes, 0);
      expect(editor.value.ready, isTrue);
      expect(session.value.dirty, isTrue);
    },
  );

  test('discard can exit a failed transport and native close is awaited asynchronously', () async {
    final core = ControlledCore()..closeGate = Completer<void>();
    final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'copyable');
    editor.reportTransportError('Editor channel lost');
    final closing = session.close(
      NotebookDisposition.discard,
      (_) => fail('Broken channel must not block explicitly confirmed discard'),
    );
    await turn();
    expect(core.closes, 1);
    expect(session.value.closed, isFalse);
    expect(session.value.transitioning, isTrue);
    core.closeGate!.complete();
    expect(await closing, isTrue);
    expect(session.value.closed, isTrue);
    expect(editor.value.text, 'base\r\ncopyable');
    await session.shutdown();
    await session.shutdown();
    expect(core.closes, 1);
  });
}
