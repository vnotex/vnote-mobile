// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

const _book = '10000000-0000-4000-8000-000000000001';
const _node = '20000000-0000-4000-8000-000000000002';
const _token = '0123456789abcdef0123456789abcdef';
const _nextToken = 'fedcba9876543210fedcba9876543210';
String _hash(String source) => sha256.convert(utf8.encode(source)).toString();
Matcher get _failure => isA<CoreException>();

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  late String key;
  String get drafts => '${root.path}/drafts';
  String get capture => '$drafts/$key/$_token';
  Map<String, Object?> request(String op, [Map<String, Object?> extra = const {}]) => {
    'op': op, 'draftsRoot': drafts, 'documentKey': key, 'token': _token, ...extra,
  };
  Future<Map<String, Object?>> run(String op, {Map<String, Object?> extra = const {}, String? payload}) {
    final input = request(op, extra);
    return Isolate.run(() => CoreDraftStore.run(
      input, payload: payload == null ? null : Uint8List.fromList(utf8.encode(payload)),
    ));
  }
  Future<void> start([String source = 'base\r\n']) async {
    await Directory(drafts).create();
    key = await Isolate.run(() => CoreDraftStore.documentKey(_book, _node));
    await run('begin', extra: {'descriptor': {
      'notebookRelative': 'book', 'notebookId': _book, 'nodeId': _node,
      'pathHint': 'note.md', 'editorType': 'markdown', 'openingDiskHash': _hash(source), 'eol': 0,
    }}, payload: source);
  }
  Future<Map<String, dynamic>> manifest() async =>
      jsonDecode(await File('$capture/manifest.json').readAsString()) as Map<String, dynamic>;
  Future<File> log() async => File('$capture/${((await manifest())['body'] as Map)['log']}');
  Future<Map<String, Object?>> append(int revision, int from, int to, String insert) => run(
    'append', extra: {'expectedRevision': revision}, payload: jsonEncode({'frames': [{
      'token': _token, 'baseRevision': revision, 'revision': revision + 1, 'requestId': 'edit-${revision + 1}',
      'changes': [{'from': from, 'to': to, 'insert': insert}],
      'selection': {'anchor': from + insert.length, 'head': from + insert.length},
    }]}),
  );
  Future<Map<String, Object?>> scan() {
    final request = {'op': 'scan', 'draftsRoot': drafts, 'offset': 0};
    return Isolate.run(() => CoreDraftStore.run(request));
  }
}

void main() {
  late _Fixture fixture;
  setUp(() async => fixture = _Fixture(await Directory.systemTemp.createTemp('vnote-drafts-')));
  tearDown(() async { if (await fixture.root.exists()) await fixture.root.delete(recursive: true); });

  test('lazy begin retains exact source and has no fabricated saved watermark', () async {
    await fixture.start('a\r\n😀b\n');
    final summary = CoreDraftSummary.fromJson(await fixture.run('inspect'));
    expect(summary.revision, 0);
    expect(summary.savedRevision, isNull);
    expect(summary.sourceHash, _hash('a\r\n😀b\n'));
    expect((await fixture.run('read'))['source'], 'a\r\n😀b\n');
    expect((await fixture.run('readBase'))['baseSource'], 'a\r\n😀b\n');
    expect(summary.descriptor.openingDiskHash, summary.sourceHash);
  });

  test('committed prefix survives torn unacknowledged append tail', () async {
    await fixture.start();
    await fixture.append(0, 0, 0, 'draft ');
    final log = await fixture.log();
    final length = await log.length();
    await log.writeAsBytes([255, 0, 4, 9, 77], mode: FileMode.append, flush: true);
    final restored = await fixture.run('read');
    expect(restored['source'], 'draft base\r\n');
    expect(restored['revision'], 1);
    expect(await log.length(), length);
  });

  test('acknowledged frame corruption quarantines without returning a prefix', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'draft ');
    final log = await fixture.log(); final bytes = await log.readAsBytes();
    bytes[bytes.length - 1] ^= 1; await log.writeAsBytes(bytes, flush: true);
    await expectLater(fixture.run('read'), throwsA(_failure));
    final entries = (await fixture.scan())['entries']! as List;
    expect((entries.single as Map)['status'], 'quarantined');
    expect((entries.single as Map)['descriptor'], isNotNull);
    expect(await log.readAsBytes(), bytes);
    final raw = CoreDraftExport.fromJson(await fixture.run('prepareExport', extra: {'revision': 1, 'format': 'raw-archive'}));
    expect(raw.format, 'raw-archive');
    expect(raw.sha256, hasLength(64));
    await expectLater(fixture.run('discard'), throwsA(_failure));
    await fixture.run('releaseExport', extra: {'candidateId': raw.candidateId});
    await fixture.run('discard');
    expect(await Directory(fixture.capture).exists(), isFalse);
  });

  test('manifest publication obstruction cannot advance acknowledged revision', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'first ');
    // Replace authority with an invalid object while retaining the exact bytes.
    // Native must refuse before append rather than overwrite an unexpected head.
    final manifest = File('${fixture.capture}/manifest.json');
    final prior = await manifest.readAsBytes();
    await manifest.delete(); await Directory(manifest.path).create();
    await expectLater(fixture.append(1, 0, 0, 'second '), throwsA(_failure));
    await Directory(manifest.path).delete(); await manifest.writeAsBytes(prior, flush: true);
    expect((await fixture.run('read'))['source'], 'first base\r\n');
    expect((await fixture.run('inspect'))['revision'], 1);
  });

  test('checkpoint replacement reclaims log but preserves immutable save candidate', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'saved-prefix ');
    final candidate = CoreDraftCandidate.fromJson(await fixture.run('prepareSave', extra: {'revision': 1, 'requestId': 'save-1'}));
    final intentFile = File('${fixture.capture}/intent-${candidate.candidateId}.json');
    final intent = jsonDecode(await intentFile.readAsString()) as Map;
    final pinned = ((intent['body'] as Map)['source'] as Map)['file'] as String;
    final savedBytes = await File('${fixture.capture}/$pinned').readAsBytes();
    await fixture.append(1, 0, 0, 'later ');
    await fixture.run('checkpoint', extra: {'revision': 2});
    expect(await File('${fixture.capture}/$pinned').readAsBytes(), savedBytes);
    expect((await fixture.run('read'))['source'], 'later saved-prefix base\r\n');
    expect((await fixture.run('inspect'))['candidateId'], candidate.candidateId);
    final retried = CoreDraftCandidate.fromJson(await fixture.run('prepareSave', extra: {'revision': 1, 'requestId': 'save-1'}));
    expect(retried.record, candidate.record);
    expect(retried.revision, 1);
    await expectLater(fixture.run('prepareSave', extra: {'revision': 1, 'requestId': 'different-request'}), throwsA(_failure));
    await expectLater(fixture.run('prepareSave', extra: {'revision': 2, 'requestId': 'replace'}), throwsA(_failure));
    final body = (await fixture.manifest())['body'] as Map;
    expect(body['offset'], 0); expect(body['baseRevision'], 2);
    expect((await fixture.log()).lengthSync(), 0);
  });

  test('UTF16 ranges reject split surrogates and preserve CRLF outside edit', () async {
    await fixture.start('a😀\r\nb');
    await expectLater(fixture.append(0, 2, 2, 'x'), throwsA(_failure));
    expect((await fixture.run('inspect'))['revision'], 0);
    await fixture.append(0, 1, 3, 'z');
    expect((await fixture.run('read'))['source'], 'az\r\nb');
    await expectLater(fixture.append(0, 0, 0, 'stale'), throwsA(_failure));
    expect((await fixture.run('inspect'))['revision'], 1);
  });

  test('rebase checkpoints exact head before retiring old capturing token', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'dirty ');
    final next = CoreDraftSummary.fromJson(await fixture.run('rebase', extra: {'newToken': _nextToken}));
    expect(next.token, _nextToken); expect(next.revision, 0); expect(next.savedRevision, isNull);
    final old = CoreDraftSummary.fromJson(await fixture.run('inspect'));
    expect(old.status, 'superseded'); expect(old.supersededBy, _nextToken);
    await expectLater(fixture.append(1, 0, 0, 'old'), throwsA(_failure));
    expect((await fixture.run('read', extra: {'token': _nextToken}))['source'], 'dirty base\r\n');
    expect((await fixture.run('read'))['source'], 'dirty base\r\n');
  });

  test('explicit divergent resync is a new dirty source not a client saved proof', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'mirror ');
    final next = await fixture.run('rebaseSource', extra: {'newToken': _nextToken}, payload: 'chosen\r\n');
    expect(next['savedRevision'], isNull);
    expect((await fixture.run('read', extra: {'token': _nextToken}))['source'], 'chosen\r\n');
    expect((await fixture.run('readBase', extra: {'token': _nextToken}))['baseSource'], 'base\r\n');
    await expectLater(fixture.run('recordSaved', extra: {'revision': 0, 'diskHash': _hash('chosen\r\n')}), throwsA(_failure));
  });

  test('closed commands reject spoofed identity, source policy, token, and proof', () async {
    await fixture.start();
    await expectLater(fixture.run('inspect', extra: {'documentKey': '0' * 64}), throwsA(_failure));
    await expectLater(fixture.run('inspect', extra: {'token': '../escape'}), throwsA(_failure));
    await expectLater(fixture.run('inspect', extra: {'saved': true}), throwsA(_failure));
    await expectLater(fixture.run('append', extra: {'expectedRevision': 0}, payload: '{"frames":[],"frames":[]}'), throwsA(_failure));
    await expectLater(fixture.append(0, 0, 0, '\u0000'), throwsA(_failure));
    expect((await fixture.run('inspect'))['revision'], 0);
  });

  test('bounded replay compacts continuous edits rather than note lifetime', () async {
    await fixture.start('');
    for (var base = 0; base < 288; base += 32) {
      final frames = [for (var index = base; index < base + 32; index++) {
        'token': _token, 'baseRevision': index, 'revision': index + 1, 'requestId': 'r$index',
        'changes': [{'from': index, 'to': index, 'insert': 'x'}],
        'selection': {'anchor': index + 1, 'head': index + 1},
      }];
      await fixture.run('append', extra: {'expectedRevision': base}, payload: jsonEncode({'frames': frames}));
    }
    expect((await fixture.run('read'))['source'], 'x' * 288);
    final body = (await fixture.manifest())['body'] as Map;
    expect(body['baseRevision'], greaterThanOrEqualTo(256));
    expect(body['frames'], lessThan(256));
  });

  test('32 unresolved document ceiling blocks new obligations without eviction', () async {
    await fixture.start('');
    for (var index = 1; index < 32; index++) {
      final node = 'node-$index';
      final key = await Isolate.run(() => CoreDraftStore.documentKey(_book, node));
      await fixture.run('begin', extra: {'documentKey': key, 'descriptor': {
        'notebookRelative': 'book', 'notebookId': _book, 'nodeId': node,
        'pathHint': '$node.md', 'editorType': 'markdown', 'openingDiskHash': _hash(''), 'eol': 0,
      }}, payload: '');
    }
    final key = await Isolate.run(() => CoreDraftStore.documentKey(_book, 'overflow'));
    await expectLater(fixture.run('begin', extra: {'documentKey': key, 'descriptor': {
      'notebookRelative': 'book', 'notebookId': _book, 'nodeId': 'overflow',
      'pathHint': 'overflow.md', 'editorType': 'markdown', 'openingDiskHash': _hash(''), 'eol': 0,
    }}, payload: ''), throwsA(_failure));
    expect((await fixture.scan())['entries'], hasLength(32));
    expect((await fixture.run('read'))['source'], '');
    final request = {'op': 'prune', 'draftsRoot': fixture.drafts};
    expect((await Isolate.run(() => CoreDraftStore.run(request)))['removed'], 0);
  });

  test('pre-requested cancellation leaves previous committed source intact', () async {
    await fixture.start();
    final address = CoreImportStore.createCancellation();
    try {
      CoreImportStore.requestCancellation(address);
      final request = fixture.request('checkpoint', {'revision': 0});
      await expectLater(Isolate.run(() => CoreDraftStore.run(request, cancellationAddress: address)), throwsA(_failure));
    } finally { CoreImportStore.freeCancellation(address); }
    expect((await fixture.run('read'))['source'], 'base\r\n');
  });

  test('linked journal bodies cannot redirect reads or discard outside root', () async {
    await fixture.start();
    final outside = File('${fixture.root.path}/outside.txt'); await outside.writeAsString('private outside', flush: true);
    final body = (await fixture.manifest())['body'] as Map;
    final source = File('${fixture.capture}/${(body['base'] as Map)['file']}'); await source.delete();
    final linked = Platform.isWindows
        ? await Process.run('cmd', ['/c', 'mklink', '/H', source.path.replaceAll('/', '\\'), outside.path.replaceAll('/', '\\')])
        : await Process.run('ln', [outside.path, source.path]);
    expect(linked.exitCode, 0, reason: '${linked.stdout}\n${linked.stderr}');
    await expectLater(fixture.run('read'), throwsA(_failure));
    await fixture.run('discard');
    expect(await outside.readAsString(), 'private outside');
  });

  test('per-document reservation failure retains the acknowledged source', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'retained ');
    final reservation = await File('${fixture.capture}/reservation.bin').open(mode: FileMode.write);
    try { await reservation.truncate(32 * 1024 * 1024 - 4096); await reservation.flush(); }
    finally { await reservation.close(); }
    await expectLater(fixture.append(1, 0, 0, 'unacknowledged '), throwsA(_failure));
    expect((await fixture.run('read'))['source'], 'retained base\r\n');
    expect((await fixture.run('inspect'))['revision'], 1);
  });

  test('native draft exporter produces a pinned ready6 copy independent of later edits', () async {
    await fixture.start(); await fixture.append(0, 0, 0, 'captured ');
    final binding = await fixture.run('prepareExport', extra: {'revision': 1, 'format': 'text'});
    await fixture.append(1, 0, 0, 'later ');
    await fixture.run('checkpoint', extra: {'revision': 2});
    final resources = '${fixture.root.path}/resources', notebooks = '${fixture.root.path}/notebooks';
    await Directory(resources).create(); await Directory(notebooks).create();
    final target = {'version': 1, 'id': _nextToken, 'notebookId': _book, 'nodeId': _node, 'notebookRelative': 'book'};
    Future<Map<String, Object?>> transfer(String op, [Map<String, Object?> extra = const {}]) {
      final request = {'op': op, 'scope': 'resource', 'root': resources, 'notebooksRoot': notebooks,
        'id': _nextToken, ...extra};
      return Isolate.run(() => CoreImportStore.runTransfer(request));
    }
    await transfer('allocate', {'kind': 'file', 'target': target});
    await transfer('writeResourceIntent', {'version': 2, 'operation': 'export', 'name': 'draft.md', 'newName': null,
      'origin': 'draft', 'binding': binding});
    await expectLater(fixture.run('releaseExport', extra: {'candidateId': binding['candidateId']}), throwsA(_failure));
    final ready = await fixture.run('export', extra: {'resourceRoot': '$resources/$_nextToken', 'binding': binding});
    expect(await File(ready['path']! as String).readAsString(), 'captured base\r\n');
    final marker = jsonDecode(await File('$resources/$_nextToken/ready.json').readAsString()) as Map;
    expect(marker.keys, unorderedEquals(['version', 'id', 'scope', 'name', 'bytes', 'sha256']));
    await fixture.run('releaseExport', extra: {'candidateId': binding['candidateId']});
    await fixture.run('releaseExport', extra: {'candidateId': binding['candidateId']});
    await fixture.run('discard');
    expect((await transfer('verifyExport'))['sha256'], binding['sha256']);
    expect(await File(ready['path']! as String).readAsString(), 'captured base\r\n');
  });

  test('corrupt identity can export only owned raw archive using private target', () async {
    await fixture.start();
    await File('${fixture.capture}/manifest.json').writeAsString('corrupt acknowledged manifest', flush: true);
    await File('${fixture.capture}/descriptor.json').writeAsString('corrupt identity', flush: true);
    final binding = await fixture.run('prepareExport', extra: {'revision': 0, 'format': 'raw-archive'});
    final resources = '${fixture.root.path}/resources', notebooks = '${fixture.root.path}/notebooks';
    await Directory(resources).create(); await Directory(notebooks).create();
    Future<Map<String, Object?>> transfer(String op, Map<String, Object?> extra) {
      final request = {'op': op, 'scope': 'resource', 'root': resources, 'notebooksRoot': notebooks,
        'id': _nextToken, ...extra};
      return Isolate.run(() => CoreImportStore.runTransfer(request));
    }
    await transfer('allocate', {'kind': 'file', 'target': {'version': 1, 'id': _nextToken,
      'notebookId': 'private-draft', 'nodeId': fixture.key, 'notebookRelative': 'private-draft'}});
    await transfer('writeResourceIntent', {'version': 2, 'operation': 'export', 'name': 'draft.vxdraft', 'newName': null,
      'origin': 'draft', 'binding': binding});
    final ready = await fixture.run('export', extra: {'resourceRoot': '$resources/$_nextToken', 'binding': binding});
    final bytes = await File(ready['path']! as String).readAsBytes();
    expect(utf8.decode(bytes.sublist(0, 8)), 'VXDRAFT1');
    expect(utf8.decode(bytes, allowMalformed: true), contains('corrupt acknowledged manifest'));
    expect(sha256.convert(bytes).toString(), binding['sha256']);
    await fixture.run('releaseExport', extra: {'candidateId': binding['candidateId']});
    await fixture.run('discard');
    expect(await File(ready['path']! as String).exists(), isTrue);
  });

  test('atomic insertion plus later deletion may keep a full-size source in bounds', () async {
    const maximum = 4 * 1024 * 1024;
    await fixture.start('x' * maximum);
    final result = await fixture.run('append', extra: {'expectedRevision': 0}, payload: jsonEncode({'frames': [{
      'token': _token, 'baseRevision': 0, 'revision': 1, 'requestId': 'atomic-full-source',
      'changes': [{'from': 0, 'to': 0, 'insert': 'y'}, {'from': maximum - 1, 'to': maximum, 'insert': ''}],
      'selection': {'anchor': 1, 'head': 1},
    }]}));
    expect(result['sourceHash'], _hash('y${'x' * (maximum - 1)}'));
    await expectLater(fixture.append(1, 0, 0, 'z'), throwsA(_failure));
    expect((await fixture.run('inspect'))['revision'], 1);
  });
}
