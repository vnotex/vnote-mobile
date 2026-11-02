// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Immutable, volatile state. No revision in this object represents persistence.
@immutable
class EditorSessionState {
  const EditorSessionState({
    required this.text,
    this.revision = 0,
    this.anchor = 0,
    this.head = 0,
    this.ready = false,
    this.closing = false,
    this.closed = false,
    this.snapshotRevision,
    this.error,
  });

  final String text;
  final int revision;
  final int anchor;
  final int head;
  final bool ready;
  final bool closing;
  final bool closed;
  final int? snapshotRevision;
  final String? error;

  EditorSessionState _with({
    String? text,
    int? revision,
    int? anchor,
    int? head,
    bool? ready,
    bool? closing,
    bool? closed,
    int? snapshotRevision,
    String? error,
  }) => EditorSessionState(
    text: text ?? this.text,
    revision: revision ?? this.revision,
    anchor: anchor ?? this.anchor,
    head: head ?? this.head,
    ready: ready ?? this.ready,
    closing: closing ?? this.closing,
    closed: closed ?? this.closed,
    snapshotRevision: snapshotRevision ?? this.snapshotRevision,
    error: error ?? this.error,
  );
}

/// Constructor-injected protocol consumer, independent of WebView/native APIs.
///
/// The mirror is updated once per validated batch. Exact wire fingerprints and
/// their responses are retained for only the last 64 requests (not full snapshots);
/// evicted editor requests cannot be applied again. NotebookSession owns writes.
class EditorSession extends ValueNotifier<EditorSessionState> {
  EditorSession({
    required String initialText,
    required this.documentId,
    required this.baseVersion,
    required this.language,
    String Function()? generationFactory,
  }) : generation = (generationFactory ?? _randomGeneration)(),
       super(EditorSessionState(text: initialText)) {
    if (generation.length != 32 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(generation)) {
      throw ArgumentError('A generation must be 128 bits of lowercase hex.');
    }
    if (documentId.isEmpty ||
        documentId.length > 256 ||
        RegExp(r'[^A-Za-z0-9._:-]').hasMatch(documentId) ||
        baseVersion.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(baseVersion)) {
      throw ArgumentError('Invalid document identity or disk base hash.');
    }
    if (language != 'markdown' && language != 'text') {
      throw ArgumentError('Unsupported source editor language.');
    }
    _sourceBytes = _sourceSize(initialText);
  }

  final String documentId;
  final String baseVersion;
  final String language;
  static const maxSourceUnits = 4 * 1024 * 1024;
  static const maxSourceBytes = 4 * 1024 * 1024;
  static const maxEnvelopeBytes = 32 * 1024 * 1024;
  static const maxEditBytes = 512 * 1024;
  static const maxControlBytes = 8 * 1024;
  static const maxChanges = 256;
  static const maxInsertedUnits = 65536;
  static const maxRevision = 9007199254740991;
  final String generation;
  final _completed = <String, _CompletedRequest>{};
  final _pending = <String, String>{};
  int _hostSequence = 0;
  int _lastEditorSequence = 0;
  int _sourceBytes = 0;
  String? _loadRequest;
  bool _faulted = false;
  int? _snapshotTarget;
  Completer<EditorSnapshot>? _snapshotCompletion;
  Completer<void>? _closeCompletion;
  String? _closeDisposition;
  int? _closeTarget;
  _PendingInsertion? _insertion;
  bool _disposed = false;

  static String _randomGeneration() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      growable: false,
    ).join();
  }

  /// Called once, and only after the bundled page actually finishes loading.
  Map<String, Object?>? beginLoad() {
    if (_loadRequest != null || value.closed || _faulted) {
      reportTransportError(
        'Unexpected editor reload. The received text is retained; no reload or replacement was attempted.',
      );
      return null;
    }
    final message = _request('load', {
      'text': value.text,
      'language': language,
      'baseVersion': baseVersion,
      'lineEndingPolicy': 'preserve',
      'reason': 'open',
      'selection': {'anchor': 0, 'head': 0},
    });
    _loadRequest = message['requestId']! as String;
    _pending[_loadRequest!] = 'ready';
    return message;
  }

  Map<String, Object?>? command(String command) {
    if (command != 'undo' && command != 'redo') {
      throw ArgumentError.value(command, 'command');
    }
    if (!_canControl) return null;
    return _request('command', {'command': command});
  }

  Map<String, Object?>? theme({required bool dark}) {
    if (!_canControl) return null;
    return _request('theme', {'theme': dark ? 'dark' : 'light'});
  }

  /// Inserts literal source at a freshly flushed cursor, never a cached cursor.
  /// Asset durability and explicit notebook Write remain separate operations.
  Future<void> insertText(EditorSend send, String text) {
    if (!_canControl || _insertion != null) {
      return Future.error(
        StateError('Insertion is unavailable or already pending.'),
      );
    }
    try {
      _require(
        text.length <= maxInsertedUnits,
        'Insertion exceeds its source limit.',
      );
      _utf8Size(text, limit: maxControlBytes);
      // Reserve worst-case counters/offsets before asking the page for a cursor.
      // JSON escaping counts too; no full-document snapshot is allocated.
      _utf8Size(
        jsonEncode({
          'v': 1,
          'type': 'insert',
          'documentId': documentId,
          'generation': generation,
          'revision': maxRevision,
          'requestId': 'host-$maxRevision',
          'text': text,
          'anchor': maxSourceUnits,
          'head': maxSourceUnits,
        }),
        limit: maxControlBytes,
      );
      _require(
        _hostSequence <= maxRevision - 2,
        'Host request numbers exhausted.',
      );
    } on FormatException catch (error) {
      return Future.error(error);
    }
    final request = _request('selection', {'mode': 'request'});
    final insertion = _PendingInsertion(
      send,
      text,
      request['requestId']! as String,
      value.revision,
    );
    _insertion = insertion;
    _pending[insertion.selectionRequest] = 'insertSelection';
    try {
      send(request);
    } on Object catch (_) {
      reportTransportError(
        'Unable to request the insertion cursor. Text is retained.',
      );
    }
    return insertion.completion.future;
  }

  /// Flushes one correlated current snapshot; receipt alone is not a write.
  Map<String, Object?>? requestSnapshot() {
    if (!canRequestSnapshot) return null;
    _snapshotTarget = value.revision;
    final message = _request('save', {
      'mode': 'snapshotRequest',
      'reason': 'manual',
    });
    _pending[message['requestId']! as String] = 'snapshot';
    return message;
  }

  bool get canRequestSnapshot => _canControl && _snapshotTarget == null;

  Future<EditorSnapshot> captureSnapshot(EditorSend send) {
    final request = requestSnapshot();
    if (request == null) {
      return Future.error(StateError('Snapshot is unavailable.'));
    }
    final completion = Completer<EditorSnapshot>();
    _snapshotCompletion = completion;
    try {
      send(request);
    } on Object catch (_) {
      reportTransportError(
        'Unable to send the snapshot request. Text is retained.',
      );
    }
    return completion.future;
  }

  Future<void> closeEditor(EditorSend send, {required bool discard}) {
    if (value.closed || _loadRequest == null) return Future.value();
    if (_closeCompletion != null) return _closeCompletion!.future;
    final completion = Completer<void>();
    _closeCompletion = completion;
    final message = _requestClose(discard ? 'discard' : 'written');
    if (message == null) {
      _closeCompletion = null;
      return Future.error(StateError('Editor close is unavailable.'));
    }
    try {
      send(message);
    } on Object catch (_) {
      reportTransportError(
        'Unable to send the close request. Text is retained.',
      );
    }
    return completion.future;
  }

  bool get _canControl =>
      !_disposed && value.ready && !value.closing && !value.closed && !_faulted;

  Map<String, Object?>? _requestClose(String disposition) {
    if (value.closed || value.closing || _loadRequest == null) return null;
    final message = _request('close', {
      'mode': 'request',
      'disposition': disposition,
    });
    _settleInsertion(
      'The editor is closing. Received text and the asset are retained.',
    );
    _closeDisposition = disposition;
    _closeTarget = value.revision;
    _pending[message['requestId']! as String] = 'close';
    value = value._with(closing: true);
    return message;
  }

  void reportTransportError(String error) {
    if (_disposed) return;
    _faulted = true;
    _settleInsertion(error);
    _snapshotCompletion?.completeError(StateError(error));
    _snapshotCompletion = null;
    _closeCompletion?.completeError(StateError(error));
    _closeCompletion = null;
    value = value._with(ready: false, error: error);
  }

  @override
  void dispose() {
    _settleInsertion(
      'The editor session was retired. Received text and the asset are retained.',
    );
    _disposed = true;
    super.dispose();
  }

  bool _isInsertionRequest(String? requestId) =>
      requestId != null &&
      _insertion != null &&
      (requestId == _insertion!.selectionRequest ||
          requestId == _insertion!.requestId);

  void _settleInsertion([String? error]) {
    final insertion = _insertion;
    if (insertion == null) return;
    _insertion = null;
    for (final id in [insertion.selectionRequest, insertion.requestId]) {
      if (id == null) continue;
      _pending.remove(id);
      // Late/changed receipts are tombstones, not new operations or edit faults.
      _remember(id, null, null);
    }
    if (error == null) {
      insertion.completion.complete();
    } else {
      insertion.completion.completeError(StateError(error));
    }
  }

  void _receiveInsertionSelection(
    Map<String, dynamic> message,
    String requestId,
  ) {
    _keys(message, {'mode', 'anchor', 'head'});
    _require(
      _canControl &&
          _insertion != null &&
          _pending[requestId] == 'insertSelection' &&
          message['mode'] == 'current',
      'Unexpected insertion selection barrier.',
    );
    final insertion = _insertion!;
    final revision = message['revision'] as int;
    _require(
      revision == value.revision && revision >= insertion.minimumRevision,
      'Insertion selection no longer matches the received source.',
    );
    final selection = _selection(message, value.text);
    final from = min(selection.$1, selection.$2);
    final to = max(selection.$1, selection.$2);
    final text = insertion.text;
    _require(from != to || text.isNotEmpty, 'Insertion must change source.');
    _require(
      revision < maxRevision,
      'Revision exhausted; retain this session.',
    );
    _require(
      _hostSequence < maxRevision,
      'Host request numbers exhausted; retain this session.',
    );
    _require(
      value.text.length + text.length - (to - from) <= maxSourceUnits &&
          _sourceBytes +
                  _utf8Size(text) -
                  _utf8Size(value.text, start: from, end: to) <=
              maxSourceBytes,
      'Insertion exceeds the document limit.',
    );
    // Do not create a CRLF pair with the resulting cursor inside it.
    _require(
      to == value.text.length ||
          value.text.codeUnitAt(to) != 10 ||
          (text.isNotEmpty
              ? text.codeUnitAt(text.length - 1) != 13
              : from == 0 || value.text.codeUnitAt(from - 1) != 13),
      'Insertion would split a CRLF at its resulting cursor.',
    );
    final request = _request('insert', {
      'revision': revision,
      'text': text,
      'anchor': selection.$1,
      'head': selection.$2,
    });
    _utf8Size(jsonEncode(request), limit: maxControlBytes);
    insertion.requestId = request['requestId']! as String;
    insertion.baseRevision = revision;
    insertion.from = from;
    insertion.to = to;
    _pending.remove(requestId);
    _remember(requestId, null, null);
    _pending[insertion.requestId!] = 'insert';
    value = value._with(anchor: selection.$1, head: selection.$2);
    // A listener may retire this session while the cursor is published.
    if (!identical(_insertion, insertion)) return;
    try {
      insertion.send(request);
    } on Object catch (_) {
      reportTransportError(
        'Unable to send the insertion. Received text and the asset are retained.',
      );
    }
  }

  void _failControl(String? requestId, String error) {
    if (_isInsertionRequest(requestId)) {
      _settleInsertion(error);
      return;
    }
    final pending = _pending.remove(requestId);
    if (pending == 'snapshot') {
      _snapshotTarget = null;
      _snapshotCompletion?.completeError(StateError(error));
      _snapshotCompletion = null;
    } else if (pending == 'close') {
      value = value._with(closing: false);
      _closeCompletion?.completeError(StateError(error));
      _closeCompletion = null;
    } else if (pending == 'ready') {
      reportTransportError(error);
    }
  }

  void _receiveAcknowledgement(Map<String, dynamic> message, String requestId) {
    _keys(message, {'stage', 'throughRevision', 'error'}, optional: {'error'});
    _require(
      requestId.startsWith('host-'),
      'Acknowledgements must answer a host request.',
    );
    final stage = message['stage'];
    _require(
      stage == 'received' || stage == 'rejected',
      'Invalid acknowledgement stage.',
    );
    final revision = message['revision'] as int;
    _require(
      _integer(message['throughRevision']) &&
          message['throughRevision'] == revision &&
          revision <= value.revision,
      'Invalid acknowledgement revision.',
    );
    _require(
      !message.containsKey('error') ||
          (message['error'] is String &&
              (message['error'] as String).length <= 1024),
      'Invalid acknowledgement error.',
    );
    if (stage == 'rejected') {
      _require(
        message['error'] is String && (message['error'] as String).isNotEmpty,
        'Missing rejection error.',
      );
      _failControl(requestId, message['error'] as String);
      return;
    }
    final insertion = _insertion;
    if (insertion != null &&
        _pending[requestId] == 'insert' &&
        insertion.requestId == requestId) {
      _require(
        insertion.matchedRevision == revision &&
            revision == insertion.baseRevision! + 1,
        'Insertion receipt arrived without its matching edit batch.',
      );
      _settleInsertion();
    } else {
      _require(
        !_pending.containsKey(requestId),
        'Unexpected received acknowledgement.',
      );
      // A late receipt outside the bounded replay window cannot become a fault
      // or settle a newer insertion. Host controls never get a rejected reply.
    }
  }

  Map<String, Object?> _request(String type, Map<String, Object?> fields) {
    if (_hostSequence == maxRevision) {
      throw StateError('Host request numbers exhausted; retain this session.');
    }
    return {
      'v': 1,
      'type': type,
      'documentId': documentId,
      'generation': generation,
      'revision': value.revision,
      'requestId': 'host-${++_hostSequence}',
      ...fields,
    };
  }

  /// Receives only the narrow VNoteEditor channel's JSON string. Any returned
  /// message is sent as JSON data; this controller never constructs JavaScript.
  Map<String, Object?>? receive(String wire) {
    if (_disposed) return null;
    Map<String, dynamic>? message;
    String? requestId;
    var rememberWire = false;
    try {
      // Count without allocating an encoded copy, before allowing JSON parsing.
      final bytes = _utf8Size(wire, limit: maxEnvelopeBytes);
      final decoded = jsonDecode(wire);
      _require(decoded is Map<String, dynamic>, 'Expected a JSON object.');
      message = decoded as Map<String, dynamic>;
      // Other documents/generations are untrusted stale traffic, not this
      // session's errors. Do not change its UI, mirror, or replay window.
      if (message['generation'] != generation ||
          message['documentId'] != documentId) {
        return null;
      }
      _require(
        message['v'] is int && message['v'] == 1,
        'Unsupported protocol version.',
      );
      _require(message['type'] is String, 'Missing message type.');
      _require(_integer(message['revision']), 'Invalid revision.');
      _require(message['requestId'] is String, 'Missing request ID.');
      final candidateId = message['requestId'] as String;
      _require(
        candidateId.length <= 32 &&
            RegExp(r'^(host|editor)-[1-9][0-9]*$').hasMatch(candidateId),
        'Invalid request ID.',
      );
      requestId = candidateId;
      final type = message['type'] as String;
      final revision = message['revision'] as int;
      _require(
        bytes <=
            (type == 'edit'
                ? maxEditBytes
                : type == 'save'
                ? maxEnvelopeBytes
                : maxControlBytes),
        'Message exceeds its encoded size limit.',
      );
      // A malformed acknowledgement must not consume an editor sequence and
      // make the next unrelated edit look like a replay.
      _require(
        type != 'ack' || requestId.startsWith('host-'),
        'Acknowledgements must answer a host request.',
      );
      // Full snapshots are never retained in the replay cache.
      rememberWire = type != 'save' || bytes <= maxControlBytes;
      if (value.closed) return null;
      // Stale selection is intentionally dropped, even outside the replay window.
      if (type == 'selection' &&
          requestId.startsWith('editor-') &&
          revision < value.revision) {
        return null;
      }
      final completed = _completed[requestId];
      if (completed != null) {
        // Retired full transfers are tombstones, not repeatable mutations.
        if (completed.wire == null) return null;
        _require(
          completed.wire == wire,
          'Request ID reused with changed payload.',
        );
        return completed.response;
      }
      if (requestId.startsWith('editor-')) {
        final sequence = int.tryParse(requestId.substring(7));
        _require(
          sequence != null && sequence <= maxRevision,
          'Invalid editor request number.',
        );
        _require(
          sequence! > _lastEditorSequence,
          'Request is older than the replay window; both texts are retained.',
        );
        _lastEditorSequence = sequence;
      } else {
        final sequence = int.tryParse(requestId.substring(5));
        _require(
          sequence != null && sequence <= _hostSequence,
          'Unknown host request.',
        );
        _require(
          type == 'ready' ||
              type == 'save' ||
              type == 'close' ||
              type == 'ack' ||
              type == 'selection',
          'Invalid host request reply.',
        );
      }
      Map<String, Object?>? response;
      switch (type) {
        case 'ready':
          _keys(message, {'textLength'});
          _require(
            !_faulted &&
                _pending[requestId] == 'ready' &&
                requestId == _loadRequest,
            'Unexpected ready response.',
          );
          _require(
            revision == 0 && value.revision == 0,
            'Ready revision mismatch.',
          );
          _require(
            message['textLength'] is int &&
                message['textLength'] == value.text.length,
            'Ready text length mismatch.',
          );
          _pending.remove(requestId);
          value = value._with(ready: true);
          response = _ack(requestId, 'received');
        case 'edit':
          _require(
            !_faulted && value.ready,
            'Editor is not ready; retain both texts.',
          );
          _require(
            requestId.startsWith('editor-'),
            'Edits require an editor request ID.',
          );
          _applyEdit(message);
          response = _ack(requestId, 'received');
        case 'selection':
          if (requestId.startsWith('host-')) {
            // Old cursor replies after cache eviction are inert too.
            if (!_pending.containsKey(requestId)) return null;
            _receiveInsertionSelection(message, requestId);
            break;
          }
          _keys(message, {'anchor', 'head'});
          _require(value.ready && !_faulted, 'Editor is not ready.');
          _require(
            requestId.startsWith('editor-'),
            'Selection requires an editor request ID.',
          );
          _require(revision == value.revision, 'Future selection revision.');
          final selection = _selection(message, value.text);
          value = value._with(anchor: selection.$1, head: selection.$2);
        case 'save':
          if (message.containsKey('reason')) {
            _require(
              const {'manual', 'close'}.contains(message['reason']),
              'Invalid snapshot/save reason.',
            );
          }
          _keys(message, {'mode', 'text', 'reason'}, optional: {'reason'});
          _require(
            message['mode'] == 'snapshot' && _pending[requestId] == 'snapshot',
            'Unrequested snapshot.',
          );
          _require(
            _snapshotTarget != null &&
                revision >= _snapshotTarget! &&
                revision == value.revision,
            'Snapshot revision mismatch; both texts are retained.',
          );
          _require(
            message['text'] is String,
            'Snapshot text must be a string.',
          );
          _sourceSize(message['text'] as String);
          _require(
            message['text'] == value.text,
            'Snapshot differs from the validated mirror; both texts are retained.',
          );
          _pending.remove(requestId);
          _snapshotTarget = null;
          final completion = _snapshotCompletion;
          _snapshotCompletion = null;
          value = value._with(snapshotRevision: revision);
          completion?.complete(EditorSnapshot(value.text, revision));
          response = _ack(requestId, 'received');
        case 'close':
          _keys(message, {'mode', 'disposition'});
          _require(
            message['mode'] == 'ready' &&
                message['disposition'] == _closeDisposition,
            'Invalid close response.',
          );
          _require(
            _pending[requestId] == 'close' && value.closing,
            'Close requires an approved barrier.',
          );
          _require(
            revision == value.revision &&
                (_closeDisposition == 'discard' || revision == _closeTarget),
            'Close revision mismatch; view retained.',
          );
          _pending.remove(requestId);
          value = value._with(ready: false, closed: true);
          _closeCompletion?.complete();
          _closeCompletion = null;
        case 'ack':
          _receiveAcknowledgement(message, requestId);
        default:
          throw const FormatException('Unknown editor message type.');
      }
      _remember(
        requestId,
        type == 'save' ||
                type == 'ack' ||
                (type == 'selection' && requestId.startsWith('host-'))
            ? null
            : wire,
        response,
      );
      return response;
    } on FormatException catch (error) {
      final correlatedId =
          requestId ??
          (message?['requestId'] is String
              ? message!['requestId'] as String
              : null);
      if (_isInsertionRequest(correlatedId) || message?['type'] == 'ack') {
        _failControl(correlatedId, error.message);
        return null;
      }
      reportTransportError(error.message);

      // Never acknowledge an acknowledgement, or respond to an unbound message.
      if (requestId == null || message?['type'] == 'ack') return null;
      final response = _ack(requestId, 'rejected', error: error.message);
      // A changed duplicate must not replace the original replay fingerprint.
      if (rememberWire && !_completed.containsKey(requestId)) {
        _remember(requestId, wire, response);
      }
      return response;
    }
  }

  void _applyEdit(Map<String, dynamic> message) {
    _keys(message, {'baseRevision', 'changes', 'selection'});
    _require(
      _integer(message['baseRevision']) &&
          message['baseRevision'] == value.revision,
      'Out-of-order edit base; both texts are retained.',
    );
    _require(
      value.revision < maxRevision && message['revision'] == value.revision + 1,
      'Edit revision gap; both texts are retained.',
    );
    final changes = message['changes'];
    _require(
      changes is List && changes.isNotEmpty && changes.length <= maxChanges,
      'Invalid edit range count.',
    );
    var end = 0;
    var inserted = 0;
    var units = value.text.length;
    var bytes = _sourceBytes;
    for (final item in changes as List) {
      _require(item is Map<String, dynamic>, 'Invalid change object.');
      final change = item as Map<String, dynamic>;
      _require(
        change.length == 3 &&
            change.containsKey('from') &&
            change.containsKey('to') &&
            change.containsKey('insert'),
        'Invalid change fields.',
      );
      _require(
        _integer(change['from']) &&
            _integer(change['to']) &&
            change['insert'] is String,
        'Invalid change types.',
      );
      final from = change['from'] as int;
      final to = change['to'] as int;
      final insert = change['insert'] as String;
      _require(
        from >= end && to >= from && to <= value.text.length,
        'Overlapping or out-of-bounds edit range.',
      );
      _require(
        _boundary(value.text, from) && _boundary(value.text, to),
        'Edit splits a surrogate pair or CRLF.',
      );
      inserted += insert.length;
      _require(
        inserted <= maxInsertedUnits,
        'Edit exceeds 65,536 inserted UTF-16 units.',
      );
      units += insert.length - (to - from);
      bytes +=
          _utf8Size(insert, limit: maxSourceBytes) -
          _utf8Size(value.text, start: from, end: to);
      end = to;
    }
    _require(
      units <= maxSourceUnits && bytes <= maxSourceBytes,
      'Edit exceeds the 4 MiB document limit. Previous text is retained.',
    );
    // One linear construction, rather than repeatedly copying the full document.
    final buffer = StringBuffer();
    end = 0;
    for (final item in changes) {
      final change = item as Map<String, dynamic>;
      final from = change['from'] as int;
      final to = change['to'] as int;
      if (from > end) buffer.write(value.text.substring(end, from));
      buffer.write(change['insert']);
      end = to;
    }
    if (end < value.text.length) buffer.write(value.text.substring(end));
    final next = buffer.toString();
    _require(
      message['selection'] is Map<String, dynamic>,
      'Missing edit selection.',
    );
    final selection = message['selection'] as Map<String, dynamic>;
    _require(
      selection.length == 2 &&
          selection.containsKey('anchor') &&
          selection.containsKey('head'),
      'Invalid selection fields.',
    );
    final positions = _selection(selection, next);
    // Correlation does not mutate the mirror: this still is an ordinary edit.
    final insertion = _insertion;
    if (insertion != null &&
        insertion.requestId != null &&
        insertion.baseRevision == value.revision &&
        changes.length == 1) {
      final change = changes.single as Map<String, dynamic>;
      final position = insertion.from! + insertion.text.length;
      if (change['from'] == insertion.from &&
          change['to'] == insertion.to &&
          change['insert'] == insertion.text &&
          positions.$1 == position &&
          positions.$2 == position) {
        insertion.matchedRevision = message['revision'] as int;
      }
    }
    // Publish only after every range, byte limit, and selection has passed.
    _sourceBytes = bytes;

    value = value._with(
      text: next,
      revision: message['revision'] as int,
      anchor: positions.$1,
      head: positions.$2,
    );
  }

  Map<String, Object?> _ack(String requestId, String stage, {String? error}) =>
      {
        'v': 1,
        'type': 'ack',
        'documentId': documentId,
        'generation': generation,
        'revision': value.revision,
        'requestId': requestId,
        'stage': stage,
        'throughRevision': value.revision,
        'error': ?error,
      };

  void _remember(
    String requestId,
    String? wire,
    Map<String, Object?>? response,
  ) {
    _completed[requestId] = _CompletedRequest(
      wire,
      response == null ? null : Map.unmodifiable(response),
    );
    if (_completed.length > 64) _completed.remove(_completed.keys.first);
  }

  static bool _integer(Object? value) =>
      value is int && value >= 0 && value <= maxRevision;

  static void _keys(
    Map<String, dynamic> message,
    Set<String> payload, {
    Set<String> optional = const {},
  }) {
    const envelope = {
      'v',
      'type',
      'documentId',
      'generation',
      'revision',
      'requestId',
    };
    _require(
      message.keys.every(
            (key) => envelope.contains(key) || payload.contains(key),
          ) &&
          payload.difference(optional).every(message.containsKey),
      'Unexpected or missing message fields.',
    );
  }

  static (int, int) _selection(Map<String, dynamic> selection, String text) {
    _require(
      _integer(selection['anchor']) && _integer(selection['head']),
      'Invalid selection types.',
    );
    final anchor = selection['anchor'] as int;
    final head = selection['head'] as int;
    _require(
      anchor <= text.length &&
          head <= text.length &&
          _boundary(text, anchor) &&
          _boundary(text, head),
      'Selection splits a surrogate pair or CRLF, or is out of bounds.',
    );
    return (anchor, head);
  }

  static bool _boundary(String text, int offset) {
    if (offset <= 0 || offset >= text.length) return true;
    final before = text.codeUnitAt(offset - 1);
    final after = text.codeUnitAt(offset);
    return !(before >= 0xd800 &&
            before <= 0xdbff &&
            after >= 0xdc00 &&
            after <= 0xdfff) &&
        !(before == 13 && after == 10);
  }

  static int _sourceSize(String text) {
    _require(
      text.length <= maxSourceUnits,
      'Source exceeds the UTF-16 document limit.',
    );
    return _utf8Size(text, limit: maxSourceBytes);
  }

  static int _utf8Size(
    String text, {
    int start = 0,
    int? end,
    int limit = maxEnvelopeBytes,
  }) {
    var bytes = 0;
    final through = end ?? text.length;
    for (var index = start; index < through; index++) {
      final unit = text.codeUnitAt(index);
      if (unit < 0x80) {
        bytes++;
      } else if (unit < 0x800) {
        bytes += 2;
      } else if (unit >= 0xd800 && unit <= 0xdbff) {
        _require(index + 1 < through, 'Source contains a lone surrogate.');
        final low = text.codeUnitAt(++index);
        _require(
          low >= 0xdc00 && low <= 0xdfff,
          'Source contains a lone surrogate.',
        );
        bytes += 4;
      } else {
        _require(
          unit < 0xdc00 || unit > 0xdfff,
          'Source contains a lone surrogate.',
        );
        bytes += 3;
      }
      _require(bytes <= limit, 'Encoded text exceeds its byte limit.');
    }
    return bytes;
  }

  static void _require(bool condition, String message) {
    if (!condition) throw FormatException(message);
  }
}

class _PendingInsertion {
  _PendingInsertion(
    this.send,
    this.text,
    this.selectionRequest,
    this.minimumRevision,
  );

  final EditorSend send;
  final String text;
  final String selectionRequest;
  final int minimumRevision;
  final completion = Completer<void>();
  String? requestId;
  int? baseRevision;
  int? from;
  int? to;
  int? matchedRevision;
}

class _CompletedRequest {
  const _CompletedRequest(this.wire, this.response);

  // Exact bounded wire fingerprints avoid accepting hash collisions as replays.
  final String? wire;
  final Map<String, Object?>? response;
}

/// Only a validated mirror-matching transfer can produce this capture.
@immutable
class EditorSnapshot {
  const EditorSnapshot(this.text, this.revision);
  final String text;
  final int revision;
}

typedef EditorSend = void Function(Map<String, Object?> message);
