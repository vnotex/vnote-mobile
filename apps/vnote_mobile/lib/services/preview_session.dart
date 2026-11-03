// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'web_surface_platform.dart';

class PreviewCaptureRequest {
  PreviewCaptureRequest(this.previewId, this.renderId);
  final String previewId;
  final String renderId;
  final _cancelledSignal = Completer<void>();
  Future<void> get whenCancelled => _cancelledSignal.future;
  bool _cancelled = false;
  void Function()? _onCancel;
  bool get cancelled => _cancelled;
  set onCancel(void Function()? value) {
    _onCancel = value;
    if (_cancelled) value?.call();
  }
  void check() {
    if (_cancelled) throw StateError('Preview capture was cancelled.');
  }
  void cancel() {
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    _onCancel?.call();
  }
}

typedef PreviewCapture = Future<CorePreviewSnapshot> Function(PreviewCaptureRequest request);
typedef PreviewStore = Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef PreviewNavigation = Future<void> Function(CorePreviewSnapshot snapshot, CorePreviewNavigation target);

Future<Map<String, Object?>> _runPreviewStore(Map<String, Object?> request) =>
    Isolate.run(() => CoreImportStore.runPreview(request));

@immutable
class PreviewSessionState {
  const PreviewSessionState({
    this.snapshot,
    this.busy = false,
    this.waitingForView = false,
    this.closed = false,
    this.error,
  });
  final CorePreviewSnapshot? snapshot;
  final bool busy;
  final bool waitingForView;
  final bool closed;
  final String? error;
}

class _PreviewRequest {
  _PreviewRequest(this.preferences, String previewId)
    : capture = PreviewCaptureRequest(previewId, WebSurfacePlatform.newSurfaceId());
  final SurfacePreferences preferences;
  final PreviewCaptureRequest capture;
  final completion = Completer<bool>();
}

/// One active capture/render and one newest pending target. Source lives in the
/// separate NotebookSession; a preview failure never replaces that editor.
class PreviewSession extends ValueNotifier<PreviewSessionState> {
  PreviewSession({
    required this.platform,
    required this._capture,
    required this._isCurrent,
    required this.onPrepared,
    required PreviewNavigation onNavigate,
    PreviewStore? store,
  }) : _navigate = onNavigate,
       _store = store ?? _runPreviewStore,
       super(const PreviewSessionState()) {
    platform.listen(surfaceId, _event);
  }

  final WebSurfacePlatform platform;
  final PreviewCapture _capture;
  final bool Function(CorePreviewSnapshot) _isCurrent;
  final VoidCallback onPrepared;
  final PreviewNavigation _navigate;
  final PreviewStore _store;
  final String surfaceId = WebSurfacePlatform.newSurfaceId();
  final String previewId = WebSurfacePlatform.newSurfaceId();
  final _viewReady = Completer<void>();
  final _retained = <CorePreviewSnapshot>[];
  _PreviewRequest? _active;
  _PreviewRequest? _pending;
  Future<void>? _runner;
  Future<void>? _closing;
  bool _stopping = false;
  bool _disposed = false;
  bool _navigationActive = false;
  bool _retirementFailed = false;
  String? _renderingId;

  void attachView() {
    if (!_viewReady.isCompleted) _viewReady.complete();
  }

  bool isCurrent(CorePreviewSnapshot snapshot) =>
      !_stopping && !_retirementFailed && identical(value.snapshot, snapshot) && _isCurrent(snapshot);

  Future<bool> request(SurfacePreferences preferences) {
    preferences.toJson();
    if (_stopping || _retirementFailed) {
      return Future.error(StateError('The preview must finish retirement before another render.'));
    }
    final request = _PreviewRequest(preferences, previewId);
    final previous = _pending;
    _pending = request;
    previous?.capture.cancel();
    if (previous != null && !previous.completion.isCompleted) previous.completion.complete(false);
    _runner ??= _drain();
    return request.completion.future;
  }

  Future<void> _drain() async {
    try {
      while (!_stopping && _pending != null && !_retirementFailed) {
        final request = _pending!;
        _pending = null;
        _active = request;
        final completed = await _run(request);
        if (!request.completion.isCompleted) request.completion.complete(completed);
        _active = null;
      }
    } finally {
      _runner = null;
      if (_retirementFailed) {
        final pending = _pending;
        _pending = null;
        pending?.capture.cancel();
        if (pending != null && !pending.completion.isCompleted) pending.completion.complete(false);
      }
      if (!_stopping) _publish(busy: false);
    }
  }

  Future<bool> _run(_PreviewRequest request) async {
    CorePreviewSnapshot? snapshot;
    var rendererStarted = false;
    var displayStarted = false;
    var joined = false;
    _publish(busy: true, clearError: true);
    try {
      request.capture.check();
      snapshot = await _capture(request.capture);
      if (snapshot.previewId != previewId || snapshot.renderId != request.capture.renderId) {
        snapshot = null; // A mismatched result is not authority to revoke another owner.
        _retirementFailed = true;
        throw StateError('Preview capture returned a different generation.');
      }
      request.capture.check();
      if (!_isCurrent(snapshot) || _pending != null) return false;
      _publish(busy: true, waitingForView: !_viewReady.isCompleted);
      onPrepared();
      await Future.any([_viewReady.future, request.capture.whenCancelled]);
      request.capture.check();
      if (_stopping || !_isCurrent(snapshot)) return false;
      rendererStarted = true;
      _renderingId = snapshot.renderId;
      final result = await platform.render(
        surfaceId: surfaceId,
        previewId: previewId,
        renderId: snapshot.renderId,
        preferences: request.preferences,
      );
      joined = true;
      if (!result.ready || _stopping || request.capture.cancelled || _pending != null || !_isCurrent(snapshot)) {
        return false;
      }
      displayStarted = true;
      await platform.show(surfaceId: surfaceId, previewId: previewId, renderId: snapshot.renderId);
      if (_stopping || request.capture.cancelled || !_isCurrent(snapshot)) {
        if (!_stopping) {
          _retirementFailed = true;
          await platform.close(surfaceId);
        }
        _retained.add(snapshot);
        snapshot = null;
        return false;
      }
      final old = value.snapshot;
      _publish(snapshot: snapshot, busy: false, waitingForView: false, clearError: true);
      if (old != null && !identical(old, snapshot)) {
        _retained.add(old);
        await _revoke(old);
        _retained.remove(old);
      }
      snapshot = null; // Visible native view now owns this generation until replacement/close.
      return true;
    } on Object catch (error) {
      if (displayStarted) {
        _retirementFailed = true;
        try { await platform.close(surfaceId); joined = true; }
        on Object { joined = false; }
      } else if (rendererStarted && !joined) {
        try {
          await platform.cancel(surfaceId, request.capture.renderId);
          joined = true;
        } on Object {
          _retirementFailed = true;
        }
      }
      if (!_stopping && !request.capture.cancelled) {
        _publish(busy: false, waitingForView: false, error: _describe(error));
      }
      return false;
    } finally {
      request.capture.onCancel = null;
      if (_renderingId == request.capture.renderId) _renderingId = null;
      if (snapshot != null) {
        if (!_stopping && (!rendererStarted || joined)) {
          try { await _revoke(snapshot); }
          on Object { _retained.add(snapshot); _retirementFailed = true; }
        } else {
          _retained.add(snapshot);
        }
      }
    }
  }

  Future<void> _revoke(CorePreviewSnapshot snapshot) async {
    await _store(snapshot.command('revoke'));
  }

  void _event(SurfaceEvent event) {
    if (_stopping) return;
    final snapshot = value.snapshot;
    if (event.kind == SurfaceEventKind.failure) {
      if (event.renderId == snapshot?.renderId || event.renderId == _active?.capture.renderId) {
        _publish(error: event.category == 'renderer_timeout'
            ? 'Preview exceeded its time limit. The editor and draft are retained.'
            : event.category == 'offline_policy_unavailable'
            ? 'This WebView cannot enforce the required offline security policy.'
            : 'Preview became unavailable. The editor and draft are retained.');
      }
      return;
    }
    if (event.kind != SurfaceEventKind.navigation || snapshot == null ||
        event.renderId != snapshot.renderId || _navigationActive || !isCurrent(snapshot)) {
      return;
    }
    _navigationActive = true;
    unawaited(_navigation(snapshot, event.handle!).whenComplete(() => _navigationActive = false));
  }

  Future<void> _navigation(CorePreviewSnapshot snapshot, String handle) async {
    try {
      final raw = await _store({...snapshot.command('navigation'), 'handle': handle});
      final target = CorePreviewNavigation.fromJson(raw);
      if (target.handle != handle || !isCurrent(snapshot)) return;
      // The callback always obtains explicit Flutter confirmation. Native gesture
      // evidence is not, by itself, permission to leave or modify a document.
      await _navigate(snapshot, target);
    } on Object catch (error) {
      if (!_stopping) _publish(error: _describe(error));
    }
  }

  Future<void> updatePreferences(SurfacePreferences preferences) async {
    if (_stopping) return;
    await platform.preferences(surfaceId, preferences);
  }

  Future<void> cancel() async {
    final pending = _pending;
    _pending = null;
    pending?.capture.cancel();
    if (pending != null && !pending.completion.isCompleted) pending.completion.complete(false);
    final active = _active;
    active?.capture.cancel();
    try {
      if (active != null && _renderingId == active.capture.renderId) {
        await platform.cancel(surfaceId, active.capture.renderId);
      }
    } finally {
      await _runner;
    }
  }

  bool get retiring => _stopping;

  Future<void> close() {
    if (value.closed) return Future<void>.value();
    final pending = _closing;
    if (pending != null) return pending;
    final closing = _close().whenComplete(() => _closing = null);
    _closing = closing;
    return closing;
  }

  Future<void> _close() async {
    _stopping = true;
    final pending = _pending;
    _pending = null;
    pending?.capture.cancel();
    if (pending != null && !pending.completion.isCompleted) pending.completion.complete(false);
    _active?.capture.cancel();
    if (!_viewReady.isCompleted) _viewReady.complete();
    // Native close is the renderer/display reader barrier. Never reclaim a
    // snapshot merely because a Dart timeout or cancellation was requested.
    await platform.close(surfaceId);
    await _runner;
    final visible = value.snapshot;
    if (visible != null && !_retained.contains(visible)) _retained.add(visible);
    while (_retained.isNotEmpty) {
      await _revoke(_retained.first);
      _retained.removeAt(0);
    }
    _publish(busy: false, waitingForView: false, closed: true);
  }

  void _publish({
    CorePreviewSnapshot? snapshot,
    bool? busy,
    bool? waitingForView,
    bool? closed,
    String? error,
    bool clearError = false,
  }) {
    if (_disposed) return;
    value = PreviewSessionState(
      snapshot: snapshot ?? value.snapshot,
      busy: busy ?? value.busy,
      waitingForView: waitingForView ?? value.waitingForView,
      closed: closed ?? value.closed,
      error: clearError ? null : error ?? value.error,
    );
  }

  static String _describe(Object error) => error is CoreException
      ? error.message
      : error is StateError
      ? error.message.toString()
      : 'Preview could not complete. Source and drafts are retained.';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    platform.unlisten(surfaceId);
    // Lifetime owner calls close before disposal; retain snapshots if native
    // retirement is unavailable rather than deleting beneath an active reader.
    if (!value.closed && _closing == null) unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}
