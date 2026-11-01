// SPDX-License-Identifier: LGPL-3.0-only
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
/// their responses are retained for only the last 64 requests; evicted editor
/// request numbers cannot be applied again. Nothing writes a notebook or draft.
class EditorSession extends ValueNotifier<EditorSessionState> {
  EditorSession({
    String initialText = diagnosticText,
    String Function()? generationFactory,
  }) : generation = (generationFactory ?? _randomGeneration)(),
       super(EditorSessionState(text: initialText)) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(generation)) {
      throw ArgumentError('A generation must be 128 bits of lowercase hex.');
    }
    _sourceBytes = _sourceSize(initialText);
  }

  static const documentId = 'diagnostic:editor';
  static const maxSourceUnits = 4 * 1024 * 1024;
  static const maxSourceBytes = 4 * 1024 * 1024;
  static const maxEnvelopeBytes = 32 * 1024 * 1024;
  static const maxEditBytes = 512 * 1024;
  static const maxControlBytes = 8 * 1024;
  static const maxChanges = 256;
  static const maxInsertedUnits = 65536;
  static const maxRevision = 9007199254740991;
  static const diagnosticText = '''# Editor validation

This document exists only in memory. It is not saved, synced, or connected to a notebook.

Try typing Markdown, selecting text, Undo / Redo, and changing the theme.

- Exact source text stays in the editor and the volatile host mirror.
- Check snapshot compares the two at a diagnostic boundary; it does not save.
- Closing or terminating the app loses this text.

Unicode: 中文 · 日本語 · العربية · é · 🌍
''';

  final String generation;
  final _completed = <String, _CompletedRequest>{};
  final _pending = <String, String>{};
  int _hostSequence = 0;
  int _lastEditorSequence = 0;
  int _sourceBytes = 0;
  String? _loadRequest;
  bool _faulted = false;
  bool _snapshotRequested = false;
  int? _snapshotTarget;

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
      'baseVersion': 'volatile',
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

  /// A single optional full-text diagnostic transfer, never a save operation.
  Map<String, Object?>? requestSnapshot() {
    if (!_canControl || _snapshotRequested) return null;
    _snapshotRequested = true;
    _snapshotTarget = value.revision;
    final message = _request('save', {
      'mode': 'snapshotRequest',
      'reason': 'manual',
    });
    _pending[message['requestId']! as String] = 'snapshot';
    return message;
  }

  bool get canRequestSnapshot => _canControl && !_snapshotRequested;
  bool get _canControl => value.ready && !value.closing && !_faulted;

  /// The UI must obtain explicit discard consent before calling this method.
  /// It must retain the view until close-ready, or obtain separate force-discard
  /// consent if composition/transport prevents that barrier from completing.
  Map<String, Object?>? closeAfterDiscardConsent() {
    if (value.closed || value.closing || _loadRequest == null) return null;
    final message = _request('close', {
      'mode': 'request',
      'disposition': 'discard',
    });
    _pending[message['requestId']! as String] = 'close';
    value = value._with(closing: true);
    return message;
  }

  void reportTransportError(String error) {
    _faulted = true;
    value = value._with(ready: false, error: error);
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
      // Only the single validated snapshot may occupy a full-transfer cache
      // slot; oversized or unsolicited payloads cannot inflate replay memory.
      rememberWire = type != 'save' || bytes <= maxControlBytes;
      if (value.closed) return null;
      // Stale selection is intentionally dropped, even outside the replay window.
      if (type == 'selection' && revision < value.revision) return null;
      final completed = _completed[requestId];
      if (completed != null) {
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
          type == 'ready' || type == 'save' || type == 'close' || type == 'ack',
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
              const {
                'manual',
                'autosave',
                'close',
                'resync',
              }.contains(message['reason']),
              'Invalid snapshot/save reason.',
            );
          }
          if (message['mode'] == 'request') {
            _keys(message, {'mode', 'reason'});
            _require(
              bytes <= maxControlBytes,
              'Control message exceeds its encoded size limit.',
            );
            _require(
              revision == value.revision,
              'Save request revision mismatch.',
            );
            throw const FormatException(
              'Persistence is unavailable. This editor is memory only; nothing was saved.',
            );
          }
          _keys(message, {'mode', 'text', 'reason'}, optional: {'reason'});
          _require(
            message['mode'] == 'snapshot' && _pending[requestId] == 'snapshot',
            'Unrequested snapshot.',
          );
          _require(
            revision == _snapshotTarget && revision == value.revision,
            'Snapshot revision mismatch; both texts are retained.',
          );
          _require(
            message['text'] is String,
            'Snapshot text must be a string.',
          );
          _sourceSize(message['text'] as String);
          _require(
            message['text'] == value.text,
            'Snapshot differs from the volatile mirror; both texts are retained.',
          );
          _pending.remove(requestId);
          value = value._with(snapshotRevision: revision);
          rememberWire = true;
          response = _ack(requestId, 'received');
        case 'close':
          _keys(message, {'mode', 'disposition'});
          _require(
            message['mode'] == 'ready' && message['disposition'] == 'discard',
            'Invalid close response.',
          );
          _require(
            _pending[requestId] == 'close' && value.closing,
            'Close requires explicit discard consent.',
          );
          _require(
            revision == value.revision,
            'Close revision mismatch; view retained.',
          );
          _pending.remove(requestId);
          value = value._with(ready: false, closed: true);
        case 'ack':
          _keys(message, {'stage', 'throughRevision', 'error'});
          _require(
            requestId.startsWith('host-'),
            'Rejections must answer a host request.',
          );
          _require(
            message['stage'] == 'rejected',
            'Only rejected editor acknowledgements are supported.',
          );
          _require(
            _integer(message['throughRevision']) &&
                message['throughRevision'] == revision,
            'Invalid rejection revision.',
          );
          _require(
            message['error'] is String &&
                (message['error'] as String).isNotEmpty,
            'Missing rejection error.',
          );
          _pending.remove(requestId);
          reportTransportError(
            'Editor rejected a request: ${message['error']}',
          );
        default:
          throw const FormatException('Unknown editor message type.');
      }
      _remember(requestId, wire, response);
      return response;
    } on FormatException catch (error) {
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
    String wire,
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

class _CompletedRequest {
  const _CompletedRequest(this.wire, this.response);

  // Exact bounded wire fingerprints avoid accepting hash collisions as replays.
  final String wire;
  final Map<String, Object?>? response;
}
