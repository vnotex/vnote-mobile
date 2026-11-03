// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'editor_session.dart';
import 'transfer_worker.dart';

typedef DraftStoreRunner = Future<Map<String, Object?>> Function(
  Map<String, Object?> request, {Uint8List? payload});
typedef DraftReconciler = Future<CoreDraftInspection> Function(DraftRecoveryEntry);

@immutable
class DraftRecoveryEntry {
  DraftRecoveryEntry(Map<String, Object?> record)
    : record = Map.unmodifiable(record);
  final Map<String, Object?> record;
  String get documentKey => record['documentKey'] as String;
  String get token => record['token'] as String;
  int get revision => record['revision'] as int? ?? 0;
  Map<String, Object?>? get descriptor => record['descriptor'] is Map
      ? Map<String, Object?>.from(record['descriptor'] as Map) : null;
  String? get notebookId => descriptor?['notebookId'] as String?;
  String? get nodeId => descriptor?['nodeId'] as String?;
  String? get notebookRelative => descriptor?['notebookRelative'] as String?;
  String get label => descriptor?['pathHint'] as String? ?? 'Quarantined private draft';
  bool get quarantined => record['status'] == 'quarantined';
  bool get resolved => record['status'] == 'superseded' ||
      (record['outcome'] != 'conflict' && record['recoveryError'] == null &&
       record['status'] == 'saved' && record['savedRevision'] == revision &&
       record['candidateId'] == null);
}

@immutable
class DraftRecoveryInspection {
  const DraftRecoveryInspection({required this.entry, required this.outcome,
    this.source, this.baseSource, this.diskHash, this.savedRevision,
    this.error, this.canRetry = false});
  final DraftRecoveryEntry entry;
  final String outcome;
  final String? source;
  final String? baseSource;
  final String? diskHash;
  final int? savedRevision;
  final bool canRetry;
  final String? error;
  bool get canRestore => source != null &&
      (outcome == 'base' || outcome == 'saved') && !entry.quarantined;
}

@immutable
class EditorDraftsState {
  const EditorDraftsState({this.entries = const [], this.initialized = false,
    this.busy = false, this.error});
  final List<DraftRecoveryEntry> entries;
  final bool initialized;
  final bool busy;
  final String? error;
}

/// One capture retains immutable deltas, never a new whole-source copy per key.
/// The opening source remains the exact CoreNote representation, including EOL.
class EditorDraftCapture {
  EditorDraftCapture._({required this.editor, required this.note,
    required this.documentKey, required this.notebookRelative,
    this.begun = false, this.summary})
      : _durableText = editor.value.text;
  final EditorSession editor;
  final CoreNote note;
  final String documentKey;
  final String notebookRelative;
  final List<EditorEditBatch> _pending = [];
  int _pendingBytes = 0;
  int durableRevision = 0;
  String _durableText;
  bool begun;
  bool retired = false;
  Map<String, Object?>? summary;
  Timer? _timer;
  Future<void>? _flushing;
  Future<void> _storeTail = Future.value();
  Map<String, Object?>? _preparation;
  Object? error;
  String get token => editor.generation;
  EditorCapture capture(int revision) =>
      EditorCapture(editor.documentId, token, revision);
  Map<String, Object?> get descriptor => {
    'notebookRelative': notebookRelative, 'notebookId': note.notebookId,
    'nodeId': note.nodeId, 'pathHint': note.path,
    'editorType': note.editorType.name, 'openingDiskHash': note.baseHash,
    'eol': note.lineEnding,
  };
}

/// App scheduling only: native storage owns fsync, replay, quota and retention.
/// Failed flushes retain the accepted deltas and never advance durable credits.
class EditorDrafts extends ValueNotifier<EditorDraftsState> {
  EditorDrafts({required this.root, DraftStoreRunner? runStore})
    : _run = runStore ?? _native, super(const EditorDraftsState());
  final String root;
  final DraftStoreRunner _run;
  final Set<EditorDraftCapture> _captures = {};
  final Set<Future<void>> _workers = {};
  final Map<String, Map<String, Object?>> _outcomes = {};
  bool _closed = false;
  bool _disposed = false;
  Future<void>? _shutdown;

  static Future<Map<String, Object?>> _native(Map<String, Object?> request,
      {Uint8List? payload}) => runDraftStore(request, payload: payload);
  static String documentKey(String notebookId, String nodeId) =>
      crypto.sha256.convert(utf8.encode('$notebookId\u0000$nodeId')).toString();

  Future<Map<String, Object?>> _store(String op, {
    EditorDraftCapture? capture, DraftRecoveryEntry? entry,
    Map<String, Object?> arguments = const {}, Uint8List? payload,
  }) {
    if (_closed) throw StateError('Private draft storage is closed.');
    final request = {'op': op, 'draftsRoot': root,
      if (capture != null) ...{'documentKey': capture.documentKey, 'token': capture.token},
      if (entry != null) ...{'documentKey': entry.documentKey, 'token': entry.token},
      ...arguments};
    final job = capture == null ? _run(request, payload: payload)
      : capture._storeTail.then((_) => _run(request, payload: payload));
    if (capture != null) {
      capture._storeTail = job.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    }
    late final Future<void> joined;
    joined = job.then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _workers.remove(joined));
    _workers.add(joined);
    return job;
  }

  void _publish({List<DraftRecoveryEntry>? entries, bool? initialized,
      bool? busy, String? error}) {
    if (_disposed) return;
    value = EditorDraftsState(entries: entries ?? value.entries,
      initialized: initialized ?? value.initialized,
      busy: busy ?? value.busy, error: error);
  }

  Future<void> initialize({required DraftReconciler reconcile}) async {
    _publish(busy: true);
    try {
      _outcomes.clear();
      await scan();
      for (final entry in value.entries) {
        // Fully saved receipts are retained history, not an outstanding draft.
        // Rechecking an older capture against a later saved epoch invents conflict.
        if (entry.resolved || entry.quarantined || entry.descriptor == null) continue;
        try {
          final result = await reconcile(entry);
          _outcomes['${entry.documentKey}:${entry.token}'] = {
            'outcome': result.outcome,
          };
        } on Object catch (error) {
          _outcomes['${entry.documentKey}:${entry.token}'] = {
            'recoveryError': transferError(error),
          };
        }
      }
      await _store('prune');
      await scan();
      _publish(initialized: true, error: _outcomes.values.any((item) => item['recoveryError'] != null)
        ? 'Some private drafts could not establish a durable disk receipt. Inspect or export them; affected documents remain blocked.' : null);
    } on Object catch (error) {
      _publish(initialized: false, error: transferError(error));
      rethrow;
    } finally {
      _publish(busy: false, error: value.error);
    }
  }

  Future<void> scan() async {
    final entries = <DraftRecoveryEntry>[];
    int? offset = 0;
    do {
      final page = await _store('scan', arguments: {'offset': offset});
      entries.addAll((page['entries'] as List).map((raw) {
        final record = Map<String, Object?>.from(raw as Map);
        return DraftRecoveryEntry({...record,
          ...?_outcomes['${record['documentKey']}:${record['token']}']});
      }));
      final next = page['nextOffset'] as int?;
      if (entries.length > 10000 || (next != null && next <= offset!)) {
        throw StateError('Private draft enumeration exceeded its bound.');
      }
      offset = next;
    } while (offset != null);
    _publish(entries: List.unmodifiable(entries));
  }

  bool blocksDocument(String notebookId, String nodeId) {
    final key = documentKey(notebookId, nodeId);
    return !value.initialized || value.entries.any((entry) =>
      entry.documentKey == key && !entry.resolved);
  }

  EditorDraftCapture attach(EditorSession editor, CoreNote note,
      String notebookRelative, {Map<String, Object?>? restored}) {
    if (_closed) throw StateError('Private draft storage is closed.');
    final capture = EditorDraftCapture._(editor: editor, note: note,
      documentKey: documentKey(note.notebookId, note.nodeId),
      notebookRelative: notebookRelative, begun: restored != null,
      summary: restored);
    if (restored != null && (restored['token'] != editor.generation ||
        restored['documentKey'] != capture.documentKey || restored['revision'] != 0)) {
      throw StateError('Restored checkpoint belongs to a different capture.');
    }
    _captures.add(capture);
    return capture;
  }

  void accept(EditorDraftCapture capture, EditorEditBatch batch,
      {required void Function(EditorCapture) durable,
       required void Function(Object) failed}) {
    if (capture.retired || _closed || batch.generation != capture.token ||
        batch.documentId != capture.editor.documentId) {
      throw StateError('The draft capture has retired.');
    }
    final previous = capture._pending.isEmpty ? capture.durableRevision
        : capture._pending.last.revision;
    if (batch.baseRevision != previous || capture._pending.length >= 32 ||
        capture._pendingBytes + batch.wireBytes > 8 * 1024 * 1024) {
      throw StateError('Private draft credits are exhausted; source is retained.');
    }
    capture._pending.add(batch);
    capture._pendingBytes += batch.wireBytes;
    void flush() {
      scheduleMicrotask(() => unawaited(flushCapture(capture).then((_) {
        durable(capture.capture(capture.durableRevision));
      }, onError: (Object error, StackTrace _) { failed(error); })));
    }
    capture._timer ??= Timer(const Duration(milliseconds: 250), flush);
    if (capture._pendingBytes >= 64 * 1024) {
      capture._timer?.cancel();
      capture._timer = null;
      flush();
    }
  }

  Future<void> flushCapture(EditorDraftCapture capture, {bool ensure = false}) async {
    capture._timer?.cancel();
    capture._timer = null;
    final active = capture._flushing;
    if (active != null) {
      await active;
      return flushCapture(capture, ensure: ensure);
    }
    if (capture._pending.isEmpty && (!ensure || capture.begun)) return;
    final job = _flush(capture, ensure: ensure);
    capture._flushing = job;
    try { await job; } finally {
      if (identical(capture._flushing, job)) capture._flushing = null;
    }
  }

  Future<void> _flush(EditorDraftCapture capture, {required bool ensure}) async {
    try {
      if (!capture.begun && (ensure || capture._pending.isNotEmpty)) {
        capture.summary = await _store('begin', capture: capture,
          arguments: {'descriptor': capture.descriptor},
          payload: utf8.encode(capture.note.text));
        _check(capture, capture.summary!, 0);
        capture.begun = true;
      }
      if (capture.error != null) await _recoverAppend(capture);
      while (capture._pending.isNotEmpty) {
        final batches = List<EditorEditBatch>.of(capture._pending);
        final through = batches.last.revision;
        // A String reference, not a copied/encoded whole-document snapshot.
        final throughSource = capture.editor.value.text;
        final frames = batches.map((batch) => {
          'token': batch.generation, 'baseRevision': batch.baseRevision,
          'revision': batch.revision, 'requestId': batch.requestId,
          'changes': batch.changes.map((change) => change.toJson()).toList(),
          'selection': {'anchor': batch.anchor, 'head': batch.head},
        }).toList();
        final result = await _store('append', capture: capture,
          arguments: {'expectedRevision': capture.durableRevision},
          payload: utf8.encode(jsonEncode({'frames': frames})));
        _check(capture, result, through);
        capture.summary = result;
        capture.durableRevision = through;
        capture._durableText = throughSource;
        capture._pending.removeRange(0, batches.length);
        capture._pendingBytes -= batches.fold(0, (sum, batch) => sum + batch.wireBytes);
      }
      capture.error = null;
    } on Object catch (error) {
      capture.error = error;
      rethrow;
    }
  }

  Future<void> _recoverAppend(EditorDraftCapture capture) async {
    final actual = await _store('inspect', capture: capture);
    final revision = actual['revision'];
    if (revision is! int || revision < capture.durableRevision ||
        revision > (capture._pending.lastOrNull?.revision ?? capture.durableRevision)) {
      throw StateError('The retained journal does not match the received chain.');
    }
    _check(capture, actual, revision);
    if (revision == capture.durableRevision) return;
    final committed = capture._pending.where((batch) => batch.revision <= revision).toList();
    var expected = capture._durableText;
    // Replay is only on a failed-reply recovery path. UTF16 offsets apply to
    // the original source representation, never EOL-normalized disk bytes.
    for (final batch in committed) {
      final output = StringBuffer();
      var offset = 0;
      for (final change in batch.changes) {
        output.write(expected.substring(offset, change.from));
        output.write(change.insert);
        offset = change.to;
      }
      output.write(expected.substring(offset));
      expected = output.toString();
    }
    final source = await _store('read', capture: capture);
    if (source['revision'] != revision || source['source'] != expected) {
      throw StateError('The acknowledged journal and received source conflict.');
    }
    capture.summary = actual;
    capture.durableRevision = revision;
    capture._durableText = expected;
    capture._pending.removeRange(0, committed.length);
    capture._pendingBytes -= committed.fold(0, (sum, batch) => sum + batch.wireBytes);
  }

  void _check(EditorDraftCapture capture, Map<String, Object?> result, int revision) {
    if (result['documentKey'] != capture.documentKey ||
        result['token'] != capture.token || result['revision'] != revision) {
      throw StateError('Private storage returned a mismatched durable receipt.');
    }
  }

  Future<Map<String, Object?>> prepareSave(EditorDraftCapture capture) async {
    await flushCapture(capture, ensure: true);
    if (capture._preparation != null) {
      final actual = await _store('inspect', capture: capture);
      _check(capture, actual, capture.durableRevision);
      // No core write is dispatched without a returned candidate. If no intent
      // committed, a fresh admission can capture the newest durable head. An
      // existing intent instead keeps its original exact request and revision.
      if (actual['candidateId'] == null) capture._preparation = null;
    }
    final preparation = capture._preparation ??= {
      'revision': capture.durableRevision, 'requestId': newTransferId()};
    final result = await _store('prepareSave', capture: capture, arguments: preparation);
    _check(capture, result, preparation['revision'] as int);
    if (!validTransferId(result['candidateId'])) {
      throw StateError('Private save candidate is invalid.');
    }
    capture._preparation = null;
    return result;
  }

  Future<DraftRecoveryInspection> inspect(DraftRecoveryEntry entry,
      DraftReconciler reconcile) async {
    if (entry.quarantined) {
      return DraftRecoveryInspection(entry: entry,
        outcome: 'quarantined', error: 'Acknowledged journal data is invalid. Export its raw archive; no text was fabricated.');
    }
    Map<String, Object?>? source;
    Map<String, Object?>? base;
    try {
      source = await _store('read', entry: entry);
      base = await _store('readBase', entry: entry);
      final receipt = (await reconcile(entry)).record;
      return DraftRecoveryInspection(entry: DraftRecoveryEntry(receipt),
        outcome: receipt['outcome'] as String,
        source: source['source'] as String, baseSource: base['baseSource'] as String,
        diskHash: receipt['observedDiskHash'] as String?,
        savedRevision: receipt['savedRevision'] as int?,
        canRetry: receipt['canRetry'] == true);
    } on Object catch (error) {
      return DraftRecoveryInspection(entry: entry, outcome: 'unavailable',
        source: source?['source'] as String?, baseSource: base?['baseSource'] as String?,
        error: transferError(error));
    }
  }

  Future<Map<String, Object?>> rebase(DraftRecoveryEntry entry, String newToken,
      {String? chosenSource}) => _store(chosenSource == null ? 'rebase' : 'rebaseSource',
        entry: entry, arguments: {'newToken': newToken},
        payload: chosenSource == null ? null : utf8.encode(chosenSource));

  Future<Map<String, Object?>> readSource(DraftRecoveryEntry entry) =>
      _store('read', entry: entry);

  Future<Map<String, Object?>> prepareExport(DraftRecoveryEntry entry,
      {required bool raw}) => _store('prepareExport', entry: entry,
        arguments: {'revision': entry.revision, 'format': raw ? 'raw-archive' : 'text'});

  Future<CoreResourceExport> export(DraftRecoveryEntry entry,
      Map<String, Object?> binding, String resourceRoot) async {
    final result = await _store('export', entry: entry,
      arguments: {'resourceRoot': resourceRoot, 'binding': binding});
    return CoreResourceExport(name: result['name'] as String,
      path: result['path'] as String, bytes: result['bytes'] as int,
      sha256: result['sha256'] as String);
  }

  Future<void> discard(DraftRecoveryEntry entry) async {
    await _store('discard', entry: entry);
    await scan();
  }

  Future<void> detach(EditorDraftCapture capture, {bool discard = false}) async {
    capture._timer?.cancel();
    await flushCapture(capture);
    if (discard && capture.begun) {
      await _store('discard', capture: capture);
    }
    capture.retired = true;
    _captures.remove(capture);
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    Object? failure;
    for (final capture in _captures.toList()) {
      capture._timer?.cancel();
      try { await flushCapture(capture); } on Object catch (error) { failure ??= error; }
    }
    while (_workers.isNotEmpty) { await Future.wait(_workers.toList()); }
    _closed = true;
    if (failure != null) throw failure;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final capture in _captures) { capture._timer?.cancel(); }
    super.dispose();
  }
}
