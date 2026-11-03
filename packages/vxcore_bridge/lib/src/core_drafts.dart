// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'core_notebook.dart' show CoreException;
import 'generated/vxcore_host_bindings.dart' as native;

Never _malformed() => throw const CoreException(
  native.VxCoreError.VXCORE_ERR_JSON_PARSE,
  'Malformed native draft response',
);
Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) _malformed();
  return Map<String, Object?>.unmodifiable(value);
}
String _string(Map<String, Object?> value, String key, {int? hex}) {
  final field = value[key];
  if (field is! String || field.contains('\u0000')) _malformed();
  if (hex != null && !RegExp('^[0-9a-f]{$hex}\$').hasMatch(field)) _malformed();
  return field;
}
String? _optionalString(Map<String, Object?> value, String key, {int? hex}) =>
    value[key] == null ? null : _string(value, key, hex: hex);
int _integer(Map<String, Object?> value, String key, {int maximum = 9007199254740991}) {
  final field = value[key];
  if (field is! int || field < 0 || field > maximum) _malformed();
  return field;
}
bool _boolean(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! bool) _malformed();
  return field;
}

/// Stable ordinary-source policy captured by the native note owner at open.
final class CoreDraftDescriptor {
  const CoreDraftDescriptor({
    required this.notebookRelative,
    required this.notebookId,
    required this.nodeId,
    required this.pathHint,
    required this.editorType,
    required this.openingDiskHash,
    required this.eol,
  });

  factory CoreDraftDescriptor.fromJson(Map<String, Object?> value) {
    if (value.length != 7 ||
        !{'markdown', 'text'}.contains(value['editorType'])) _malformed();
    return CoreDraftDescriptor(
      notebookRelative: _string(value, 'notebookRelative'),
      notebookId: _string(value, 'notebookId'),
      nodeId: _string(value, 'nodeId'),
      pathHint: _string(value, 'pathHint'),
      editorType: _string(value, 'editorType'),
      openingDiskHash: _string(value, 'openingDiskHash', hex: 64),
      eol: _integer(value, 'eol', maximum: 3),
    );
  }

  final String notebookRelative;
  final String notebookId;
  final String nodeId;
  final String pathHint;
  final String editorType;
  final String openingDiskHash;
  final int eol;

  Map<String, Object?> toJson() => {
    'notebookRelative': notebookRelative,
    'notebookId': notebookId,
    'nodeId': nodeId,
    'pathHint': pathHint,
    'editorType': editorType,
    'openingDiskHash': openingDiskHash,
    'eol': eol,
  };
}

/// A validated acknowledged prefix. A saved revision is not a newer head's
/// saved proof: compare token, revision, source hash, and pending intent.
final class CoreDraftSummary {
  CoreDraftSummary._(this.record, this.descriptor) {
    _string(record, 'documentKey', hex: 64);
    _string(record, 'token', hex: 32);
    _integer(record, 'revision');
    _string(record, 'sourceHash', hex: 64);
    _string(record, 'baseSourceHash', hex: 64);
    if (record['savedRevision'] != null) {
      _integer(record, 'savedRevision', maximum: revision);
      _string(record, 'savedSourceHash', hex: 64);
      _string(record, 'savedDiskHash', hex: 64);
    } else if (record['savedSourceHash'] != null || record['savedDiskHash'] != null) {
      _malformed();
    }
    _optionalString(record, 'candidateId', hex: 32);
    _optionalString(record, 'supersededBy', hex: 32);
    _optionalString(record, 'savedCandidateId', hex: 32);
    _optionalString(record, 'savedRequestId');
    if (!{'draft', 'pending', 'saved', 'superseded'}.contains(status) ||
        (status != 'superseded' && (status == 'pending') != (candidateId != null)) ||
        (status == 'superseded') != (supersededBy != null) ||
        (status == 'saved' && (savedSourceHash != sourceHash || savedRevision == null))) {
      _malformed();
    }
  }

  factory CoreDraftSummary.fromJson(Map<String, Object?> value) => CoreDraftSummary._(
    _map(value), CoreDraftDescriptor.fromJson(_map(value['descriptor'])),
  );

  final Map<String, Object?> record;
  final CoreDraftDescriptor descriptor;
  String get documentKey => record['documentKey']! as String;
  String get token => record['token']! as String;
  int get revision => record['revision']! as int;
  String get sourceHash => record['sourceHash']! as String;
  String get baseSourceHash => record['baseSourceHash']! as String;
  int? get savedRevision => record['savedRevision'] as int?;
  String? get savedSourceHash => record['savedSourceHash'] as String?;
  String? get savedDiskHash => record['savedDiskHash'] as String?;
  String? get candidateId => record['candidateId'] as String?;
  String? get supersededBy => record['supersededBy'] as String?;
  String? get savedCandidateId => record['savedCandidateId'] as String?;
  String? get savedRequestId => record['savedRequestId'] as String?;
  String get status => record['status']! as String;
  bool get resolved => status == 'saved' || status == 'superseded';
}

final class CoreDraftCandidate {
  CoreDraftCandidate._(this.record) {
    _string(record, 'documentKey', hex: 64); _string(record, 'token', hex: 32);
    _string(record, 'candidateId', hex: 32); _integer(record, 'revision');
    for (final key in ['sourceHash', 'expectedDiskHash', 'intendedDiskHash']) {
      _string(record, key, hex: 64);
    }
    _integer(record, 'eol', maximum: 3);
  }
  factory CoreDraftCandidate.fromJson(Map<String, Object?> value) => CoreDraftCandidate._(_map(value));
  final Map<String, Object?> record;
  String get documentKey => record['documentKey']! as String;
  String get token => record['token']! as String;
  String get candidateId => record['candidateId']! as String;
  int get revision => record['revision']! as int;
  String get sourceHash => record['sourceHash']! as String;
  String get expectedDiskHash => record['expectedDiskHash']! as String;
  String get intendedDiskHash => record['intendedDiskHash']! as String;
  int get eol => record['eol']! as int;
}

/// Native owner matrix facts, not writable saved-proof input to the FS API.
class CoreDraftInspection {
  CoreDraftInspection._(this.record) : summary = CoreDraftSummary.fromJson(record) {
    if (!{'base', 'saved', 'conflict'}.contains(record['outcome'])) _malformed();
    _boolean(record, 'canRetry');
    _string(record, 'observedDiskHash');
    if (observedDiskHash.isEmpty) {
      if (outcome != 'conflict') _malformed();
    } else {
      _string(record, 'observedDiskHash', hex: 64);
    }
    _optionalString(record, 'completedCandidateId', hex: 32);
    _optionalString(record, 'completedRequestId');
    if (canRetry && summary.candidateId == null) _malformed();
  }
  factory CoreDraftInspection.fromJson(Map<String, Object?> value) => CoreDraftInspection._(_map(value));
  final Map<String, Object?> record;
  final CoreDraftSummary summary;
  String get outcome => record['outcome']! as String;
  bool get canRetry => record['canRetry']! as bool;
  String get observedDiskHash => record['observedDiskHash']! as String;
  String? get completedCandidateId => record['completedCandidateId'] as String?;
  String? get completedRequestId => record['completedRequestId'] as String?;
}

final class CoreDraftWriteResult extends CoreDraftInspection {
  CoreDraftWriteResult._(super.record) : super._();
  factory CoreDraftWriteResult.fromJson(Map<String, Object?> value) {
    final result = CoreDraftWriteResult._(_map(value));
    if (result.outcome != 'saved' || result.summary.savedRevision == null || result.completedCandidateId == null) {
      _malformed();
    }
    return result;
  }
}

/// Immutable native-pinned source binding, suitable only for v2 origin=draft.
final class CoreDraftExport {
  CoreDraftExport._(this.record) {
    if (record.length != 6) _malformed();
    _string(record, 'documentKey', hex: 64); _string(record, 'token', hex: 32);
    _string(record, 'candidateId', hex: 32); _string(record, 'sha256', hex: 64);
    _integer(record, 'revision');
    if (!{'text', 'raw-archive'}.contains(record['format'])) _malformed();
  }
  factory CoreDraftExport.fromJson(Map<String, Object?> value) => CoreDraftExport._(_map(value));
  final Map<String, Object?> record;
  String get documentKey => record['documentKey']! as String;
  String get token => record['token']! as String;
  int get revision => record['revision']! as int;
  String get candidateId => record['candidateId']! as String;
  String get sha256 => record['sha256']! as String;
  String get format => record['format']! as String;
  Map<String, Object?> toJson() => Map<String, Object?>.of(record);
}

/// Synchronous pure-filesystem ABI; execute on a joined worker isolate. Never
/// creates or borrows a core context, and never writes live notebook bodies.
abstract final class CoreDraftStore {
  static const _maximumRequest = 16384;
  static const _maximumPayload = 8 * 1024 * 1024;
  static const _maximumSourceResponse = 32 * 1024 * 1024;

  static String documentKey(String notebookId, String nodeId) => _string(run({
    'op': 'key', 'notebookId': notebookId, 'nodeId': nodeId,
  }), 'documentKey', hex: 64);

  static Map<String, Object?> run(
    Map<String, Object?> request, {
    Uint8List? payload,
    int cancellationAddress = 0,
  }) {
    if (cancellationAddress < 0 || (payload?.length ?? 0) > _maximumPayload) {
      throw const CoreException(native.VxCoreError.VXCORE_ERR_INVALID_PARAM, 'Invalid draft command or payload');
    }
    final encoded = jsonEncode(request);
    if (encoded.length > _maximumRequest || utf8.encode(encoded).length > _maximumRequest) {
      throw const CoreException(native.VxCoreError.VXCORE_ERR_INVALID_PARAM, 'Draft command exceeds its bound');
    }
    return using((arena) {
      final output = arena<Pointer<Char>>();
      final data = payload == null || payload.isEmpty ? nullptr.cast<Uint8>() : arena<Uint8>(payload.length);
      if (payload != null && payload.isNotEmpty) data.asTypedList(payload.length).setAll(0, payload);
      final code = native.vxm_draft_run(
        encoded.toNativeUtf8(allocator: arena).cast(), data, payload?.length ?? 0,
        Pointer<native.VxmImportCancel>.fromAddress(cancellationAddress), output,
      );
      final response = output.value;
      try {
        if (code != native.VxCoreError.VXCORE_OK) throw CoreException(code, _message(code));
        if (response == nullptr) _malformed();
        final maximum = request['op'] == 'read' || request['op'] == 'readBase' ? _maximumSourceResponse : 65536;
        final bytes = response.cast<Uint8>(); var length = 0;
        while (length <= maximum && bytes[length] != 0) { length++; }
        if (length > maximum) _malformed();
        final Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes.asTypedList(length), allowMalformed: false));
        } on FormatException { _malformed(); }
        return _map(decoded);
      } finally { native.vxm_import_result_free(response); }
    });
  }

  static String _message(int code) => switch (code) {
    native.VxCoreError.VXCORE_ERR_CANCELLED => 'Draft work was cancelled; inspect its committed prefix before retrying',
    native.VxCoreError.VXCORE_ERR_FILE_CHANGED_OUTSIDE => 'Draft bytes or ownership changed; preserve and export the retained journal',
    native.VxCoreError.VXCORE_ERR_UNSUPPORTED => 'Draft source, storage policy, or durability capacity limit was refused',
    native.VxCoreError.VXCORE_ERR_JSON_PARSE => 'Draft metadata or acknowledged data is malformed; retained bytes remain exportable',
    native.VxCoreError.VXCORE_ERR_INVALID_STATE => 'Draft token, revision, candidate, or durable pin does not match',
    _ => 'Draft storage failed; no durable acknowledgement was issued for this operation',
  };
}
