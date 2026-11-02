// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'editor_session.dart';

enum NotebookDisposition { write, discard, cancel }

@immutable
class NotebookSessionState {
  const NotebookSessionState({
    this.editor,
    this.note,
    this.onDiskRevision = 0,
    this.loading = false,
    this.writing = false,
    this.transitioning = false,
    this.resourcesBusy = false,
    this.closed = false,
    this.error,
  });

  final EditorSession? editor;
  final CoreNote? note;
  final int onDiskRevision;
  final bool loading;
  final bool writing;
  final bool transitioning;
  final bool resourcesBusy;
  final bool closed;
  final String? error;
  bool get dirty => editor != null && editor!.value.revision != onDiskRevision;
  bool get busy => loading || writing || transitioning || resourcesBusy;
}

/// Owns one native notebook and one editor generation. Native writes are never
/// inferred from editor receipt. The platform adapter alone creates support dirs.
class NotebookSession extends ValueNotifier<NotebookSessionState> {
  NotebookSession({required this._openCore})
    : super(const NotebookSessionState());

  final Future<NotebookCore> Function() _openCore;
  NotebookCore? _core;
  String? _baseHash;
  Future<void>? _initialization;
  Future<void>? _shutdownFuture;
  Completer<void>? _active;
  Completer<void>? _resources;
  String? _resourceBlock;
  bool _disposed = false;
  bool _shuttingDown = false;

  String get nativeNotices => _core?.nativeNotices ?? '';

  void setResourceBlock(String? message) {
    if (_resourceBlock == message) return;
    _resourceBlock = message;
    _publish(error: message, clearError: message == null);
  }

  Future<void> initialize() =>
      _shuttingDown ? Future<void>.value() : _initialization ??= _initialize();

  Future<void> retryOpen() async {
    if (value.editor != null || !_admit()) return;
    _publish(loading: true, clearError: true);
    try {
      await _core?.close();
      _core = null;
      if (!_shuttingDown) await (_initialization = _initialize());
    } on Object catch (error) {
      _publish(error: _error(error));
    } finally {
      _publish(loading: false);
      _retire();
    }
  }

  Future<void> _initialize() async {
    _publish(loading: true);
    try {
      final core = await _openCore();
      _core = core;
      if (_shuttingDown) return;
      final note = await core.read();
      _install(note);
    } on Object catch (error) {
      _publish(error: _error(error));
    } finally {
      _publish(loading: false);
    }
  }

  void _install(CoreNote note) {
    if (_shuttingDown) return;
    // UTF-8 hex is stable, delimiter-unambiguous and bounded by EditorSession.
    String identity(String value) => utf8
        .encode(value)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final editor = EditorSession(
      initialText: note.text,
      documentId: '${identity(note.notebookId)}:${identity(note.nodeId)}',
      baseVersion: note.baseHash,
      language: note.editorType.name,
    );
    final previous = value.editor;
    previous?.removeListener(_editorChanged);
    editor.addListener(_editorChanged);
    _baseHash = note.baseHash;
    value = NotebookSessionState(editor: editor, note: note);
    previous?.dispose();
  }

  void _editorChanged() => _publish();

  /// Borrows the existing NOTE owner, never a competing native context. The
  /// entire transfer (including provider leases) remains inside this barrier.
  Future<T> withResources<T>(
    Future<T> Function(ResourceCore core) action,
  ) async {
    if (_core == null || value.note == null || !_admit()) {
      throw StateError('The note is not available for a resource operation.');
    }
    final barrier = Completer<void>();
    _resources = barrier;
    _publish(resourcesBusy: true, clearError: true);
    try {
      return await action(_core!);
    } finally {
      _resources = null;
      _publish(resourcesBusy: false);
      _retire();
      barrier.complete();
    }
  }

  Future<bool> write(EditorSend send) async {
    final editor = value.editor;
    final barrier = _resources;
    if (barrier != null) await barrier.future;
    if (!identical(editor, value.editor)) return false;
    if (!_admit()) return false;
    try {
      return await _write(send);
    } finally {
      _retire();
    }
  }

  Future<bool> _write(EditorSend send) async {
    final editor = value.editor;
    if (editor == null || _core == null) return false;
    if (_resourceBlock != null) {
      _publish(error: _resourceBlock);
      return false;
    }
    _publish(writing: true, clearError: true);
    try {
      final snapshot = await editor.captureSnapshot(send);
      if (_shuttingDown) return false;
      // A write with no accepted edits must not normalize the original bytes.
      if (snapshot.revision != value.onDiskRevision) {
        final result = await _core!.write(
          snapshot.text,
          revision: snapshot.revision,
          baseHash: _baseHash!,
        );
        if (result.revision != snapshot.revision ||
            result.baseHash.length != 64 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.baseHash)) {
          throw StateError('Native write returned a mismatched receipt.');
        }
        _baseHash = result.baseHash;
        _publish(onDiskRevision: snapshot.revision);
      }
      return true;
    } on Object catch (error) {
      _publish(error: _error(error));
      return false;
    } finally {
      _publish(writing: false);
    }
  }

  Future<bool> reopen(NotebookDisposition disposition, EditorSend send) =>
      _transition(disposition, send, reopen: true);

  Future<bool> close(NotebookDisposition disposition, EditorSend send) =>
      _transition(disposition, send, reopen: false);

  Future<bool> _transition(
    NotebookDisposition disposition,
    EditorSend send, {
    required bool reopen,
  }) async {
    if (disposition == NotebookDisposition.cancel) return false;
    final editor = value.editor;
    final barrier = _resources;
    if (barrier != null) await barrier.future;
    if (!identical(editor, value.editor) || !_admit()) return false;
    _publish(transitioning: true, clearError: true);
    try {
      if (reopen && _resourceBlock != null) {
        throw StateError(_resourceBlock!);
      }
      if (disposition == NotebookDisposition.write && !await _write(send)) {
        return false;
      }
      if (_shuttingDown) return false;
      if (disposition == NotebookDisposition.write && value.dirty) {
        throw StateError(
          'Newer edits arrived during Write. Write again or explicitly discard them.',
        );
      }
      // Even a received-clean mirror may have pending/composing JS input. The
      // written barrier flushes it and refuses close if its revision advanced.
      if (disposition != NotebookDisposition.discard ||
          value.editor?.value.error == null) {
        await value.editor?.closeEditor(
          send,
          discard: disposition == NotebookDisposition.discard,
        );
      }
      if (_shuttingDown) return false;
      if (reopen) {
        // A new editor starts revision zero, so it needs a new native host epoch.
        // Drain/join the old owner before reusing the same persistent roots.
        final previousCore = _core;
        await previousCore?.close();
        _core = null;
        if (_shuttingDown) return false;
        _core = await _openCore();
        if (_shuttingDown) return false;
        final note = await _core!.read();
        _install(note);
      } else {
        await _core?.close();
        _core = null;
        _publish(closed: true);
      }
      return true;
    } on Object catch (error) {
      // Keep the old generation/source available for copying after read errors.
      _publish(error: _error(error));
      return false;
    } finally {
      _publish(transitioning: false);
      _retire();
    }
  }

  bool _admit() {
    if (_shuttingDown || value.busy || value.closed || _active != null) {
      return false;
    }
    _active = Completer<void>();
    return true;
  }

  void _retire() {
    _active?.complete();
    _active = null;
  }

  /// Native close performs its join off the UI isolate. Disposal stops editor
  /// waits, then drains any admitted native mutation before closing the owner.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _shuttingDown = true;
    final editor = value.editor;
    editor?.reportTransportError('The notebook session is closing.');
    await _initialization;
    await _active?.future;
    await _core?.close();
    _core = null;
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

  void _publish({
    bool? loading,
    bool? writing,
    bool? transitioning,
    bool? resourcesBusy,
    bool? closed,
    int? onDiskRevision,
    String? error,
    bool clearError = false,
  }) {
    if (_disposed) return;
    value = NotebookSessionState(
      editor: value.editor,
      note: value.note,
      onDiskRevision: onDiskRevision ?? value.onDiskRevision,
      loading: loading ?? value.loading,
      writing: writing ?? value.writing,
      transitioning: transitioning ?? value.transitioning,
      resourcesBusy: resourcesBusy ?? value.resourcesBusy,
      closed: closed ?? value.closed,
      error: clearError ? null : error ?? value.error,
    );
  }

  static String _error(Object error) => error is CoreException
      ? 'Core error ${error.code}: ${error.message}'
      : error is StateError
      ? error.message.toString()
      : 'Notebook operation failed. Source is retained; no notebook was recreated.';
}
