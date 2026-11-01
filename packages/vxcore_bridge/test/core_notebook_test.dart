// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

final class _Fixture {
  _Fixture(this.root);

  final Directory root;
  final hosts = <CoreNotebook>[];
  String path(String child) => '${root.path}${Platform.pathSeparator}$child';
  File get note => File('${path('book')}${Platform.pathSeparator}Welcome.md');

  Future<CoreNotebook> open({String initial = 'initial\r\n'}) async {
    final host = await CoreNotebook.open(
      appDataPath: path('app'),
      localDataPath: path('local'),
      notebookPath: path('book'),
      notebookName: 'Personal',
      notePath: 'Welcome.md',
      initialText: initial,
    );
    hosts.add(host);
    return host;
  }

  Future<void> dispose() async {
    for (final host in hosts) {
      await host.close();
    }
    await root.delete(recursive: true);
  }
}

Matcher _code(int code) => isA<CoreException>().having(
  (error) => error.code,
  'actual core error code',
  code,
);

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture(await Directory.systemTemp.createTemp('vnote-ffi-'));
  });
  tearDown(() => fixture.dispose());

  test('real UTF8 and CRLF source survives write, close and reopen with stable IDs', () async {
    const source = '\ufeff# 中文 😀\r\ne\u0301\r\nالعربية\rlast\n';
    final first = await fixture.open(initial: source);
    final opened = await first.read();
    expect(opened.text, source);
    expect(opened.baseHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(opened.lineEnding, 0);
    expect(await fixture.note.readAsBytes(), utf8.encode(source));

    const edited = '$source\n日本語 edited 😀\r\n';
    final written = await first.write(
      edited,
      revision: 7,
      baseHash: opened.baseHash,
    );
    expect(written.revision, 7);
    expect(written.baseHash, isNot(opened.baseHash));
    final read = await first.read();
    expect(read.text, edited);
    expect(read.baseHash, written.baseHash);
    expect(read.nodeId, opened.nodeId);
    expect(await fixture.note.readAsBytes(), utf8.encode(edited));
    final closing = first.close();
    expect(identical(closing, first.close()), isTrue);
    await closing;
    await expectLater(first.read(), throwsA(_code(10)));
    await expectLater(
      first.write('closed', revision: 8, baseHash: written.baseHash),
      throwsA(_code(10)),
    );

    final reopened = await fixture.open(
      initial: 'this must not recreate anything',
    );
    final restored = await reopened.read();
    expect(restored.notebookId, opened.notebookId);
    expect(restored.nodeId, opened.nodeId);
    expect(restored.text, edited);
    expect(restored.baseHash, written.baseHash);
  });

  test(
    'empty source is written and reopened without null-pointer ambiguity',
    () async {
      final host = await fixture.open(initial: 'erase this');
      final base = await host.read();
      final written = await host.write(
        '',
        revision: 1,
        baseHash: base.baseHash,
      );
      expect(await fixture.note.readAsBytes(), isEmpty);
      await host.close();
      final reopened = await fixture.open(
        initial: 'do not replace an empty note',
      );
      final note = await reopened.read();
      expect(note.text, '');
      expect(note.nodeId, base.nodeId);
      expect(note.baseHash, written.baseHash);
    },
  );

  test(
    'same-mtime external bytes conflict before set/save and remain intact',
    () async {
      final host = await fixture.open(initial: 'old text\r\n');
      final base = await host.read();
      final modified = await fixture.note.lastModified();
      const external =
          'new text\r\n'; // Same length; no size or mtime shortcut works.
      await fixture.note.writeAsBytes(utf8.encode(external), flush: true);
      await fixture.note.setLastModified(modified);
      await expectLater(
        host.write(
          'unsaved editor source',
          revision: 1,
          baseHash: base.baseHash,
        ),
        throwsA(_code(18)),
      );
      expect(await fixture.note.readAsBytes(), utf8.encode(external));
      final fresh = await host.read();
      expect(fresh.text, external);
      expect(fresh.baseHash, isNot(base.baseHash));
      final written = await host.write(
        'explicit retry\r\n',
        revision: 1,
        baseHash: fresh.baseHash,
      );
      expect(written.revision, 1);
      expect((await host.read()).text, 'explicit retry\r\n');
    },
  );

  test(
    'invalid Unicode, oversized input and stale revisions never change disk',
    () async {
      final host = await fixture.open();
      final base = await host.read();
      await expectLater(
        host.write(
          String.fromCharCode(0xd800),
          revision: 1,
          baseHash: base.baseHash,
        ),
        throwsA(_code(14)),
      );
      await expectLater(
        host.write(
          'x' * (4 * 1024 * 1024 + 1),
          revision: 1,
          baseHash: base.baseHash,
        ),
        throwsA(_code(1)),
      );
      await expectLater(
        host.write(
          '😀' * (1024 * 1024 + 1),
          revision: 1,
          baseHash: base.baseHash,
        ),
        throwsA(_code(1)),
      );
      await expectLater(
        host.write('invalid', revision: -1, baseHash: base.baseHash),
        throwsA(_code(1)),
      );
      await expectLater(
        host.write('invalid', revision: 1, baseHash: 'not a hash'),
        throwsA(_code(1)),
      );
      expect((await host.read()).text, base.text);
      final written = await host.write(
        'revision two',
        revision: 2,
        baseHash: base.baseHash,
      );
      await expectLater(
        host.write('stale', revision: 1, baseHash: written.baseHash),
        throwsA(_code(10)),
      );
      expect(await fixture.note.readAsString(), 'revision two');
    },
  );

  test(
    'invalid source encoding and missing indexed file are not repaired',
    () async {
      final first = await fixture.open();
      final initial = await first.read();
      await fixture.note.writeAsBytes([0xff, 0xfe, 0x61, 0], flush: true);
      await expectLater(first.read(), throwsA(_code(14)));
      await expectLater(
        first.write('never replace', revision: 1, baseHash: initial.baseHash),
        throwsA(_code(14)),
      );
      expect(await fixture.note.readAsBytes(), [0xff, 0xfe, 0x61, 0]);
      await first.close();
      await expectLater(
        fixture.open(initial: 'never decode-repair'),
        throwsA(_code(14)),
      );
      expect(await fixture.note.readAsBytes(), [0xff, 0xfe, 0x61, 0]);
      await fixture.note.delete();
      await expectLater(
        fixture.open(initial: 'never recreate'),
        throwsA(_code(31)),
      );
      expect(await fixture.note.exists(), isFalse);
      await fixture.note.writeAsString('restored outside host', flush: true);
      final restored = await fixture.open();
      expect((await restored.read()).nodeId, initial.nodeId);
    },
  );

  test('malformed existing notebook init fails with redacted error and joins safely', () async {
    final host = await fixture.open();
    await host.close();
    final config = File(
      '${fixture.path('book')}${Platform.pathSeparator}vx_notebook${Platform.pathSeparator}config.json',
    );
    await config.writeAsString('{malformed private config', flush: true);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await fixture.open(initial: 'never repair metadata');
        fail('Malformed existing notebook was accepted');
      } on CoreException catch (error) {
        expect(error.code, isNot(0));
        expect(error.message, isNot(contains(fixture.root.path)));
        expect(error.message, isNot(contains('private config')));
      }
    }
    expect(await config.readAsString(), '{malformed private config');
    expect(await fixture.note.readAsString(), 'initial\r\n');
  });

  test('encrypted bytes are rejected without plaintext fallback', () async {
    final host = await fixture.open();
    final base = await host.read();
    final encryptedEnvelope = <int>[...ascii.encode('VNOTEE1'), 0, 0, 0, 0, 0];
    await fixture.note.writeAsBytes(encryptedEnvelope, flush: true);
    await expectLater(
      host.read(),
      throwsA(
        isA<CoreException>().having(
          (error) => error.code,
          'encryption error',
          isIn([14, 32, 34]),
        ),
      ),
    );
    await expectLater(
      host.write(
        'must stay editable in caller only',
        revision: 1,
        baseHash: base.baseHash,
      ),
      throwsA(isA<CoreException>()),
    );
    expect(await fixture.note.readAsBytes(), encryptedEnvelope);
  });

  test('close settles every admitted future, including pending cancellations', () async {
    final host = await fixture.open(initial: 'base');
    final base = await host.read();
    final outcomes = <Future<Object>>[];
    for (var revision = 1; revision <= 64; revision++) {
      outcomes.add(
        host
            .write(
              'capture $revision',
              revision: revision,
              baseHash: base.baseHash,
            )
            .then<Object>((value) => value, onError: (Object error) => error),
      );
    }
    final closing = host.close();
    final results = await Future.wait(outcomes);
    await closing;
    expect(results, hasLength(64));
    final successful = results.whereType<CoreWriteResult>().toList();
    expect(successful.length, lessThanOrEqualTo(1));
    for (final error in results.whereType<CoreException>()) {
      expect(error.code, isIn([3, 18, 20]));
    }
    expect(
      results.every(
        (value) => value is CoreException || value is CoreWriteResult,
      ),
      isTrue,
    );
    final bytes = await fixture.note.readAsString();
    if (successful.isEmpty) {
      expect(bytes, 'base');
    } else {
      expect(bytes, 'capture ${successful.single.revision}');
    }
    // The old listener has joined/closed; a fresh host is independently usable.
    final next = await fixture.open();
    expect((await next.read()).text, bytes);
  });

  test('multiple explicit-root hosts do not share context storage', () async {
    final other = _Fixture(
      await Directory.systemTemp.createTemp('vnote-ffi-other-'),
    );
    try {
      final hosts = await Future.wait([
        fixture.open(initial: 'first'),
        other.open(initial: 'second'),
      ]);
      final first = await hosts[0].read();
      final second = await hosts[1].read();
      expect(first.notebookId, isNot(second.notebookId));
      expect(first.nodeId, isNot(second.nodeId));
      await hosts[0].write('only first', revision: 1, baseHash: first.baseHash);
      expect((await hosts[1].read()).text, 'second');
    } finally {
      await other.dispose();
    }
  });
}
