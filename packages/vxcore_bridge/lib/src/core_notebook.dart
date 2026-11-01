// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated/core_json_keys.dart';
import 'generated/vxcore_host_bindings.dart' as native;

abstract interface class NotebookCore {
  Future<CoreNote> read();
  Future<CoreWriteResult> write(
    String text, {
    required int revision,
    required String baseHash,
  });
  Future<void> close();
  String get nativeNotices;
}

enum CoreEditorType { markdown, text }

final class CoreEntry {
  const CoreEntry({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.exists,
    required this.encrypted,
  });

  final String id;
  final String name;
  final bool isFolder;
  final bool exists;
  final bool encrypted;
}

final class CoreDirectory {
  CoreDirectory({
    required this.notebookId,
    required this.notebookName,
    required this.folderId,
    required this.path,
    required this.parentId,
    required List<CoreEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final String notebookId;
  final String notebookName;
  final String folderId;
  final String path;
  final String? parentId;
  final List<CoreEntry> entries;
}

final class CoreSearchHit {
  const CoreSearchHit({
    required this.id,
    required this.path,
    required this.line,
    required this.snippet,
  });
  final String id;
  final String path;
  final int line;
  final String snippet;
}

final class CoreSearchResult {
  CoreSearchResult({
    required this.notebookId,
    required List<CoreSearchHit> matches,
    required this.limited,
    required this.skipped,
  }) : matches = List.unmodifiable(matches);
  final String notebookId;
  final List<CoreSearchHit> matches;
  final bool limited;
  final int skipped;
}

final class CoreTag {
  const CoreTag({required this.name, required this.parent});
  final String name;
  final String parent;
}

final class CoreTags {
  CoreTags({
    required this.notebookId,
    required List<CoreTag> tags,
    required List<String> assigned,
  }) : tags = List.unmodifiable(tags),
       assigned = List.unmodifiable(assigned);
  final String notebookId;
  final List<CoreTag> tags;
  final List<String> assigned;
}

abstract interface class CatalogCore {
  CoreDirectory get initialDirectory;
  String get nativeNotices;
  Future<CoreDirectory> list([String? folderId]);
  Future<String> createNote(String folderId, String name);
  Future<String> createFolder(String folderId, String name);
  Future<void> rename(String nodeId, String name);
  Future<void> move(String nodeId, String destinationFolderId);
  Future<void> delete(String nodeId);
  Future<CoreSearchResult> search(
    String text, {
    String? tag,
    bool caseSensitive = false,
  });
  Future<CoreTags> tags([String? nodeId]);
  Future<void> createTag(String name);
  Future<void> setTags(String nodeId, List<String> tags);
  void cancelSearch();
  Future<void> close();
}

final class CoreNote {
  const CoreNote({
    required this.notebookId,
    required this.nodeId,
    required this.path,
    required this.notebookName,
    required this.editorType,
    required this.text,
    required this.baseHash,
    required this.coreVersion,
    required this.lineEnding,
  });

  final String notebookId;
  final String nodeId;
  final String path;
  final String notebookName;
  final CoreEditorType editorType;
  final String text;
  final String baseHash;
  final String coreVersion;
  final int lineEnding;
}

final class CoreWriteResult {
  const CoreWriteResult({required this.revision, required this.baseHash});

  final int revision;
  final String baseHash;
}

final class CoreException implements Exception {
  const CoreException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'CoreException($code): $message';
}

const _maxSource = 4 * 1024 * 1024;
const _maxCatalog = 8 * 1024 * 1024;
const _maxInteger = 9007199254740991;
const _invalid = native.VxCoreError.VXCORE_ERR_INVALID_PARAM;
const _unusable = native.VxCoreError.VXCORE_ERR_INVALID_STATE;
const _unsupported = native.VxCoreError.VXCORE_ERR_UNSUPPORTED;

// Counting first rejects malformed UTF-16 rather than replacement-encoding it,
// and bounds the allocation made by utf8.encode before it can grow.
Uint8List _encode(String text, {int maximum = _maxSource}) {
  if (text.length > maximum) {
    throw const CoreException(_invalid, 'The source exceeds the native limit');
  }
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final value = text.codeUnitAt(i);
    if (value < 0x80) {
      bytes++;
    } else if (value < 0x800) {
      bytes += 2;
    } else if (value >= 0xd800 && value <= 0xdbff) {
      if (++i >= text.length) {
        throw const CoreException(
          _unsupported,
          'The source contains invalid Unicode',
        );
      }
      final low = text.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) {
        throw const CoreException(
          _unsupported,
          'The source contains invalid Unicode',
        );
      }
      bytes += 4;
    } else if (value >= 0xdc00 && value <= 0xdfff) {
      throw const CoreException(
        _unsupported,
        'The source contains invalid Unicode',
      );
    } else {
      bytes += 3;
    }
    if (bytes > maximum) {
      throw const CoreException(
        _invalid,
        'The source exceeds the native limit',
      );
    }
  }
  return utf8.encode(text);
}

Pointer<Uint8> _copyBytes(Arena arena, Uint8List bytes) {
  if (bytes.isEmpty) return nullptr;
  final pointer = arena<Uint8>(bytes.length);
  pointer.asTypedList(bytes.length).setAll(0, bytes);
  return pointer;
}

Pointer<Char> _option(Arena arena, String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw const CoreException(_invalid, 'A native notebook option is invalid');
  }
  final encoded = _encode(value, maximum: 16384);
  final pointer = arena<Uint8>(encoded.length + 1);
  pointer.asTypedList(encoded.length).setAll(0, encoded);
  pointer[encoded.length] = 0;
  return pointer.cast<Char>();
}

// Top-level isolation prevents accidentally capturing the host, callback or any
// non-sendable FFI object. Only the address crosses to the cleanup isolate.
Future<void> _destroyOffIsolate(int address) => Isolate.run(() {
  native.vxm_host_destroy(Pointer<native.VxmHost>.fromAddress(address));
});

final class _Pending {
  _Pending(this.kind, this.revision, {this.decode});

  final int kind;
  final int revision;
  final Object Function(native.VxmEvent)? decode;
  final completer = Completer<Object>();
}

Never _badDirectory() => throw const CoreException(
  native.VxCoreError.VXCORE_ERR_JSON_PARSE,
  'Malformed native directory listing',
);

String _listingString(Object? value, {int maximum = 16384}) {
  if (value is! String || value.isEmpty || value.contains('\u0000'))
    _badDirectory();
  _encode(value, maximum: maximum);
  return value;
}

CoreDirectory _directory(native.VxmEvent event) {
  if (event.size <= 0 || event.size > _maxCatalog || event.data == nullptr)
    _badDirectory();
  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(event.data.asTypedList(event.size), allowMalformed: false),
    );
  } on FormatException {
    _badDirectory();
  }
  if (decoded is! Map<String, dynamic>) _badDirectory();
  final files = decoded[CoreJsonKeys.files];
  final folders = decoded[CoreJsonKeys.folders];
  if (files is! List || folders is! List) _badDirectory();
  if (files.length + folders.length > 10000) {
    throw const CoreException(
      _unsupported,
      'Directory exceeds the 10000-child limit',
    );
  }
  final entries = <CoreEntry>[];
  final identities = <String>{};
  void append(List<dynamic> children, bool isFolder) {
    for (final child in children) {
      if (child is! Map<String, dynamic>) _badDirectory();
      final id = _listingString(child[CoreJsonKeys.id], maximum: 127);
      if (!identities.add(id)) _badDirectory();
      final name = _listingString(child[CoreJsonKeys.name]);
      final exists = child[CoreJsonKeys.nodeExists];
      final metadata = child[CoreJsonKeys.metadata];
      if (exists is! bool || metadata is! Map<String, dynamic>) _badDirectory();
      final encrypted = metadata.containsKey(CoreJsonKeys.encrypted)
          ? metadata[CoreJsonKeys.encrypted]
          : false;
      if (encrypted is! bool) _badDirectory();
      entries.add(
        CoreEntry(
          id: id,
          name: name,
          isFolder: isFolder,
          exists: exists,
          encrypted: encrypted,
        ),
      );
    }
  }

  append(folders, true);
  append(files, false);
  final parent = event.parent_id.cast<Utf8>().toDartString();
  final path = _listingString(event.path.cast<Utf8>().toDartString());
  if ((path == '.') != parent.isEmpty) _badDirectory();
  return CoreDirectory(
    notebookId: _listingString(
      event.notebook_id.cast<Utf8>().toDartString(),
      maximum: 127,
    ),
    notebookName: _listingString(
      event.notebook_name.cast<Utf8>().toDartString(),
    ),
    folderId: _listingString(
      event.node_id.cast<Utf8>().toDartString(),
      maximum: 127,
    ),
    path: path,
    parentId: parent.isEmpty ? null : _listingString(parent, maximum: 127),
    entries: entries,
  );
}

Never _badQuery() => throw const CoreException(
  native.VxCoreError.VXCORE_ERR_JSON_PARSE,
  'Malformed native query result',
);

String _queryString(Object? value, {int maximum = 16384, bool empty = false}) {
  if (value is! String || (!empty && value.isEmpty) || value.contains('\u0000'))
    _badQuery();
  _encode(value, maximum: maximum);
  return value;
}

Map<String, dynamic> _queryObject(native.VxmEvent event) {
  if (event.size <= 0 || event.size > _maxCatalog || event.data == nullptr)
    _badQuery();
  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(event.data.asTypedList(event.size), allowMalformed: false),
    );
  } on FormatException {
    _badQuery();
  }
  if (decoded is! Map<String, dynamic>) _badQuery();
  return decoded;
}

CoreSearchResult _searchResult(native.VxmEvent event) {
  final json = _queryObject(event);
  final notebookId = _queryString(json['notebookId'], maximum: 127);
  final rows = json['matches'];
  final limited = json['limited'];
  final skipped = json['skipped'];
  if (rows is! List ||
      rows.length > 10000 ||
      limited is! bool ||
      skipped is! int ||
      skipped < 0 ||
      skipped > 100000)
    _badQuery();
  final matches = <CoreSearchHit>[];
  final ids = <String>{};
  for (final row in rows) {
    if (row is! Map<String, dynamic>) _badQuery();
    final id = _queryString(row['id'], maximum: 127);
    if (!ids.add(id)) _badQuery();
    final path = _queryString(row['path']);
    if (path.startsWith('/') ||
        path.contains('\\') ||
        path.contains(':') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..'))
      _badQuery();
    final line = row['line'];
    if (line is! int || line < 0 || line > _maxInteger) _badQuery();
    matches.add(
      CoreSearchHit(
        id: id,
        path: path,
        line: line,
        snippet: _queryString(row['snippet'], maximum: 512, empty: true),
      ),
    );
  }
  return CoreSearchResult(
    notebookId: notebookId,
    matches: matches,
    limited: limited,
    skipped: skipped,
  );
}

CoreTags _tagsResult(native.VxmEvent event) {
  final json = _queryObject(event);
  final notebookId = _queryString(json['notebookId'], maximum: 127);
  final rows = json['tags'];
  final assigned = json['assigned'];
  if (rows is! List ||
      rows.length > 10000 ||
      assigned is! List ||
      assigned.length > 10000)
    _badQuery();
  final tags = <CoreTag>[];
  final names = <String>{};
  for (final row in rows) {
    if (row is! Map<String, dynamic>) _badQuery();
    final name = _queryString(row['name']);
    if (!names.add(name)) _badQuery();
    tags.add(
      CoreTag(name: name, parent: _queryString(row['parent'], empty: true)),
    );
  }
  final assignments = assigned.map((name) => _queryString(name)).toList();
  return CoreTags(notebookId: notebookId, tags: tags, assigned: assignments);
}

final class CoreNotebook implements NotebookCore, CatalogCore {
  CoreNotebook._(this._mode) : _token = _nextToken++ {
    _listener = NativeCallable<Void Function(Int64)>.listener(_onNotify);
  }

  static int _nextToken = 1;
  final int _token;
  late final NativeCallable<Void Function(Int64)> _listener;
  Pointer<native.VxmHost>? _handle;
  Pointer<native.VxmHost>? _eventHandle;
  int _generation = 0;
  int _nextRequest = 2;
  int? _searchRequest;
  final _pending = <int, _Pending>{};
  final _closedEvent = Completer<int>();
  Future<void>? _closing;

  final int _mode;
  CoreDirectory? _initialDirectory;

  @override
  CoreDirectory get initialDirectory {
    _requireMode(native.VXM_MODE_CATALOG);
    return _initialDirectory!;
  }

  void _requireMode(int mode) {
    if (_mode != mode) {
      throw const CoreException(
        _unusable,
        'Operation is not available in this notebook mode',
      );
    }
  }

  static Future<CoreNotebook> openCatalog({
    required String appDataPath,
    required String localDataPath,
    required String notebookPath,
    required String notebookName,
    String? expectedNotebookId,
  }) => _open(
    appDataPath: appDataPath,
    localDataPath: localDataPath,
    notebookPath: notebookPath,
    notebookName: notebookName,
    expectedNotebookId: expectedNotebookId,
    mode: native.VXM_MODE_CATALOG,
  );

  static Future<CoreNotebook> openNote({
    required String appDataPath,
    required String localDataPath,
    required String notebookPath,
    required String notebookId,
    required String nodeId,
  }) => _open(
    appDataPath: appDataPath,
    localDataPath: localDataPath,
    notebookPath: notebookPath,
    expectedNotebookId: notebookId,
    nodeId: nodeId,
    mode: native.VXM_MODE_NOTE,
  );
  static Future<CoreNotebook> _open({
    required String appDataPath,
    required String localDataPath,
    required String notebookPath,
    required int mode,
    String? notebookName,
    String? expectedNotebookId,
    String? nodeId,
  }) async {
    if (_nextToken > _maxInteger) {
      throw const CoreException(
        _unusable,
        'Native session tokens are exhausted',
      );
    }
    final host = CoreNotebook._(mode);
    final pending = _Pending(
      mode == native.VXM_MODE_CATALOG
          ? native.VXM_EVENT_CATALOG_OPEN
          : native.VXM_EVENT_OPEN,
      0,
    );
    try {
      using((arena) {
        final options = arena<native.VxmOpenOptions>();
        options.ref
          ..app_data_path = _option(arena, appDataPath)
          ..local_data_path = _option(arena, localDataPath)
          ..notebook_path = _option(arena, notebookPath)
          ..notebook_name = notebookName == null
              ? nullptr
              : _option(arena, notebookName)
          ..expected_notebook_id = expectedNotebookId == null
              ? nullptr
              : _option(arena, expectedNotebookId)
          ..node_id = nodeId == null ? nullptr : _option(arena, nodeId)
          ..mode = mode;
        final out = arena<Pointer<native.VxmHost>>();
        final code = native.vxm_host_create(
          options,
          host._listener.nativeFunction,
          host._token,
          out,
        );
        if (code != native.VxCoreError.VXCORE_OK) {
          throw CoreException(code, 'Native notebook admission failed');
        }
        host._handle = out.value;
        host._eventHandle = out.value;
        host._generation = native.vxm_host_generation(out.value);
        host._pending[1] = pending;
      });
      final initial = await pending.completer.future;
      if (initial is CoreDirectory) host._initialDirectory = initial;
      return host;
    } catch (error, stack) {
      // Even initialization errors retain the listener until owner teardown and
      // off-isolate join. Cleanup cannot replace the original core failure.
      try {
        await host.close();
      } catch (_) {
        // The original initialization outcome is the useful failure here.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  String get nativeNotices =>
      native.vxm_native_notices().cast<Utf8>().toDartString();

  Pointer<native.VxmHost> _usableHandle() {
    final handle = _handle;
    if (handle == null || _nextRequest > _maxInteger) {
      throw const CoreException(_unusable, 'The native notebook is closed');
    }
    if (_pending.length >= native.VXM_MAX_OPERATIONS) {
      throw const CoreException(
        native.VxCoreError.VXCORE_ERR_OUT_OF_MEMORY,
        'Native request capacity is exhausted',
      );
    }
    return handle;
  }

  @override
  Future<CoreNote> read() async {
    _requireMode(native.VXM_MODE_NOTE);
    final handle = _usableHandle();
    final id = _nextRequest++;
    final pending = _Pending(native.VXM_EVENT_READ, 0);
    final code = native.vxm_host_read(handle, id, _generation);
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native read admission failed');
    }
    _pending[id] = pending;
    return await pending.completer.future as CoreNote;
  }

  @override
  Future<CoreWriteResult> write(
    String text, {
    required int revision,
    required String baseHash,
  }) async {
    _requireMode(native.VXM_MODE_NOTE);
    final handle = _usableHandle();
    if (revision < 0 ||
        revision > _maxInteger ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(baseHash)) {
      throw const CoreException(
        _invalid,
        'Invalid native write revision or base',
      );
    }
    final bytes = _encode(text);
    final id = _nextRequest++;
    final pending = _Pending(native.VXM_EVENT_WRITE, revision);
    final code = using(
      (arena) => native.vxm_host_write(
        handle,
        id,
        _generation,
        revision,
        baseHash.toNativeUtf8(allocator: arena).cast<Char>(),
        _copyBytes(arena, bytes),
        bytes.length,
      ),
    );
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native write admission failed');
    }
    _pending[id] = pending;
    return await pending.completer.future as CoreWriteResult;
  }

  @override
  Future<CoreDirectory> list([String? folderId]) async {
    _requireMode(native.VXM_MODE_CATALOG);
    final handle = _usableHandle();
    final id = _nextRequest++;
    final pending = _Pending(native.VXM_EVENT_LIST, 0);
    final code = using(
      (arena) => native.vxm_host_catalog_list(
        handle,
        id,
        _generation,
        folderId == null || folderId.isEmpty
            ? nullptr
            : _option(arena, folderId),
      ),
    );
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native listing admission failed');
    }
    _pending[id] = pending;
    return await pending.completer.future as CoreDirectory;
  }

  Future<String> _mutate(
    int operation,
    String nodeId, {
    String? name,
    String? destination,
  }) async {
    _requireMode(native.VXM_MODE_CATALOG);
    final handle = _usableHandle();
    final id = _nextRequest++;
    final pending = _Pending(native.VXM_EVENT_MUTATE, 0);
    final code = using(
      (arena) => native.vxm_host_catalog_mutate(
        handle,
        id,
        _generation,
        operation,
        _option(arena, nodeId),
        name == null ? nullptr : _option(arena, name),
        destination == null ? nullptr : _option(arena, destination),
      ),
    );
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native mutation admission failed');
    }
    _pending[id] = pending;
    return await pending.completer.future as String;
  }

  @override
  Future<String> createNote(String folderId, String name) =>
      _mutate(native.VXM_CREATE_NOTE, folderId, name: name);
  @override
  Future<String> createFolder(String folderId, String name) =>
      _mutate(native.VXM_CREATE_FOLDER, folderId, name: name);
  @override
  Future<void> rename(String nodeId, String name) async {
    await _mutate(native.VXM_RENAME, nodeId, name: name);
  }

  @override
  Future<void> move(String nodeId, String destinationFolderId) async {
    await _mutate(native.VXM_MOVE, nodeId, destination: destinationFolderId);
  }

  @override
  Future<void> delete(String nodeId) async {
    await _mutate(native.VXM_DELETE, nodeId);
  }

  Future<T> _catalogJson<T>(
    Map<String, Object> input, {
    Object Function(native.VxmEvent)? decode,
    bool mutation = false,
    bool search = false,
  }) async {
    _requireMode(native.VXM_MODE_CATALOG);
    final handle = _usableHandle();
    if (search && _searchRequest != null) {
      throw const CoreException(
        _unusable,
        'A notebook search is already running',
      );
    }
    final json = jsonEncode(input);
    final id = _nextRequest++;
    final pending = _Pending(
      mutation ? native.VXM_EVENT_TAG : native.VXM_EVENT_QUERY,
      0,
      decode: decode,
    );
    final code = using((arena) {
      final payload = _option(arena, json);
      return mutation
          ? native.vxm_host_catalog_tag(handle, id, _generation, payload)
          : native.vxm_host_catalog_query(handle, id, _generation, payload);
    });
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native catalog query admission failed');
    }
    _pending[id] = pending;
    if (search) _searchRequest = id;
    try {
      return await pending.completer.future as T;
    } finally {
      if (search && _searchRequest == id) _searchRequest = null;
    }
  }

  static void _queryInput(
    String value, {
    bool empty = false,
    int maximum = 16384,
  }) {
    if ((!empty && value.isEmpty) || value.contains('\u0000')) {
      throw const CoreException(_invalid, 'Invalid native query input');
    }
    _encode(value, maximum: maximum);
  }

  @override
  Future<CoreSearchResult> search(
    String text, {
    String? tag,
    bool caseSensitive = false,
  }) async {
    _queryInput(text, empty: true);
    if (tag != null) _queryInput(tag);
    if (text.isEmpty && tag == null) {
      throw const CoreException(_invalid, 'Enter search text or choose a tag');
    }
    return _catalogJson<CoreSearchResult>(
      {
        'op': 'search',
        'text': text,
        if (tag != null) 'tag': tag,
        'caseSensitive': caseSensitive,
      },
      decode: _searchResult,
      search: true,
    );
  }

  @override
  Future<CoreTags> tags([String? nodeId]) async {
    if (nodeId != null) _queryInput(nodeId, maximum: 127);
    return _catalogJson<CoreTags>({
      'op': 'tags',
      if (nodeId != null) 'nodeId': nodeId,
    }, decode: _tagsResult);
  }

  @override
  Future<void> createTag(String name) async {
    _queryInput(name);
    await _catalogJson<bool>({'op': 'createTag', 'name': name}, mutation: true);
  }

  @override
  Future<void> setTags(String nodeId, List<String> tags) async {
    _queryInput(nodeId, maximum: 127);
    if (tags.length > 10000)
      throw const CoreException(_invalid, 'Too many tag assignments');
    var bytes = 0;
    final unique = <String>{};
    for (final tag in tags) {
      _queryInput(tag);
      bytes += _encode(tag, maximum: 16384).length;
      if (bytes > 16384 || !unique.add(tag))
        throw const CoreException(
          _invalid,
          'Invalid or oversized tag assignments',
        );
    }
    await _catalogJson<bool>({
      'op': 'setTags',
      'nodeId': nodeId,
      'tags': tags,
    }, mutation: true);
  }

  @override
  void cancelSearch() {
    final id = _searchRequest;
    final handle = _handle;
    if (id == null || handle == null) return;
    final code = native.vxm_host_cancel(handle, id, _generation);
    // Completion may already be queued; cancellation never rewrites its outcome.
    if (code != native.VxCoreError.VXCORE_OK && code != _unusable) {
      throw CoreException(code, 'Native search cancellation failed');
    }
  }

  void _onNotify(int token) {
    final handle = _eventHandle;
    if (token != _token || handle == null) return;
    for (;;) {
      final pointer = native.vxm_host_take_event(handle);
      if (pointer == nullptr) return;
      try {
        final event = pointer.ref;
        if (event.generation != _generation) continue;
        if (event.kind == native.VXM_EVENT_CLOSED) {
          if (!_closedEvent.isCompleted) _closedEvent.complete(event.code);
          continue;
        }
        final pending = _pending.remove(event.request_id);
        if (pending == null) continue;
        try {
          if (event.kind != pending.kind ||
              event.revision != pending.revision) {
            throw const CoreException(
              _unusable,
              'Native completion correlation failed',
            );
          }
          if (event.code != native.VxCoreError.VXCORE_OK) {
            throw CoreException(
              event.code,
              event.message.cast<Utf8>().toDartString(),
            );
          }
          final hash = event.base_hash.cast<Utf8>().toDartString();
          if (event.kind == native.VXM_EVENT_WRITE) {
            pending.completer.complete(
              CoreWriteResult(revision: event.revision, baseHash: hash),
            );
          } else if (event.kind == native.VXM_EVENT_MUTATE) {
            pending.completer.complete(
              event.node_id.cast<Utf8>().toDartString(),
            );
          } else if (event.kind == native.VXM_EVENT_QUERY) {
            pending.completer.complete(pending.decode!(event));
          } else if (event.kind == native.VXM_EVENT_TAG) {
            pending.completer.complete(true);
          } else if (event.kind == native.VXM_EVENT_LIST ||
              event.kind == native.VXM_EVENT_CATALOG_OPEN) {
            pending.completer.complete(_directory(event));
          } else {
            if (event.size > _maxSource) {
              throw const CoreException(
                _unsupported,
                'Native source exceeds the editor limit',
              );
            }
            var text = '';
            if (event.size != 0) {
              final bytes = event.data.asTypedList(event.size);
              text = utf8.decode(bytes, allowMalformed: false);
              // Dart's decoder consumes one leading BOM; source offsets and
              // subsequent writes must retain that original code unit.
              if (bytes.length >= 3 &&
                  bytes[0] == 0xef &&
                  bytes[1] == 0xbb &&
                  bytes[2] == 0xbf) {
                text = '\ufeff$text';
              }
            }
            pending.completer.complete(
              CoreNote(
                notebookId: event.notebook_id.cast<Utf8>().toDartString(),
                nodeId: event.node_id.cast<Utf8>().toDartString(),
                path: event.path.cast<Utf8>().toDartString(),
                notebookName: event.notebook_name.cast<Utf8>().toDartString(),
                editorType: switch (event.editor_type) {
                  native.VXM_EDITOR_MARKDOWN => CoreEditorType.markdown,
                  native.VXM_EDITOR_TEXT => CoreEditorType.text,
                  _ => throw const CoreException(
                    _unsupported,
                    'Unsupported native editor type',
                  ),
                },
                text: text,
                baseHash: hash,
                coreVersion: event.core_version.cast<Utf8>().toDartString(),
                lineEnding: event.line_ending,
              ),
            );
          }
        } catch (error, stack) {
          pending.completer.completeError(error, stack);
        }
      } finally {
        native.vxm_event_free(pointer);
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final handle = _handle;
    _handle =
        null; // Retire admission before any asynchronous cleanup boundary.
    if (handle == null) {
      _eventHandle = null;
      _listener.close();
      return;
    }
    native.vxm_host_request_close(handle);
    final code = await _closedEvent.future;
    // CLOSED is behind every admitted terminal. All request futures have settled.
    _eventHandle = null;
    await _destroyOffIsolate(handle.address);
    _listener.close(); // A queued stale notification cannot dereference a host.
    if (code != native.VxCoreError.VXCORE_OK) {
      throw CoreException(code, 'Native notebook shutdown failed');
    }
  }
}
