// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'editor_drafts.dart';
import 'editor_session.dart';
import 'transfer_worker.dart';
import 'notebook_sync.dart';

enum NotebookDisposition { write, retain, discard, cancel }

@immutable
class NotebookSessionState {
  const NotebookSessionState({this.editor, this.note, this.onDiskRevision = 0,
    this.draftRevision = 0, this.savedToken, this.inFlightRevision,
    this.pendingRevision, this.loading = false,
    this.writing = false, this.transitioning = false, this.resourcesBusy = false,
    this.closed = false, this.recoveryRequired = false, this.durabilityError,
    this.error, this.syncBusy = false, this.syncReserved = false,
    this.syncRecoveryRequired = false, this.syncError, this.inboxBlocked = false,
    this.restartRequired = false});
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
  final bool syncBusy;
  final bool syncReserved;
  final bool syncRecoveryRequired;
  final String? syncError;
  final bool inboxBlocked;
  final bool restartRequired;
  bool get dirty => editor != null && (recoveryRequired || syncRecoveryRequired || durabilityError != null ||
    error != null || editor!.value.error != null ||
    editor!.value.pending || editor!.value.composing ||
    editor!.value.resyncCandidate != null || savedToken != editor!.generation ||
    editor!.value.revision != onDiskRevision);
  bool get busy => loading || writing || transitioning || resourcesBusy || syncReserved || inboxBlocked || restartRequired;
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
    this._restored, this._beforeCoreClose, this._onCoreChanged, this._onLocalSaved})
      : super(const NotebookSessionState());
  final Future<NotebookCore> Function() _openCore;
  final EditorDrafts drafts;
  final String notebookRelative;
  final Future<void> Function()? _beforeCoreClose;
  final VoidCallback? _onCoreChanged;
  final VoidCallback? _onLocalSaved;
  _NoteSyncReservation? _syncReservation;
  _NoteSyncReservation? _syncRecovery;
  String? _syncError;
  bool _syncBusy = false;
  bool _syncAllowsWrites = true;
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
  Completer<void>? _inboxBarrier;
  String? _resourceBlock;
  Timer? _idle;
  Timer? _ceiling;
  int _observedRevision = 0;
  bool _foreground = true;
  bool _disposed = false;
  bool _stopping = false;
  bool _restartRequired = false;
  ({EditorSession editor, EditorDraftCapture capture, EditorSnapshot snapshot})? _terminalClose;

  static const ownerRestartRequiredMessage = 'Notebook shutdown did not finish. Received source is retained. Copy it, then restart the app before reopening this notebook. This editor cannot be resumed.';
  String get nativeNotices => _core?.nativeNotices ?? '';
  SyncCore? get synchronizationCore => _restartRequired ? null : _core;

  /// Only an acknowledged quiesce followed by an irreversible close attempt
  /// permits replacement without asking a possibly closed page to resynchronize.
  bool get canRecoverQuiescedView {
    final proof = _terminalClose;
    if (_restartRequired || proof == null || !identical(proof.editor, value.editor) ||
        !identical(proof.capture, _capture) || proof.capture.retired) {
      return false;
    }
    final source = proof.editor.value;
    return source.quiesced && !source.pending && !source.composing &&
      source.resyncCandidate == null && source.revision == proof.snapshot.revision &&
      source.text == proof.snapshot.text;
  }

  void setSyncActivity({required bool busy, required bool allowsLocalWrites}) {
    if (_syncBusy == busy && _syncAllowsWrites == allowsLocalWrites) return;
    _syncBusy = busy; _syncAllowsWrites = allowsLocalWrites;
    if (!allowsLocalWrites) _cancelTimers();
    _publish(); _startSaving(); _schedule();
  }

  NotebookSyncReservation installSyncReservation(SyncReservationRequest request) {
    if (_stopping || _restartRequired || _terminalClose != null || _inboxBarrier != null || _syncReservation != null || value.transitioning || _core == null ||
        _capture == null || _resourceBlock != null || (_syncRecovery?._abortPending ?? false)) {
      throw StateError('The note cannot reserve synchronization while another owner is active.');
    }
    final reservation = _NoteSyncReservation(this, request);
    _syncReservation = reservation;
    _cancelTimers(); _publish();
    return reservation;
  }

  Future<bool> recoverSyncSources() async {
    if (_restartRequired || _terminalClose != null || _inboxBarrier != null) return false;
    final retained = _syncRecovery;
    if (retained == null) return true;
    final current = _syncReservation;
    return current == null ? retained.recover() : current.recoverRetained(retained);
  }

  void bindTransport(EditorSend send) { if (_restartRequired || _terminalClose != null) return; _send = send; _schedule(); }
  void unbindTransport(EditorSend send) {
    if (identical(_send, send)) { _send = null; _cancelTimers(); }
  }
  void setForeground(bool foreground) {
    _foreground = foreground && _inboxBarrier == null;
    if (_foreground) { _schedule(); } else {
      _cancelTimers();
      final capture = _capture;
      if (capture != null) {
        unawaited(_flush(capture).catchError((Object error) {
          _durabilityFailed(error);
        }));
      }
    }
  }

  /// Stops new notebook writes immediately, then joins admitted owners. Accepted
  /// editor input continues into private drafts; no editor epoch is replaced.
  Future<void> beginInboxBarrier() {
    final existing = _inboxBarrier;
    if (existing != null) return existing.future;
    final barrier = Completer<void>();
    _inboxBarrier = barrier;
    _foreground = false;
    _cancelTimers();
    // A queued request has not dispatched. Refuse its receipt, not its source;
    // resume may autosave the latest editor text after quarantine is known.
    _pending?.completion.complete(false);
    _pending = null;
    _publish();
    unawaited(_joinInboxWriters().then(barrier.complete, onError: barrier.completeError));
    return barrier.future;
  }

  Future<void> _joinInboxWriters() async {
    await _initialization;
    await _transition?.future;
    await _resources?.future;
    await _saving;
    await _syncRecovery?._aborting;
    final capture = _capture;
    if (capture != null && !capture.retired) await _flush(capture);
  }

  /// Releases only the transient inbox exclusion, never a resource quarantine.
  void endInboxBarrier({required bool foreground}) {
    final barrier = _inboxBarrier;
    if (barrier == null) return;
    if (!barrier.isCompleted) throw StateError('Join inbox writers before releasing the barrier.');
    _inboxBarrier = null;
    _publish();
    setForeground(foreground);
  }
  void setResourceBlock(String? message) {
    _resourceBlock = message;
    if (message != null) _cancelTimers();
    _publish(error: message, clearError: message == null);
    if (message == null) { _startSaving(); _schedule(); }
  }
  Future<void> initialize() => _stopping || _restartRequired || _inboxBarrier != null ? Future.value() :
      _initialization ??= _initialize();
  Future<void> _initialize({bool afterJoinedClose = false}) async {
    if (_restartRequired && !afterJoinedClose) throw StateError(ownerRestartRequiredMessage);
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
    finally { _publish(loading: false); _onCoreChanged?.call(); }
  }
  Future<void> retryOpen() async {
    if (_stopping || _restartRequired || value.busy || value.editor != null || _resourceBlock != null) return;
    final transition = Completer<void>();
    _transition = transition;
    _publish(transitioning: true);
    try {
      await _beforeCoreClose?.call();
      await _core?.close();
      _core = null;
      await (_initialization = _initialize());
    } finally {
      _transition = null;
      transition.complete();
      _publish(transitioning: false);
    }
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
    _terminalClose = null;
    _restartRequired = false;
    editor.onEdit = (batch) => drafts.accept(capture, batch,
      durable: _durable, failed: _durabilityFailed);
    editor.addListener(_editorChanged);
    _observedRevision = 0;
    _candidate = null;
    value = NotebookSessionState(editor: editor, note: note,
      onDiskRevision: saved ? 0 : null, savedToken: saved ? editor.generation : null,
      syncBusy: _syncBusy, syncReserved: _syncReservation != null,
      inboxBlocked: _inboxBarrier != null,
      syncRecoveryRequired: _syncRecovery != null, syncError: _syncError);
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
    if (!value.dirty) {
      _cancelTimers();
      return;
    }
    if (_stopping || _restartRequired || _terminalClose != null || _inboxBarrier != null || _resourceBlock != null || !_foreground || !_syncAllowsWrites || _syncReservation != null ||
        _syncRecovery != null || _send == null ||
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
    if (_stopping || _restartRequired || _terminalClose != null || _inboxBarrier != null || _syncBusy || _syncReservation != null || _syncRecovery != null ||
        _resources != null || value.transitioning || _core == null) {
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
    if (_stopping || _restartRequired || _terminalClose != null || _inboxBarrier != null || _resourceBlock != null || editor == null || value.closed || value.transitioning ||
        (!explicit && (!_foreground || value.recoveryRequired))) {
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
    if (_saving != null || _pending == null || _resources != null || _stopping || _restartRequired || _terminalClose != null ||
        _inboxBarrier != null || _resourceBlock != null ||
        !_syncAllowsWrites || _syncReservation != null || _syncRecovery != null) { return; }
    final done = Completer<void>();
    _saving = done.future;
    unawaited(_drainSaves().whenComplete(() {
      _saving = null;
      done.complete();
      _startSaving();
    }));
  }
  Future<void> _drainSaves() async {
    while (_pending != null && _resources == null && !_stopping &&
        _inboxBarrier == null && _resourceBlock == null &&
        _syncAllowsWrites && _syncReservation == null && _syncRecovery == null) {
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
    if (!identical(editor, value.editor) || _core == null || _syncRecovery != null) return false;
    if (_resourceBlock != null) { _publish(error: _resourceBlock); return false; }
    // An automatic target can outlive the write that already saved its source.
    // Explicit writes still require a fresh source barrier, even when clean.
    if (!explicit && !value.dirty) return true;
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
    final advanced = value.savedToken != capture.token || value.onDiskRevision != revision;
    final message = capture.editor.acknowledgeSaved(capture.capture(revision));
    _publish(onDiskRevision: revision, savedToken: capture.token,
      recoveryRequired: result['candidateId'] != null, clearDurabilityError: true);
    if (message != null) _sendControl(message);
    if (advanced) _onLocalSaved?.call();
  }
  Future<Map<String, Object?>> _reconcile(EditorDraftCapture capture) async {
    final result = (await _core!.reconcileDraft(draftsRoot: drafts.root,
      documentKey: capture.documentKey, token: capture.token)).record;
    capture.summary = result;
    if (result['outcome'] == 'saved' && result['savedRevision'] is int) {
      _acceptSaved(capture, result, result['savedRevision'] as int);
      if (result['candidateId'] == null) _candidate = null;
    } else {
      _publish(recoveryRequired: result['outcome'] != 'base' || result['candidateId'] != null);
    }
    return result;
  }

  Future<bool> reopen(NotebookDisposition disposition, EditorSend send) =>
      _close(disposition, send, reopen: true);
  Future<bool> close(NotebookDisposition disposition, EditorSend send) =>
      _close(disposition, send, reopen: false);
  Future<bool> _close(NotebookDisposition disposition, EditorSend send,
      {required bool reopen}) async {
    if (disposition == NotebookDisposition.cancel || _transition != null || _stopping || _restartRequired || _terminalClose != null || _inboxBarrier != null ||
        (reopen && _resourceBlock != null)) {
      return false;
    }
    final editor = value.editor;
    if (editor == null) return false;
    final transition = Completer<void>();
    _transition = transition;
    _publish(transitioning: true);
    _cancelTimers();
    _pending?.completion.complete(false);
    _pending = null;
    var abandonView = disposition == NotebookDisposition.discard && editor.value.error != null;
    try {
      await _beforeCoreClose?.call();
      await _resources?.future;
      await _saving;
      // Explicit discard may abandon a failed view, but is never reported as a
      // successful flush/quiesce or as persistence of unreceived input.
      abandonView = disposition == NotebookDisposition.discard && editor.value.error != null;
      final snapshot = abandonView || editor.value.quiesced
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
        final capture = _capture!;
        if (_syncRecovery != null && !reopen && capture.begun &&
            capture.summary?['savedRevision'] == snapshot.revision &&
            capture.summary?['candidateId'] == null) {
          // Explicit Keep draft after a remote replacement must not leave the
          // received old source hidden as fully-saved retention history.
          final retained = await drafts.rebase(DraftRecoveryEntry(capture.summary!), newTransferId());
          if (retained['token'] == capture.token || retained['revision'] != 0 ||
              retained['savedRevision'] != null || retained['sourceHash'] != capture.summary!['sourceHash']) {
            throw StateError('The retained synchronization source was not safely checkpointed.');
          }
        }
      }
      if (reopen && disposition == NotebookDisposition.retain && _capture!.begun) {
        final actual = await _core!.reconcileDraft(draftsRoot: drafts.root,
          documentKey: _capture!.documentKey, token: _capture!.token);
        if (actual.outcome == 'conflict') {
          throw StateError('Disk and draft conflict. Retain the draft and inspect recovery before reopening.');
        }
        _restored = await drafts.rebase(DraftRecoveryEntry(actual.record), newTransferId());
      }
      await _flush(_capture!);
      if (!abandonView && _capture!.durableRevision < snapshot.revision) {
        throw StateError('The final source prefix was not durably retained.');
      }
      if (!abandonView) {
        // Once sent, complete may close the page even if its reply times out.
        // Keep the exact quiesced draft attached; this epoch must never abort.
        _terminalClose = (editor: editor, capture: _capture!, snapshot: snapshot);
        await editor.completeClose(send, capture: snapshot,
          discard: disposition == NotebookDisposition.discard);
      }
      _send = null;
      // close() retires native admission synchronously, before its future joins.
      _restartRequired = true;
      await _core?.close();
      _core = null;
      await drafts.detach(_capture!, discard: disposition == NotebookDisposition.discard);
      if (reopen) {
        await drafts.scan();
        await (_initialization = _initialize(afterJoinedClose: true));
        return value.editor != editor;
      }
      _restartRequired = false;
      _terminalClose = null;
      _publish(closed: true);
      return true;
    } on Object catch (error) {
      if (_restartRequired || _terminalClose != null || abandonView) {
        final message = _restartRequired ? ownerRestartRequiredMessage : _error(error);
        editor.reportTransportError(message);
        _publish(error: message);
        return false;
      }
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
    if (_restartRequired) throw StateError(ownerRestartRequiredMessage);
    if (_terminalClose != null && !canRecoverQuiescedView) {
      throw StateError('The final source capture changed. Received source and private drafts are retained.');
    }
    if (_send != null && value.editor?.value.ready == true && value.editor?.value.error == null && !canRecoverQuiescedView) {
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
    if (_stopping || _restartRequired || _inboxBarrier != null || _syncBusy || _syncReservation != null || _syncRecovery != null ||
        value.transitioning || _resources != null || _capture == null) {
      throw StateError('The note cannot replace its source view during an operation.');
    }
    final terminal = _terminalClose;
    if (terminal != null && (!canRecoverQuiescedView || chosenSource != null)) {
      throw StateError('The final source capture changed. Received source and private drafts are retained.');
    }
    _cancelTimers();
    _send = null;
    _pending?.completion.complete(false);
    _pending = null;
    final transition = Completer<void>();
    _transition = transition;
    _publish(transitioning: true);
    try {
      await _saving;
      final previous = _capture!;
      await _flush(previous, ensure: true);
      if (terminal != null) {
        final retained = await drafts.readSource(DraftRecoveryEntry(previous.summary!));
        if (terminal != _terminalClose || !canRecoverQuiescedView ||
            previous.durableRevision != terminal.snapshot.revision ||
            retained['revision'] != terminal.snapshot.revision ||
            retained['source'] != terminal.snapshot.text) {
          throw StateError('The final source capture changed. Received source and private drafts are retained.');
        }
      }
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
      if (terminal != null) _restored = null;
      return value.editor!;
    } finally {
      _transition = null;
      transition.complete();
      _publish(transitioning: false);
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    _stopping = true;
    _cancelTimers();
    _pending?.completion.complete(false);
    _pending = null;
    await _beforeCoreClose?.call();
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
  void _publish({CoreNote? note, bool? loading, bool? writing, bool? transitioning,
      bool? resourcesBusy, bool? closed, int? onDiskRevision, int? draftRevision,
      String? savedToken, bool? recoveryRequired, String? durabilityError,
      bool clearDurabilityError = false, String? error, bool clearError = false}) {
    if (_disposed) return;
    value = NotebookSessionState(editor: value.editor, note: note ?? value.note,
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
      error: _restartRequired ? ownerRestartRequiredMessage : clearError ? null : error ?? value.error, syncBusy: _syncBusy,
      syncReserved: _syncReservation != null, syncRecoveryRequired: _syncRecovery != null,
      syncError: _syncError, inboxBlocked: _inboxBarrier != null, restartRequired: _restartRequired);
  }
  static String _error(Object error) => error is CoreException
      ? 'Core error ${error.code}: ${error.message}' : error is StateError
      ? error.message.toString() : error is TransferFailure ? error.message
      : 'Notebook operation failed. Received source and private recovery data are retained.';
}


/// One identity-bound exclusion. Error retirement keeps source ownership explicit;
/// it never turns a failed abort/refresh into permission to write or replace text.
class _NoteSyncReservation implements NotebookSyncReservation {
  _NoteSyncReservation(this.session, this.request)
      : editor = session.value.editor!, capture = session._capture!,
        core = session._core!, note = session.value.note!, send = session._send;
  final NotebookSession session;
  final SyncReservationRequest request;
  final EditorSession editor;
  final EditorDraftCapture capture;
  final NotebookCore core;
  final CoreNote note;
  final EditorSend? send;
  EditorSnapshot? snapshot;
  EditorSession? _replacement;
  Future<void>? _draining;
  Future<bool>? _aborting;
  bool _quiesceRequested = false;
  bool _abortPending = false;
  bool _cancelled = false;
  bool _released = false;
  bool _dirty = true;

  bool get _owns => !_released && identical(session._syncReservation, this) &&
      identical(session._core, core) && identical(session.value.editor, _replacement ?? editor);
  void _check() {
    if (!_owns || _cancelled) throw StateError('The synchronization reservation retired.');
  }

  @override
  Future<void> drainWriters() => _draining ??= _drain();
  Future<void> _drain() async {
    _check();
    await session._resources?.future;
    await session._saving;
    _check();
  }

  @override
  Future<SyncProtection> quiesceAndDrainDrafts() async {
    await drainWriters(); _check();
    if (session._syncRecovery != null && !editor.value.ready) {
      // A prior failed retirement already blocks source writes/replacement. A
      // lifecycle recovery may repair native state, but cannot infer clean text.
      await session._flush(capture, ensure: true); _check();
      _dirty = true;
      return SyncProtection(dirtyNodeIds: [note.nodeId]);
    }
    final transport = send;
    if (transport == null || !editor.value.ready) {
      throw StateError('Wait for the secure editor, or close the note before synchronizing.');
    }
    _quiesceRequested = true;
    if (session._syncRecovery != null && (editor.value.closing || editor.value.quiesced)) {
      await editor.abortClose(transport); _check();
    }
    snapshot = await editor.quiesce(transport);
    _check();
    await session._resources?.future;
    await session._saving;
    await session._flush(capture, ensure: true);
    _check();
    if (capture.durableRevision < snapshot!.revision) {
      throw StateError('The quiesced prefix is not yet a durable private draft.');
    }
    // Opening a clean document need not have created a receipt. Establish saved0
    // by exact native disk equality, never by the quiesce or draft acknowledgement.
    if (!session.value.dirty) {
      await session._reconcile(capture); _check();
    }
    _dirty = session.value.dirty;
    return SyncProtection(dirtyNodeIds: _dirty ? [note.nodeId] : const []);
  }

  bool _affected(List<String> paths) => paths.any((path) => path == note.path ||
      note.path.startsWith('$path/') || path == 'vx_notebook/config.json' ||
      path.startsWith('vx_notebook/contents/'));

  void _release() {
    if (!identical(session._syncReservation, this)) return;
    session._syncReservation = null;
    _released = true;
    session._publish(); session._startSaving(); session._schedule();
  }

  Future<void> _unfreeze() async {
    if (_quiesceRequested && !editor.value.closed) {
      final transport = send;
      if (transport == null) throw StateError('Source abort transport is unavailable.');
      await editor.abortClose(transport);
    }
  }

  Future<void> _reloadClean() async {
    _check();
    final actual = await core.read(); _check();
    if (actual.notebookId != note.notebookId || actual.nodeId != note.nodeId) {
      throw StateError('The synchronized note identity changed. Received source is retained.');
    }
    final savedHash = capture.summary?['savedDiskHash'] as String? ?? note.baseHash;
    if (actual.baseHash == savedHash && actual.path == note.path &&
        actual.editorType == note.editorType && actual.lineEnding == note.lineEnding) {
      // A receipt may project LF source to CRLF disk. Equal disk bytes preserve
      // the original source representation and undo history.
      session._publish(note: actual);
      await _unfreeze(); _check();
      return;
    }
    final transport = send;
    final captured = snapshot;
    if (transport == null || captured == null || captured.revision != editor.value.revision) {
      throw StateError('The clean source changed during synchronization.');
    }
    await editor.completeClose(transport, capture: captured, discard: false);
    _check();
    await session.drafts.detach(capture); _check();
    session._send = null;
    session._syncRecovery = null; session._syncError = null;
    session._install(actual);
    _replacement = session.value.editor;
    // _install intentionally retires the old editor; ownership is still this
    // reservation until its token is released, but its source identity is new.
  }

  @override
  Future<SyncSettlement> settle(SyncRefreshReport? report) async {
    try {
      _check();
      if (report != null && (!report.metadataRefreshed || report.changedPaths == null)) {
        if (_dirty) await _unfreeze();
        retainRecovery('Synchronization source refresh needs explicit recovery.');
        return const SyncSettlement(safe: false, recoveryRequired: true);
      }
      if (report != null && !_dirty && _affected(report.changedPaths!)) {
        await _reloadClean();
      } else {
        await _unfreeze(); _check();
      }
      _release();
      return const SyncSettlement(safe: true);
    } on Object {
      retainRecovery('Synchronization could not safely refresh or resume the source.');
      return const SyncSettlement(safe: false, recoveryRequired: true);
    }
  }

  @override
  Future<bool> abort() => _aborting ??= _abort();
  Future<bool> _abort() async {
    if (!_owns) return _released;
    _abortPending = true;
    _cancelled = true;
    try {
      var safe = true;
      // Sending abort removes old quiesce/abort correlations immediately. A
      // retired token cannot send a control that unfreezes its successor.
      try { await _unfreeze(); } on Object { safe = false; }
      try {
        await session._resources?.future; await session._saving;
        await session._flush(capture, ensure: _quiesceRequested);
      } on Object { safe = false; }
      if (!_owns) return _released;
      if (safe) { _release(); }
      else { retainRecovery('Synchronization cancellation could not resume the source safely.'); }
      return safe;
    } finally { _abortPending = false; }
  }

  @override
  void retainRecovery(String code) {
    if (!_owns) return;
    session._syncRecovery = this; session._syncError = code;
    session._syncReservation = null; _released = true;
    session._cancelTimers(); session._publish();
  }

  Future<bool> recoverRetained(_NoteSyncReservation previous) async {
    if (!_owns || !identical(session._syncRecovery, previous) ||
        !identical(previous.core, core) || !identical(previous.editor, editor)) { return false; }
    snapshot = previous.snapshot;
    _dirty = previous._dirty;
    _quiesceRequested = previous._quiesceRequested || editor.value.quiesced;
    return _recoverSource(release: false);
  }

  Future<bool> recover() async {
    if (!identical(session._syncRecovery, this) || !identical(session._core, core) ||
        !identical(session.value.editor, editor) || session._syncReservation != null) { return false; }
    session._syncReservation = this; _released = false; _cancelled = false;
    session._publish();
    return _recoverSource(release: true);
  }

  Future<bool> _recoverSource({required bool release}) async {
    try {
      _check();
      final hadDirtySource = _dirty || editor.value.pending || editor.value.composing ||
          editor.value.resyncCandidate != null ||
          (snapshot != null && editor.value.revision != snapshot!.revision);
      if (hadDirtySource) {
        final proof = await session._reconcile(capture); _check();
        if (proof['outcome'] == 'conflict') throw StateError('Disk and draft still conflict.');
        await _unfreeze(); _check();
      } else {
        await _reloadClean();
      }
      session._syncRecovery = null; session._syncError = null;
      if (release) { _release(); } else { session._publish(); }
      return true;
    } on Object {
      retainRecovery('Sync recovery could not prove safe source replacement. Keep the received draft.');
      return false;
    }
  }

}
