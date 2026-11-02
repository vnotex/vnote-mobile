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
  'v': 1,
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
}) => message('edit', revision, requestId, {
  'baseRevision': baseRevision,
  'changes': [
    {'from': from, 'to': to, 'insert': insert},
  ],
  'selection': {'anchor': anchor, 'head': head},
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
        {...edit(), 'v': 2},
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
        {'v': 2},
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
        deliver(session, edit(insert: 'link', anchor: 4, head: 4));
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
      deliver(session, edit(insert: 'link', anchor: 4, head: 4));
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
        deliver(session, edit(insert: 'link', anchor: 4, head: 4))?['stage'],
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
      deliver(session, edit(insert: 'link', anchor: 4, head: 4));
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
        deliver(session, edit(insert: 'link', anchor: 4, head: 4));
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
          deliver(session, edit(insert: 'link', anchor: 4, head: 4));
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
        final close = session.closeEditor(sent.add, discard: true);
        await failure;
        expect(deliver(session, currentSelection(sent.first)), isNull);
        expect(sent.length, 2);
        deliver(
          session,
          message('close', 0, sent.last['requestId']! as String, {
            'mode': 'ready',
            'disposition': 'discard',
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
              edit(from: 1, to: 1, insert: 'link', anchor: 5, head: 5),
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

  group('controls never imply persistence', () {
    test('snapshot is exact with one transfer pending and repeatable after receipt', () {
      final session = sessionWith('prior\r\n🌍');
      open(session);
      final request = session.requestSnapshot()!;
      expect(session.requestSnapshot(), isNull);
      final ack = deliver(
        session,
        message('save', 0, request['requestId']! as String, {
          'mode': 'snapshot',
          'text': session.value.text,
        }),
      );
      expect(ack?['stage'], 'received');
      expect(session.value.snapshotRevision, 0);
      expect(session.value.text, 'prior\r\n🌍');
      expect(session.canRequestSnapshot, isTrue);
      final next = session.requestSnapshot()!;
      expect(next['requestId'], isNot(request['requestId']));
      expect(
        deliver(
          session,
          message('save', 0, next['requestId']! as String, {
            'mode': 'snapshot',
            'text': session.value.text,
          }),
        )?['stage'],
        'received',
      );
    });

    test('snapshot mismatch cannot overwrite the mirror', () {
      final session = sessionWith('prior');
      open(session);
      final request = session.requestSnapshot()!;
      expectRejectedWithoutMutation(
        session,
        message('save', 0, request['requestId']! as String, {
          'mode': 'snapshot',
          'text': 'other',
        }),
      );
    });

    test(
      'snapshot revision may advance past the requested lower bound',
      () async {
        final session = sessionWith('prior');
        open(session);
        late Map<String, Object?> request;
        final capture = session.captureSnapshot((message) => request = message);
        deliver(session, edit());
        expect(
          deliver(
            session,
            message('save', 1, request['requestId']! as String, {
              'mode': 'snapshot',
              'text': session.value.text,
            }),
          )?['stage'],
          'received',
        );
        final snapshot = await capture;
        expect(snapshot.revision, 1);
        expect(snapshot.text, 'xprior');
        expect(session.canRequestSnapshot, isTrue);
      },
    );

    test('retired full snapshots cannot mutate or replay large source', () {
      final session = sessionWith('prior');
      open(session);
      final request = session.requestSnapshot()!;
      final response = message('save', 0, request['requestId']! as String, {
        'mode': 'snapshot',
        'text': 'prior',
      });
      deliver(session, response);
      deliver(session, edit());
      expect(deliver(session, response), isNull);
      expect(deliver(session, {...response, 'text': 'changed'}), isNull);
      expect(session.value.text, 'xprior');
      expect(session.value.error, isNull);
    });

    test(
      'a snapshot must equal the current mirror revision, not an old one',
      () {
        final session = sessionWith('prior');
        open(session);
        final request = session.requestSnapshot()!;
        deliver(session, edit());
        expectRejectedWithoutMutation(
          session,
          message('save', 0, request['requestId']! as String, {
            'mode': 'snapshot',
            'text': session.value.text,
          }),
        );
      },
    );

    test('an unrequested snapshot is never a write request', () {
      final session = sessionWith('prior');
      open(session);
      expectRejectedWithoutMutation(
        session,
        message('save', 0, 'editor-1', {'mode': 'snapshot', 'text': 'prior'}),
      );
    });

    test('close needs discard consent and an exact final revision', () async {
      final session = sessionWith('prior');
      open(session);
      late Map<String, Object?> close;
      final barrier = session.closeEditor(
        (message) => close = message,
        discard: true,
      );
      expect(session.value.closing, isTrue);
      expect(session.value.closed, isFalse);
      // Final composition edits are still accepted before close-ready.
      expect(deliver(session, edit())?['stage'], 'received');
      expect(
        deliver(
          session,
          message('close', 1, close['requestId']! as String, {
            'mode': 'ready',
            'disposition': 'discard',
          }),
        ),
        isNull,
      );
      expect(session.value.closed, isTrue);
      expect(session.value.text, 'xprior');
      await barrier;
    });

    test('unsolicited close cannot retire the current session', () {
      final session = sessionWith('prior');
      open(session);
      expectRejectedWithoutMutation(
        session,
        message('close', 0, 'editor-1', {
          'mode': 'ready',
          'disposition': 'discard',
        }),
      );
      expect(session.value.closed, isFalse);
    });

    test(
      'written close refusal preserves an editable session for newer input',
      () async {
        final session = sessionWith('prior');
        open(session);
        late Map<String, Object?> close;
        final barrier = session.closeEditor(
          (message) => close = message,
          discard: false,
        );
        final failure = expectLater(barrier, throwsStateError);
        deliver(session, edit());
        deliver(
          session,
          message('ack', 1, close['requestId']! as String, {
            'stage': 'rejected',
            'throughRevision': 1,
            'error': 'Newer pending input',
          }),
        );
        await failure;
        expect(session.value.closed, isFalse);
        expect(session.value.closing, isFalse);
        expect(session.value.ready, isTrue);
        expect(session.canRequestSnapshot, isTrue);
      },
    );

    test('written close cannot advance beyond the approved revision', () async {
      final session = sessionWith('prior');
      open(session);
      late Map<String, Object?> close;
      final barrier = session.closeEditor(
        (message) => close = message,
        discard: false,
      );
      final failure = expectLater(barrier, throwsStateError);
      deliver(session, edit());
      expectRejectedWithoutMutation(
        session,
        message('close', 1, close['requestId']! as String, {
          'mode': 'ready',
          'disposition': 'written',
        }),
      );
      await failure;
      expect(session.value.closed, isFalse);
    });

    test(
      'composition snapshot refusal is recoverable without changing source',
      () async {
        final session = sessionWith('prior');
        open(session);
        late Map<String, Object?> request;
        final snapshot = session.captureSnapshot(
          (message) => request = message,
        );
        final failure = expectLater(snapshot, throwsStateError);
        deliver(
          session,
          message('ack', 0, request['requestId']! as String, {
            'stage': 'rejected',
            'throughRevision': 0,
            'error': 'Uncommitted composition',
          }),
        );
        await failure;
        expect(session.value.text, 'prior');
        expect(session.value.ready, isTrue);
        expect(session.canRequestSnapshot, isTrue);
      },
    );

    test(
      'transport failure completes a pending snapshot without dropping source',
      () async {
        final session = sessionWith('prior');
        open(session);
        final capture = session.captureSnapshot((_) {});
        final failure = expectLater(capture, throwsStateError);
        session.reportTransportError('Channel unavailable');
        await failure;
        expect(session.value.text, 'prior');
        expect(session.value.ready, isFalse);
      },
    );

    test('editor rejection is never acknowledged or marked saved', () {
      final session = sessionWith('prior');
      open(session);
      final request = session.command('undo')!;
      expect(
        deliver(
          session,
          message('ack', 0, request['requestId']! as String, {
            'stage': 'rejected',
            'throughRevision': 0,
            'error': 'composition active',
          }),
        ),
        isNull,
      );
      expect(session.value.text, 'prior');
    });
  });
}
