// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/notebook_import_archive.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _config = 'vx_notebook/config.json';

class _Entry {
  const _Entry(
    this.name, {
    this.bytes = const [],
    this.method = 0,
    this.flags = 0x800,
    this.attributes,
    this.rawName,
    this.localName,
    this.extra = const [],
    this.localExtra,
    this.zip64 = false,
    this.descriptor = false,
    this.signedDescriptor = true,
    this.declaredSize,
    this.declaredCrc,
    this.compressed,
  });
  final String name;
  final List<int> bytes;
  final int method;
  final int flags;
  final int? attributes;
  final List<int>? rawName;
  final List<int>? localName;
  final List<int> extra;
  final List<int>? localExtra;
  final bool zip64;
  final bool descriptor;
  final bool signedDescriptor;
  final int? declaredSize;
  final int? declaredCrc;
  final List<int>? compressed;
}

class _Writer {
  final output = BytesBuilder(copy: false);
  int get length => output.length;
  void bytes(List<int> value) => output.add(value);
  void u16(int value) => bytes(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(int value) => bytes(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => bytes(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  Uint8List take() => output.takeBytes();
}

class _Built {
  _Built(
    this.bytes,
    this.locals,
    this.data,
    this.central,
    this.eocd,
    this.zip64Offset,
  );
  final Uint8List bytes;
  final List<int> locals;
  final List<int> data;
  final List<int> central;
  final int eocd;
  final int? zip64Offset;
  void u16(int at, int value) =>
      ByteData.sublistView(bytes).setUint16(at, value, Endian.little);
  void u32(int at, int value) =>
      ByteData.sublistView(bytes).setUint32(at, value, Endian.little);
  void u64(int at, int value) =>
      ByteData.sublistView(bytes).setUint64(at, value, Endian.little);
}

List<int> _extra(int id, List<int> bytes) =>
    (_Writer()
          ..u16(id)
          ..u16(bytes.length)
          ..bytes(bytes))
        .take();

_Built _zip(List<_Entry> entries, {bool zip64 = false}) {
  final output = _Writer();
  final central = _Writer();
  final locals = <int>[];
  final data = <int>[];
  final centralRelative = <int>[];
  for (final entry in entries) {
    final name = entry.rawName ?? utf8.encode(entry.name);
    final localName = entry.localName ?? name;
    final body =
        entry.compressed ??
        (entry.method == 8
            ? ZLibEncoder(raw: true).convert(entry.bytes)
            : entry.bytes);
    final size = entry.declaredSize ?? entry.bytes.length;
    final crc = entry.declaredCrc ?? getCrc32(entry.bytes);
    final flags = entry.flags | (entry.descriptor ? 8 : 0);
    final local64 = entry.zip64
        ? _extra(
            1,
            (_Writer()
                  ..u64(entry.descriptor ? 0 : size)
                  ..u64(entry.descriptor ? 0 : body.length))
                .take(),
          )
        : <int>[];
    final central64 = entry.zip64
        ? _extra(
            1,
            (_Writer()
                  ..u64(size)
                  ..u64(body.length))
                .take(),
          )
        : <int>[];
    final localExtra = [...local64, ...(entry.localExtra ?? entry.extra)];
    final centralExtra = [...central64, ...entry.extra];
    final local = output.length;
    locals.add(local);
    output
      ..u32(0x04034b50)
      ..u16(entry.zip64 ? 45 : 20)
      ..u16(flags)
      ..u16(entry.method)
      ..u16(0)
      ..u16(0)
      ..u32(entry.descriptor ? 0 : crc)
      ..u32(
        entry.zip64
            ? 0xffffffff
            : entry.descriptor
            ? 0
            : body.length,
      )
      ..u32(
        entry.zip64
            ? 0xffffffff
            : entry.descriptor
            ? 0
            : size,
      )
      ..u16(localName.length)
      ..u16(localExtra.length)
      ..bytes(localName)
      ..bytes(localExtra);
    data.add(output.length);
    output.bytes(body);
    if (entry.descriptor) {
      if (entry.signedDescriptor) output.u32(0x08074b50);
      output.u32(crc);
      if (entry.zip64) {
        output
          ..u64(body.length)
          ..u64(size);
      } else {
        output
          ..u32(body.length)
          ..u32(size);
      }
    }
    centralRelative.add(central.length);
    central
      ..u32(0x02014b50)
      ..u16(0x031e)
      ..u16(entry.zip64 ? 45 : 20)
      ..u16(flags)
      ..u16(entry.method)
      ..u16(0)
      ..u16(0)
      ..u32(crc)
      ..u32(entry.zip64 ? 0xffffffff : body.length)
      ..u32(entry.zip64 ? 0xffffffff : size)
      ..u16(name.length)
      ..u16(centralExtra.length)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32(
        entry.attributes ??
            (entry.name.endsWith('/') ? 0x41ed0010 : 0x81a40000),
      )
      ..u32(local)
      ..bytes(name)
      ..bytes(centralExtra);
  }
  final centralOffset = output.length;
  final centralBytes = central.take();
  output.bytes(centralBytes);
  int? zip64Offset;
  if (zip64) {
    zip64Offset = output.length;
    output
      ..u32(0x06064b50)
      ..u64(44)
      ..u16(45)
      ..u16(45)
      ..u32(0)
      ..u32(0)
      ..u64(entries.length)
      ..u64(entries.length)
      ..u64(centralBytes.length)
      ..u64(centralOffset)
      ..u32(0x07064b50)
      ..u32(0)
      ..u64(zip64Offset)
      ..u32(1);
  }
  final eocd = output.length;
  output
    ..u32(0x06054b50)
    ..u16(0)
    ..u16(0)
    ..u16(zip64 ? 0xffff : entries.length)
    ..u16(zip64 ? 0xffff : entries.length)
    ..u32(zip64 ? 0xffffffff : centralBytes.length)
    ..u32(zip64 ? 0xffffffff : centralOffset)
    ..u16(0);
  return _Built(
    output.take(),
    locals,
    data,
    [for (final offset in centralRelative) centralOffset + offset],
    eocd,
    zip64Offset,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late String transaction;
  late int cancellation;

  Future<void> marker(DocumentImportKind kind) async {
    await File(p.join(transaction, 'request.json')).writeAsString(
      jsonEncode({'version': 1, 'id': _id, 'kind': kind.name}),
      flush: true,
    );
    await File(p.join(transaction, 'captured.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'id': _id,
        'kind': kind.name,
        'sourceName': 'fixture',
        'bytes': 0,
        'entries': 0,
      }),
      flush: true,
    );
  }

  Future<ImportPreparedTree> prepare(DocumentImportKind kind) {
    final root = transaction;
    final address = cancellation;
    return Isolate.run(
      () => NotebookImportArchive.prepare(
        transactionRoot: root,
        kind: kind,
        scope: DocumentTransferScope.notebook,
        format: ImportPreparationFormat.notebook,
        cancellationAddress: address,
      ),
    );
  }

  Future<ImportPreparedTree> prepareZip(_Built fixture) async {
    await marker(DocumentImportKind.zip);
    await File(p.join(transaction, 'input.zip')).writeAsBytes(fixture.bytes);
    return prepare(DocumentImportKind.zip);
  }

  Future<void> rejected(_Built fixture, {bool raw = true}) async {
    await expectLater(prepareZip(fixture), throwsA(isA<Exception>()));
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
    expect(await File(p.join(transaction, 'prepared.json')).exists(), isFalse);
    expect(
      await File(p.join(transaction, 'publication.json')).exists(),
      isFalse,
    );
    expect(
      await Directory(p.join(temporary.path, 'notebooks')).list().isEmpty,
      isTrue,
    );
    if (raw) {
      expect(
        await Directory(p.join(transaction, 'unpacked')).exists(),
        isFalse,
      );
    }
    expect(
      await File(p.join(transaction, 'input.zip')).readAsBytes(),
      fixture.bytes,
    );
  }

  Future<void> folder(
    Map<String, List<int>?> entries, {
    List<Map<String, String>>? accepted,
  }) async {
    await marker(DocumentImportKind.folder);
    final root = p.join(transaction, 'unpacked');
    await Directory(root).create();
    for (final entry in entries.entries) {
      final path = p.joinAll([root, ...entry.key.split('/')]);
      if (entry.value == null) {
        await Directory(path).create(recursive: true);
      } else {
        await Directory(p.dirname(path)).create(recursive: true);
        await File(path).writeAsBytes(entry.value!);
      }
    }
    final paths = <String, String>{};
    for (final entry in entries.entries) {
      final parts = entry.key.split('/');
      for (var i = 1; i < parts.length; i++) {
        paths[parts.take(i).join('/')] = 'directory';
      }
      paths[entry.key] = entry.value == null ? 'directory' : 'file';
    }
    final records =
        accepted ??
        [
          for (final entry in paths.entries)
            {'path': entry.key, 'type': entry.value},
        ];
    await File(
      p.join(transaction, 'accepted.jsonl'),
    ).writeAsString(records.map((record) => '${jsonEncode(record)}\n').join());
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'notebook-import-archive-',
    );
    transaction = p.join(temporary.path, 'imports', _id);
    await Directory(transaction).create(recursive: true);
    await Directory(p.join(temporary.path, 'notebooks')).create();
    await Directory(p.join(temporary.path, 'exports')).create();
    cancellation = CoreImportStore.createCancellation();
  });

  tearDown(() async {
    CoreImportStore.freeCancellation(cancellation);
    await temporary.delete(recursive: true);
  });

  Future<void> allocateFiles(
    DocumentImportKind kind, {
    DocumentTransferScope scope = DocumentTransferScope.cohort,
  }) async {
    await Directory(transaction).delete();
    final root = p.join(
      temporary.path,
      scope == DocumentTransferScope.cohort ? 'cohorts' : 'resources',
    );
    await Directory(root).create();
    transaction = p.join(root, _id);
    await Isolate.run(
      () => CoreImportStore.runTransfer({
        'op': 'allocate',
        'scope': scope.name,
        'root': root,
        'notebooksRoot': p.join(temporary.path, 'notebooks'),
        'id': _id,
        'kind': kind.name,
        'target': {
          'version': 1,
          'id': _id,
          'notebookId': '11111111-1111-4111-8111-111111111111',
          'notebookRelative': 'fixture',
          if (scope == DocumentTransferScope.cohort) ...{
            'parentId': '22222222-2222-4222-8222-222222222222',
            'folderName': 'Imported files',
          } else
            'nodeId': '22222222-2222-4222-8222-222222222222',
        },
      }),
    );
  }

  Future<ImportPreparedTree> prepareFiles(
    DocumentImportKind kind, {
    required int bytes,
    required int entries,
    DocumentTransferScope scope = DocumentTransferScope.cohort,
  }) async {
    final root = transaction;
    final address = cancellation;
    final notebooks = p.join(temporary.path, 'notebooks');
    return Isolate.run(() async {
      CoreImportStore.runTransfer({
        'op': 'capture',
        'scope': scope.name,
        'root': p.dirname(root),
        'notebooksRoot': notebooks,
        'id': _id,
        'sourceName': 'Raw fixture',
        'bytes': bytes,
        'entries': entries,
      });
      return NotebookImportArchive.prepare(
        transactionRoot: root,
        kind: kind,
        scope: scope,
        format: ImportPreparationFormat.files,
        cancellationAddress: address,
      );
    });
  }

  test(
    'files ZIP keeps its sole wrapper and every hidden opaque byte',
    () async {
      await allocateFiles(DocumentImportKind.zip);
      final zip = _zip([
        _Entry(
          'Wrapper/note.md',
          bytes: utf8.encode('![picture](assets/图.png)\n'),
        ),
        const _Entry('Wrapper/assets/图.png', bytes: [0, 255, 128, 3]),
        const _Entry('Wrapper/.hidden', bytes: [0, 42, 255]),
        const _Entry('Wrapper/empty/'),
      ]);
      await File(p.join(transaction, 'input.zip')).writeAsBytes(zip.bytes);
      final prepared = await prepareFiles(
        DocumentImportKind.zip,
        bytes: zip.bytes.length,
        entries: 1,
      );
      expect(prepared.treeRelative, 'unpacked');
      expect(prepared.entries, 6);
      expect(
        await File(p.join(transaction, 'unpacked/Wrapper/.hidden'))
            .readAsBytes(),
        [0, 42, 255],
      );
      expect(
        await File(p.join(transaction, 'unpacked/Wrapper/assets/图.png'))
            .readAsBytes(),
        [0, 255, 128, 3],
      );
      final inventory = await File(p.join(transaction, 'inventory.jsonl'))
          .readAsBytes();
      expect(
        prepared.inventoryHash,
        crypto.sha256.convert(inventory).toString(),
      );
      expect(
        (jsonDecode(const LineSplitter().convert(utf8.decode(inventory)).first)
            as Map)['path'],
        'Wrapper',
      );
      expect(
        await File(p.join(transaction, 'prepared.json')).exists(),
        isFalse,
      );
    },
  );

  test('files mode accepts empty standalone opaque input without notebook metadata', () async {
    await allocateFiles(DocumentImportKind.file);
    await Directory(p.join(transaction, 'unpacked')).create();
    await File(p.join(transaction, 'unpacked/empty.bin')).writeAsBytes([]);
    await File(
      p.join(transaction, 'accepted.jsonl'),
    ).writeAsString('${jsonEncode({'path': 'empty.bin', 'type': 'file'})}\n');
    final prepared = await prepareFiles(
      DocumentImportKind.file,
      bytes: 0,
      entries: 1,
    );
    expect(prepared.treeRelative, 'unpacked');
    expect(prepared.bytes, 0);
    expect(prepared.entries, 1);
    expect(
      jsonDecode(
        await File(p.join(transaction, 'inventory.jsonl')).readAsString(),
      )['sha256'],
      crypto.sha256.convert(const <int>[]).toString(),
    );
  });

  test('preparation scope cannot address another private namespace', () async {
    await allocateFiles(DocumentImportKind.zip);
    final root = transaction;
    final address = cancellation;
    await expectLater(
      Isolate.run(
        () => NotebookImportArchive.prepare(
          transactionRoot: root,
          kind: DocumentImportKind.zip,
          scope: DocumentTransferScope.resource,
          format: ImportPreparationFormat.files,
          cancellationAddress: address,
        ),
      ),
      throwsA(isA<NotebookImportArchiveException>()),
    );
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
  });

  test('stored root preserves opaque bytes and inventories every physical directory', () async {
    final config = utf8.encode('{ "opaque": [1, 2], "id": "unchanged" }\n');
    final opaque = [0, 255, 0, 128, 42];
    final prepared = await prepareZip(
      _zip([
        _Entry(_config, bytes: config),
        _Entry('private/opaque.bin', bytes: opaque),
        const _Entry('private/empty/'),
        const _Entry('private/'), // acknowledges the earlier implicit directory
      ]),
    );
    expect(prepared.treeRelative, 'unpacked');
    expect(prepared.bytes, config.length + opaque.length);
    expect(prepared.entries, 5);
    expect(
      await File(p.join(transaction, 'unpacked', _config)).readAsBytes(),
      config,
    );
    expect(
      await File(p.join(transaction, 'unpacked/private/opaque.bin'))
          .readAsBytes(),
      opaque,
    );
    final inventory = await File(p.join(transaction, 'inventory.jsonl'))
        .readAsBytes();
    expect(prepared.inventoryHash, crypto.sha256.convert(inventory).toString());
    final records = const LineSplitter()
        .convert(utf8.decode(inventory))
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(records.map((record) => record['path']), [
      'private',
      'private/empty',
      'private/opaque.bin',
      'vx_notebook',
      _config,
    ]);
    expect(records[1], {
      'path': 'private/empty',
      'type': 'directory',
      'size': 0,
      'sha256': '',
    });
    expect(records[2]['sha256'], crypto.sha256.convert(opaque).toString());
    expect(await File(p.join(transaction, 'prepared.json')).exists(), isFalse);
    expect(
      await Directory(p.join(temporary.path, 'notebooks')).list().isEmpty,
      isTrue,
    );
  });

  test(
    'sole wrapper is retained in inventory and selects the candidate only',
    () async {
      final prepared = await prepareZip(
        _zip([
          const _Entry(
            'My notebook/vx_notebook/config.json',
            bytes: [123, 125],
          ),
          const _Entry('My notebook/assets/empty/'),
        ]),
      );
      expect(prepared.treeRelative, 'unpacked/My notebook');
      expect(prepared.entries, 5);
      final records = await File(p.join(transaction, 'inventory.jsonl'))
          .readAsLines();
      expect(jsonDecode(records.first)['path'], 'My notebook');
    },
  );

  test(
    'extra root siblings are not dropped to find a wrapped notebook',
    () async {
      await rejected(
        _zip([
          const _Entry('wrapper/vx_notebook/config.json', bytes: [123, 125]),
          const _Entry('README.txt', bytes: [1]),
        ]),
        raw: false,
      );
    },
  );

  test(
    'deflate backreferences preserve bytes across the 32KiB history boundary',
    () async {
      final random = Random(31);
      final block = List<int>.generate(8192, (_) => random.nextInt(256));
      final body = [for (var i = 0; i < 16; i++) ...block];
      final prepared = await prepareZip(
        _zip([
          const _Entry(_config, bytes: [123, 125], method: 8),
          _Entry('opaque.bin', bytes: body, method: 8),
          const _Entry('empty/', method: 8),
        ]),
      );
      expect(prepared.bytes, body.length + 2);
      expect(
        await File(p.join(transaction, 'unpacked/opaque.bin')).readAsBytes(),
        body,
      );
    },
  );

  for (final zip64 in [false, true]) {
    for (final signed in [false, true]) {
      test(
        'valid ${zip64 ? 'ZIP64' : 'classic'} ${signed ? 'signed' : 'unsigned'} descriptor',
        () async {
          final prepared = await prepareZip(
            _zip([
              _Entry(
                _config,
                bytes: const [123, 125],
                method: 8,
                zip64: zip64,
                descriptor: true,
                signedDescriptor: signed,
              ),
            ], zip64: zip64),
          );
          expect(prepared.bytes, 2);
          expect(prepared.entries, 2);
        },
      );
    }
  }

  for (final pair in [
    ['Straße', 'STRASSE'],
    ['é', 'e\u0301'],
    ['Å', 'Å'],
    ['σ', 'ς'],
    ['ﬃ', 'ffi'],
    ['İ', 'i\u0307'],
    ['Dir/one', 'dir/two'],
    ['parent', 'parent/child'],
    ['parent/child', 'parent'],
    ['directory/', 'directory/'],
    ['same', 'same'],
  ]) {
    test(
      'rejects dual-key/prefix collision ${jsonEncode(pair)} before extraction',
      () async {
        await rejected(
          _zip([const _Entry(_config), _Entry(pair[0]), _Entry(pair[1])]),
        );
      },
    );
  }

  for (final name in [
    '../escape',
    '/absolute',
    'C:/drive',
    '//host/path',
    'a\\b',
    'a//b',
    'a/./b',
    'a/../b',
    'a\u0000b',
    'a\u0085b',
    'trailing.',
    'trailing ',
    'CON',
    'nul.txt',
    'COM¹',
    'LPT9.log',
    'stream:ads',
    ('x' * 256),
    (List.filled(33, 'a').join('/')),
    '${'a' * 255}/${'b' * 255}/${'c' * 255}/${'d' * 255}/e',
  ]) {
    test('rejects nonportable path ${jsonEncode(name)}', () async {
      await rejected(_zip([const _Entry(_config), _Entry(name)]));
    });
  }

  test('local filename cannot contradict the central directory', () async {
    await rejected(
      _zip([
        const _Entry(_config),
        _Entry('safe', localName: utf8.encode('other')),
      ]),
    );
  });
  test('local-only Unicode path extra cannot rename an entry', () async {
    final extra =
        (_Writer()
              ..bytes([1])
              ..u32(getCrc32(utf8.encode('safe')))
              ..bytes(utf8.encode('other')))
            .take();
    await rejected(
      _zip([
        const _Entry(_config),
        _Entry('safe', localExtra: _extra(0x7075, extra)),
      ]),
    );
  });

  test('invalid UTF8 is rejected without decoding content', () async {
    await rejected(
      _zip([
        const _Entry(_config),
        const _Entry('bad', rawName: [0xc0, 0xaf]),
      ]),
    );
  });

  test('non-ASCII names without UTF8 flag are rejected', () async {
    await rejected(
      _zip([const _Entry(_config), const _Entry('café', flags: 0)]),
    );
  });

  test('matching Unicode path extra preserves spelling', () async {
    final name = utf8.encode('café');
    final unicode =
        (_Writer()
              ..bytes([1])
              ..u32(getCrc32(name))
              ..bytes(name))
            .take();
    final prepared = await prepareZip(
      _zip([
        const _Entry(_config),
        _Entry('café', extra: _extra(0x7075, unicode)),
      ]),
    );
    expect(prepared.entries, 3);
    expect(await File(p.join(transaction, 'unpacked/café')).exists(), isTrue);
  });

  test('Unicode path extra cannot silently rename a raw path', () async {
    final unicode =
        (_Writer()
              ..bytes([1])
              ..u32(getCrc32(utf8.encode('raw')))
              ..bytes(utf8.encode('renamed')))
            .take();
    await rejected(
      _zip([
        const _Entry(_config),
        _Entry('raw', extra: _extra(0x7075, unicode)),
      ]),
    );
  });

  for (final attribute in [
    0xa1ff0000,
    0x21ff0000,
    0x61ff0000,
    0x11ff0000,
    0xc1ff0000,
    0x81a40400,
    0x81a40010,
    0x81a40008,
  ]) {
    test(
      'rejects link/special/contradictory attributes ${attribute.toRadixString(16)}',
      () async {
        await rejected(
          _zip([
            const _Entry(_config),
            _Entry('unsafe', attributes: attribute, bytes: const [1]),
          ]),
        );
      },
    );
  }

  test('PKWARE Unix hardlink payload is refused before decoder', () async {
    await rejected(
      _zip([
        const _Entry(_config),
        _Entry('unsafe', extra: _extra(0x000d, List.filled(13, 0))),
      ]),
    );
  });

  test('ASi Unix symlink encoding is refused before decoder', () async {
    final mode =
        (_Writer()
              ..u16(0xa1ff)
              ..u32(0)
              ..u16(0)
              ..u16(0))
            .take();
    final asi =
        (_Writer()
              ..u32(getCrc32(mode))
              ..bytes(mode))
            .take();
    await rejected(
      _zip([
        const _Entry(_config),
        _Entry('unsafe', extra: _extra(0x756e, asi)),
      ]),
    );
  });

  for (final flags in [1, 0x40, 0x2000, 0x10, 0x20]) {
    test('rejects encrypted/patched/unsupported flag $flags', () async {
      await rejected(_zip([_Entry(_config, flags: 0x800 | flags)]));
    });
  }

  test('unsupported compression is refused before materialization', () async {
    await rejected(_zip([const _Entry(_config, method: 12)]));
  });

  final mutations = <String, void Function(_Built)>{
    'disk number': (zip) => zip.u16(zip.eocd + 4, 1),
    'central disk number': (zip) => zip.u16(zip.eocd + 6, 1),
    'per-disk count': (zip) => zip.u16(zip.eocd + 8, 0),
    'central offset': (zip) => zip.u32(zip.eocd + 16, zip.central.first + 1),
    'central byte range': (zip) => zip.u32(zip.eocd + 12, 46),
    'local method': (zip) => zip.u16(zip.locals.first + 8, 8),
    'local flags': (zip) => zip.u16(zip.locals.first + 6, 0),
    'local CRC': (zip) => zip.u32(zip.locals.first + 14, 123),
    'local size': (zip) => zip.u32(zip.locals.first + 22, 3),
    'local raw name': (zip) => zip.bytes[zip.locals.first + 30] = 65,
    'entry disk': (zip) => zip.u16(zip.central.first + 34, 1),
    'offset into central': (zip) =>
        zip.u32(zip.central.first + 42, zip.central.first),
    'unsupported version': (zip) => zip.u16(zip.central.first + 6, 63),
    'missing ZIP64 locator': (zip) => zip.u16(zip.eocd + 8, 0xffff),
  };
  for (final mutation in mutations.entries) {
    test('raw preflight rejects ${mutation.key}', () async {
      final fixture = _zip([
        const _Entry(_config, bytes: [123, 125]),
      ]);
      mutation.value(fixture);
      await rejected(fixture);
    });
  }

  test('overlapping local/data ranges fail before any output', () async {
    final fixture = _zip([
      const _Entry(_config, bytes: [123, 125]),
      const _Entry('second', bytes: [1, 2, 3]),
    ]);
    final overlap = fixture.data[1] - fixture.data[0] + 1;
    fixture.u32(fixture.locals[0] + 18, overlap);
    fixture.u32(fixture.locals[0] + 22, overlap);
    fixture.u32(fixture.central[0] + 20, overlap);
    fixture.u32(fixture.central[0] + 24, overlap);
    await rejected(fixture);
  });

  test('descriptor CRC must agree with the central directory', () async {
    final fixture = _zip([
      const _Entry(_config, bytes: [123, 125], descriptor: true),
    ]);
    fixture.u32(fixture.data.first + 2 + 4, 1);
    await rejected(fixture);
  });

  for (final mutation in <String, void Function(_Built)>{
    'locator disk': (zip) => zip.u32(zip.eocd - 16, 1),
    'locator disk total': (zip) => zip.u32(zip.eocd - 4, 2),
    'end count': (zip) => zip.u64(zip.zip64Offset! + 32, 2),
    'end range': (zip) => zip.u64(zip.zip64Offset! + 40, 1),
    'negative unsigned size': (zip) => zip.bytes[zip.zip64Offset! + 47] = 0x80,
    'record size': (zip) => zip.u64(zip.zip64Offset! + 4, 43),
    'too many entries': (zip) {
      zip.u64(zip.zip64Offset! + 24, 100001);
      zip.u64(zip.zip64Offset! + 32, 100001);
    },
    'missing per-entry extra': (zip) =>
        zip.u16(zip.central.first + 46 + _config.length, 2),
  }.entries) {
    test('ZIP64 preflight rejects ${mutation.key}', () async {
      final fixture = _zip([
        const _Entry(_config, bytes: [123, 125], zip64: true),
      ], zip64: true);
      mutation.value(fixture);
      await rejected(fixture);
    });
  }

  test('file size limit is enforced before expansion', () async {
    await rejected(
      _zip([
        const _Entry(
          _config,
          method: 8,
          declaredSize: 256 * 1024 * 1024 + 1,
          compressed: [3, 0],
        ),
      ]),
    );
  });

  test(
    'aggregate declared tree limit is independent of per-file and ratio limits',
    () async {
      const size = 256 * 1024 * 1024;
      final boundedCompressed = Uint8List((size + 99) ~/ 100);
      await rejected(
        _zip([
          for (var i = 0; i < 9; i++)
            _Entry(
              'entry$i',
              method: 8,
              declaredSize: size,
              compressed: boundedCompressed,
            ),
        ]),
      );
    },
  );

  test('exact 100:1 declaration passes raw ratio preflight', () async {
    await rejected(
      _zip([
        const _Entry(_config, method: 8, declaredSize: 200, compressed: [3, 0]),
      ]),
      raw: false,
    );
    // The intentionally short payload fails actual size verification, not the
    // inclusive ratio boundary; reaching extraction makes that observable.
    expect(await Directory(p.join(transaction, 'unpacked')).exists(), isTrue);
  });

  test('one byte over 100:1 declaration fails before extraction', () async {
    await rejected(
      _zip([
        const _Entry(_config, method: 8, declaredSize: 201, compressed: [3, 0]),
      ]),
    );
  });

  test(
    'unsigned descriptor may have the optional signature as its CRC',
    () async {
      await rejected(
        _zip([
          const _Entry(
            _config,
            bytes: [1, 2],
            descriptor: true,
            signedDescriptor: false,
            declaredCrc: 0x08074b50,
          ),
        ]),
        raw: false,
      );
      expect(await Directory(p.join(transaction, 'unpacked')).exists(), isTrue);
    },
  );

  test('declared expansion ratio is enforced before decoding', () async {
    await rejected(
      _zip([_Entry(_config, bytes: List.filled(65536, 0), method: 8)]),
    );
  });

  test(
    'actual expansion cannot exceed a smaller trusted declaration',
    () async {
      await rejected(
        _zip([
          _Entry(
            _config,
            bytes: List.filled(65536, 0),
            method: 8,
            declaredSize: 1,
          ),
        ]),
        raw: false,
      );
    },
  );

  test(
    'stored bytes must match CRC, not merely matching header CRCs',
    () async {
      await rejected(
        _zip([
          const _Entry(_config, bytes: [123, 125], declaredCrc: 123),
        ]),
        raw: false,
      );
    },
  );

  test('empty raw deflate still requires a complete final block', () async {
    await rejected(
      _zip([
        const _Entry(_config, method: 8, compressed: [3]),
      ]),
      raw: false,
    );
  });

  test('trailing deflate bytes are not silently ignored', () async {
    await rejected(
      _zip([
        const _Entry(_config, method: 8, compressed: [3, 0, 0]),
      ]),
      raw: false,
    );
  });

  test('ZIP input quota checks physical length without buffering', () async {
    await marker(DocumentImportKind.zip);
    final handle = await File(p.join(transaction, 'input.zip'))
        .open(mode: FileMode.write);
    await handle.truncate(1024 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
      prepare(DocumentImportKind.zip),
      throwsA(isA<Exception>()),
    );
    expect(await Directory(p.join(transaction, 'unpacked')).exists(), isFalse);
  });

  test(
    'provider copy accepts compressible content without ZIP ratio restriction',
    () async {
      final bytes = List.filled(65536, 0);
      await folder({
        _config: [123, 125],
        'opaque': bytes,
        'empty': null,
      });
      final prepared = await prepare(DocumentImportKind.folder);
      expect(prepared.treeRelative, 'unpacked');
      expect(prepared.bytes, bytes.length + 2);
      expect(prepared.entries, 4);
    },
  );

  test('accepted provider file cannot become a physical directory', () async {
    await folder(
      {
        _config: [123, 125],
        'changed': null,
      },
      accepted: [
        {'path': 'vx_notebook', 'type': 'directory'},
        {'path': _config, 'type': 'file'},
        {'path': 'changed', 'type': 'file'},
      ],
    );
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
  });

  test('provider symlink is rejected without opening its target', () async {
    await folder({
      _config: [123, 125],
      'linked': [],
    });
    final path = p.join(transaction, 'unpacked/linked');
    await File(path).delete();
    final outside = File(p.join(temporary.path, 'outside'));
    await outside.writeAsString('untouched');
    await Link(path).create(outside.path);
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsA(isA<Exception>()),
    );
    expect(await outside.readAsString(), 'untouched');
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
  }, skip: Platform.isWindows);

  test('provider inventory requires exact original spelling, not just folding keys', () async {
    await folder(
      {
        _config: [123, 125],
        'Case': [1],
      },
      accepted: [
        {'path': 'vx_notebook', 'type': 'directory'},
        {'path': _config, 'type': 'file'},
        {'path': 'case', 'type': 'file'},
      ],
    );
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
  });

  test('provider inventory requires exact canonical spelling', () async {
    await folder(
      {
        _config: [123, 125],
        'é': [1],
      },
      accepted: [
        {'path': 'vx_notebook', 'type': 'directory'},
        {'path': _config, 'type': 'file'},
        {'path': 'e\u0301', 'type': 'file'},
      ],
    );
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
  });

  test(
    'provider file types and complete physical set must match accepted list',
    () async {
      await folder(
        {
          _config: [123, 125],
          'extra': [1],
        },
        accepted: [
          {'path': 'vx_notebook', 'type': 'directory'},
          {'path': _config, 'type': 'file'},
        ],
      );
      await expectLater(
        prepare(DocumentImportKind.folder),
        throwsFormatException,
      );
    },
  );

  test('provider cannot omit an implicit parent record', () async {
    await folder(
      {
        _config: [123, 125],
      },
      accepted: [
        {'path': _config, 'type': 'file'},
      ],
    );
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
  });

  test(
    'provider accepted inventory rejects full Unicode case-fold aliases',
    () async {
      await folder(
        {
          _config: [123, 125],
        },
        accepted: [
          {'path': 'vx_notebook', 'type': 'directory'},
          {'path': _config, 'type': 'file'},
          {'path': 'Straße', 'type': 'file'},
          {'path': 'STRASSE', 'type': 'file'},
        ],
      );
      await expectLater(
        prepare(DocumentImportKind.folder),
        throwsFormatException,
      );
    },
  );

  test('provider record length is bounded before JSON parsing', () async {
    await folder({
      _config: [123, 125],
    });
    await File(p.join(transaction, 'accepted.jsonl'))
        .writeAsString('${' ' * 8193}\n');
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
  });

  test(
    'provider record count is bounded even when physical files are absent',
    () async {
      await folder({
        _config: [123, 125],
      });
      final output = File(p.join(transaction, 'accepted.jsonl')).openWrite();
      for (var i = 0; i <= 100000; i++) {
        output.writeln(jsonEncode({'path': 'd$i', 'type': 'directory'}));
      }
      await output.close();
      await expectLater(
        prepare(DocumentImportKind.folder),
        throwsFormatException,
      );
    },
  );

  test('provider physical file byte limit is checked before hashing', () async {
    await folder({
      _config: [123, 125],
      'large': [],
    });
    final handle = await File(p.join(transaction, 'unpacked/large'))
        .open(mode: FileMode.write);
    await handle.truncate(256 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
      prepare(DocumentImportKind.folder),
      throwsFormatException,
    );
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).exists(),
      isFalse,
    );
  });

  test(
    'provider root is not silently stripped as an archive wrapper',
    () async {
      await folder({
        'wrapper/$_config': [123, 125],
      });
      await expectLater(
        prepare(DocumentImportKind.folder),
        throwsFormatException,
      );
    },
  );

  test(
    'inventory is UTF8 sorted across supplementary/BMP code points',
    () async {
      final prepared = await prepareZip(
        _zip([
          const _Entry(_config),
          const _Entry('\u{10000}'),
          const _Entry('\ue000'),
        ]),
      );
      expect(prepared.entries, 4);
      final lines = await File(p.join(transaction, 'inventory.jsonl'))
          .readAsLines();
      final paths = lines.map((line) => jsonDecode(line)['path']).toList();
      expect(paths, ['vx_notebook', _config, '\ue000', '\u{10000}']);
    },
  );

  test(
    'atomic cancellation at entry boundary creates no output or publication',
    () async {
      await marker(DocumentImportKind.zip);
      await File(p.join(transaction, 'input.zip')).writeAsBytes(
        _zip([
          const _Entry(_config, bytes: [123, 125]),
        ]).bytes,
      );
      CoreImportStore.requestCancellation(cancellation);
      expect(CoreImportStore.queryCancellation(cancellation), isTrue);
      await expectLater(prepare(DocumentImportKind.zip), throwsStateError);
      expect(
        await Directory(p.join(transaction, 'unpacked')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(transaction, 'inventory.jsonl')).exists(),
        isFalse,
      );
      expect(
        await Directory(p.join(temporary.path, 'notebooks')).list().isEmpty,
        isTrue,
      );
    },
  );

  test(
    'existing extraction destination is never reused or overwritten',
    () async {
      await Directory(p.join(transaction, 'unpacked')).create();
      final foreign = File(p.join(transaction, 'unpacked/foreign'));
      await foreign.writeAsString('untouched');
      await rejected(_zip([const _Entry(_config)]), raw: false);
      expect(await foreign.readAsString(), 'untouched');
    },
  );

  test('existing inventory is never overwritten', () async {
    await File(p.join(transaction, 'inventory.jsonl'))
        .writeAsString('untouched');
    await expectLater(
      prepareZip(_zip([const _Entry(_config)])),
      throwsFormatException,
    );
    expect(
      await File(p.join(transaction, 'inventory.jsonl')).readAsString(),
      'untouched',
    );
  });
}
