// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Received source and separately proven persistence watermarks.
@immutable
class EditorSessionState {
  const EditorSessionState({
    required this.text, this.revision = 0, this.anchor = 0, this.head = 0,
    this.ready = false, this.closing = false, this.closed = false,
    this.pending = false, this.composing = false, this.quiesced = false,
    this.draftDurableRevision = 0, this.savedRevision = 0,
    this.snapshotRevision, this.error, this.resyncCandidate,
  });
  final String text;
  final int revision;
  final int anchor;
  final int head;
  final bool ready;
  final bool closing;
  final bool closed;
  final bool pending;
  final bool composing;
  final bool quiesced;
  final int draftDurableRevision;
  final int? savedRevision;
  final int? snapshotRevision;
  final String? error;
  final EditorResyncCandidate? resyncCandidate;
  bool get locallySaved => !pending && !composing && error == null && savedRevision == revision;

  EditorSessionState _with({
    String? text, int? revision, int? anchor, int? head, bool? ready,
    bool? closing, bool? closed, bool? pending, bool? composing, bool? quiesced,
    int? draftDurableRevision, int? savedRevision, int? snapshotRevision,
    String? error, bool clearError = false, EditorResyncCandidate? resyncCandidate, bool clearCandidate = false,
  }) => EditorSessionState(
    text: text ?? this.text, revision: revision ?? this.revision,
    anchor: anchor ?? this.anchor, head: head ?? this.head,
    ready: ready ?? this.ready, closing: closing ?? this.closing,
    closed: closed ?? this.closed, pending: pending ?? this.pending,
    composing: composing ?? this.composing, quiesced: quiesced ?? this.quiesced,
    draftDurableRevision: draftDurableRevision ?? this.draftDurableRevision,
    savedRevision: savedRevision ?? this.savedRevision,
    snapshotRevision: snapshotRevision ?? this.snapshotRevision,
    error: clearError ? null : error ?? this.error,
    resyncCandidate: clearCandidate ? null : resyncCandidate ?? this.resyncCandidate,
  );
}

/// Validates the source bridge; the journal owner alone proves durable outcomes.
class EditorSession extends ValueNotifier<EditorSessionState> {
  EditorSession({
    required String initialText, required this.documentId,
    required this.baseVersion, required this.language,
    String Function()? generationFactory, this.onEdit, bool initiallySaved = true,
    int initialAnchor = 0, int initialHead = 0,
  }) : generation = (generationFactory ?? _randomGeneration)(),
       super(EditorSessionState(text: initialText, anchor: initialAnchor, head: initialHead,
         savedRevision: initiallySaved ? 0 : null)) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(generation) || generation.length != 32) {
      throw ArgumentError('A generation must be 128 bits of lowercase hex.');
    }
    if (documentId.isEmpty || documentId.length > 256 ||
        RegExp(r'[^A-Za-z0-9._:-]').hasMatch(documentId) || baseVersion.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(baseVersion)) {
      throw ArgumentError('Invalid document identity or disk base hash.');
    }
    if (language != 'markdown' && language != 'text') throw ArgumentError('Unsupported source editor language.');
    _sourceBytes = _sourceSize(initialText);
    _selection({'anchor': initialAnchor, 'head': initialHead}, initialText);
  }

  final String documentId;
  final String baseVersion;
  final String language;
  final String generation;
  void Function(EditorEditBatch)? onEdit;
  static const maxSourceUnits = 4 * 1024 * 1024;
  static const maxSourceBytes = 4 * 1024 * 1024;
  static const maxEnvelopeBytes = 32 * 1024 * 1024;
  static const maxEditBytes = 512 * 1024;
  static const maxControlBytes = 8 * 1024;
  static const maxChanges = 256;
  static const maxInsertedUnits = 65536;
  static const maxRevision = 9007199254740991;
  final _completed = <String, _CompletedRequest>{};
  final _pending = <String, _PendingControl>{};
  final _undurable = <int, int>{};
  int _hostSequence = 0, _lastEditorSequence = 0, _sourceBytes = 0;
  int _activitySequence = 0, _undurableBytes = 0;
  String? _loadRequest;
  bool _faulted = false, _disposed = false;
  _PendingSourceOperation? _operation;

  EditorCapture get capture => EditorCapture(documentId, generation, value.revision);
  bool get _canControl => !_disposed && value.ready && !value.closing && !value.closed && !_faulted;
  bool get canFlushSource => _canControl && !_pending.values.any((entry) => entry.kind == 'flush');

  static String _randomGeneration() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'), growable: false).join();
  }

  Map<String, Object?>? beginLoad() {
    if (_loadRequest != null || value.closed || _faulted || _disposed) {
      reportTransportError('Unexpected editor reload. Received source is retained; a durable new epoch is required.');
      return null;
    }
    final message = _request('load', {
      'text': value.text, 'language': language, 'baseVersion': baseVersion,
      'lineEndingPolicy': 'preserve', 'reason': 'open', 'selection': {'anchor': value.anchor, 'head': value.head},
    });
    _loadRequest = message['requestId']! as String;
    return message;
  }

  Map<String, Object?>? command(String command) {
    if (command != 'undo' && command != 'redo') throw ArgumentError.value(command, 'command');
    return _canControl ? _request('command', {'command': command}) : null;
  }

  Map<String, Object?>? preferences({required bool dark, bool highContrast = false,
    double fontScale = 1, bool reducedMotion = false}) {
    if (!fontScale.isFinite || fontScale < 0.5 || fontScale > 3) throw ArgumentError.value(fontScale, 'fontScale');
    if (_disposed || !value.ready || value.closed) return null;
    return _request('preferences', {'dark': dark, 'highContrast': highContrast,
      'fontScale': fontScale, 'reducedMotion': reducedMotion});
  }

  Map<String, Object?>? acknowledgeDraftDurable(EditorCapture captured) {
    if (!_matches(captured)) return null;
    _require(captured.revision <= value.revision, 'Draft durability exceeds received source.');
    if (captured.revision < value.draftDurableRevision) return null;
    for (final revision in _undurable.keys.where((revision) => revision <= captured.revision).toList()) {
      _undurableBytes -= _undurable.remove(revision)!;
    }
    value = value._with(draftDurableRevision: captured.revision);
    return _request('ack', {'revision': captured.revision, 'stage': 'draftDurable', 'throughRevision': captured.revision});
  }

  Map<String, Object?>? acknowledgeSaved(EditorCapture captured) {
    if (!_matches(captured)) return null;
    _require(captured.revision <= value.draftDurableRevision && captured.revision <= value.revision,
      'Saved receipt exceeds durable source.');
    if (value.savedRevision != null && captured.revision < value.savedRevision!) return null;
    value = value._with(savedRevision: captured.revision);
    return _request('ack', {'revision': captured.revision, 'stage': 'saved', 'throughRevision': captured.revision});
  }

  bool _matches(EditorCapture captured) => !_disposed && !value.closed &&
    captured.documentId == documentId && captured.generation == generation && _integer(captured.revision);

  Future<void> insertText(EditorSend send, String text) => _sourceOperation(send, 'insert', {'text': text});
  Future<void> format(EditorSend send, EditorFormat action) {
    if (language != 'markdown') return Future.error(StateError('Formatting requires Markdown source.'));
    try { action.validate(); } on Object catch (error) { return Future.error(error); }
    return _sourceOperation(send, 'format', action.toJson());
  }

  Future<void> _sourceOperation(EditorSend send, String type, Map<String, Object?> fields) {
    if (!_canControl || _operation != null) return Future.error(StateError('A source operation is unavailable or already pending.'));
    try {
      if (type == 'insert') {
        final text = fields['text']! as String;
        _require(text.length <= maxInsertedUnits, 'Insertion exceeds its source limit.');
        _utf8Size(text, limit: maxControlBytes);
      }
      _utf8Size(jsonEncode({'v': 2, 'type': type, 'documentId': documentId, 'generation': generation,
        'revision': maxRevision, 'requestId': 'host-$maxRevision', 'anchor': maxSourceUnits, 'head': maxSourceUnits,
        ...fields}), limit: maxControlBytes);
      _require(_hostSequence <= maxRevision - 2, 'Host request numbers exhausted.');
    } on Object catch (error) { return Future.error(error); }
    final request = _request('selection', {'mode': 'request'});
    final operation = _PendingSourceOperation(send, type, fields, request['requestId']! as String, value.revision);
    _operation = operation;
    operation.timer = Timer(const Duration(seconds: 5), () => _settleOperation('Source operation timed out; source is retained.'));
    try { send(request); } on Object catch (_) { reportTransportError('Unable to request the source-operation cursor. Text is retained.'); }
    return operation.completion.future;
  }

  Future<EditorSnapshot> flushSource(EditorSend send) {
    if (!canFlushSource) return Future.error(StateError('Source flush is unavailable.'));
    return _barrier(send, 'flush', {'mode': 'request'}, 'flush').then((result) => result! as EditorSnapshot);
  }

  Future<EditorSnapshot> quiesce(EditorSend send) {
    if (!_canControl) return Future.error(StateError('Editor quiescence is unavailable.'));
    _settleOperation('The editor is closing. Received source is retained.');
    value = value._with(closing: true);
    return _barrier(send, 'close', {'mode': 'quiesce'}, 'quiesce').then((result) => result! as EditorSnapshot);
  }

  Future<void> completeClose(EditorSend send, {required EditorCapture capture, required bool discard}) {
    if (!_matches(capture) || !value.quiesced || capture.revision != value.revision ||
        (!discard && value.draftDurableRevision < capture.revision)) {
      return Future.error(StateError('Close requires the exact quiesced, durable source or explicit discard.'));
    }
    return _barrier(send, 'close', {'mode': 'complete', 'disposition': discard ? 'discard' : 'retained'}, 'complete').then((_) {});
  }

  Future<void> abortClose(EditorSend send) {
    if (_disposed || value.closed || _loadRequest == null) return Future.error(StateError('Close abort is unavailable.'));
    for (final id in _pending.keys.where((id) =>
        _pending[id]!.kind == 'quiesce' || _pending[id]!.kind == 'abort').toList()) {
      _failControl(id, 'Close aborted; source is retained.');
    }
    return _barrier(send, 'close', {'mode': 'abort'}, 'abort').then((_) {});
  }

  Future<EditorResyncCandidate> requestResync(EditorSend send) {
    if (_disposed || value.closed || _loadRequest == null || value.resyncCandidate != null ||
        _pending.values.any((entry) => entry.kind == 'resync')) {
      return Future.error(StateError('A resync candidate is already retained or unavailable.'));
    }
    return _barrier(send, 'resync', {'mode': 'request'}, 'resync').then((result) => result! as EditorResyncCandidate);
  }

  Future<void> resumeResync(EditorSend send) {
    final candidate = value.resyncCandidate;
    if (candidate == null || candidate.revision != value.revision || candidate.text != value.text) {
      return Future.error(StateError('Divergent source requires an explicit recovery choice.'));
    }
    return _barrier(send, 'resync', {'mode': 'resume'}, 'resume').then((_) {});
  }

  Future<Object?> _barrier(EditorSend send, String type, Map<String, Object?> fields, String kind) {
    final request = _request(type, fields), id = request['requestId']! as String;
    final pending = _PendingControl(kind, value.revision);
    _pending[id] = pending;
    pending.timer = Timer(const Duration(seconds: 5), () {
      _failControl(id, 'Editor barrier timed out; source is retained.');
      if (kind == 'quiesce' && !_disposed && !value.closed) {
        unawaited(abortClose(send).catchError((Object _) {}));
      }
    });
    try { send(request); } on Object catch (_) { reportTransportError('Unable to send the editor barrier. Text is retained.'); }
    return pending.completion.future;
  }

  void reportTransportError(String error) {
    if (_disposed) return;
    _faulted = true;
    _settleOperation(error);
    for (final id in _pending.keys.toList()) { _failControl(id, error); }
    value = value._with(ready: false, error: error);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _settleOperation('Editor retired. Received source is retained.');
    for (final id in _pending.keys.toList()) { _failControl(id, 'Editor retired. Received source is retained.'); }
    _disposed = true;
    super.dispose();
  }

  bool _isOperationRequest(String? id) => id != null && _operation != null &&
    (id == _operation!.selectionRequest || id == _operation!.requestId);

  void _settleOperation([String? error]) {
    final operation = _operation;
    if (operation == null) return;
    _operation = null;
    operation.timer?.cancel();
    for (final id in [operation.selectionRequest, operation.requestId]) { if (id != null) _remember(id, null, null); }
    if (error == null) { operation.completion.complete(); }
    else { operation.completion.completeError(StateError(error)); }
  }

  void _receiveOperationSelection(Map<String, dynamic> message, String id) {
    _keys(message, {'mode', 'anchor', 'head'});
    _require(_canControl && _operation?.selectionRequest == id && message['mode'] == 'current', 'Unexpected source selection barrier.');
    final operation = _operation!, revision = message['revision'] as int;
    _require(revision == value.revision && revision >= operation.minimumRevision, 'Source selection no longer matches the received revision.');
    final selection = _selection(message, value.text);
    final from = min(selection.$1, selection.$2), to = max(selection.$1, selection.$2);
    if (operation.type == 'insert') {
      final text = operation.fields['text']! as String;
      _require(from != to || text.isNotEmpty, 'Insertion must change source.');
      _require(value.text.length + text.length - (to - from) <= maxSourceUnits &&
        _sourceBytes + _utf8Size(text) - _utf8Size(value.text, start: from, end: to) <= maxSourceBytes,
        'Insertion exceeds the document limit.');
      _require(to == value.text.length || value.text.codeUnitAt(to) != 10 ||
        (text.isNotEmpty ? text.codeUnitAt(text.length - 1) != 13 : from == 0 || value.text.codeUnitAt(from - 1) != 13),
        'Insertion would split a CRLF at its resulting cursor.');
      operation.noChange = to - from == text.length && value.text.substring(from, to) == text;
    }
    final request = _request(operation.type, {...operation.fields, 'anchor': selection.$1, 'head': selection.$2});
    _utf8Size(jsonEncode(request), limit: maxControlBytes);
    operation.requestId = request['requestId']! as String;
    operation.baseRevision = revision;
    operation.from = from;
    operation.to = to;
    _remember(id, null, null);
    value = value._with(anchor: selection.$1, head: selection.$2);
    if (!identical(_operation, operation)) return;
    try { operation.send(request); } on Object catch (_) { reportTransportError('Unable to send the source operation. Source is retained.'); }
  }

  void _failControl(String? id, String error) {
    if (_isOperationRequest(id)) { _settleOperation(error); return; }
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    _remember(id!, null, null);
    if (pending.kind == 'quiesce') value = value._with(closing: false);
    pending.completion.completeError(StateError(error));
  }

  void _receiveAcknowledgement(Map<String, dynamic> message, String id) {
    _keys(message, {'stage', 'throughRevision', 'error', 'changed'}, optional: {'error', 'changed'});
    _require(id.startsWith('host-'), 'Acknowledgements must answer a host request.');
    final stage = message['stage'], revision = message['revision'] as int;
    _require((stage == 'received' || stage == 'rejected') && _integer(message['throughRevision']) &&
      message['throughRevision'] == revision && revision <= value.revision, 'Invalid acknowledgement capture.');
    _require(!message.containsKey('error') || (message['error'] is String && (message['error'] as String).length <= 1024), 'Invalid acknowledgement error.');
    if (stage == 'rejected') {
      _require(message['error'] is String && (message['error'] as String).isNotEmpty, 'Missing rejection error.');
      _failControl(id, message['error'] as String);
      return;
    }
    if (_operation?.requestId == id) {
      final operation = _operation!;
      _require(message['changed'] is bool, 'Missing source-operation change outcome.');
      _require(message['changed'] == true
        ? operation.matchedRevision == revision && revision == operation.baseRevision! + 1
        : operation.matchedRevision == null && revision == operation.baseRevision && (operation.type == 'format' || operation.noChange),
        'Source receipt arrived without its matching edit or no-change result.');
      _settleOperation();
    } else { _require(!_pending.containsKey(id), 'Unexpected received acknowledgement.'); }
  }

  Map<String, Object?> _request(String type, Map<String, Object?> fields) {
    if (_hostSequence == maxRevision) throw StateError('Host request numbers exhausted; retain this session.');
    return {'v': 2, 'type': type, 'documentId': documentId, 'generation': generation,
      'revision': value.revision, 'requestId': 'host-${++_hostSequence}', ...fields};
  }

  Map<String, Object?>? receive(String wire) {
    if (_disposed) return null;
    Map<String, dynamic>? message;
    String? requestId;
    var rememberWire = false;
    try {
      final bytes = _utf8Size(wire, limit: maxEnvelopeBytes), decoded = jsonDecode(wire);
      _require(decoded is Map<String, dynamic>, 'Expected a JSON object.');
      message = decoded as Map<String, dynamic>;
      if (message['generation'] != generation || message['documentId'] != documentId) return null;
      _require(message['v'] is int && message['v'] == 2, 'Unsupported protocol version.');
      _require(message['type'] is String && _integer(message['revision']), 'Invalid message type or revision.');
      _require(message['requestId'] is String, 'Missing request ID.');
      final id = message['requestId'] as String;
      _require(id.length <= 32 && RegExp(r'^(host|editor)-[1-9][0-9]*$').hasMatch(id), 'Invalid request ID.');
      requestId = id;
      final type = message['type'] as String, revision = message['revision'] as int;
      _require(bytes <= (type == 'edit' ? maxEditBytes : type == 'resync' ? maxEnvelopeBytes : maxControlBytes), 'Message exceeds its encoded size limit.');
      _require(type != 'ack' || id.startsWith('host-'), 'Acknowledgements must answer a host request.');
      rememberWire = type != 'resync';
      if (value.closed) return null;
      if ((type == 'selection' || type == 'activity') && id.startsWith('editor-') && revision < value.revision) return null;
      if (type == 'activity' && _integer(message['sequence']) && (message['sequence'] as int) <= _activitySequence) return null;
      final replaying = type == 'edit' && _pending.values.any((entry) => entry.kind == 'resync');
      final completed = _completed[id];
      if (completed != null) {
        if (completed.wire == null) return null;
        _require(completed.wire == wire, 'Request ID reused with changed payload.');
        if (!(replaying && completed.response?['stage'] == 'rejected' && message['baseRevision'] == value.revision)) return completed.response;
      }
      if (id.startsWith('editor-')) {
        final sequence = int.tryParse(id.substring(7));
        _require(sequence != null && sequence <= maxRevision && (sequence > _lastEditorSequence ||
          replaying && sequence >= max(1, _lastEditorSequence - 64) && message['baseRevision'] == value.revision),
          'Request is older than the replay window; both texts are retained.');
        _lastEditorSequence = max(_lastEditorSequence, sequence!);
      } else {
        final sequence = int.tryParse(id.substring(5));
        _require(sequence != null && sequence <= _hostSequence, 'Unknown host request.');
        _require(const {'ready', 'flush', 'resync', 'close', 'ack', 'selection'}.contains(type), 'Invalid host request reply.');
      }
      Map<String, Object?>? response;
      switch (type) {
        case 'ready':
          _keys(message, {'textLength'});
          _require(!_faulted && id == _loadRequest && !value.ready && revision == 0 && value.revision == 0 &&
            message['textLength'] is int && message['textLength'] == value.text.length, 'Unexpected ready response.');
          value = value._with(ready: true);
          response = _ack(id, 'received', at: revision);
        case 'edit':
          _require((!_faulted && value.ready || replaying) && !value.quiesced && id.startsWith('editor-'), 'Editor cannot accept this edit; source is retained.');
          _applyEdit(message, bytes);
          response = _ack(id, 'received', at: revision);
        case 'activity':
          _keys(message, {'sequence', 'pending', 'composing'});
          _require(id.startsWith('editor-') && revision == value.revision && _integer(message['sequence']) &&
            message['pending'] is bool && message['composing'] is bool, 'Invalid editor activity.');
          _activitySequence = message['sequence'] as int;
          value = value._with(pending: message['pending'] as bool, composing: message['composing'] as bool);
        case 'selection':
          if (id.startsWith('host-')) {
            if (!_isOperationRequest(id)) return null;
            _receiveOperationSelection(message, id);
            break;
          }
          _keys(message, {'anchor', 'head'});
          _require(value.ready && !_faulted && revision == value.revision, 'Invalid selection revision.');
          final selection = _selection(message, value.text);
          value = value._with(anchor: selection.$1, head: selection.$2);
        case 'flush':
        case 'close':
          final pending = _pending[id];
          if (pending == null && id.startsWith('host-')) return null;
          _require(pending != null, 'Unrequested editor barrier.');
          final kind = pending!.kind;
          final captures = kind == 'flush' || kind == 'quiesce';
          _keys(message, captures ? {'mode', 'anchor', 'head'} : {'mode'});
          final expected = switch (kind) { 'flush' => 'ready', 'quiesce' => 'quiesced', 'complete' => 'closed', 'abort' => 'aborted', _ => '' };
          _require(message['mode'] == expected && revision == value.revision && revision >= pending.minimumRevision,
            'Editor barrier does not match the received prefix.');
          if (kind == 'complete') _require(value.quiesced && revision == pending.minimumRevision, 'Close capture changed.');
          EditorSnapshot? captured;
          if (captures) {
            final selection = _selection(message, value.text);
            captured = EditorSnapshot(value.text, revision, documentId: documentId,
              generation: generation, anchor: selection.$1, head: selection.$2);
            value = value._with(anchor: selection.$1, head: selection.$2, pending: false, composing: false,
              quiesced: kind == 'quiesce' ? true : null, snapshotRevision: revision);
          } else if (kind == 'complete') { value = value._with(ready: false, closed: true); }
          else if (kind == 'abort') { value = value._with(closing: false, quiesced: false); }
          _pending.remove(id);
          pending.timer?.cancel();
          pending.completion.complete(captured);
        case 'resync':
          if (_pending[id]?.kind == 'resume') {
            _keys(message, {'mode'});
            _require(message['mode'] == 'resumed' && revision == value.revision &&
              value.resyncCandidate?.revision == revision && value.resyncCandidate?.text == value.text, 'Resync resume capture changed.');
            final resume = _pending.remove(id)!;
            resume.timer?.cancel();
            _faulted = false;
            value = value._with(ready: true, pending: false, composing: false, clearError: true, clearCandidate: true);
            resume.completion.complete();
            break;
          }
          _keys(message, {'mode', 'text', 'anchor', 'head'});
          final pending = _pending[id];
          _require(pending?.kind == 'resync' && message['mode'] == 'candidate' && message['text'] is String,
            'Unrequested resync candidate.');
          final text = message['text'] as String;
          _sourceSize(text);
          final selection = _selection(message, text);
          final candidate = EditorResyncCandidate(text, revision, documentId: documentId, generation: generation,
            anchor: selection.$1, head: selection.$2);
          // A divergent live view is evidence, never authority to overwrite the mirror.
          value = value._with(resyncCandidate: candidate);
          _pending.remove(id);
          pending!.timer?.cancel();
          pending.completion.complete(candidate);
          response = _ack(id, 'received', at: revision);
        case 'ack':
          _receiveAcknowledgement(message, id);
        default: throw const FormatException('Unknown editor message type.');
      }
      _remember(id, type == 'resync' || type == 'ack' || id.startsWith('host-') && type != 'ready' ? null : wire, response);
      return response;
    } on FormatException catch (error) {
      final id = requestId ?? (message?['requestId'] is String ? message!['requestId'] as String : null);
      if (_isOperationRequest(id) || message?['type'] == 'ack' || _pending.containsKey(id)) {
        _failControl(id, error.message);
        return null;
      }
      if (message?['type'] == 'edit' && _pending.values.any((entry) => entry.kind == 'resync')) {
        value = value._with(error: error.message);
      } else { reportTransportError(error.message); }
      if (requestId == null || message?['type'] == 'ack') return null;
      final response = _ack(requestId, 'rejected', error: error.message);
      if (rememberWire && !_completed.containsKey(requestId)) _remember(requestId, wire, response);
      return response;
    } on Object catch (_) {
      reportTransportError('Draft admission failed. Received source is retained; preserve the live editor too.');
      return requestId == null ? null : _ack(requestId, 'rejected', error: 'Draft admission failed; source is retained.');
    }
  }

  void _applyEdit(Map<String, dynamic> message, int wireBytes) {
    _keys(message, {'baseRevision', 'changes', 'selection', 'operationId'}, optional: {'operationId'});
    _require(!message.containsKey('operationId') || (message['operationId'] is String &&
      RegExp(r'^host-[1-9][0-9]{0,15}$').hasMatch(message['operationId'] as String)), 'Invalid source-operation identity.');
    _require(_undurable.length < 32 && _undurableBytes + wireBytes <= 8 * 1024 * 1024,
      'Durable draft credit exhausted; source is retained.');
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
    final batch = EditorEditBatch._(documentId, generation, message['requestId'] as String,
      value.revision, message['revision'] as int,
      List<EditorChange>.unmodifiable(changes.map((item) => EditorChange(
        item['from'] as int, item['to'] as int, item['insert'] as String))),
      positions.$1, positions.$2, wireBytes, message['operationId'] as String?);
    // Admission must retain these exact immutable deltas before receipt; no snapshot copy.
    onEdit?.call(batch);
    final operation = _operation;
    if (operation != null && operation.requestId != null &&
        batch.operationId == operation.requestId && operation.baseRevision == value.revision) {
      var matches = true;
      if (operation.type == 'insert') {
        final text = operation.fields['text']! as String;
        matches = changes.length == 1 && changes.single['from'] == operation.from &&
          changes.single['to'] == operation.to && changes.single['insert'] == text &&
          positions.$1 == operation.from! + text.length && positions.$2 == positions.$1;
      }
      if (matches) operation.matchedRevision = batch.revision;
    }
    _undurable[batch.revision] = wireBytes;
    _undurableBytes += wireBytes;
    _sourceBytes = bytes;

    value = value._with(
      text: next,
      revision: message['revision'] as int,
      anchor: positions.$1,
      head: positions.$2,
    );
  }

  Map<String, Object?> _ack(String requestId, String stage, {String? error, int? at}) =>
      {
        'v': 2,
        'type': 'ack',
        'documentId': documentId,
        'generation': generation,
        'revision': at ?? value.revision,
        'requestId': requestId,
        'stage': stage,
        'throughRevision': at ?? value.revision,
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

class _PendingSourceOperation {
  _PendingSourceOperation(this.send, this.type, this.fields, this.selectionRequest, this.minimumRevision);
  final EditorSend send;
  final String type;
  final Map<String, Object?> fields;
  final String selectionRequest;
  final int minimumRevision;
  final completion = Completer<void>();
  Timer? timer;
  String? requestId;
  int? baseRevision;
  int? from;
  int? to;
  int? matchedRevision;
  bool noChange = false;
}

class _PendingControl {
  _PendingControl(this.kind, this.minimumRevision);
  final String kind;
  final int minimumRevision;
  final completion = Completer<Object?>();
  Timer? timer;
}

class _CompletedRequest {
  const _CompletedRequest(this.wire, this.response);

  // Exact bounded wire fingerprints avoid accepting hash collisions as replays.
  final String? wire;
  final Map<String, Object?>? response;
}

@immutable
class EditorCapture {
  const EditorCapture(this.documentId, this.generation, this.revision);
  final String documentId;
  final String generation;
  final int revision;
}

@immutable
class EditorSnapshot extends EditorCapture {
  const EditorSnapshot(this.text, int revision, {required String documentId,
    required String generation, required this.anchor, required this.head})
    : super(documentId, generation, revision);
  final String text;
  final int anchor;
  final int head;
}

@immutable
class EditorResyncCandidate extends EditorSnapshot {
  const EditorResyncCandidate(super.text, super.revision, {required super.documentId,
    required super.generation, required super.anchor, required super.head});
}

@immutable
class EditorChange {
  const EditorChange(this.from, this.to, this.insert);
  final int from;
  final int to;
  final String insert;
  Map<String, Object?> toJson() => {'from': from, 'to': to, 'insert': insert};
}

@immutable
class EditorEditBatch extends EditorCapture {
  const EditorEditBatch._(String documentId, String generation, this.requestId,
    this.baseRevision, int revision, this.changes, this.anchor, this.head, this.wireBytes, this.operationId)
    : super(documentId, generation, revision);
  final String requestId;
  final int baseRevision;
  final List<EditorChange> changes;
  final int anchor;
  final int head;
  final int wireBytes;
  final String? operationId;
  Map<String, Object?> toJson() => {'token': generation, 'baseRevision': baseRevision,
    'revision': revision, 'requestId': requestId, 'changes': changes.map((change) => change.toJson()).toList(growable: false),
    'selection': {'anchor': anchor, 'head': head}};
}

@immutable
class EditorFormat {
  const EditorFormat(this.action, {this.level, this.destination});
  final String action;
  final int? level;
  final String? destination;
  void validate() {
    EditorSession._require(const {'bold', 'italic', 'code', 'fence', 'heading', 'quote', 'bullet', 'ordered', 'task', 'link'}.contains(action),
      'Unknown formatting action.');
    EditorSession._require(action == 'heading' ? level != null && level! >= 1 && level! <= 6 : level == null, 'Invalid heading level.');
    EditorSession._require(action == 'link' ? destination != null && destination!.isNotEmpty && destination!.length <= 2048 &&
      !RegExp(r'[\x00-\x20\x7f<>]').hasMatch(destination!) : destination == null, 'Invalid explicit link destination.');
  }
  Map<String, Object?> toJson() => {'action': action, 'level': ?level, 'destination': ?destination};
}

typedef EditorSend = void Function(Map<String, Object?> message);
