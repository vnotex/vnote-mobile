// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

final class CoreNote {
  const CoreNote({
    required this.notebookId,
    required this.nodeId,
    required this.text,
    required this.baseHash,
    required this.coreVersion,
    required this.lineEnding,
  });

  final String notebookId;
  final String nodeId;
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
  _Pending(this.kind, this.revision);

  final int kind;
  final int revision;
  final completer = Completer<Object>();
}

final class CoreNotebook implements NotebookCore {
  CoreNotebook._() : _token = _nextToken++ {
    _listener = NativeCallable<Void Function(Int64)>.listener(_onNotify);
  }

  static int _nextToken = 1;
  final int _token;
  late final NativeCallable<Void Function(Int64)> _listener;
  Pointer<native.VxmHost>? _handle;
  Pointer<native.VxmHost>? _eventHandle;
  int _generation = 0;
  int _nextRequest = 2;
  final _pending = <int, _Pending>{};
  final _closedEvent = Completer<int>();
  Future<void>? _closing;

  static Future<CoreNotebook> open({
    required String appDataPath,
    required String localDataPath,
    required String notebookPath,
    required String notebookName,
    required String notePath,
    required String initialText,
  }) async {
    if (_nextToken > _maxInteger) {
      throw const CoreException(
        _unusable,
        'Native session tokens are exhausted',
      );
    }
    final initial = _encode(initialText);
    final host = CoreNotebook._();
    final pending = _Pending(native.VXM_EVENT_OPEN, 0);
    try {
      using((arena) {
        final options = arena<native.VxmOpenOptions>();
        options.ref
          ..app_data_path = _option(arena, appDataPath)
          ..local_data_path = _option(arena, localDataPath)
          ..notebook_path = _option(arena, notebookPath)
          ..notebook_name = _option(arena, notebookName)
          ..note_path = _option(arena, notePath)
          ..initial_data = _copyBytes(arena, initial)
          ..initial_size = initial.length;
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
      await pending.completer.future;
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
                  bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
                text = '\ufeff$text';
              }
            }
            pending.completer.complete(
              CoreNote(
                notebookId: event.notebook_id.cast<Utf8>().toDartString(),
                nodeId: event.node_id.cast<Utf8>().toDartString(),
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
