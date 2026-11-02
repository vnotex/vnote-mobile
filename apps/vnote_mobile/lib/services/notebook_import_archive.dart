// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        ByteOrder,
        Inflate,
        InputFileStream,
        InputStream,
        OutputStream,
        ZipFileHeader,
        getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';

class ImportPreparedTree {
  const ImportPreparedTree({
    required this.treeRelative,
    required this.inventoryHash,
    required this.bytes,
    required this.entries,
  });

  final String treeRelative;
  final String inventoryHash;
  final int bytes;
  final int entries;
}

/// Worker-only preparation. No core context, provider lease or publication is
/// acquired here. Failed output remains private and has no prepared marker.
class NotebookImportArchive {
  static Future<ImportPreparedTree> prepare({
    required String transactionRoot,
    required DocumentImportKind kind,
    required int cancellationAddress,
  }) async {
    final worker = _Preparation(transactionRoot, cancellationAddress);
    return worker.prepare(kind);
  }
}

const _zipLimit = 1024 * 1024 * 1024;
const _treeLimit = 2 * 1024 * 1024 * 1024;
const _fileLimit = 256 * 1024 * 1024;
const _entryLimit = 100000;
const _lineLimit = 8192;
const _chunkSize = 64 * 1024;
const _ratio = 100;
final _reservedDevice = RegExp(r'^(COM|LPT)[1-9¹²³]$');

/// Only fixed application-authored diagnostics; never codec source excerpts.
class NotebookImportArchiveException extends FormatException {
  const NotebookImportArchiveException(super.message);
}

Never _bad(String message) => throw NotebookImportArchiveException(message);

class _Cancellation {
  _Cancellation(this.address);
  final int address;

  void check() {
    if (address != 0 && CoreImportStore.queryCancellation(address)) {
      throw StateError('Notebook import cancelled.');
    }
  }
}

class _Name {
  _Name(this.path, this.directory, this.explicit);
  final String path;
  final bool directory;
  bool explicit;
}

/// Keys include every prefix, not merely leaf paths. An explicit directory may
/// acknowledge an implicit parent once, but may not change its spelling.
class _Names {
  final entries = <String, _Name>{};
  final _nfc = <String, String>{};
  final _nfd = <String, String>{};

  void add(String path, bool directory) {
    _validatePath(path);
    final parts = path.split('/');
    var prefix = '';
    for (var i = 0; i < parts.length; i++) {
      prefix = prefix.isEmpty ? parts[i] : '$prefix/${parts[i]}';
      final leaf = i == parts.length - 1;
      final isDirectory = !leaf || directory;
      final previous = entries[prefix];
      if (previous != null) {
        if (!previous.directory ||
            !isDirectory ||
            (leaf && previous.explicit)) {
          _bad('Duplicate path or file/directory collision.');
        }
        if (leaf) previous.explicit = true;
        continue;
      }
      if (entries.length >= _entryLimit) _bad('Too many imported entries.');
      final keys = CoreImportStore.pathKeys(prefix);
      if ((_nfc[keys.nfc] != null && _nfc[keys.nfc] != prefix) ||
          (_nfd[keys.nfd] != null && _nfd[keys.nfd] != prefix)) {
        _bad('Case-folded or canonically equivalent paths collide.');
      }
      _nfc[keys.nfc] = prefix;
      _nfd[keys.nfd] = prefix;
      entries[prefix] = _Name(prefix, isDirectory, leaf);
    }
  }
}

void _validatePath(String path) {
  final encoded = utf8.encode(path);
  if (path.isEmpty ||
      encoded.length > 1024 ||
      utf8.decode(encoded) != path ||
      path.startsWith('/')) {
    _bad('Invalid imported path.');
  }
  final parts = path.split('/');
  if (parts.length > 32) _bad('Imported path is too deep.');
  for (final part in parts) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        utf8.encode(part).length > 255) {
      _bad('Invalid imported path component.');
    }
    for (final rune in part.runes) {
      if (rune < 32 ||
          (rune >= 127 && rune <= 159) ||
          const {60, 62, 58, 34, 92, 124, 63, 42}.contains(rune)) {
        _bad('Nonportable imported path.');
      }
    }
    final base = part.split('.').first.toUpperCase();
    if (const {
          'CON',
          'PRN',
          'AUX',
          'NUL',
          r'CLOCK$',
          r'CONIN$',
          r'CONOUT$',
        }.contains(base) ||
        _reservedDevice.hasMatch(base)) {
      _bad('Reserved imported path component.');
    }
  }
}

// UTF-8 lexical order is scalar order, not Dart's UTF-16 compareTo order.
int _comparePaths(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    var ac = a.codeUnitAt(i++);
    var bc = b.codeUnitAt(j++);
    if (ac >= 0xd800 && ac <= 0xdbff) {
      ac = 0x10000 + ((ac - 0xd800) << 10) + a.codeUnitAt(i++) - 0xdc00;
    }
    if (bc >= 0xd800 && bc <= 0xdbff) {
      bc = 0x10000 + ((bc - 0xd800) << 10) + b.codeUnitAt(j++) - 0xdc00;
    }
    if (ac != bc) return ac.compareTo(bc);
  }
  return (a.length - i).compareTo(b.length - j);
}

class _Preparation {
  _Preparation(String root, int address)
    : root = p.normalize(p.absolute(root)),
      cancel = _Cancellation(address);

  final String root;
  final _Cancellation cancel;
  String get unpacked => p.join(root, 'unpacked');

  Future<ImportPreparedTree> prepare(DocumentImportKind kind) async {
    cancel.check();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(root)) ||
        p.basename(p.dirname(root)) != 'imports') {
      _bad('Invalid import transaction location.');
    }
    _directory(root);
    // Native no-follow traversal rejects hardlinks/reparse/special files before
    // any Dart input open; FileStat alone does not expose a link count.
    _checkSpace(0);
    _absent(p.join(root, 'inventory.jsonl'));
    _absent(p.join(root, 'inventory.jsonl.tmp'));
    final _Names accepted;
    if (kind == DocumentImportKind.zip) {
      final input = p.join(root, 'input.zip');
      _regular(input);
      final raw = _RawZip(input, cancel);
      try {
        raw.preflight();
        accepted = raw.names;
        _reserve(raw.uncompressed, accepted.entries.length);
        _absent(unpacked);
        Directory(unpacked).createSync();
        _extract(input, raw);
      } finally {
        raw.close();
      }
    } else {
      _directory(unpacked);
      accepted = _readAccepted();
      _reserve(0, accepted.entries.length);
    }
    cancel.check();
    final actual = await _walk(accepted);
    if (actual.length != accepted.entries.length) {
      _bad('The physical tree differs from the accepted names.');
    }
    final treeRelative = _candidate(kind, accepted);
    return _inventory(actual, treeRelative);
  }

  void _reserve(int outputBytes, int entries) {
    // 8 KiB per inventory record is an upper bound even with JSON escaping;
    // inspection has its own bounded metadata/cache allowance, never a body copy.
    _checkSpace(outputBytes + entries * _lineLimit + 64 * 1024 * 1024);
  }

  void _checkSpace(int requiredBytes) {
    CoreImportStore.run({
      'op': 'checkSpace',
      'importsRoot': p.dirname(root),
      'notebooksRoot': p.join(p.dirname(p.dirname(root)), 'notebooks'),
      'id': p.basename(root),
      'requiredBytes': requiredBytes,
    }, cancellationAddress: cancel.address);
    cancel.check();
  }

  _Names _readAccepted() {
    final accepted = _Names();
    final file = p.join(root, 'accepted.jsonl');
    _regular(file);
    var count = 0;
    _lines(file, cancel, (line) {
      if (++count > _entryLimit) _bad('Too many accepted provider entries.');
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> ||
          value.length != 2 ||
          value['path'] is! String ||
          (value['type'] != 'file' && value['type'] != 'directory')) {
        _bad('Invalid provider accepted-name record.');
      }
      accepted.add(value['path'] as String, value['type'] == 'directory');
    });
    if (accepted.entries.values.any((entry) => !entry.explicit)) {
      _bad('Provider inventory omitted a physical directory.');
    }
    return accepted;
  }

  void _extract(String inputPath, _RawZip raw) {
    final directories =
        raw.names.entries.values.where((entry) => entry.directory).toList()
          ..sort((a, b) => _comparePaths(a.path, b.path));
    for (final directory in directories) {
      cancel.check();
      final path = _under(unpacked, directory.path);
      _directory(p.dirname(path));
      _absent(path);
      Directory(path).createSync();
    }
    final input = InputFileStream(inputPath, bufferSize: _chunkSize);
    final budget = _OutputBudget(raw.compressed, cancel);
    try {
      for (final entry in raw.entries) {
        cancel.check();
        // The maintained parser is deliberately invoked only AFTER every raw
        // header/range/type has passed preflight. Parsing one entry bounds extra
        // and comment allocation independently of the central directory size.
        input.position = entry.centralOffset + 4;
        final header = ZipFileHeader()
          ..read(input, fileBytes: input, verify: true, filenameEncoding: utf8);
        final parsed = header.file;
        if (header.filename != entry.rawName ||
            parsed == null ||
            parsed.filename != entry.rawName ||
            header.compressedSize != entry.compressed ||
            header.uncompressedSize != entry.uncompressed ||
            parsed.crc32 != entry.crc ||
            header.crc32 != entry.crc ||
            header.localHeaderOffset != entry.localOffset ||
            header.generalPurposeBitFlag != entry.flags ||
            header.compressionMethod != entry.method) {
          _bad('ZIP parser disagrees with raw preflight.');
        }
        RandomAccessFile? output;
        if (!entry.directory) {
          final path = _under(unpacked, entry.path);
          _directory(p.dirname(path));
          _absent(path);
          File(path).createSync(exclusive: true);
          output = File(path).openSync(mode: FileMode.writeOnly);
        }
        final sink = _BoundedOutput(output, entry, budget);
        try {
          final data = input.subset(
            position: entry.dataOffset,
            length: entry.compressed,
          );
          if (entry.method == 0) {
            sink.writeStream(data);
            data.position = entry.compressed;
          } else {
            // Inflate.lazy is archive's public block API. Unlike decodeBytes,
            // it does not allocate an entry-sized output; unlike the native raw
            // zlib wrapper it verifies the final block even for empty output.
            final inflate = Inflate.lazy(data, output: sink);
            while (inflate.inflateBlock()) {
              cancel.check();
            }
            if (!inflate.isFinished || data.position != entry.compressed) {
              _bad('Truncated or trailing deflate data.');
            }
          }
          sink.finish();
        } finally {
          output?.closeSync();
        }
      }
      if (budget.bytes != raw.uncompressed) {
        _bad('ZIP output total differs from its declaration.');
      }
    } finally {
      input.closeSync();
    }
  }

  Future<List<_Name>> _walk(_Names accepted) async {
    final actual = <_Name>[];
    final seen = <String>{};
    var bytes = 0;
    Future<void> visit(String directory, String prefix) async {
      cancel.check();
      _directory(directory);
      await for (final child in Directory(directory).list(followLinks: false)) {
        cancel.check();
        final name = p.basename(child.path);
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        if (p.dirname(child.path) != directory) {
          _bad('Escaping imported entry.');
        }
        final type = FileSystemEntity.typeSync(child.path, followLinks: false);
        // Accepted prefixes already passed both full-Unicode key policies.
        // Matching the actual spelling, not computing another normalized key,
        // also detects a filesystem/provider normalization rewrite.
        final expected = accepted.entries[relative];
        if (expected == null ||
            !seen.add(relative) ||
            expected.directory != (type == FileSystemEntityType.directory)) {
          _bad('A stored name or file type changed during import.');
        }
        actual.add(expected);
        if (type == FileSystemEntityType.directory) {
          await visit(child.path, relative);
        } else if (type == FileSystemEntityType.file) {
          _regular(child.path);
          final length = File(child.path).lengthSync();
          if (length > _fileLimit || bytes + length > _treeLimit) {
            _bad('Imported file or tree exceeds the byte limit.');
          }
          bytes += length;
        } else {
          _bad('Links and special files cannot be imported.');
        }
      }
    }

    await visit(unpacked, '');
    return actual..sort((a, b) => _comparePaths(a.path, b.path));
  }

  String _candidate(DocumentImportKind kind, _Names names) {
    bool config(String prefix) =>
        names.entries['${prefix}vx_notebook/config.json']?.directory == false;
    if (config('')) return 'unpacked';
    if (kind == DocumentImportKind.zip) {
      final roots = names.entries.values
          .where((entry) => !entry.path.contains('/'))
          .toList();
      if (roots.length == 1 &&
          roots.single.directory &&
          config('${roots.single.path}/')) {
        return 'unpacked/${roots.single.path}';
      }
    }
    _bad('Expected a notebook root or one sole notebook wrapper directory.');
  }

  ImportPreparedTree _inventory(List<_Name> entries, String treeRelative) {
    final temporary = p.join(root, 'inventory.jsonl.tmp');
    File(temporary).createSync(exclusive: true);
    final output = File(temporary).openSync(mode: FileMode.writeOnly);
    final inventoryDigest = _Digest();
    final hash = crypto.sha256.startChunkedConversion(inventoryDigest);
    final buffer = Uint8List(_chunkSize);
    var total = 0;
    try {
      for (final entry in entries) {
        cancel.check();
        final path = _under(unpacked, entry.path);
        var size = 0;
        var digest = '';
        if (entry.directory) {
          _directory(path);
        } else {
          _regular(path);
          final before = File(path).statSync();
          final fileDigest = _Digest();
          final fileHash = crypto.sha256.startChunkedConversion(fileDigest);
          final input = File(path).openSync();
          try {
            while (true) {
              cancel.check();
              final read = input.readIntoSync(buffer);
              if (read == 0) break;
              size += read;
              total += read;
              if (size > _fileLimit ||
                  total > _treeLimit ||
                  size > before.size) {
                _bad('Actual imported bytes exceed the limit.');
              }
              fileHash.add(Uint8List.sublistView(buffer, 0, read));
            }
          } finally {
            input.closeSync();
            fileHash.close();
          }
          _regular(path);
          final after = File(path).statSync();
          if (size != before.size ||
              after.size != before.size ||
              after.modified != before.modified) {
            _bad('An imported file changed while inventorying.');
          }
          digest = fileDigest.value.toString();
        }
        final line = utf8.encode(
          '${jsonEncode({'path': entry.path, 'type': entry.directory ? 'directory' : 'file', 'size': size, 'sha256': digest})}\n',
        );
        if (line.length > _lineLimit) _bad('Inventory record is too large.');
        output.writeFromSync(line);
        hash.add(line);
      }
      cancel.check();
      output.flushSync();
    } finally {
      output.closeSync();
      hash.close();
    }
    cancel.check();
    _absent(p.join(root, 'inventory.jsonl'));
    File(temporary).renameSync(p.join(root, 'inventory.jsonl'));
    return ImportPreparedTree(
      treeRelative: treeRelative,
      inventoryHash: inventoryDigest.value.toString(),
      bytes: total,
      entries: entries.length,
    );
  }
}

String _under(String root, String path) =>
    p.joinAll([root, ...path.split('/')]);

void _absent(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    _bad('Import output already exists; nothing was replaced.');
  }
}

void _directory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(Directory(path).resolveSymbolicLinksSync(), p.absolute(path))) {
    _bad('Import directory is missing, linked or changed.');
  }
}

void _regular(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.equals(File(path).resolveSymbolicLinksSync(), p.absolute(path))) {
    _bad('Import file is missing, linked or special.');
  }
  final mode = File(path).statSync().mode & 0xf000;
  if (mode != 0 && mode != 0x8000) _bad('Special files cannot be imported.');
}

class _Digest implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

void _lines(String path, _Cancellation cancel, void Function(String) consume) {
  final file = File(path).openSync();
  final buffer = Uint8List(_chunkSize);
  final line = <int>[];
  try {
    while (true) {
      cancel.check();
      final count = file.readIntoSync(buffer);
      if (count == 0) break;
      for (var i = 0; i < count; i++) {
        if (buffer[i] == 10) {
          if (line.isEmpty) _bad('Empty accepted-name record.');
          consume(utf8.decode(line, allowMalformed: false));
          line.clear();
        } else {
          if (line.length >= _lineLimit) {
            _bad('Accepted-name record too large.');
          }
          line.add(buffer[i]);
        }
      }
    }
    if (line.isNotEmpty) _bad('Unterminated accepted-name record.');
  } finally {
    file.closeSync();
  }
}

class _ZipEntry {
  _ZipEntry({
    required this.rawName,
    required this.directory,
    required this.centralOffset,
    required this.localOffset,
    required this.flags,
    required this.method,
    required this.crc,
    required this.compressed,
    required this.uncompressed,
    required this.dataOffset,
    required this.end,
  });
  final String rawName;
  String get path =>
      directory ? rawName.substring(0, rawName.length - 1) : rawName;
  final bool directory;
  final int centralOffset;
  final int localOffset;
  final int flags;
  final int method;
  final int crc;
  final int compressed;
  final int uncompressed;
  final int dataOffset;
  final int end;
}

class _RawZip {
  _RawZip(String path, this.cancel) : file = File(path).openSync() {
    length = file.lengthSync();
  }
  final RandomAccessFile file;
  final _Cancellation cancel;
  late final int length;
  final names = _Names();
  final entries = <_ZipEntry>[];
  int compressed = 0;
  int uncompressed = 0;

  void close() => file.closeSync();

  Uint8List at(int offset, int count) {
    cancel.check();
    if (offset < 0 || count < 0 || count > 196605 || offset > length - count) {
      _bad('ZIP header range is invalid or truncated.');
    }
    file.setPositionSync(offset);
    final data = file.readSync(count);
    if (data.length != count) _bad('ZIP changed during preflight.');
    return data;
  }

  void preflight() {
    if (length < 22 || length > _zipLimit) _bad('ZIP input size is invalid.');
    final tailStart = length > 65557 ? length - 65557 : 0;
    final tail = at(tailStart, length - tailStart);
    var eocd = -1;
    for (var i = 0; i <= tail.length - 22; i++) {
      if (_u32(tail, i) == 0x06054b50 &&
          i + 22 + _u16(tail, i + 20) == tail.length) {
        if (eocd >= 0) _bad('Ambiguous ZIP end record.');
        eocd = tailStart + i;
      }
    }
    if (eocd < 0) _bad('Missing or truncated ZIP end record.');
    final end = at(eocd, 22);
    if (_u16(end, 4) != 0 ||
        _u16(end, 6) != 0 ||
        _u16(end, 8) != _u16(end, 10)) {
      _bad('Split ZIP archives are unsupported.');
    }
    var count = _u16(end, 10);
    var centralSize = _u32(end, 12);
    var centralOffset = _u32(end, 16);
    var centralEnd = eocd;
    final locator = eocd >= 20 ? at(eocd - 20, 20) : null;
    final has64 = locator != null && _u32(locator, 0) == 0x07064b50;
    final needs64 =
        count == 0xffff ||
        centralSize == 0xffffffff ||
        centralOffset == 0xffffffff;
    if (needs64 && !has64) _bad('Missing ZIP64 end records.');
    if (has64) {
      if (_u32(locator, 4) != 0 || _u32(locator, 16) != 1) {
        _bad('Split ZIP64 archives are unsupported.');
      }
      final offset64 = _u64(locator, 8);
      final end64 = at(offset64, 56);
      final size64 = _u64(end64, 4);
      if (_u32(end64, 0) != 0x06064b50 ||
          size64 < 44 ||
          size64 > 65535 ||
          offset64 + 12 + size64 != eocd - 20 ||
          _u16(end64, 14) < 45 ||
          _u16(end64, 14) > 45 ||
          _u32(end64, 16) != 0 ||
          _u32(end64, 20) != 0 ||
          _u64(end64, 24) != _u64(end64, 32)) {
        _bad('Invalid ZIP64 end record.');
      }
      final count64 = _u64(end64, 32);
      final centralSize64 = _u64(end64, 40);
      final centralOffset64 = _u64(end64, 48);
      if ((count != 0xffff && count != count64) ||
          (centralSize != 0xffffffff && centralSize != centralSize64) ||
          (centralOffset != 0xffffffff && centralOffset != centralOffset64)) {
        _bad('Contradictory ZIP64 end records.');
      }
      count = count64;
      centralSize = centralSize64;
      centralOffset = centralOffset64;
      centralEnd = offset64;
    }
    if (count < 1 ||
        count > _entryLimit ||
        centralSize < count * 46 ||
        centralOffset < 0 ||
        centralSize > centralEnd ||
        centralOffset != centralEnd - centralSize) {
      _bad('Invalid ZIP central-directory range or entry count.');
    }
    var cursor = centralOffset;
    for (var i = 0; i < count; i++) {
      cancel.check();
      if (cursor > centralEnd - 46) _bad('Truncated central directory.');
      final h = at(cursor, 46);
      if (_u32(h, 0) != 0x02014b50) {
        _bad('Invalid central directory signature.');
      }
      final needed = _u16(h, 6);
      final flags = _u16(h, 8);
      final method = _u16(h, 10);
      if ((needed != 10 && needed != 20 && needed != 45) ||
          (method != 0 && method != 8) ||
          (flags & ~0x080e) != 0 ||
          (method == 0 && (flags & 6) != 0)) {
        _bad('Encrypted or unsupported ZIP entry.');
      }
      final nameLength = _u16(h, 28);
      final extraLength = _u16(h, 30);
      final commentLength = _u16(h, 32);
      final next = cursor + 46 + nameLength + extraLength + commentLength;
      if (nameLength < 1 || nameLength > 1025 || next > centralEnd) {
        _bad('Invalid central name or header range.');
      }
      final rawName = at(cursor + 46, nameLength);
      if ((flags & 0x800) == 0 && rawName.any((byte) => byte >= 128)) {
        _bad('Non-ASCII ZIP names must be flagged UTF-8.');
      }
      final name = utf8.decode(rawName, allowMalformed: false);
      final directory = name.endsWith('/');
      final attributes = _u32(h, 38);
      _attributes(attributes, directory);
      final extras = _extras(
        at(cursor + 46 + nameLength, extraLength),
        rawName,
        name,
        directory,
      );
      final sizes = _zip64(
        extras[1],
        _u32(h, 24),
        _u32(h, 20),
        _u32(h, 42),
        _u16(h, 34),
      );
      if (sizes.disk != 0 || (extras.containsKey(1) && needed < 45)) {
        _bad('Invalid ZIP64 version or split entry.');
      }
      final crc = _u32(h, 16);
      if (sizes.size > _fileLimit ||
          uncompressed + sizes.size > _treeLimit ||
          sizes.compressed > _zipLimit) {
        _bad('ZIP file, tree, or input byte limit exceeded.');
      }
      if (sizes.size >
          (sizes.compressed == 0 ? 1 : sizes.compressed) * _ratio) {
        _bad(
          'ZIP expansion exceeds 100:1. Use Import folder for the equivalent notebook instead.',
        );
      }
      if ((method == 0 && sizes.size != sizes.compressed) ||
          (directory && (sizes.size != 0 || crc != 0))) {
        _bad('ZIP entry sizes or directory checksum disagree.');
      }
      final path = directory ? name.substring(0, name.length - 1) : name;
      names.add(path, directory);
      final local = at(sizes.offset, 30);
      if (sizes.offset > centralOffset - 30 ||
          _u32(local, 0) != 0x04034b50 ||
          _u16(local, 4) != needed ||
          _u16(local, 6) != flags ||
          _u16(local, 8) != method ||
          _u16(local, 10) != _u16(h, 12) ||
          _u16(local, 12) != _u16(h, 14) ||
          _u16(local, 26) != nameLength) {
        _bad('Local and central ZIP headers disagree.');
      }
      final localExtraLength = _u16(local, 28);
      final dataOffset = sizes.offset + 30 + nameLength + localExtraLength;
      if (dataOffset > centralOffset ||
          sizes.compressed > centralOffset - dataOffset ||
          !_equal(at(sizes.offset + 30, nameLength), rawName)) {
        _bad('Local ZIP name or data range disagrees.');
      }
      final localExtras = _extras(
        at(sizes.offset + 30 + nameLength, localExtraLength),
        rawName,
        name,
        directory,
      );
      final localSizes = _zip64(
        localExtras[1],
        _u32(local, 22),
        _u32(local, 18),
        0,
        0,
      );
      if (localExtras.containsKey(1) && needed < 45) {
        _bad('Invalid local ZIP64 version.');
      }
      final descriptor = (flags & 8) != 0;
      if (!_declared(_u32(local, 14), crc, descriptor) ||
          !_declared(localSizes.size, sizes.size, descriptor) ||
          !_declared(localSizes.compressed, sizes.compressed, descriptor)) {
        _bad('Local ZIP sizes or CRC contradict the central entry.');
      }
      var rangeEnd = dataOffset + sizes.compressed;
      if (descriptor) {
        rangeEnd += _descriptor(
          rangeEnd,
          centralOffset,
          crc,
          sizes.compressed,
          sizes.size,
          localExtras.containsKey(1),
        );
      }
      entries.add(
        _ZipEntry(
          rawName: name,
          directory: directory,
          centralOffset: cursor,
          localOffset: sizes.offset,
          flags: flags,
          method: method,
          crc: crc,
          compressed: sizes.compressed,
          uncompressed: sizes.size,
          dataOffset: dataOffset,
          end: rangeEnd,
        ),
      );
      compressed += sizes.compressed;
      uncompressed += sizes.size;
      cursor = next;
    }
    if (cursor != centralEnd) _bad('Central-directory count disagrees.');
    if (uncompressed > (compressed == 0 ? 1 : compressed) * _ratio) {
      _bad(
        'ZIP expansion exceeds 100:1. Use Import folder for the equivalent notebook instead.',
      );
    }
    final ranges = entries.toList()
      ..sort((a, b) => a.localOffset.compareTo(b.localOffset));
    var endOfPrevious = 0;
    for (final entry in ranges) {
      if (entry.localOffset < endOfPrevious || entry.end > centralOffset) {
        _bad('ZIP local/data/descriptor ranges overlap.');
      }
      endOfPrevious = entry.end;
    }
  }

  int _descriptor(
    int offset,
    int limit,
    int crc,
    int compressed,
    int size,
    bool zip64,
  ) {
    final width = zip64 ? 20 : 12;
    final available = limit - offset;
    if (available < width) _bad('Truncated ZIP descriptor.');
    final data = at(offset, available < width + 4 ? available : width + 4);
    bool matches(int start) =>
        data.length >= start + width &&
        _u32(data, start) == crc &&
        (zip64 ? _u64(data, start + 4) : _u32(data, start + 4)) == compressed &&
        (zip64 ? _u64(data, start + 12) : _u32(data, start + 8)) == size;
    final unsigned = matches(0);
    final signed = _u32(data, 0) == 0x08074b50 && matches(4);
    if (unsigned == signed) _bad('Invalid or ambiguous ZIP descriptor.');
    return width + (signed ? 4 : 0);
  }
}

bool _declared(int local, int central, bool descriptor) =>
    local == central || (descriptor && local == 0);

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);
int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);
int _u64(Uint8List bytes, int offset) {
  // All admitted values fit in signed 64 bits. Reject before Dart's uint64
  // conversion can reinterpret a malicious high bit as a negative integer.
  if ((bytes[offset + 7] & 0x80) != 0) _bad('ZIP64 integer is out of range.');
  return _u32(bytes, offset) | (_u32(bytes, offset + 4) << 32);
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _attributes(int attributes, bool directory) {
  final type = (attributes >> 16) & 0xf000;
  if ((type != 0 && type != (directory ? 0x4000 : 0x8000)) ||
      (attributes & (0x08 | 0x40 | 0x400)) != 0 ||
      (!directory && (attributes & 0x10) != 0)) {
    _bad(
      'ZIP links, special types or contradictory attributes are unsupported.',
    );
  }
}

Map<int, Uint8List> _extras(
  Uint8List bytes,
  Uint8List rawName,
  String name,
  bool directory,
) {
  final result = <int, Uint8List>{};
  var cursor = 0;
  while (cursor < bytes.length) {
    if (bytes.length - cursor < 4) _bad('Truncated ZIP extra header.');
    final id = _u16(bytes, cursor);
    final size = _u16(bytes, cursor + 2);
    cursor += 4;
    if (size > bytes.length - cursor || result.containsKey(id)) {
      _bad('Truncated or repeated ZIP extra field.');
    }
    final value = Uint8List.sublistView(bytes, cursor, cursor + size);
    result[id] = value;
    cursor += size;
    if (id == 0x7075) {
      if (size < 5 ||
          value[0] != 1 ||
          _u32(value, 1) != getCrc32(rawName) ||
          utf8.decode(Uint8List.sublistView(value, 5), allowMalformed: false) !=
              name) {
        _bad('Contradictory Unicode ZIP path.');
      }
    } else if (id == 0x000d) {
      // PKWARE Unix's variable tail encodes links or device numbers.
      if (size != 12) _bad('ZIP Unix link/device encoding is unsupported.');
    } else if (id == 0x756e) {
      // ASi Unix: CRC, mode, sizdev, uid, gid, optional link target.
      if (size != 14 ||
          _u32(value, 0) != getCrc32(Uint8List.sublistView(value, 4)) ||
          _u32(value, 6) != 0) {
        _bad('ZIP ASi link/device encoding is unsupported.');
      }
      _attributes(_u16(value, 4) << 16, directory);
    } else if (id == 0x0017 ||
        id == 0x9901 ||
        id == 0x000f ||
        id == 0x0014 ||
        id == 0x0015 ||
        id == 0x0016) {
      _bad('Encrypted or patched ZIP metadata is unsupported.');
    }
  }
  return result;
}

({int size, int compressed, int offset, int disk}) _zip64(
  Uint8List? extra,
  int size,
  int compressed,
  int offset,
  int disk,
) {
  final expected =
      (size == 0xffffffff ? 8 : 0) +
      (compressed == 0xffffffff ? 8 : 0) +
      (offset == 0xffffffff ? 8 : 0) +
      (disk == 0xffff ? 4 : 0);
  if ((extra == null && expected != 0) ||
      (extra != null && (expected == 0 || extra.length != expected))) {
    _bad('Missing or contradictory ZIP64 extra values.');
  }
  var cursor = 0;
  int take64() {
    final value = _u64(extra!, cursor);
    cursor += 8;
    return value;
  }

  if (size == 0xffffffff) size = take64();
  if (compressed == 0xffffffff) compressed = take64();
  if (offset == 0xffffffff) offset = take64();
  if (disk == 0xffff) disk = _u32(extra!, cursor);
  return (size: size, compressed: compressed, offset: offset, disk: disk);
}

class _OutputBudget {
  _OutputBudget(this.compressed, this.cancel);
  final int compressed;
  final _Cancellation cancel;
  // Entries are decoded serially; history validity is controlled by each
  // sink's fresh length, so these buffers need no entry-sized allocation/reset.
  final window = Uint8List(32768);
  final pending = Uint8List(_chunkSize);
  final inputBuffer = Uint8List(_chunkSize);
  int bytes = 0;
  void add(int count) {
    if (count < 0 ||
        bytes + count > _treeLimit ||
        bytes + count > compressed * _ratio) {
      _bad('Actual ZIP output exceeds its tree or ratio limit.');
    }
    bytes += count;
  }
}

/// Fixed-size pending buffer plus the 32 KiB LZ77 history. Neither subset nor
/// overlapping backreferences ever reads/materializes an entire output file.
class _BoundedOutput extends OutputStream {
  _BoundedOutput(this.file, this.entry, this.budget)
    : _window = budget.window,
      _pending = budget.pending,
      super(byteOrder: ByteOrder.littleEndian);
  final RandomAccessFile? file;
  final _ZipEntry entry;
  final _OutputBudget budget;
  final Uint8List _window;
  final Uint8List _pending;
  int _used = 0;
  int _length = 0;
  int _crc = 0;
  @override
  int get length => _length;

  void _admit(int count) {
    budget.cancel.check();
    if (count < 0 ||
        length + count > entry.uncompressed ||
        length + count > _fileLimit ||
        length + count > entry.compressed * _ratio) {
      _bad('Actual ZIP entry exceeds its declared size or ratio limit.');
    }
    budget.add(count);
  }

  void _byte(int value) {
    _window[_length & 32767] = value;
    _pending[_used++] = value;
    _length++;
    if (_used == _pending.length) flush();
  }

  @override
  void writeByte(int value) {
    _admit(1);
    _byte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count > bytes.length) _bad('Invalid decoder output range.');
    _admit(count);
    for (var i = 0; i < count; i++) {
      _byte(bytes[i]);
    }
  }

  @override
  void writeStream(InputStream stream) {
    final original = stream.position;
    final buffer = budget.inputBuffer;
    try {
      while (!stream.isEOS) {
        budget.cancel.check();
        final count = stream.readInto(
          buffer,
          0,
          stream.length < buffer.length ? stream.length : buffer.length,
        );
        if (count <= 0) _bad('Truncated stored ZIP data.');
        writeBytes(buffer, length: count);
      }
    } finally {
      stream.position = original;
    }
  }

  @override
  void writeBackReference(int distance, int count) {
    _admit(count);
    if (distance <= 0 || distance > 32768 || distance > length || count > 258) {
      _bad('Invalid deflate backreference.');
    }
    for (var i = 0; i < count; i++) {
      _byte(_window[(_length - distance) & 32767]);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    budget.cancel.check();
    if (start < 0) start += length;
    var stop = end ?? length;
    if (stop < 0) stop += length;
    if (start < 0 ||
        start < length - 32768 ||
        stop < start ||
        stop > length ||
        stop - start > 32768) {
      _bad('Decoder requested an unbounded or unavailable history range.');
    }
    final result = Uint8List(stop - start);
    for (var i = 0; i < result.length; i++) {
      result[i] = _window[(start + i) & 32767];
    }
    return result;
  }

  @override
  void clear() => _bad('Decoder cannot reset imported output.');

  @override
  void flush() {
    budget.cancel.check();
    if (_used == 0) return;
    _crc = getCrc32(Uint8List.sublistView(_pending, 0, _used), _crc);
    file?.writeFromSync(_pending, 0, _used);
    _used = 0;
  }

  void finish() {
    flush();
    if (length != entry.uncompressed || _crc != entry.crc) {
      _bad('ZIP actual size or CRC does not match the header.');
    }
    file?.flushSync();
  }
}
