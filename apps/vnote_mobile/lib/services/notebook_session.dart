// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'editor_drafts.dart';
import 'editor_session.dart';
import 'transfer_worker.dart';

enum NotebookDisposition { write, retain, discard, cancel }

@immutable
class NotebookSessionState {
  const NotebookSessionState({this.editor, this.note, this.onDiskRevision = 0,
    this.draftRevision = 0, this.savedToken, this.inFlightRevision,
    this.pendingRevision, this.loading = false,
    this.writing = false, this.transitioning = false, this.resourcesBusy = false,
    this.closed = false, this.recoveryRequired = false, this.durabilityError,
    this.error});
  final EditorSession? editor;
  final CoreNote? note;
  final int? onDiskRevision;
  final int draftRevision;
  final String? savedToken;
  final int? inFlightRevision;
  final int? pendingRevision;
  int get receivedRevision => editor?.value.revision ?? 0;
  final bool loading;
  final bool writing;
  final bool transitioning;
  final bool resourcesBusy;
  final bool closed;
  final bool recoveryRequired;
  final String? durabilityError;
  final String? error;
  bool get dirty => editor != null && (recoveryRequired || durabilityError != null ||
    error != null || editor!.value.error != null ||
    editor!.value.pending || editor!.value.composing ||
    editor!.value.resyncCandidate != null || savedToken != editor!.generation ||
    editor!.value.revision != onDiskRevision);
  bool get busy => loading || writing || transitioning || resourcesBusy;
}

class _SaveTarget {
  _SaveTarget(this.editor, this.send, this.explicit)
    : requestedRevision = editor.value.revision;
  final EditorSession editor;
  final EditorSend send;
  final bool explicit;
  final int requestedRevision;
  final completion = Completer<bool>();
}

/// Owns the sole NOTE owner. FS durability continues through resource barriers;
/// core writes have one pinned in-flight candidate and one newest pending target.
class NotebookSession extends ValueNotifier<NotebookSessionState> {
  NotebookSession({required this._openCore,
    required this.drafts, required this.notebookRelative,
    this._restored}) : super(const NotebookSessionState());
  final Future<NotebookCore> Function() _openCore;
  final EditorDrafts drafts;
  final String notebookRelative;
  Map<String, Object?>? _restored;
  NotebookCore? _core;
  EditorDraftCapture? _capture;
  EditorSend? _send;
  Future<void>? _initialization;
  Future<void>? _shutdownFuture;
  Future<void>? _saving;
  _SaveTarget? _pending;
  Map<String, Object?>? _candidate;
  Completer<void>? _resources;
  Completer<void>? _transition;
  String? _resourceBlock;
  Timer? _idle;
  Timer? _ceiling;
  int _observedRevision = 0;
  bool _foreground = true;
  bool _disposed = false;
  bool _stopping = false;

  String get nativeNotices => _core?.nativeNotices ?? '';

  void bindTransport(EditorSend send) { _send = send; _schedule(); }
  void unbindTransport(EditorSend send) {
    if (identical(_send, send)) { _send = null; _cancelTimers(); }
  }
  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) { _schedule(); } else {
      _cancelTimers();
      final capture = _capture;
      if (capture != null) {
        unawaited(_flush(capture).catchError((Object error) {
          _durabilityFailed(error);
        }));
      }
    }
  }
  void setResourceBlock(String? message) {
    _resourceBlock = message;
    _publish(error: message, clearError: message == null);
  }
  Future<void> initialize() => _stopping ? Future.value() :
      _initialization ??= _initialize();
  Future<void> _initialize() async {
    _publish(loading: true);
    try {
      _core = await _openCore();
      if (_stopping) return;
      final note = await _core!.read();
      if (_stopping) return;
      if (_restored == null && drafts.blocksDocument(note.notebookId, note.nodeId)) {
        throw StateError('A retained draft needs an explicit recovery decision. Return to Notebooks.');
      }
      if (_restored case final Map<String, Object?> restored) {
        // Selection/reopen can race an external writer after library inspection.
        // Re-run the same native matrix on the actual NOTE owner before load.
        final proof = (await _core!.reconcileDraft(draftsRoot: drafts.root,
          documentKey: restored['documentKey'] as String,
          token: restored['token'] as String)).record;
        if (proof['outcome'] == 'conflict') {
          throw StateError('Disk or source policy changed during recovery. Both disk and the private checkpoint are retained.');
        }
        final source = await drafts.readSource(DraftRecoveryEntry(proof));
        _install(note, source: source['source'] as String, restored: proof);
        _restored = null;
      } else {
        _install(note);
      }
    } on Object catch (error) { _publish(error: _error(error)); }
    finally { _publish(loading: false); }
  }
  Future<void> retryOpen() async {
    if (_stopping || value.busy || value.editor != null) return;
    await _core?.close();
    _core = null;
    await (_initialization = _initialize());
  }

  void _install(CoreNote note, {String? source, Map<String, Object?>? restored,
      int anchor = 0, int head = 0}) {
    final saved = restored == null || (restored['savedRevision'] == 0 &&
      restored['savedSourceHash'] == restored['sourceHash'] &&
      restored['outcome'] == 'saved');
    final editor = EditorSession(initialText: source ?? note.text,
      documentId: EditorDrafts.documentKey(note.notebookId, note.nodeId),
      baseVersion: note.baseHash, language: note.editorType.name,
      initiallySaved: saved,
      initialAnchor: anchor, initialHead: head,
      generationFactory: restored == null ? null : () => restored['token'] as String);
    final previous = value.editor;
    previous?.removeListener(_editorChanged);
    final capture = drafts.attach(editor, note, notebookRelative, restored: restored);
    _capture = capture;
    editor.onEdit = (batch) => drafts.accept(capture, batch,
      durable: _durable, failed: _durabilityFailed);
    editor.addListener(_editorChanged);
    _observedRevision = 0;
    _candidate = null;
    value = NotebookSessionState(editor: editor, note: note,
      onDiskRevision: saved ? 0 : null, savedToken: saved ? editor.generation : null);
    previous?.dispose();
    _schedule();
  }

  void _editorChanged() {
    final revision = value.editor?.value.revision;
    if (revision != _observedRevision) {
      _observedRevision = revision ?? 0;
      _idle?.cancel();
      _idle = null;
      _schedule();
    }
    _publish();
    _schedule();
  }
  void _cancelTimers() { _idle?.cancel(); _ceiling?.cancel(); _idle = null; _ceiling = null; }
  void _schedule() {
    if (_stopping || !_foreground || _send == null || !value.dirty ||
        value.editor?.value.ready != true || value.editor?.value.error != null ||
        value.error != null || value.recoveryRequired || value.durabilityError != null ||
        value.transitioning) {
      return;
    }
    void save() {
      _cancelTimers();
      final send = _send;
      if (send != null && !_stopping && _foreground) {
        unawaited(_enqueue(send, explicit: false));
      }
    }
    _idle ??= Timer(const Duration(milliseconds: 750), save);
    _ceiling ??= Timer(const Duration(seconds: 5), save);
  }
  void _durabilityFailed(Object error) => _publish(durabilityError: _error(error));
  void _durable(EditorCapture capture) {
    final editor = value.editor;
    if (editor == null || editor.generation != capture.generation) return;
    final message = editor.acknowledgeDraftDurable(capture);
    _publish(draftRevision: capture.revision, clearDurabilityError: true);
    if (message != null) _sendControl(message);
  }
  void _sendControl(Map<String, Object?> message) {
    final send = _send;
    if (send == null) return;
    unawaited(Future<void>.sync(() => send(message)).catchError((Object error) {
      value.editor?.reportTransportError('Editor transport failed; acknowledged private source is retained.');
    }));
  }
  Future<void> _flush(EditorDraftCapture capture, {bool ensure = false}) async {
    await drafts.flushCapture(capture, ensure: ensure);
    _durable(capture.capture(capture.durableRevision));
  }

  Future<T> withResources<T>(Future<T> Function(ResourceCore core) action) async {
    if (_stopping || _resources != null || value.transitioning || _core == null) {
      throw StateError('The note is not available for a resource operation.');
    }
    // Reserve before awaiting an in-flight write so no second borrower enters.
    final barrier = Completer<void>();
    _resources = barrier;
    _publish(resourcesBusy: true);
    try {
      await _saving;
      return await action(_core!);
    } finally {
      _resources = null;
      _publish(resourcesBusy: false);
      barrier.complete();
      _startSaving();
    }
  }

  Future<T> withPreview<T>(Future<T> Function(NotebookCore core, EditorSnapshot source) action) async {
    final send = _send;
    final editor = value.editor;
    if (send == null || editor == null) throw StateError('The source view is unavailable.');
    return withResources((_) async {
      final source = await editor.flushSource(send);
      await _flush(_capture!);
      if (!identical(editor, value.editor)) throw StateError('The source capture changed.');
      return action(_core!, source);
    });
  }

  Future<bool> write(EditorSend send) => _enqueue(send, explicit: true);
  Future<bool> _enqueue(EditorSend send, {required bool explicit}) {
    final editor = value.editor;
    if (_stopping || editor == null || value.closed || value.transitioning ||
        (!explicit && value.recoveryRequired)) {
      return Future.value(false);
    }
    final target = _SaveTarget(editor, send, explicit);
    _pending?.completion.complete(false); // Superseded, never a saved receipt.
    _pending = target;
    _publish();
    _startSaving();
    return target.completion.future;
  }
  void _startSaving() {
    if (_saving != null || _pending == null || _resources != null || _stopping) return;
    final done = Completer<void>();
    _saving = done.future;
    unawaited(_drainSaves().whenComplete(() {
      _saving = null;
      done.complete();
      _startSaving();
    }));
  }
  Future<void> _drainSaves() async {
    while (_pending != null && _resources == null && !_stopping) {
      final target = _pending!;
      _pending = null;
      final result = await _save(target.editor, target.send, explicit: target.explicit);
      target.completion.complete(result);
      if (!result && value.recoveryRequired) {
        _pending?.completion.complete(false);
        _pending = null;
      }
    }
  }
  Future<bool> _save(EditorSession editor, EditorSend send, {required bool explicit,
      EditorSnapshot? quiesced}) async {
    if (!identical(editor, value.editor) || _core == null) return false;
    if (_resourceBlock != null) { _publish(error: _resourceBlock); return false; }
    _cancelTimers();
    _publish(writing: true, clearError: true);
    try {
      final snapshot = quiesced ?? await editor.flushSource(send);
      if (!identical(editor, value.editor)) return false;
      if (!value.dirty) return true; // No-edit browsing never creates a journal.
      final capture = _capture!;
      await _flush(capture, ensure: true);
      if (value.recoveryRequired) {
        if (!explicit) return false;
        final actual = await _reconcile(capture);
        if (actual['outcome'] == 'conflict' ||
            (actual['outcome'] != 'saved' && actual['canRetry'] != true)) {
          throw StateError('Disk and draft disagree. Inspect recovery before writing.');
        }
        if (_candidate == null && value.onDiskRevision == snapshot.revision &&
            actual['savedSourceHash'] == actual['sourceHash']) {
          return true;
        }
      }
      // Candidate is captured exactly once when dispatch starts, not timer ticks.
      _candidate ??= await drafts.prepareSave(capture);
      final candidate = _candidate!;
      _publish();
      final result = await _core!.writeDraft(draftsRoot: drafts.root,
        documentKey: capture.documentKey, token: capture.token,
        candidateId: candidate['candidateId'] as String);
      if (result.record['completedCandidateId'] != candidate['candidateId'] ||
          result.record['savedSourceHash'] != candidate['sourceHash']) {
        throw StateError('The saved receipt does not identify the dispatched source candidate.');
      }
      _acceptSaved(capture, result.record, candidate['revision'] as int);
      _candidate = null;
      _publish(recoveryRequired: false);
      // A retry can first settle an older pinned intent. Complete the requested
      // flush barrier too; edits newer than that barrier remain a later target.
      if ((value.onDiskRevision ?? -1) < snapshot.revision) {
        return await _save(editor, send, explicit: true, quiesced: snapshot);
      }
      return true;
    } on Object catch (error) {
      _publish(error: _error(error), recoveryRequired: _candidate != null);
      final capture = _capture;
      if (capture != null && _candidate != null) {
        try { await _reconcile(capture); } on Object catch (receiptError) {
          _publish(recoveryRequired: true,
            durabilityError: 'The write outcome requires a durable receipt: ${_error(receiptError)}');
        }
      }
      return false;
    } finally { _publish(writing: false); _schedule(); }
  }
  void _acceptSaved(EditorDraftCapture capture, Map<String, Object?> result, int revision) {
    if (result['documentKey'] != capture.documentKey || result['token'] != capture.token ||
        result['outcome'] != 'saved' || result['savedRevision'] != revision ||
        result['savedDiskHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result['savedDiskHash'] as String) ||
        revision > capture.durableRevision) {
      throw StateError('Native write returned a mismatched saved receipt.');
    }
    capture.summary = result;
    if (!identical(capture, _capture)) return;
    final message = capture.editor.acknowledgeSaved(capture.capture(revision));
    _publish(onDiskRevision: revision, savedToken: capture.token,
      recoveryRequired: result['candidateId'] != null, clearDurabilityError: true);
    if (message != null) _sendControl(message);
  }
  Future<Map<String, Object?>> _reconcile(EditorDraftCapture capture) async {
    final result = (await _core!.reconcileDraft(draftsRoot: drafts.root,
      documentKey: capture.documentKey, token: capture.token)).record;
    capture.summary = result;
    if (result['outcome'] == 'saved' && result['savedRevision'] is int) {
      _acceptSaved(capture, result, result['savedRevision'] as int);
      if (result['candidateId'] == null) _candidate = null;
    } else {
      _publish(recoveryRequired: true);
    }
    return result;
  }

  Future<bool> reopen(NotebookDisposition disposition, EditorSend send) =>
      _close(disposition, send, reopen: true);
  Future<bool> close(NotebookDisposition disposition, EditorSend send) =>
      _close(disposition, send, reopen: false);
  Future<bool> _close(NotebookDisposition disposition, EditorSend send,
      {required bool reopen}) async {
    if (disposition == NotebookDisposition.cancel || _transition != null || _stopping) return false;
    final editor = value.editor;
    if (editor == null) return false;
    final transition = Completer<void>();
    _transition = transition;
    _publish(transitioning: true);
    _cancelTimers();
    _pending?.completion.complete(false);
    _pending = null;
    try {
      await _resources?.future;
      await _saving;
      // Explicit discard may abandon a failed view, but is never reported as a
      // successful flush/quiesce or as persistence of unreceived input.
      final abandonView = disposition == NotebookDisposition.discard && editor.value.error != null;
      final snapshot = abandonView
        ? EditorSnapshot(editor.value.text, editor.value.revision,
            documentId: editor.documentId, generation: editor.generation,
            anchor: editor.value.anchor, head: editor.value.head)
        : await editor.quiesce(send);
      if (disposition == NotebookDisposition.write) {
        if (!await _save(editor, send, explicit: true, quiesced: snapshot)) {
          throw StateError(value.error ?? 'The final source prefix was not saved.');
        }
      } else if (disposition == NotebookDisposition.retain) {
        await _flush(_capture!, ensure: value.dirty);
      }
      if (reopen && disposition == NotebookDisposition.retain && _capture!.begun) {
        final actual = await _core!.reconcileDraft(draftsRoot: drafts.root,
          documentKey: _capture!.documentKey, token: _capture!.token);
        if (actual.outcome == 'conflict') {
          throw StateError('Disk and draft conflict. Retain the draft and inspect recovery before reopening.');
        }
        _restored = await drafts.rebase(DraftRecoveryEntry(actual.record), newTransferId());
      }
      if (disposition == NotebookDisposition.discard) {
        await drafts.detach(_capture!, discard: true);
      } else {
        await _flush(_capture!);
        if (_capture!.durableRevision < snapshot.revision) {
          throw StateError('The final source prefix was not durably retained.');
        }
        await drafts.detach(_capture!);
      }
      if (!abandonView) {
        await editor.completeClose(send, capture: snapshot,
          discard: disposition == NotebookDisposition.discard);
      }
      _send = null;
      await _core?.close();
      _core = null;
      if (reopen) {
        await drafts.scan();
        await (_initialization = _initialize());
        return value.editor != editor;
      }
      _publish(closed: true);
      return true;
    } on Object catch (error) {
      _publish(error: _error(error));
      if (_candidate != null && _capture != null && _core != null) {
        try { await _reconcile(_capture!); } on Object catch (receiptError) {
          _publish(recoveryRequired: true, durabilityError: _error(receiptError));
        }
      }
      try { await editor.abortClose(send); } on Object catch (abortError) {
        _publish(error: _error(abortError));
      }
      return false;
    } finally {
      _transition = null;
      transition.complete();
      _publish(transitioning: false);
      _schedule();
    }
  }

  Future<EditorSession> recoverWebView() async {
    if (_send != null && value.editor?.value.ready == true && value.editor?.value.error == null) {
      throw StateError('A live source view must resynchronize or retire before replacement.');
    }
    if (value.editor?.value.resyncCandidate != null) {
      throw StateError('Choose between the received source and the divergent view before reloading.');
    }
    return _replaceView();
  }
  Future<EditorSession> resolveResync({required bool useViewSource}) async {
    final candidate = value.editor?.value.resyncCandidate;
    if (candidate == null) throw StateError('No divergent source candidate is retained.');
    return _replaceView(chosenSource: useViewSource ? candidate.text : null,
      anchor: useViewSource ? candidate.anchor : null,
      head: useViewSource ? candidate.head : null);
  }
  Future<EditorSession> _replaceView({String? chosenSource, int? anchor, int? head}) async {
    if (_stopping || value.transitioning || _resources != null || _capture == null) {
      throw StateError('The note cannot replace its source view during an operation.');
    }
    _cancelTimers();
    _send = null;
    _pending?.completion.complete(false);
    _pending = null;
    _publish(transitioning: true);
    try {
      await _saving;
      final previous = _capture!;
      await _flush(previous, ensure: true);
      final rebased = await drafts.rebase(DraftRecoveryEntry(previous.summary!),
        newTransferId(), chosenSource: chosenSource);
      final proof = (await _core!.reconcileDraft(draftsRoot: drafts.root,
        documentKey: previous.documentKey, token: rebased['token'] as String)).record;
      if (proof['outcome'] == 'conflict') {
        throw StateError('Disk changed during source restoration. Both captures are retained.');
      }
      final source = await drafts.readSource(DraftRecoveryEntry(proof));
      await drafts.detach(previous);
      _install(value.note!, source: source['source'] as String, restored: proof,
        anchor: anchor ?? previous.editor.value.anchor,
        head: head ?? previous.editor.value.head);
      return value.editor!;
    } finally { _publish(transitioning: false); }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    _stopping = true;
    _cancelTimers();
    _pending?.completion.complete(false);
    _pending = null;
    value.editor?.reportTransportError('The notebook session is closing; accepted draft obligations are being joined.');
    await _initialization;
    await _resources?.future;
    await _saving;
    await _transition?.future;
    Object? failure;
    final capture = _capture;
    if (capture != null && !capture.retired) {
      try { await _flush(capture); await drafts.detach(capture); }
      on Object catch (error) { failure = error; _durabilityFailed(error); }
    }
    await _core?.close();
    _core = null;
    if (failure != null) throw failure;
  }
  @override
  void dispose() {
    if (_disposed) return;
    value.editor?.removeListener(_editorChanged);
    unawaited(shutdown().catchError((Object _) {}));
    _disposed = true;
    value.editor?.dispose();
    super.dispose();
  }
  void _publish({bool? loading, bool? writing, bool? transitioning,
      bool? resourcesBusy, bool? closed, int? onDiskRevision, int? draftRevision,
      String? savedToken, bool? recoveryRequired, String? durabilityError,
      bool clearDurabilityError = false, String? error, bool clearError = false}) {
    if (_disposed) return;
    value = NotebookSessionState(editor: value.editor, note: value.note,
      onDiskRevision: onDiskRevision ?? value.onDiskRevision,
      draftRevision: draftRevision ?? value.draftRevision,
      savedToken: savedToken ?? value.savedToken,
      inFlightRevision: (writing ?? value.writing) ? (_candidate?['revision'] as int?) : null,
      pendingRevision: _pending?.requestedRevision,
      loading: loading ?? value.loading, writing: writing ?? value.writing,
      transitioning: transitioning ?? value.transitioning,
      resourcesBusy: resourcesBusy ?? value.resourcesBusy, closed: closed ?? value.closed,
      recoveryRequired: recoveryRequired ?? value.recoveryRequired,
      durabilityError: clearDurabilityError ? null : durabilityError ?? value.durabilityError,
      error: clearError ? null : error ?? value.error);
  }
  static String _error(Object error) => error is CoreException
      ? 'Core error ${error.code}: ${error.message}' : error is StateError
      ? error.message.toString() : error is TransferFailure ? error.message
      : 'Notebook operation failed. Received source and private recovery data are retained.';
}
