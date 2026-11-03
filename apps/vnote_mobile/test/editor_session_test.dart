// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/editor_session.dart';

const generation = '0123456789abcdef0123456789abcdef';
const documentId = 'notebookA:nodeA';
final baseHash = 'a' * 64;

EditorSession sessionWith(String text) {
  final session = EditorSession(
    initialText: text,
    documentId: documentId,
    baseVersion: baseHash,
    language: 'markdown',
    generationFactory: () => generation,
  );
  addTearDown(session.dispose);
  return session;
}

Map<String, Object?> message(
  String type,
  int revision,
  String requestId,
  Map<String, Object?> payload,
) => {
  'v': 2,
  'type': type,
  'documentId': documentId,
  'generation': generation,
  'revision': revision,
  'requestId': requestId,
  ...payload,
};

Map<String, Object?>? deliver(
  EditorSession session,
  Map<String, Object?> message,
) => session.receive(jsonEncode(message));

void open(EditorSession session) {
  final load = session.beginLoad()!;
  final ack = deliver(
    session,
    message('ready', 0, load['requestId']! as String, {
      'textLength': session.value.text.length,
    }),
  );
  expect(ack?['stage'], 'received');
  expect(session.value.ready, isTrue);
}

Map<String, Object?> edit({
  int revision = 1,
  int baseRevision = 0,
  String requestId = 'editor-1',
  int from = 0,
  int to = 0,
  String insert = 'x',
  int anchor = 0,
  int head = 0,
  String? operationId,
}) => message('edit', revision, requestId, {
  'baseRevision': baseRevision,
  'changes': [
    {'from': from, 'to': to, 'insert': insert},
  ],
  'selection': {'anchor': anchor, 'head': head},
  'operationId': ?operationId,
});

Map<String, Object?> currentSelection(
  Map<String, Object?> request, {
  int revision = 0,
  int anchor = 0,
  int head = 0,
}) => message('selection', revision, request['requestId']! as String, {
  'mode': 'current',
  'anchor': anchor,
  'head': head,
});

Map<String, Object?> insertionReceipt(
  Map<String, Object?> request, {
  int revision = 1,
}) => message('ack', revision, request['requestId']! as String, {
  'stage': 'received',
  'throughRevision': revision,
  'changed': true,
});

void expectRejectedWithoutMutation(
  EditorSession session,
  Map<String, Object?> request,
) {
  final text = session.value.text;
  final revision = session.value.revision;
  final ack = deliver(session, request);
  expect(ack?['stage'], 'rejected');
  expect(ack?['throughRevision'], revision);
  expect(session.value.text, text);
  expect(session.value.revision, revision);
  expect(session.value.error, isNotEmpty);
}

void main() {
  group('session and handshake', () {
    test('unsupported language cannot establish an editor session', () {
      for (final language in ['', 'html', 'text\n']) {
        expect(
          () => EditorSession(
            initialText: '',
            documentId: documentId,
            baseVersion: baseHash,
            language: language,
          ),
          throwsArgumentError,
        );
      }
    });

    test('injected generation is validated as a 128-bit session token', () {
      expect(
        () => EditorSession(
          initialText: '',
          documentId: documentId,
          baseVersion: baseHash,
          language: 'markdown',
          generationFactory: () => 'invalid',
        ),
        throwsArgumentError,
      );
    });

    test(
      'only the dynamically bound ready grants received acknowledgement',
      () {
        final session = sessionWith('hello');
        final load = session.beginLoad()!;
        expect(session.value.ready, isFalse);
        final ready = message('ready', 0, load['requestId']! as String, {
          'textLength': 5,
        });
        final ack = deliver(session, ready);
        expect(ack?['stage'], 'received');
        expect(ack?['requestId'], load['requestId']);
        expect(session.value.ready, isTrue);
        expect(deliver(session, ready), ack);
      },
    );

    test(
      'opaque identity and disk hash reject unbounded or invalid values',
      () {
        for (final id in ['', 'a' * 257, 'path/escape', 'identity\n']) {
          expect(
            () => EditorSession(
              initialText: '',
              documentId: id,
              baseVersion: baseHash,
              language: 'markdown',
            ),
            throwsArgumentError,
          );
        }
        expect(
          () => EditorSession(
            initialText: '',
            documentId: documentId,
            baseVersion: 'invalid',
            language: 'markdown',
          ),
          throwsArgumentError,
        );
      },
    );

    test('mismatched load reply preserves the initial source', () {
      final session = sessionWith('hello');
      final load = session.beginLoad()!;
      expectRejectedWithoutMutation(
        session,
        message('ready', 0, load['requestId']! as String, {'textLength': 4}),
      );
      expect(session.value.ready, isFalse);
    });

    test('a page reload cannot silently replace a live document', () {
      final session = sessionWith('hello');
      open(session);
      deliver(session, edit());
      expect(session.beginLoad(), isNull);
      expect(session.value.text, 'xhello');
      expect(session.value.revision, 1);
    });

    test('an edit before ready cannot mutate source', () {
      final session = sessionWith('hello');
      session.beginLoad();
      expectRejectedWithoutMutation(session, edit());
    });

    test('wrong document and generation have no current-session effects', () {
      final session = sessionWith('hello');
      open(session);
      final before = session.value;
      expect(
        deliver(session, {
          ...edit(),
          'generation': 'ffffffffffffffffffffffffffffffff',
        }),
        isNull,
      );
      expect(
        deliver(session, {...edit(), 'documentId': 'another-document'}),
        isNull,
      );
      expect(identical(session.value, before), isTrue);
      expect(deliver(session, edit())?['stage'], 'received');
    });
  });

  group('atomic revisions and duplicate requests', () {
    test('applies all ranges against the same base in one revision', () {
      final session = sessionWith('abcdef');
      open(session);
      final ack = deliver(
        session,
        message('edit', 1, 'editor-1', {
          'baseRevision': 0,
          'changes': [
            {'from': 1, 'to': 2, 'insert': 'XY'},
            {'from': 4, 'to': 6, 'insert': '!'},
          ],
          'selection': {'anchor': 3, 'head': 6},
        }),
      );
      expect(ack?['stage'], 'received');
      expect(session.value.text, 'aXYcd!');
      expect(session.value.revision, 1);
      expect(session.value.anchor, 3);
      expect(session.value.head, 6);
    });

    test('out-of-order base and revision gaps preserve existing text', () {
      for (final request in [
        edit(baseRevision: 1, revision: 2),
        edit(revision: 2),
      ]) {
        final session = sessionWith('abc');
        open(session);
        expectRejectedWithoutMutation(session, request);
      }
    });

    test('exact duplicate replays original receipt without applying twice', () {
      final session = sessionWith('abc');
      open(session);
      final request = edit();
      final ack = deliver(session, request);
      deliver(
        session,
        edit(baseRevision: 1, revision: 2, requestId: 'editor-2', insert: 'y'),
      );
      expect(deliver(session, request), ack);
      expect(session.value.text, 'yxabc');
      expect(session.value.revision, 2);
      expect(session.value.error, isNull);
    });

    test('duplicate ID with changed content faults without replacing text', () {
      final session = sessionWith('abc');
      open(session);
      deliver(session, edit());
      expectRejectedWithoutMutation(session, edit(insert: 'different'));
      expect(session.value.text, 'xabc');
    });

    test('evicted requests cannot be reapplied outside the 64-entry cache', () {
      final session = sessionWith('abc');
      open(session);
      final first = edit();
      deliver(session, first);
      for (var number = 2; number <= 66; number++) {
        deliver(
          session,
          message('selection', 1, 'editor-$number', {'anchor': 0, 'head': 0}),
        );
      }
      expectRejectedWithoutMutation(session, first);
      expect(session.value.text, 'xabc');
    });

    test('stale selection is ignored and future selection is rejected', () {
      final session = sessionWith('abc');
      open(session);
      deliver(session, edit(anchor: 1, head: 1));
      final before = session.value;
      expect(
        deliver(
          session,
          message('selection', 0, 'editor-2', {'anchor': 0, 'head': 0}),
        ),
        isNull,
      );
      expect(identical(session.value, before), isTrue);
      expectRejectedWithoutMutation(
        session,
        message('selection', 2, 'editor-3', {'anchor': 0, 'head': 0}),
      );
    });

    test('overlapping ranges reject the entire batch', () {
      final session = sessionWith('abcdef');
      open(session);
      expectRejectedWithoutMutation(
        session,
        message('edit', 1, 'editor-1', {
          'baseRevision': 0,
          'changes': [
            {'from': 1, 'to': 4, 'insert': 'x'},
            {'from': 3, 'to': 5, 'insert': 'y'},
          ],
          'selection': {'anchor': 0, 'head': 0},
        }),
      );
    });

    test('unaddressable envelopes fail without emitting invalid replies', () {
      for (final request in [
        {...edit(), 'v': 1},
        {...edit(), 'revision': 1.0},
        {...edit(), 'requestId': 'editor-01'},
      ]) {
        final session = sessionWith('abc');
        open(session);
        expect(deliver(session, request), isNull);
        expect(session.value.text, 'abc');
        expect(session.value.revision, 0);
        expect(session.value.error, isNotEmpty);
      }
    });

    test('strict envelope and field types fail closed', () {
      for (final request in [
        {...edit(), 'baseRevision': '0'},
        {...edit(), 'unexpected': true},
        {...edit(), 'type': 'nativeOpenFile'},
      ]) {
        final session = sessionWith('abc');
        open(session);
        expectRejectedWithoutMutation(session, request);
      }
    });
  });

  group('exact UTF-16 source boundaries', () {
    test('BOM, mixed endings, combining marks, and astral text survive', () {
      const text = '\ufeffA\r\n🌍é\n中\rZ';
      final session = sessionWith(text);
      open(session);
      final ack = deliver(
        session,
        edit(from: 4, to: 6, insert: '日本語', anchor: 7, head: 7),
      );
      expect(ack?['stage'], 'received');
      expect(session.value.text, '\ufeffA\r\n日本語é\n中\rZ');
    });

    test('surrogate and CRLF boundary splits are rejected', () {
      for (final offset in [2, 4]) {
        final session = sessionWith('A🌍\r\nZ');
        open(session);
        expectRejectedWithoutMutation(session, edit(from: offset, to: offset));
      }
    });

    test('invalid resulting selection rejects the whole valid text edit', () {
      final session = sessionWith('A🌍\r\nZ');
      open(session);
      expectRejectedWithoutMutation(
        session,
        edit(from: 6, to: 6, anchor: 2, head: 2),
      );
    });

    test('selection cannot bisect CRLF', () {
      final session = sessionWith('A\r\nZ');
      open(session);
      expectRejectedWithoutMutation(
        session,
        message('selection', 0, 'editor-1', {'anchor': 2, 'head': 2}),
      );
    });

    test('committed lone surrogates are rejected, not replacement-decoded', () {
      for (final unit in [0xd800, 0xdc00]) {
        final session = sessionWith('prior');
        open(session);
        expectRejectedWithoutMutation(
          session,
          edit(insert: String.fromCharCode(unit)),
        );
      }
    });

    test('initial invalid source is rejected rather than normalized', () {
      expect(
        () => EditorSession(
          initialText: String.fromCharCode(0xd800),
          documentId: documentId,
          baseVersion: baseHash,
          language: 'markdown',
          generationFactory: () => generation,
        ),
        throwsFormatException,
      );
    });

    test('whole CRLF and surrogate replacements are allowed', () {
      final session = sessionWith('A🌍\r\nZ');
      open(session);
      expect(
        deliver(
          session,
          edit(from: 1, to: 5, insert: '中\r', anchor: 3, head: 3),
        )?['stage'],
        'received',
      );
      expect(session.value.text, 'A中\rZ');
    });
  });

  group('resource limits preserve previous source', () {
    test('insert limit accepts its boundary and rejects one extra unit', () {
      final accepted = sessionWith('');
      open(accepted);
      expect(
        deliver(
          accepted,
          edit(insert: 'a' * EditorSession.maxInsertedUnits),
        )?['stage'],
        'received',
      );
      final rejected = sessionWith('prior');
      open(rejected);
      expectRejectedWithoutMutation(
        rejected,
        edit(insert: 'a' * (EditorSession.maxInsertedUnits + 1)),
      );
    });

    test('JSON length is checked before parsing malformed oversized input', () {
      final session = sessionWith('prior');
      open(session);
      expect(
        session.receive('x' * (EditorSession.maxEnvelopeBytes + 1)),
        isNull,
      );
      expect(session.value.text, 'prior');
      expect(session.value.revision, 0);
    });

    test('source byte limit applies independently of UTF-16 length', () {
      final session = sessionWith('é' * (EditorSession.maxSourceBytes ~/ 2));
      open(session);
      expectRejectedWithoutMutation(session, edit(insert: 'é'));
    });

    test('source UTF-16 limit prevents an additional ASCII unit', () {
      final session = sessionWith('a' * EditorSession.maxSourceUnits);
      open(session);
      expectRejectedWithoutMutation(session, edit());
    });

    test('too many ranges are rejected atomically', () {
      final session = sessionWith('prior');
      open(session);
      expectRejectedWithoutMutation(
        session,
        message('edit', 1, 'editor-1', {
          'baseRevision': 0,
          'changes': List.generate(
            EditorSession.maxChanges + 1,
            (_) => {'from': 0, 'to': 0, 'insert': 'x'},
          ),
          'selection': {'anchor': 0, 'head': 0},
        }),
      );
    });
  });

  group('correlated literal insertion', () {
    test('flush barrier precedes exact selection replacement and normal edit receipt', () async {
      final session = sessionWith('prior');
      open(session);
      final sent = <Map<String, Object?>>[];
      const link = '![日本語](assets/a%20b.png)\r\n</script>😀';
      var completed = false;
      final insertion = session
          .insertText(sent.add, link)
          .then((_) => completed = true);
      expect(sent.single['type'], 'selection');
      expect(sent.single['mode'], 'request');
      expect(sent.single.containsKey('text'), isFalse);
      expect(session.value.text, 'prior');
      // Composition/pending typing finishes before the page supplies its cursor.
      expect(deliver(session, edit(anchor: 1, head: 1))?['stage'], 'received');
      expect(
        deliver(
          session,
          currentSelection(sent.first, revision: 1, anchor: 6, head: 1),
        ),
        isNull,
      );
      final request = sent.last;
      expect(sent.length, 2);
      expect(request['type'], 'insert');
      expect(request['revision'], 1);
      expect(request['anchor'], 6);
      expect(request['head'], 1);
      expect(request['text'], link);
      expect(session.value.text, 'xprior');
      expect(
        deliver(
          session,
          edit(
            revision: 2,
            baseRevision: 1,
            requestId: 'editor-2',
            from: 1,
            to: 6,
            insert: link,
            anchor: link.length + 1,
            head: link.length + 1,
            operationId: request['requestId']! as String,
          ),
        )?['stage'],
        'received',
      );
      await Future<void>.value();
      expect(completed, isFalse);
      expect(session.value.text, 'x$link');
      expect(deliver(session, insertionReceipt(request, revision: 2)), isNull);
      await insertion;
      expect(completed, isTrue);
      expect(session.value.snapshotRevision, isNull);
      expect(session.baseVersion, baseHash);
      expect(session.value.ready, isTrue);
    });

    test(
      'stale selection barrier fails only insertion without a cursor retry',
      () async {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, '[a](assets/a)'),
          throwsStateError,
        );
        deliver(session, edit(anchor: 1, head: 1));
        expect(deliver(session, currentSelection(sent.first)), isNull);
        await failure;
        expect(sent.length, 1);
        expect(session.value.text, 'xabc');
        expect(session.value.ready, isTrue);
        expect(session.value.error, isNull);
        expect(
          deliver(
            session,
            edit(revision: 2, baseRevision: 1, requestId: 'editor-2'),
          )?['stage'],
          'received',
        );
      },
    );

    test(
      'selection rejection and malformed barrier never reject unrelated edits',
      () async {
        for (final fields in [
          {'mode': 'current', 'anchor': 2, 'head': 2},
          {'mode': 'set', 'anchor': 0, 'head': 0},
          {'mode': 'current', 'anchor': 0, 'head': 0, 'extra': true},
          {'mode': 'current', 'anchor': 0},
        ]) {
          final session = sessionWith('a😀');
          open(session);
          final sent = <Map<String, Object?>>[];
          final failure = expectLater(
            session.insertText(sent.add, 'link'),
            throwsStateError,
          );
          expect(
            deliver(
              session,
              message(
                'selection',
                0,
                sent.single['requestId']! as String,
                fields,
              ),
            ),
            isNull,
          );
          await failure;
          expect(sent.length, 1);
          expect(session.value.text, 'a😀');
          expect(session.value.ready, isTrue);
          expect(deliver(session, edit())?['stage'], 'received');
        }
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, 'link'),
          throwsStateError,
        );
        expect(
          deliver(
            session,
            message('ack', 0, sent.single['requestId']! as String, {
              'stage': 'rejected',
              'throughRevision': 0,
              'error': 'Composition could not finish',
            }),
          ),
          isNull,
        );
        await failure;
        expect(session.value.ready, isTrue);
      },
    );

    test('typing after the cursor barrier is retained on stale insertion rejection', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final failure = expectLater(
        session.insertText(sent.add, '[asset](assets/a)'),
        throwsStateError,
      );
      deliver(session, currentSelection(sent.first, anchor: 1, head: 1));
      deliver(session, edit(insert: 'typed', anchor: 5, head: 5));
      expect(
        deliver(
          session,
          message('ack', 1, sent.last['requestId']! as String, {
            'stage': 'rejected',
            'throughRevision': 1,
            'error': 'Selection changed before insertion',
          }),
        ),
        isNull,
      );
      await failure;
      expect(sent.length, 2);
      expect(session.value.text, 'typedabc');
      expect(session.value.ready, isTrue);
      expect(session.value.error, isNull);
      // Explicit later insertion obtains a NEW barrier; the controller never re-copies an asset.
      final later = session.insertText(sent.add, '[asset](assets/a)');
      final laterFailure = expectLater(later, throwsStateError);
      expect(sent.last['type'], 'selection');
      session.reportTransportError('Channel ended');
      await laterFailure;
    });

    test('malformed, early and stale insertion receipts fail without poisoning typing', () async {
      for (final corruption in <Map<String, Object?>>[
        {'stage': 'saved'},
        {'throughRevision': 0},
        {'throughRevision': '1'},
        {'revision': 0, 'throughRevision': 0},
        {'revision': -1},
        {'revision': 2, 'throughRevision': 2},
        {'v': 1},
        {'error': 7},
        {'extra': true},
      ]) {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, 'link'),
          throwsStateError,
        );
        deliver(session, currentSelection(sent.first));
        deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: sent.last['requestId']! as String));
        expect(
          deliver(session, {...insertionReceipt(sent.last), ...corruption}),
          isNull,
        );
        await failure;
        expect(session.value.text, 'linkabc');
        expect(session.value.ready, isTrue);
        expect(session.value.error, isNull);
        expect(
          deliver(
            session,
            edit(revision: 2, baseRevision: 1, requestId: 'editor-2'),
          )?['stage'],
          'received',
        );
      }
      for (final unrelatedEdit in [false, true]) {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, 'link'),
          throwsStateError,
        );
        deliver(session, currentSelection(sent.first));
        if (unrelatedEdit) deliver(session, edit(insert: 'not the link'));
        expect(deliver(session, insertionReceipt(sent.last)), isNull);
        await failure;
        expect(session.value.text, unrelatedEdit ? 'not the linkabc' : 'abc');
        expect(session.value.ready, isTrue);
      }
    });

    test('delayed receipt can settle the matching edit after subsequent ordinary typing', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final insertion = session.insertText(sent.add, 'link');
      deliver(session, currentSelection(sent.first));
      deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: sent.last['requestId']! as String));
      deliver(
        session,
        edit(revision: 2, baseRevision: 1, requestId: 'editor-2'),
      );
      expect(deliver(session, insertionReceipt(sent.last)), isNull);
      await insertion;
      expect(session.value.text, 'xlinkabc');
      expect(session.value.revision, 2);
      expect(session.value.snapshotRevision, isNull);
    });

    test('uncorrelated malformed acknowledgements cannot consume edit sequence numbers', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final insertion = session.insertText(sent.add, 'link');
      deliver(session, currentSelection(sent.single));
      expect(
        deliver(
          session,
          message('ack', 0, 'editor-900', {
            'stage': 'received',
            'throughRevision': 0,
          }),
        ),
        isNull,
      );
      expect(
        deliver(
          session,
          message('ack', 0, 'host-999', {
            'stage': 'received',
            'throughRevision': 0,
          }),
        ),
        isNull,
      );
      expect(
        deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: sent.last['requestId']! as String))?['stage'],
        'received',
      );
      deliver(session, insertionReceipt(sent.last));
      await insertion;
      expect(session.value.text, 'linkabc');
      expect(session.value.ready, isTrue);
      expect(session.value.error, isNull);
    });

    test('duplicate and evicted receipts cannot settle another insertion or freeze the session', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final insertion = session.insertText(sent.add, 'link');
      final barrier = sent.single;
      deliver(session, currentSelection(barrier));
      final request = sent.last;
      deliver(session, currentSelection(barrier));
      expect(sent.length, 2);
      deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: request['requestId']! as String));
      final receipt = insertionReceipt(request);
      deliver(session, receipt);
      await insertion;
      expect(deliver(session, receipt), isNull);
      expect(deliver(session, {...receipt, 'throughRevision': 999}), isNull);
      for (var index = 2; index < 70; index++) {
        deliver(
          session,
          message('selection', 1, 'editor-$index', {'anchor': 4, 'head': 4}),
        );
      }
      final nextFailure = expectLater(
        session.insertText(sent.add, 'second'),
        throwsStateError,
      );
      expect(deliver(session, receipt), isNull);
      expect(deliver(session, {...receipt, 'stage': 'malformed'}), isNull);
      expect(deliver(session, currentSelection(barrier)), isNull);
      expect(sent.length, 3);
      expect(session.value.ready, isTrue);
      deliver(
        session,
        message('ack', 1, sent.last['requestId']! as String, {
          'stage': 'rejected',
          'throughRevision': 1,
          'error': 'Cursor unavailable',
        }),
      );
      await nextFailure;
      expect(session.value.text, 'linkabc');
      expect(
        deliver(
          session,
          edit(revision: 2, baseRevision: 1, requestId: 'editor-70'),
        )?['stage'],
        'received',
      );
    });

    test(
      'one pending insertion and foreign-generation replies remain isolated',
      () async {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final insertion = session.insertText(sent.add, 'link');
        await expectLater(
          session.insertText(sent.add, 'other'),
          throwsStateError,
        );
        expect(sent.length, 1);
        expect(
          deliver(session, {
            ...currentSelection(sent.single),
            'generation': 'f' * 32,
          }),
          isNull,
        );
        expect(sent.length, 1);
        deliver(session, currentSelection(sent.single));
        deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: sent.last['requestId']! as String));
        expect(
          deliver(session, {
            ...insertionReceipt(sent.last),
            'generation': 'f' * 32,
          }),
          isNull,
        );
        deliver(session, insertionReceipt(sent.last));
        await insertion;
        expect(session.value.text, 'linkabc');
      },
    );

    test('source/control bounds reject before sending and document bounds reject before inserting', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      for (final text in [
        String.fromCharCode(0xd800),
        String.fromCharCode(0xdc00),
        'x' * (EditorSession.maxInsertedUnits + 1),
        '中' * 3000,
        '\u0000' * 1400,
      ]) {
        await expectLater(
          session.insertText(sent.add, text),
          throwsFormatException,
        );
      }
      expect(sent, isEmpty);
      expect(session.value.text, 'abc');
      expect(session.value.ready, isTrue);
      for (final source in [
        'a' * EditorSession.maxSourceUnits,
        '中' * (EditorSession.maxSourceBytes ~/ 3),
      ]) {
        final full = sessionWith(source);
        open(full);
        final requests = <Map<String, Object?>>[];
        final failure = expectLater(
          full.insertText(requests.add, '中'),
          throwsStateError,
        );
        deliver(full, currentSelection(requests.single));
        await failure;
        expect(requests.length, 1);
        expect(full.value.text, source);
        expect(full.value.ready, isTrue);
      }
      final pair = sessionWith('\n');
      open(pair);
      final requests = <Map<String, Object?>>[];
      final failure = expectLater(
        pair.insertText(requests.add, '\r'),
        throwsStateError,
      );
      deliver(pair, currentSelection(requests.single));
      await failure;
      expect(requests.length, 1);
      expect(pair.value.text, '\n');
    });

    test('transport loss settles either barrier phase while preserving all received text', () async {
      for (final afterEdit in [false, true]) {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, 'link'),
          throwsStateError,
        );
        if (afterEdit) {
          deliver(session, currentSelection(sent.single));
          deliver(session, edit(insert: 'link', anchor: 4, head: 4, operationId: sent.last['requestId']! as String));
        }
        session.reportTransportError('Channel disconnected');
        await failure;
        expect(session.value.text, afterEdit ? 'linkabc' : 'abc');
        expect(session.value.ready, isFalse);
      }
    });

    test(
      'synchronous send failures settle insertion without mutating source',
      () async {
        for (final failInsert in [false, true]) {
          final session = sessionWith('abc');
          open(session);
          final failure = expectLater(
            session.insertText((request) {
              if (failInsert && request['type'] == 'selection') {
                deliver(session, currentSelection(request));
              } else {
                throw StateError('Channel unavailable');
              }
            }, 'link'),
            throwsStateError,
          );
          await failure;
          expect(session.value.text, 'abc');
          expect(session.value.ready, isFalse);
        }
      },
    );

    test(
      'close and disposal retire insertion futures without dropping source',
      () async {
        final session = sessionWith('abc');
        open(session);
        final sent = <Map<String, Object?>>[];
        final failure = expectLater(
          session.insertText(sent.add, 'link'),
          throwsStateError,
        );
        final close = session.quiesce(sent.add);
        await failure;
        expect(deliver(session, currentSelection(sent.first)), isNull);
        expect(sent.length, 2);
        deliver(
          session,
          message('close', 0, sent.last['requestId']! as String, {
            'mode': 'quiesced',
            'anchor': 0, 'head': 0,
          }),
        );
        await close;
        expect(session.value.text, 'abc');
        final retired = EditorSession(
          initialText: 'keep',
          documentId: documentId,
          baseVersion: baseHash,
          language: 'markdown',
          generationFactory: () => generation,
        );
        open(retired);
        final retiredFailure = expectLater(
          retired.insertText((_) {}, 'link'),
          throwsStateError,
        );
        retired.dispose();
        await retiredFailure;
        expect(retired.value.text, 'keep');
        expect(deliver(retired, edit()), isNull);
      },
    );

    test('synchronous channel reentrancy still requires the real edit before completion', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <String>[];
      await session.insertText((request) {
        sent.add(request['type']! as String);
        if (request['type'] == 'selection') {
          deliver(session, currentSelection(request, anchor: 1, head: 1));
        } else {
          expect(
            deliver(
              session,
              edit(from: 1, to: 1, insert: 'link', anchor: 5, head: 5, operationId: request['requestId']! as String),
            )?['stage'],
            'received',
          );
          expect(deliver(session, insertionReceipt(request)), isNull);
        }
      }, 'link');
      expect(sent, ['selection', 'insert']);
      expect(session.value.text, 'alinkbc');
      expect(session.value.ready, isTrue);
    });
  });

  group('durable prefixes and source barriers', () {
    test('validated immutable deltas precede receipt and duplicate admission is once', () {
      final session = sessionWith('base');
      open(session);
      final batches = <EditorEditBatch>[];
      session.onEdit = (batch) {
        expect(session.value.revision, 0);
        expect(batch.documentId, documentId);
        expect(batch.generation, generation);
        expect(batch.baseRevision, 0);
        expect(batch.revision, 1);
        expect(batch.wireBytes, greaterThan(0));
        expect(() => batch.changes.add(const EditorChange(0, 0, 'bad')), throwsUnsupportedError);
        batches.add(batch);
      };
      final request = edit(insert: '日本😀', anchor: 4, head: 4);
      final received = deliver(session, request);
      expect(received?['stage'], 'received');
      expect(deliver(session, request), received);
      expect(batches, hasLength(1));
      expect(batches.single.toJson()['selection'], {'anchor': 4, 'head': 4});
      expect(batches.single.toJson().containsKey('text'), isFalse);
      expect(session.value.draftDurableRevision, 0);
      expect(session.value.savedRevision, 0);
    });

    test('reentrant listeners cannot retarget an earlier received acknowledgement', () {
      final session = sessionWith('base');
      open(session);
      session.addListener(() {
        if (session.value.revision == 1) {
          deliver(session, edit(revision: 2, baseRevision: 1, requestId: 'editor-2', insert: 'y'));
        }
      });
      final first = deliver(session, edit())!;
      expect(first['requestId'], 'editor-1');
      expect(first['throughRevision'], 1);
      expect(first['revision'], 1);
      expect(session.value.revision, 2);
      expect(session.value.text, 'yxbase');
    });

    test('typing during flush notification cannot retarget its captured source', () async {
      final session = sessionWith('base');
      open(session);
      deliver(session, edit());
      final sent = <Map<String, Object?>>[];
      final flush = session.flushSource(sent.add);
      session.addListener(() {
        if (session.value.snapshotRevision == 1 && session.value.revision == 1) {
          deliver(session, edit(revision: 2, baseRevision: 1, requestId: 'editor-2', insert: 'y'));
        }
      });
      deliver(session, message('flush', 1, sent.single['requestId']! as String,
        {'mode': 'ready', 'anchor': 0, 'head': 0}));
      final captured = await flush;
      expect(captured.revision, 1);
      expect(captured.text, 'xbase');
      expect(session.value.revision, 2);
      expect(session.value.text, 'yxbase');
    });

    test('new checkpointed epochs preserve cursor but do not inherit integer watermarks', () {
      final session = EditorSession(initialText: 'a😀\r\nb', documentId: documentId,
        baseVersion: baseHash, language: 'markdown', generationFactory: () => 'f' * 32,
        initiallySaved: false, initialAnchor: 5, initialHead: 1);
      addTearDown(session.dispose);
      final load = session.beginLoad()!;
      expect(load['selection'], {'anchor': 5, 'head': 1});
      expect(load['revision'], 0);
      expect(load['generation'], 'f' * 32);
      expect(session.value.savedRevision, isNull);
      expect(session.acknowledgeSaved(EditorCapture(documentId, generation, 0)), isNull);
      expect(() => EditorSession(initialText: 'a😀\r\nb', documentId: documentId,
        baseVersion: baseHash, language: 'markdown', initialAnchor: 2), throwsFormatException);
    });

    test('failed admission cannot acknowledge or replace the accepted mirror', () {
      final session = sessionWith('base');
      open(session);
      session.onEdit = (_) => throw StateError('quota exhausted');
      expect(deliver(session, edit())?['stage'], 'rejected');
      expect(session.value.text, 'base');
      expect(session.value.revision, 0);
      expect(session.value.draftDurableRevision, 0);
    });

    test('saved R cannot clean later R+1 and durability cannot jump received', () {
      final session = sessionWith('base');
      open(session);
      deliver(session, edit());
      final first = session.capture;
      expect(() => session.acknowledgeSaved(first), throwsFormatException);
      expect(session.acknowledgeDraftDurable(first)?['stage'], 'draftDurable');
      deliver(session, edit(revision: 2, baseRevision: 1, requestId: 'editor-2', insert: 'y'));
      final saved = session.acknowledgeSaved(first)!;
      expect(saved['revision'], 1);
      expect(saved['throughRevision'], 1);
      expect(session.value.savedRevision, 1);
      expect(session.value.locallySaved, isFalse);
      expect(session.value.text, 'yxbase');
      expect(() => session.acknowledgeDraftDurable(EditorCapture(documentId, generation, 3)), throwsFormatException);
      expect(session.acknowledgeSaved(EditorCapture(documentId, 'f' * 32, 2)), isNull);
      session.acknowledgeDraftDurable(session.capture);
      session.acknowledgeSaved(session.capture);
      expect(session.value.locallySaved, isTrue);
      expect(session.acknowledgeSaved(first), isNull);
      expect(session.value.savedRevision, 2);
    });

    test('a recovered revision zero has no saved authority from its integer', () {
      final session = EditorSession(initialText: 'recovered', documentId: documentId,
        baseVersion: baseHash, language: 'markdown', generationFactory: () => generation, initiallySaved: false);
      addTearDown(session.dispose);
      open(session);
      expect(session.value.savedRevision, isNull);
      expect(session.value.locallySaved, isFalse);
      expect(session.acknowledgeSaved(EditorCapture(documentId, 'e' * 32, 0)), isNull);
      expect(session.value.savedRevision, isNull);
    });

    test('received acknowledgements do not replenish 32 undurable edit credits', () {
      final session = sessionWith('base');
      open(session);
      for (var revision = 1; revision <= 32; revision++) {
        expect(deliver(session, edit(revision: revision, baseRevision: revision - 1,
          requestId: 'editor-$revision'))?['stage'], 'received');
      }
      expectRejectedWithoutMutation(session, edit(revision: 33, baseRevision: 32, requestId: 'editor-33'));
      expect(session.value.revision, 32);
      expect(session.value.draftDurableRevision, 0);
      final other = sessionWith('base');
      open(other);
      for (var revision = 1; revision <= 40; revision++) {
        expect(deliver(other, edit(revision: revision, baseRevision: revision - 1,
          requestId: 'editor-$revision'))?['stage'], 'received');
        other.acknowledgeDraftDurable(other.capture);
      }
      expect(other.value.revision, 40);
      expect(other.value.savedRevision, 0);
    });

    test('encoded durable-byte ceiling is independent of batch count', () {
      final session = sessionWith('');
      open(session);
      var retained = 0;
      for (var revision = 1; revision <= 32; revision++) {
        final request = edit(revision: revision, baseRevision: revision - 1,
          requestId: 'editor-$revision', insert: '\u0000' * EditorSession.maxInsertedUnits);
        final bytes = utf8.encode(jsonEncode(request)).length;
        if (retained + bytes > 8 * 1024 * 1024) {
          expect(revision, lessThan(32));
          expectRejectedWithoutMutation(session, request);
          expect(session.value.revision, revision - 1);
          return;
        }
        expect(deliver(session, request)?['stage'], 'received');
        retained += bytes;
      }
      fail('Encoded byte credit must be exhausted before the batch ceiling.');
    });

    test('pending and composition activity prevent a false locally-saved state', () {
      final session = sessionWith('base');
      open(session);
      deliver(session, message('activity', 0, 'editor-1', {'sequence': 1, 'pending': true, 'composing': false}));
      expect(session.value.locallySaved, isFalse);
      deliver(session, message('activity', 0, 'editor-2', {'sequence': 2, 'pending': false, 'composing': true}));
      deliver(session, message('activity', 0, 'editor-1', {'sequence': 1, 'pending': false, 'composing': false}));
      expect(session.value.composing, isTrue);
      deliver(session, message('activity', 0, 'editor-3', {'sequence': 3, 'pending': false, 'composing': false}));
      expect(session.value.locallySaved, isTrue);
    });

    test('flush returns exact mirror capture without a whole-source transfer', () async {
      final session = sessionWith('base\r\n😀');
      open(session);
      final sent = <Map<String, Object?>>[];
      final capture = session.flushSource(sent.add);
      expect(sent.single['type'], 'flush');
      expect(sent.single.containsKey('text'), isFalse);
      await expectLater(session.flushSource(sent.add), throwsStateError);
      deliver(session, edit(anchor: 1, head: 1));
      final response = message('flush', 1, sent.single['requestId']! as String,
        {'mode': 'ready', 'anchor': 1, 'head': 1});
      expect(deliver(session, response), isNull);
      final snapshot = await capture;
      expect(snapshot.text, 'xbase\r\n😀');
      expect(snapshot.generation, generation);
      expect(snapshot.revision, 1);
      expect(snapshot.anchor, 1);
      expect(session.value.savedRevision, 0);
      deliver(session, edit(revision: 2, baseRevision: 1, requestId: 'editor-2'));
      expect(deliver(session, response), isNull);
      expect(session.value.revision, 2);
      expect(session.canFlushSource, isTrue);
    });

    test('stale or refused flush never substitutes another source prefix', () async {
      for (final rejected in [false, true]) {
        final session = sessionWith('base');
        open(session);
        late Map<String, Object?> request;
        final failure = expectLater(session.flushSource((value) => request = value), throwsStateError);
        deliver(session, edit());
        deliver(session, rejected ? message('ack', 1, request['requestId']! as String,
          {'stage': 'rejected', 'throughRevision': 1, 'error': 'Composition active'})
          : message('flush', 0, request['requestId']! as String, {'mode': 'ready', 'anchor': 0, 'head': 0}));
        await failure;
        expect(session.value.text, 'xbase');
        expect(session.value.ready, isTrue);
        expect(session.canFlushSource, isTrue);
      }
    });

    test('quiesce captures final composition then durable retain commits close', () async {
      final session = sessionWith('base');
      open(session);
      final sent = <Map<String, Object?>>[];
      final quiesce = session.quiesce(sent.add);
      expect(session.value.closing, isTrue);
      expect(session.value.closed, isFalse);
      deliver(session, edit());
      deliver(session, message('close', 1, sent.last['requestId']! as String,
        {'mode': 'quiesced', 'anchor': 0, 'head': 0}));
      final captured = await quiesce;
      expect(session.value.quiesced, isTrue);
      await expectLater(session.completeClose(sent.add, capture: captured, discard: false), throwsStateError);
      session.acknowledgeDraftDurable(captured);
      final close = session.completeClose(sent.add, capture: captured, discard: false);
      expect(sent.last['disposition'], 'retained');
      deliver(session, message('close', 1, sent.last['requestId']! as String, {'mode': 'closed'}));
      await close;
      expect(session.value.closed, isTrue);
      expect(session.value.savedRevision, 0);
      expect(session.value.text, 'xbase');
    });

    test('storage failure abort restores editing without claiming a save', () async {
      final session = sessionWith('base');
      open(session);
      final sent = <Map<String, Object?>>[];
      final barrier = session.quiesce(sent.add);
      deliver(session, edit());
      deliver(session, message('close', 1, sent.last['requestId']! as String,
        {'mode': 'quiesced', 'anchor': 0, 'head': 0}));
      final captured = await barrier;
      await expectLater(session.completeClose(sent.add, capture: EditorCapture(documentId, generation, 0), discard: true), throwsStateError);
      expect(captured.text, 'xbase');
      final abort = session.abortClose(sent.add);
      deliver(session, message('close', 1, sent.last['requestId']! as String, {'mode': 'aborted'}));
      await abort;
      expect(session.value.quiesced, isFalse);
      expect(session.value.closing, isFalse);
      expect(deliver(session, edit(revision: 2, baseRevision: 1, requestId: 'editor-2'))?['stage'], 'received');
      expect(session.value.savedRevision, 0);
    });

    testWidgets('composition timeout cannot complete close and sends an abort', (tester) async {
      final session = sessionWith('base');
      open(session);
      final sent = <Map<String, Object?>>[];
      final failure = expectLater(session.quiesce(sent.add), throwsStateError);
      await tester.pump(const Duration(seconds: 6));
      await failure;
      expect(sent.last['mode'], 'abort');
      expect(session.value.closed, isFalse);
      deliver(session, message('close', 0, sent.last['requestId']! as String, {'mode': 'aborted'}));
      await tester.pump();
      expect(session.value.text, 'base');
    });

    test('divergent resync is bounded evidence, never mirror replacement', () async {
      final session = sessionWith('base');
      open(session);
      session.reportTransportError('Transport gap');
      final sent = <Map<String, Object?>>[];
      final pending = session.requestResync(sent.add);
      deliver(session, message('resync', 3, sent.single['requestId']! as String,
        {'mode': 'candidate', 'text': 'other live text', 'anchor': 0, 'head': 0}));
      final candidate = await pending;
      expect(candidate.text, 'other live text');
      expect(session.value.text, 'base');
      expect(session.value.revision, 0);
      await expectLater(session.requestResync(sent.add), throwsStateError);
      await expectLater(session.resumeResync(sent.add), throwsStateError);
      expect(session.value.resyncCandidate, same(candidate));
    });

    test('bounded replay closes a transport gap before exact resync resume', () async {
      final session = sessionWith('base');
      open(session);
      final second = edit(revision: 2, baseRevision: 1, requestId: 'editor-2', insert: 'y');
      expect(deliver(session, second)?['stage'], 'rejected');
      final sent = <Map<String, Object?>>[];
      final pending = session.requestResync(sent.add);
      expect(deliver(session, edit())?['stage'], 'received');
      expect(deliver(session, second)?['stage'], 'received');
      deliver(session, message('resync', 2, sent.single['requestId']! as String,
        {'mode': 'candidate', 'text': 'yxbase', 'anchor': 0, 'head': 0}));
      await pending;
      final resume = session.resumeResync(sent.add);
      deliver(session, message('resync', 2, sent.last['requestId']! as String, {'mode': 'resumed'}));
      await resume;
      expect(session.value.ready, isTrue);
      expect(session.value.error, isNull);
      expect(session.value.text, 'yxbase');
      expect(session.value.draftDurableRevision, 0);
      expect(session.value.savedRevision, 0);
    });

    test('formatting shares insertion correlation and cannot imply persistence', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final operation = session.format(sent.add, const EditorFormat('bold'));
      await expectLater(session.insertText(sent.add, 'other'), throwsStateError);
      deliver(session, currentSelection(sent.first, anchor: 3, head: 0));
      final request = sent.last;
      expect(request['type'], 'format');
      expect(request['anchor'], 3);
      final batch = message('edit', 1, 'editor-1', {'baseRevision': 0,
        'operationId': request['requestId'], 'changes': [
          {'from': 0, 'to': 0, 'insert': '**'}, {'from': 3, 'to': 3, 'insert': '**'}],
        'selection': {'anchor': 5, 'head': 2}});
      expect(deliver(session, batch)?['stage'], 'received');
      deliver(session, insertionReceipt(request));
      await operation;
      expect(session.value.text, '**abc**');
      expect(session.value.savedRevision, 0);
      expect(session.value.draftDurableRevision, 0);
      final noChange = session.format(sent.add, const EditorFormat('heading', level: 2));
      deliver(session, currentSelection(sent.last, revision: 1, anchor: 5, head: 2));
      deliver(session, {...insertionReceipt(sent.last), 'changed': false});
      await noChange;
      expect(session.value.revision, 1);
    });

    test('identical insertion has explicit no-change receipt and no durable obligation', () async {
      final session = sessionWith('abc');
      open(session);
      final sent = <Map<String, Object?>>[];
      final operation = session.insertText(sent.add, 'abc');
      deliver(session, currentSelection(sent.single, anchor: 3, head: 0));
      deliver(session, {...insertionReceipt(sent.last, revision: 0), 'changed': false});
      await operation;
      expect(session.value.revision, 0);
      expect(session.value.savedRevision, 0);
      expect(session.value.text, 'abc');
    });

    test('preferences never reload or modify source, revision or directed selection', () {
      final session = sessionWith('base');
      open(session);
      final before = session.value;
      final preferences = session.preferences(dark: true, highContrast: true, fontScale: 2, reducedMotion: true)!;
      expect(preferences['type'], 'preferences');
      expect(preferences['fontScale'], 2);
      expect(session.value, same(before));
      expect(() => session.preferences(dark: true, fontScale: double.nan), throwsArgumentError);
    });

    test('transport failure settles a pending flush and retains source', () async {
      final session = sessionWith('base');
      open(session);
      final failure = expectLater(session.flushSource((_) {}), throwsStateError);
      session.reportTransportError('Channel unavailable');
      await failure;
      expect(session.value.text, 'base');
      expect(session.value.ready, isFalse);
    });
  });
}
