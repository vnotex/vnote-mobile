// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

Matcher get _failure => isA<CoreException>();
String _id(int value) => value.toRadixString(16).padLeft(32, '0');

Future<Map<String, Object?>> _preview(Map<String, Object?> request, {int cancel = 0}) =>
    Isolate.run(() => CoreImportStore.runPreview(request, cancellationAddress: cancel));
Future<Map<String, Object?>> _transfer(Map<String, Object?> request) =>
    Isolate.run(() => CoreImportStore.runTransfer(request));

List<int> _u32(int value) => [value >> 24 & 255, value >> 16 & 255, value >> 8 & 255, value & 255];
int _crc(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  return crc ^ 0xffffffff;
}
List<int> _chunk(String type, List<int> data) {
  final body = [...ascii.encode(type), ...data];
  return [..._u32(data.length), ...body, ..._u32(_crc(body))];
}
List<int> _png({int width = 1, int height = 1, bool animated = false}) => [
  137, 80, 78, 71, 13, 10, 26, 10,
  ..._chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]),
  if (animated) ..._chunk('acTL', [..._u32(2), ..._u32(0)]),
  ..._chunk('IDAT', ZLibEncoder().convert([0, 255, 0, 0, 255])),
  ..._chunk('IEND', []),
];

// Header-policy fixtures intentionally exercise the native pre-decoder boundary.
// Decoder/rendering success is covered separately by platform image tests.
List<int> _jpegHeader(int width, int height) => [
  0xff, 0xd8, 0xff, 0xc0, 0, 17, 8,
  height >> 8, height & 255, width >> 8, width & 255, 3,
  1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0,
  0xff, 0xda, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, 63, 0, 0xff, 0xd9,
];
List<int> _webpHeader(int width, int height, {bool extended = false, int? canvasWidth}) {
  List<int> little(int value) => [value & 255, value >> 8 & 255, value >> 16 & 255, value >> 24 & 255];
  final frame = <int>[
    ...ascii.encode('VP8 '), ...little(10), 0x10, 0, 0, 0x9d, 1, 0x2a,
    width & 255, width >> 8, height & 255, height >> 8,
  ];
  final chunks = <int>[
    if (extended) ...[
      ...ascii.encode('VP8X'), ...little(10), 0, 0, 0, 0,
      ...little((canvasWidth ?? width) - 1).take(3), ...little(height - 1).take(3),
    ],
    ...frame,
  ];
  return [...ascii.encode('RIFF'), ...little(chunks.length + 4), ...ascii.encode('WEBP'), ...chunks];
}

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final owners = <CoreNotebook>[];
  late String notebookId;
  late String noteId;
  late String peerId;
  late String folderId;
  int serial = 10;
  int engine = 0;
  String get notebooks => '${root.path}/notebooks';
  String get notebook => '$notebooks/book';
  String get previews => '${root.path}/previews';
  String get resources => '${root.path}/resources';
  String get notePath => '$notebook/Folder/Note.md';
  String snapshotPath(CorePreviewSnapshot snapshot) => '$previews/${snapshot.previewId}/${snapshot.renderId}';
  String nextId() => _id(++serial);

  Future<void> start() async {
    await Directory(notebooks).create(recursive: true);
    await Directory(previews).create();
    await Directory(resources).create();
    final core = await CoreNotebook.createCatalog(
      appDataPath: '${root.path}/seed/app', localDataPath: '${root.path}/seed/local',
      notebookPath: notebook, notebookName: 'Preview boundary',
    );
    owners.add(core);
    notebookId = core.initialDirectory.notebookId;
    folderId = await core.createFolder(core.initialDirectory.folderId, 'Folder');
    noteId = await core.createNote(folderId, 'Note.md');
    peerId = await core.createNote(core.initialDirectory.folderId, 'Peer.md');
    await core.close();
    await File(notePath).writeAsString('# Disk remains original\r\n', flush: true);
    await File('$notebook/Peer.md').writeAsString('# Peer\n', flush: true);
  }

  Future<CoreNotebook> owner({bool resourceOnly = false}) async {
    final prefix = '${root.path}/owner-${++engine}';
    final core = resourceOnly
        ? await CoreNotebook.openResources(
            appDataPath: '$prefix/app', localDataPath: '$prefix/local',
            notebookPath: notebook, notebookId: notebookId, nodeId: noteId,
          )
        : await CoreNotebook.openNote(
            appDataPath: '$prefix/app', localDataPath: '$prefix/local',
            notebookPath: notebook, notebookId: notebookId, nodeId: noteId,
          );
    owners.add(core);
    return core;
  }

  Future<void> file(String relative, List<int> bytes) async {
    final file = File('$notebook/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<CorePreviewSnapshot> capture(CoreNotebook core, String source, {String? previewId, String? renderId}) =>
      core.preparePreview(
        previewsRoot: previews, previewId: previewId ?? nextId(), renderId: renderId ?? nextId(),
        token: _id(0xfeed), revision: 7, source: source,
      );

  Future<Map<String, Object?>> run(CorePreviewSnapshot snapshot, String op, [Map<String, Object?> fields = const {}]) =>
      _preview({...snapshot.command(op), ...fields});

  Future<Map<String, Object?>> resource(String id, String op, [Map<String, Object?> fields = const {}]) =>
      _transfer({'scope': 'resource', 'root': resources, 'notebooksRoot': notebooks, 'id': id, 'op': op, ...fields});

  Future<String> allocate() async {
    final id = nextId();
    await resource(id, 'allocate', {
      'kind': 'file',
      'target': {'version': 1, 'id': id, 'notebookId': notebookId, 'notebookRelative': 'book', 'nodeId': noteId},
    });
    return id;
  }

  Future<void> dispose() async {
    for (final core in owners) { await core.close(); }
    await root.delete(recursive: true);
  }
}

List<Map<String, dynamic>> _entries(Map<String, Object?> value, String key) =>
    (value[key]! as List).cast<Map<String, dynamic>>();

Future<Map<String, Object?>> _retirePrevious(_Fixture fixture, {int cancel = 0}) =>
    _preview({'op': 'retirePreviousProcess', 'previewRoot': fixture.previews}, cancel: cancel);

Future<void> _expireLeases(_Fixture fixture, CorePreviewSnapshot snapshot, {bool legacy = false}) async {
  await for (final entity in Directory('${fixture.snapshotPath(snapshot)}/leases').list()) {
    final file = entity as File;
    final pin = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (legacy) {
      pin['version'] = 1;
      pin.remove('process'); pin.remove('previewId'); pin.remove('renderId');
    } else {
      pin['process'] = pin['process'] == 'f' * 32 ? 'e' * 32 : 'f' * 32;
    }
    await file.writeAsString(jsonEncode(pin), flush: true);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture(await Directory.systemTemp.createTemp('vnote-preview-'));
    await fixture.start();
  });
  tearDown(() => fixture.dispose());

  test('NOTE snapshots preserve exact mirror bytes and resolve CommonMark references without writing disk', () async {
    final png = _png();
    await fixture.file('images/one.png', png);
    await fixture.file('images/a&b.png', png);
    await fixture.file('docs/raw.svg', utf8.encode('<svg onload="alert(1)"></svg>'));
    final core = await fixture.owner();
    const source = '# Unsaved Héading\r\n'
        '![one][asset] ![alias](../images/./one.png) ![entity](../images/a&amp;b.png)\r\n'
        '[peer](../Peer.md#H%C3%A9ading) [fragment](#unsaved-héading)\r\n'
        '[https](https://example.test/a?q=1) [http](http://example.test:8080/a)\r\n'
        '[opaque](../docs/raw.svg) ![not-inline](../docs/raw.svg)\r\n'
        '\r\n[asset]: ../images/one.png "Reference title"\r\n';
    final snapshot = await fixture.capture(core, source);
    expect(snapshot.sourceRevision, 7);
    expect(snapshot.sourceHash, sha256.convert(utf8.encode(source)).toString());
    expect(snapshot.imageCount, 3);
    expect(snapshot.fileCount, 3);
    expect(snapshot.navigationCount, 4);
    final inspected = await fixture.run(snapshot, 'inspect');
    final images = _entries(inspected, 'images');
    expect(images.map((entry) => entry['mime']), everyElement('image/png'));
    expect(images.map((entry) => entry['width']), everyElement(1));
    expect(images.first['handle'], images[1]['handle']);
    expect(images[2]['source'], '../images/a&b.png');
    final navigation = _entries(inspected, 'navigation');
    final peer = navigation.singleWhere((entry) => entry['kind'] == 'note');
    expect(peer['nodeId'], fixture.peerId);
    expect(peer['fragment'], 'Héading');
    final http = navigation.singleWhere((entry) => entry['insecure'] == true);
    expect(http['origin'], 'http://example.test:8080');
    final opaque = navigation.singleWhere((entry) => entry['kind'] == 'export');
    final exportedFile = _entries(inspected, 'files').singleWhere((entry) => entry['handle'] == opaque['fileHandle']);
    expect(exportedFile['mime'], 'application/octet-stream');
    final path = fixture.snapshotPath(snapshot);
    expect(await File('$path/source.md').readAsBytes(), utf8.encode(source));
    final manifestBytes = await File('$path/manifest.json').readAsBytes();
    expect(await File('$path/manifest.sha256').readAsString(), sha256.convert(manifestBytes).toString());
    final manifestText = utf8.decode(manifestBytes);
    expect(manifestText, isNot(contains(fixture.root.path)));
    expect(manifestText, isNot(contains(_id(0xfeed))));
    expect(manifestText, isNot(contains('notePath')));
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
    expect((await core.read()).text, '# Disk remains original\r\n');
    await core.close();
    // Immutable copies are no longer tied to a core handle or mutable assets.
    await fixture.file('images/one.png', [0, 1, 2]);
    expect((_entries(await fixture.run(snapshot, 'inspect'), 'images')).first['sha256'], sha256.convert(png).toString());
  });

  test('relative paths decode once, stay confined, and never activate private/custom/remote image targets', () async {
    await fixture.file('images/good.png', _png());
    await File('${fixture.root.path}/outside.png').writeAsBytes(_png());
    final core = await fixture.owner();
    const source = '![good](../images/good.png)\n'
        '![escape](../../outside.png) ![absolute](/images/good.png)\n'
        '![encoded separator](..%2fimages/good.png) ![double](%252e%252e/images/good.png)\n'
        '![drive](C:/outside.png) ![remote](https://example.test/x.png)\n'
        '![data](data:image/png;base64,AAAA) ![svg](../vx_notebook/config.json)\n'
        '[private](../vx_notebook/config.json) [settings](vx://settings) [ids](vnote://note/123)\n'
        '[credentials](https://user:password@example.test/) [control](https://example.test/%0a)\n'
        '[bad IPv6](https://[:::1]/) [hex IPv4](https://0x7f000001/) [octal](https://0177.0.0.1/)\n'
        '[malformed](../images/%zz.png) [query](../images/good.png?other=1)\n';
    final snapshot = await fixture.capture(core, source);
    expect(snapshot.imageCount, 1);
    expect(snapshot.fileCount, 1);
    expect(snapshot.navigationCount, 0);
    expect(_entries(await fixture.run(snapshot, 'inspect'), 'images').single['source'], '../images/good.png');
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('protected indexed notes and a newly protected selected body never enter snapshot capabilities', () async {
    final metadataFile = File('${fixture.notebook}/vx_notebook/contents/vx.json');
    final metadata = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    final peer = (metadata['files'] as List).cast<Map<String, dynamic>>().single;
    peer['name'] = 'Secret.vne';
    peer['metadata'] = {...?peer['metadata'] as Map<String, dynamic>?, 'encrypted': true, 'editorType': 'markdown'};
    await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
    await File('${fixture.notebook}/Peer.md').rename('${fixture.notebook}/Secret.vne');
    final envelope = [...ascii.encode('VNOTEE1'), 0, 7, 9];
    await fixture.file('Secret.vne', envelope);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[protected](../Secret.vne) ![protected](../Secret.vne)');
    expect(snapshot.navigationCount, 0);
    expect(snapshot.fileCount, 0);
    expect(await File('${fixture.notebook}/Secret.vne').readAsBytes(), envelope);
    await File(fixture.notePath).writeAsBytes(envelope, flush: true);
    await expectLater(fixture.capture(core, '# Old plaintext mirror'), throwsA(_failure));
    expect(await File(fixture.notePath).readAsBytes(), envelope);
  });

  test('extension, signature, bounded dimensions and animated envelopes are checked before inline admission', () async {
    await fixture.file('images/valid.png', _png());
    await fixture.file('images/valid.jpeg', _jpegHeader(2, 3));
    await fixture.file('images/valid.webp', _webpHeader(4, 5));
    await fixture.file('images/extended.webp', _webpHeader(4, 5, extended: true));
    await fixture.file('images/wrong.jpg', _png());
    await fixture.file('images/bomb.png', _png(width: 4001, height: 4000));
    await fixture.file('images/animated.png', _png(animated: true));
    await fixture.file('images/canvas.webp', _webpHeader(9000, 9000, extended: true, canvasWidth: 1));
    await fixture.file('images/truncated.png', [137, 80, 78, 71]);
    final brokenCrc = _png(); brokenCrc[29] ^= 1;
    await fixture.file('images/crc.png', brokenCrc);
    final animatedWebp = _webpHeader(1, 1, extended: true); animatedWebp[20] = 2;
    await fixture.file('images/animated.webp', animatedWebp);
    final appSegment = [0xff, 0xe1, 0xff, 0xff, ...List.filled(65533, 0)];
    await fixture.file('images/header-limit.jpg', [0xff, 0xd8,
      for (var i = 0; i < 4; i++) ...appSegment, ..._jpegHeader(1, 1).skip(2),
    ]);
    await fixture.file('images/too-large.png', _png());
    final oversized = await File('${fixture.notebook}/images/too-large.png').open(mode: FileMode.append);
    try { await oversized.truncate(16 * 1024 * 1024 + 1); } finally { await oversized.close(); }
    final core = await fixture.owner();
    final names = ['valid.png', 'valid.jpeg', 'valid.webp', 'extended.webp', 'wrong.jpg',
      'bomb.png', 'animated.png', 'canvas.webp', 'truncated.png', 'crc.png',
      'animated.webp', 'header-limit.jpg', 'too-large.png'];
    final snapshot = await fixture.capture(core, names.map((name) => '![$name](../images/$name)').join('\n'));
    final images = _entries(await fixture.run(snapshot, 'inspect'), 'images');
    expect(images.map((entry) => entry['source']), [
      '../images/valid.png', '../images/valid.jpeg', '../images/valid.webp', '../images/extended.webp',
    ]);
    expect(images.map((entry) => entry['mime']), ['image/png', 'image/jpeg', 'image/webp', 'image/webp']);
    expect(images.map((entry) => '${entry['width']}x${entry['height']}'), ['1x1', '2x3', '4x5', '4x5']);
  });

  test('external origins contain only validated authority and preserve explicit HTTP warning', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core,
      '[IPv6](https://[2001:db8::1]:8443/path) [IPv4](http://127.0.0.1:8080/path)');
    final navigation = _entries(await fixture.run(snapshot, 'inspect'), 'navigation');
    expect(navigation.map((entry) => entry['origin']), ['https://[2001:db8::1]:8443', 'http://127.0.0.1:8080']);
    expect(navigation.map((entry) => entry['insecure']), [false, true]);
  });

  test('image source aliases share one immutable encoded allocation', () async {
    final png = _png(); await fixture.file('images/one.png', png);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core,
      '![a](../images/one.png) ![b](../images/./one.png) ![c](../images/%6fne.png)');
    expect(snapshot.imageCount, 3);
    expect(snapshot.fileCount, 1);
    expect(snapshot.encodedBytes, png.length);
    expect(_entries(await fixture.run(snapshot, 'inspect'), 'images').map((entry) => entry['handle']).toSet(), hasLength(1));
  });

  test('ordinary navigation is not truncated to the media quota and supports manifests above one MiB', () async {
    final core = await fixture.owner();
    final suffix = 'a' * 180;
    final source = List.generate(6000, (index) => '[$index](https://example.test/$index/$suffix)').join('\n');
    final snapshot = await fixture.capture(core, source);
    expect(snapshot.navigationCount, 6000);
    expect(snapshot.imageCount, 0);
    expect(snapshot.fileCount, 0);
    expect(await File('${fixture.snapshotPath(snapshot)}/manifest.json').length(), greaterThan(1024 * 1024));
    final navigation = _entries(await fixture.run(snapshot, 'inspect'), 'navigation');
    expect(navigation, hasLength(6000));
    expect(navigation.last['url'], 'https://example.test/5999/$suffix');
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('stable note targets survive rename and are re-resolved by the owner at navigation', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[peer](../Peer.md#peer)');
    final navigation = _entries(await fixture.run(snapshot, 'inspect'), 'navigation').single;
    await core.close();
    final catalog = await CoreNotebook.openCatalog(
      appDataPath: '${fixture.root.path}/rename/app', localDataPath: '${fixture.root.path}/rename/local',
      notebookPath: fixture.notebook, expectedNotebookId: fixture.notebookId,
    );
    fixture.owners.add(catalog);
    await catalog.rename(fixture.peerId, 'Renamed.md');
    await catalog.close();
    final resolved = await fixture.run(snapshot, 'navigation', {'handle': navigation['handle']});
    expect(resolved['nodeId'], fixture.peerId);
    final destination = await CoreNotebook.openNote(
      appDataPath: '${fixture.root.path}/destination/app', localDataPath: '${fixture.root.path}/destination/local',
      notebookPath: fixture.notebook, notebookId: resolved['notebookId']! as String,
      nodeId: resolved['nodeId']! as String,
    );
    fixture.owners.add(destination);
    expect((await destination.read()).text, '# Peer\n');
    expect(await File('${fixture.notebook}/Peer.md').exists(), isFalse);
    expect(await File('${fixture.notebook}/Renamed.md').readAsString(), '# Peer\n');
  });

  test('previous-process and sealed legacy consumers retire without touching current readers', () async {
    final core = await fixture.owner();
    final live = await fixture.capture(core, 'current source');
    final old = await fixture.capture(core, 'previous source');
    final legacy = await fixture.capture(core, 'legacy source');
    await fixture.run(old, 'lease', {'leaseId': fixture.nextId()});
    await _expireLeases(fixture, old);
    await _expireLeases(fixture, legacy, legacy: true);
    await Directory(fixture.resources).delete(); // Owner-only retirement needs no export namespace.
    await _retirePrevious(fixture);
    expect(await Directory(fixture.snapshotPath(old)).exists(), isFalse);
    expect(await Directory(fixture.snapshotPath(legacy)).exists(), isFalse);
    expect(await File('${fixture.snapshotPath(live)}/source.md').readAsString(), 'current source');
    expect((await fixture.run(live, 'inspect'))['sourceHash'], sha256.convert(utf8.encode('current source')).toString());
    await _retirePrevious(fixture);
    expect(await File('${fixture.snapshotPath(live)}/source.md').readAsString(), 'current source');
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('current unpublished export survives while an expired orphan pin is reclaimed', () async {
    await fixture.file('docs/raw.bin', [1, 0, 255]);
    final core = await fixture.owner();
    final current = await fixture.capture(core, '[file](../docs/raw.bin)');
    final file = _entries(await fixture.run(current, 'inspect'), 'files').single;
    final currentId = fixture.nextId();
    await fixture.run(current, 'prepareExport', {'handle': file['handle'], 'leaseId': currentId});
    await fixture.run(current, 'revoke');
    final old = await fixture.capture(core, '[file](../docs/raw.bin)');
    final oldFile = _entries(await fixture.run(old, 'inspect'), 'files').single;
    await fixture.run(old, 'prepareExport', {'handle': oldFile['handle'], 'leaseId': fixture.nextId()});
    await _expireLeases(fixture, old);
    await _retirePrevious(fixture);
    expect(await Directory(fixture.snapshotPath(old)).exists(), isFalse);
    expect(await File('${fixture.snapshotPath(current)}/files/${file['handle']}').readAsBytes(), [1, 0, 255]);
    await fixture.run(current, 'releaseExport', {'transactionRoot': '${fixture.resources}/$currentId'});
    expect(await Directory(fixture.snapshotPath(current)).exists(), isFalse);
  });

  test('unready legacy export proof retains bytes without preventing other stale reclamation', () async {
    const bytes = [0, 255, 17, 0, 33];
    await fixture.file('docs/raw.bin', bytes);
    final core = await fixture.owner();
    final pinned = await fixture.capture(core, '[file](../docs/raw.bin)');
    final file = _entries(await fixture.run(pinned, 'inspect'), 'files').single;
    final id = await fixture.allocate();
    final prepared = await fixture.run(pinned, 'prepareExport', {'handle': file['handle'], 'leaseId': id});
    await fixture.resource(id, 'writeResourceIntent', {'version': 2, 'operation': 'export',
      'name': prepared['name'], 'newName': null, 'origin': prepared['origin'], 'binding': prepared['binding']});
    await _expireLeases(fixture, pinned, legacy: true);
    final disposable = await fixture.capture(core, 'old derived text');
    await _expireLeases(fixture, disposable);
    await _retirePrevious(fixture);
    expect(await Directory(fixture.snapshotPath(disposable)).exists(), isFalse);
    expect(await File('${fixture.snapshotPath(pinned)}/files/${file['handle']}').readAsBytes(), bytes);
    await fixture.file('docs/raw.bin', [9, 8, 7]);
    final ready = await fixture.run(pinned, 'export', {'transactionRoot': '${fixture.resources}/$id'});
    expect(await File(ready['path']! as String).readAsBytes(), bytes);
    await _retirePrevious(fixture);
    expect(await Directory(fixture.snapshotPath(pinned)).exists(), isFalse);
    expect((await fixture.resource(id, 'verifyExport'))['sha256'], sha256.convert(bytes).toString());
  });

  test('only a bound previous-process owner can reclaim partial snapshot data', () async {
    final core = await fixture.owner();
    final old = await fixture.capture(core, 'partial owned source');
    final legacy = await fixture.capture(core, 'unidentified legacy source');
    final mismatched = await fixture.capture(core, 'mismatched source');
    await _expireLeases(fixture, old);
    await _expireLeases(fixture, legacy, legacy: true);
    await _expireLeases(fixture, mismatched);
    for (final snapshot in [old, legacy, mismatched]) {
      await File('${fixture.snapshotPath(snapshot)}/manifest.json').delete();
      await File('${fixture.snapshotPath(snapshot)}/manifest.sha256').delete();
    }
    final owner = File('${fixture.snapshotPath(mismatched)}/leases/owner.json');
    final pin = jsonDecode(await owner.readAsString()) as Map<String, dynamic>;
    pin['renderId'] = '0' * 32; await owner.writeAsString(jsonEncode(pin), flush: true);
    final foreign = File('${fixture.previews}/foreign/private.txt');
    await foreign.parent.create(); await foreign.writeAsString('not a preview');
    final result = await _retirePrevious(fixture);
    expect(await Directory(fixture.snapshotPath(old)).exists(), isFalse);
    expect(await File('${fixture.snapshotPath(legacy)}/source.md').readAsString(), 'unidentified legacy source');
    expect(await File('${fixture.snapshotPath(mismatched)}/source.md').readAsString(), 'mismatched source');
    expect(await foreign.readAsString(), 'not a preview');
    expect(result['unrecognized'], greaterThan(0));
  });

  test('linked private children cannot authorize partial-generation deletion', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, 'owned');
    await _expireLeases(fixture, snapshot);
    await File('${fixture.snapshotPath(snapshot)}/manifest.sha256').delete();
    final outside = File('${fixture.root.path}/outside.txt');
    await outside.writeAsString('outside remains');
    final source = File('${fixture.snapshotPath(snapshot)}/source.md'); await source.delete();
    final linked = Platform.isWindows
        ? await Process.run('cmd', ['/c', 'mklink', '/H', source.path.replaceAll('/', '\\'), outside.path.replaceAll('/', '\\')])
        : await Process.run('ln', [outside.path, source.path]);
    expect(linked.exitCode, 0, reason: '${linked.stdout} ${linked.stderr}');
    await _retirePrevious(fixture);
    expect(await source.readAsString(), 'outside remains');
    expect(await outside.readAsString(), 'outside remains');
  });

  test('retirement enumeration cap and pre-requested cancellation never partially delete', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, 'retained across refused cleanup');
    await _expireLeases(fixture, snapshot);
    final token = CoreImportStore.createCancellation();
    try {
      CoreImportStore.requestCancellation(token);
      await expectLater(_retirePrevious(fixture, cancel: token), throwsA(_failure));
    } finally { CoreImportStore.freeCancellation(token); }
    expect(await File('${fixture.snapshotPath(snapshot)}/source.md').readAsString(), 'retained across refused cleanup');
    for (var index = 0; index < 10001; index++) {
      await Directory('${fixture.previews}/foreign-$index').create();
    }
    await expectLater(_retirePrevious(fixture), throwsA(_failure));
    expect(await File('${fixture.snapshotPath(snapshot)}/source.md').readAsString(), 'retained across refused cleanup');
  });

  test('revocation refuses new capabilities but waits for consumer leases to join', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[external](https://example.test/)');
    final nav = _entries(await fixture.run(snapshot, 'inspect'), 'navigation').single;
    final lease = fixture.nextId();
    await fixture.run(snapshot, 'lease', {'leaseId': lease});
    expect((await fixture.run(snapshot, 'revoke'))['retained'], isTrue);
    expect(await File('${fixture.snapshotPath(snapshot)}/source.md').exists(), isTrue);
    await expectLater(fixture.run(snapshot, 'navigation', {'handle': nav['handle']}), throwsA(_failure));
    await expectLater(fixture.run(snapshot, 'lease', {'leaseId': fixture.nextId()}), throwsA(_failure));
    expect((await fixture.run(snapshot, 'release', {'leaseId': lease}))['retained'], isFalse);
    expect(await Directory(fixture.snapshotPath(snapshot)).exists(), isFalse);
  });

  test('opaque export pins exact bytes through owner close, replacement and snapshot revocation', () async {
    const bytes = [0, 255, 17, 0, 33];
    await fixture.file('docs/raw.bin', bytes);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[export](../docs/raw.bin)');
    final file = _entries(await fixture.run(snapshot, 'inspect'), 'files').single;
    final id = await fixture.allocate();
    final prepared = await fixture.run(snapshot, 'prepareExport', {'handle': file['handle'], 'leaseId': id});
    await fixture.resource(id, 'writeResourceIntent', {
      'version': 2, 'operation': 'export', 'name': prepared['name'], 'newName': null,
      'origin': prepared['origin'], 'binding': prepared['binding'],
    });
    await core.close();
    await fixture.file('docs/raw.bin', [9, 8, 7]);
    expect((await fixture.run(snapshot, 'revoke'))['retained'], isTrue);
    final ready = await fixture.run(snapshot, 'export', {'transactionRoot': '${fixture.resources}/$id'});
    expect(await File(ready['path']! as String).readAsBytes(), bytes);
    expect(ready['sha256'], sha256.convert(bytes).toString());
    final marker = jsonDecode(await File('${fixture.resources}/$id/ready.json').readAsString()) as Map;
    expect(marker.keys.toSet(), {'version', 'id', 'scope', 'name', 'bytes', 'sha256'});
    expect(await Directory(fixture.snapshotPath(snapshot)).exists(), isFalse);
    expect((await fixture.resource(id, 'verifyExport'))['sha256'], ready['sha256']);
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['released'], isTrue);
    await fixture.resource(id, 'discardExport');
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['released'], isTrue);
    expect(await File('${fixture.notebook}/docs/raw.bin').readAsBytes(), [9, 8, 7]);
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('unknown or changed export bindings never copy an asset with the same name', () async {
    await fixture.file('docs/shared.bin', [1, 2, 3]);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[export](../docs/shared.bin)');
    final file = _entries(await fixture.run(snapshot, 'inspect'), 'files').single;
    final id = await fixture.allocate();
    final prepared = await fixture.run(snapshot, 'prepareExport', {'handle': file['handle'], 'leaseId': id});
    final binding = Map<String, Object?>.from(prepared['binding']! as Map);
    binding['manifestHash'] = '0'.padLeft(64, '0');
    await fixture.resource(id, 'writeResourceIntent', {
      'version': 2, 'operation': 'export', 'name': prepared['name'], 'newName': null,
      'origin': 'preview-file', 'binding': binding,
    });
    await expectLater(fixture.run(snapshot, 'export', {'transactionRoot': '${fixture.resources}/$id'}), throwsA(_failure));
    expect(await File('${fixture.resources}/$id/ready.json').exists(), isFalse);
    expect(await Directory('${fixture.resources}/$id/output').exists(), isFalse);
    expect((await fixture.run(snapshot, 'revoke'))['retained'], isTrue);
    await fixture.resource(id, 'discard');
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['retained'], isFalse);
  });

  test('export pins release only after ready, unpublished intent, or owned discard proof', () async {
    await fixture.file('docs/retained.bin', [9, 0, 7]);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '[export](../docs/retained.bin)');
    final file = _entries(await fixture.run(snapshot, 'inspect'), 'files').single;
    final id = await fixture.allocate();
    final request = {'handle': file['handle'], 'leaseId': id};
    final prepared = await fixture.run(snapshot, 'prepareExport', request);
    await expectLater(fixture.run(snapshot, 'release', {'leaseId': id}), throwsA(_failure));
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['released'], isTrue);
    await fixture.run(snapshot, 'prepareExport', request);
    await fixture.resource(id, 'writeResourceIntent', {
      'version': 2, 'operation': 'export', 'name': prepared['name'], 'newName': null,
      'origin': prepared['origin'], 'binding': prepared['binding'],
    });
    await expectLater(fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}), throwsA(_failure));
    expect((await fixture.run(snapshot, 'revoke'))['retained'], isTrue);
    expect(await File('${fixture.snapshotPath(snapshot)}/files/${file['handle']}').readAsBytes(), [9, 0, 7]);
    await fixture.resource(id, 'discardExport');
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['retained'], isFalse);
    expect((await fixture.run(snapshot, 'releaseExport', {'transactionRoot': '${fixture.resources}/$id'}))['released'], isTrue);
  });

  test('sealed manifests and immutable file hashes reject replacement and stale handles', () async {
    await fixture.file('images/one.png', _png());
    final core = await fixture.owner();
    final first = await fixture.capture(core, '![one](../images/one.png) [site](https://example.test/)');
    final nav = _entries(await fixture.run(first, 'inspect'), 'navigation').single;
    final second = await fixture.capture(core, '# Other', previewId: first.previewId);
    await expectLater(fixture.run(second, 'navigation', {'handle': nav['handle']}), throwsA(_failure));
    await expectLater(fixture.capture(core, '# Replacement', previewId: first.previewId, renderId: first.renderId), throwsA(_failure));
    final file = _entries(await fixture.run(first, 'inspect'), 'files').single;
    final stored = File('${fixture.snapshotPath(first)}/files/${file['handle']}');
    await stored.rename('${stored.path}.old');
    await File(stored.path).writeAsBytes([1, 2, 3], flush: true);
    await expectLater(fixture.run(first, 'inspect'), throwsA(_failure));
    final manifest = File('${fixture.snapshotPath(second)}/manifest.json');
    await manifest.writeAsString('{}', flush: true);
    await expectLater(fixture.run(second, 'inspect'), throwsA(_failure));
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('nofollow resource reads refuse symlink escapes before issuing a handle', () async {
    final outside = File('${fixture.root.path}/outside.png');
    await outside.writeAsBytes(_png());
    await Directory('${fixture.notebook}/images').create();
    await Link('${fixture.notebook}/images/link.png').create(outside.path);
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '![link](../images/link.png)');
    expect(snapshot.imageCount, 0);
    expect(snapshot.fileCount, 0);
    expect(await outside.readAsBytes(), _png());
  }, skip: Platform.isWindows ? 'Windows symlink creation requires a separately provisioned privilege' : false);

  test('source, unique-handle and aggregate encoded limits fail atomically without notebook mutation', () async {
    final core = await fixture.owner();
    await expectLater(fixture.capture(core, 'x' * (4 * 1024 * 1024 + 1)), throwsA(_failure));
    final png = _png();
    for (var i = 0; i < 201; i++) { await fixture.file('images/$i.png', png); }
    final previewId = fixture.nextId(), renderId = fixture.nextId();
    await expectLater(fixture.capture(core,
      List.generate(201, (i) => '![$i](../images/$i.png)').join('\n'), previewId: previewId, renderId: renderId), throwsA(_failure));
    expect(await Directory('${fixture.previews}/$previewId/$renderId').exists(), isFalse);
    for (var i = 0; i < 5; i++) {
      final file = File('${fixture.notebook}/large-$i.bin');
      final handle = await file.open(mode: FileMode.write);
      try { await handle.truncate(14 * 1024 * 1024); } finally { await handle.close(); }
    }
    final largeId = fixture.nextId(), largeRender = fixture.nextId();
    await expectLater(fixture.capture(core,
      List.generate(5, (i) => '[$i](../large-$i.bin)').join('\n'), previewId: largeId, renderId: largeRender), throwsA(_failure));
    expect(await Directory('${fixture.previews}/$largeId/$largeRender').exists(), isFalse);
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });

  test('preview capability transport is closed and cancellation leaves immutable authority intact', () async {
    final core = await fixture.owner();
    final snapshot = await fixture.capture(core, '# Preserved');
    await expectLater(_preview({...snapshot.command('inspect'), 'editorToken': _id(1)}), throwsA(_failure));
    await expectLater(fixture.run(snapshot, 'navigation', {'handle': '../source.md'}), throwsA(_failure));
    await expectLater(fixture.run(snapshot, 'prepareExport', {'handle': _id(1), 'leaseId': fixture.nextId()}), throwsA(_failure));
    final cancel = CoreImportStore.createCancellation();
    try {
      CoreImportStore.requestCancellation(cancel);
      await expectLater(_preview(snapshot.command('revoke'), cancel: cancel), throwsA(_failure));
    } finally { CoreImportStore.freeCancellation(cancel); }
    expect((await fixture.run(snapshot, 'inspect'))['sourceHash'], snapshot.sourceHash);
    await core.close();
    final resourceOnly = await fixture.owner(resourceOnly: true);
    await expectLater(fixture.capture(resourceOnly, '# Not a NOTE owner'), throwsA(_failure));
    expect(await File(fixture.notePath).readAsString(), '# Disk remains original\r\n');
  });
}
