// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive.dart'
    show
        ArchiveFile,
        ByteOrder,
        InputFileStream,
        InputStream,
        OutputStream,
        ZipEncoder,
        ZipEntryBody;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';
import 'share_inbox.dart';

enum NotebookExportPhase { idle, reconciling, preparing, archiving, saving }

@immutable
class PreparedNotebookExport {
  const PreparedNotebookExport({
    required this.id,
    required this.notebookId,
    required this.notebookName,
    required this.format,
    required this.path,
    required this.bytes,
    required this.sha256,
  });
  final String id;
  final String notebookId;
  final String notebookName;
  final CoreExportFormat format;
  final String path;
  final int bytes;
  final String sha256;
}

@immutable
class ExportLeftover {
  const ExportLeftover({
    required this.location,
    required this.label,
    required this.reason,
  });
  final String location;
  final String label;
  final String reason;
}

@immutable
class NotebookExportState {
  const NotebookExportState({
    this.phase = NotebookExportPhase.idle,
    this.prepared,
    this.error,
    this.message,
    this.leftovers = const [],
  });
  final NotebookExportPhase phase;
  final PreparedNotebookExport? prepared;
  final String? error;
  final String? message;
  final List<ExportLeftover> leftovers;
  bool get busy => phase != NotebookExportPhase.idle;
}

class ExportCancellation {
  bool _cancelled = false;
  VoidCallback? _onCancel;
  bool get isCancelled => _cancelled;

  set onCancel(VoidCallback? callback) {
    _onCancel = callback;
    if (_cancelled) _notifyCancellation();
  }

  void check() {
    if (_cancelled) throw const _ExportCancelled();
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _notifyCancellation();
  }

  void _notifyCancellation() {
    try {
      _onCancel?.call();
    } catch (_) {
      // A late owner may already be closing. Cancellation remains remembered;
      // its future, not the advisory callback, still controls the lease.
    }
  }
}

typedef ExportSnapshotCapture = Future<CoreExportSnapshot> Function(
  String destination,
  int stagingBudgetBytes,
  ExportCancellation cancellation,
);

const _stagingBudget = 3 * 1024 * 1024 * 1024;
// Old receipts remain inspectable even when they exceed new admission capacity.
const _legacyStagingBudget = 4 * 1024 * 1024 * 1024;
const _markerAllowance = 128 * 1024;
const _sourceLimit = 1024 * 1024 * 1024;
const _entryLimit = 100000;
const _markerLimit = _markerAllowance ~/ 2;
const _restartWarning =
    'A previous external copy may have completed or may be incomplete. '
    'Save as creates another chosen copy.';

/// Owns only export staging. Native snapshot ownership belongs to the capture
/// callback, which must close/join its owner before returning, even on failure.
/// Filesystem work runs in joined worker isolates, never on the UI isolate.
class NotebookExporter extends ValueNotifier<NotebookExportState> {
  NotebookExporter({
    required this.root,
    DocumentTransferPlatform? platform,
    this._checkAdmission,
  }) : _platform = platform ?? MethodChannelDocumentTransferPlatform(),
       super(const NotebookExportState());

  final VoidCallback? _checkAdmission;
  bool get initialized => _initialized;
  final String root;
  final DocumentTransferPlatform _platform;
  Future<void>? _active;
  Future<void>? _shutdown;
  ExportCancellation? _cancellation;
  String? _providerId;
  bool _initialized = false;
  bool _closing = false;
  bool _disposed = false;

  void _publish(NotebookExportState state) {
    if (!_disposed) value = state;
  }

  void _admit() {
    if (_closing || _disposed) throw StateError('Exporter is closed.');
    if (_active != null) {
      throw StateError('An export operation is still active.');
    }
  }

  Future<T> _operation<T>(Future<T> Function() body) async {
    _admit();
    final settled = Completer<void>();
    _active = settled.future;
    try {
      return await body();
    } finally {
      _cancellation?.onCancel = null;
      _cancellation = null;
      _active = null;
      settled.complete();
    }
  }

  Future<Map<String, Object?>> _job(
    String command, {
    Map<String, Object?> arguments = const {},
    ExportCancellation? cancellation,
  }) => _runExportWorker(root, command, arguments, cancellation);

  NotebookExportState _recovered(
    Map<String, Object?> result, {
    String? error,
    String? message,
  }) {
    final ready = result['prepared'] as Map<String, Object?>?;
    final leftovers = (result['leftovers'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(
          (item) => ExportLeftover(
            location: item['location'] as String,
            label: item['label'] as String,
            reason: item['reason'] as String,
          ),
        );
    return NotebookExportState(
      prepared: ready == null ? null : _prepared(ready),
      leftovers: List.unmodifiable(leftovers),
      error: error ?? result['error'] as String?,
      message: message ?? (ready == null ? null : _restartWarning),
    );
  }

  /// Reconciliation has no platform-channel prerequisite. The application
  /// prepares its support namespace before constructing this store.
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _operation(() async {
      _publish(
        const NotebookExportState(phase: NotebookExportPhase.reconciling),
      );
      try {
        final result = await _job('scan');
        _initialized = true;
        _publish(_recovered(result));
      } catch (error) {
        _publish(NotebookExportState(error: _message(error)));
      }
    });
  }

  Future<PreparedNotebookExport?> prepare({
    required String notebookId,
    required String notebookName,
    required CoreExportFormat format,
    required ExportSnapshotCapture capture,
  }) {
    _checkAdmission?.call();
    _admit();
    if (!_initialized) throw StateError('Initialize export storage first.');
    if (value.prepared != null || value.leftovers.isNotEmpty) {
      throw StateError('Save or discard the existing export staging first.');
    }
    return _operation(() async {
      final cancellation = ExportCancellation();
      _cancellation = cancellation;
      _publish(const NotebookExportState(phase: NotebookExportPhase.preparing));
      String? id;
      try {
        await _platform.prepareStorage();
        cancellation.check();
        final transaction = await _job(
          'allocate',
          arguments: {
            'notebookId': notebookId,
            'notebookName': notebookName,
            'format': format.name,
          },
        );
        id = transaction['id'] as String;
        cancellation.check();
        // Request marker is already flushed/renamed. Capture is the only code
        // allowed to create snapshot/, and its future is the source lease.
        final CoreExportSnapshot snapshot;
        try {
          snapshot = await capture(
            transaction['destination'] as String,
            _stagingBudget - _markerAllowance,
            cancellation,
          );
        } on CoreException catch (error) {
          // Host export reasons are static and redacted. Codec/platform errors
          // outside capture still use the generic failure message.
          throw _ExportFailure('Core error ${error.code}: ${error.message}');
        }
        cancellation.onCancel = null;
        cancellation.check();
        if (snapshot.notebookId != notebookId ||
            snapshot.notebookName != notebookName) {
          throw const _ExportFailure(
            'The notebook identity changed during export.',
          );
        }
        if (snapshot.format != format) {
          throw const _ExportFailure(
            'The snapshot format does not match the requested export.',
          );
        }
        _publish(
          const NotebookExportState(phase: NotebookExportPhase.archiving),
        );
        final result = await _job(
          'archive',
          arguments: {
            'id': id,
            'format': format.name,
            'sourceBytes': snapshot.bytes,
            'files': snapshot.files,
            'directories': snapshot.directories,
            'archiveLimit': snapshot.archiveLimit,
          },
          cancellation: cancellation,
        );
        final prepared = _prepared(result);
        const cancelledMessage =
            'Export cancelled. The completed ZIP is retained.';
        final wasCancelled = cancellation.isCancelled || _closing;
        _publish(
          NotebookExportState(
            prepared: prepared,
            message: wasCancelled
                ? cancelledMessage
                : 'ZIP prepared. Choose where to save a copy.',
          ),
        );
        // A listener can cancel/dispose while receiving the worker result.
        // Remember that cancellation before returning to an automatic Save As.
        if (cancellation.isCancelled || _closing) {
          if (!wasCancelled) {
            _publish(
              NotebookExportState(
                prepared: prepared,
                message: cancelledMessage,
              ),
            );
          }
          return null;
        }
        return prepared;
      } catch (error) {
        // Never clean a partial native snapshot until capture has settled.
        // If a ready marker was committed just before cancellation, retain it.
        try {
          if (id != null) await _job('abandon', arguments: {'id': id});
          final result = await _job('scan');
          _publish(
            _recovered(
              result,
              error: error is _ExportCancelled ? null : _message(error),
              message: error is _ExportCancelled ? 'Export cancelled.' : null,
            ),
          );
        } catch (cleanupError) {
          _publish(
            NotebookExportState(
              error: _message(cleanupError),
              leftovers: id == null
                  ? const []
                  : List.unmodifiable([
                      ExportLeftover(
                        location: p.join(root, id),
                        label: id,
                        reason: 'Export staging could not be reconciled. Explicit discard is required.',
                      ),
                    ]),
            ),
          );
        }
        return null;
      }
    });
  }

  Future<void> save(PreparedNotebookExport prepared) {
    _admit();
    _requirePrepared(prepared);
    return _operation(() async {
      final cancellation = ExportCancellation();
      _cancellation = cancellation;
      final leftovers = value.leftovers;
      _publish(
        NotebookExportState(
          phase: NotebookExportPhase.saving,
          prepared: prepared,
          leftovers: leftovers,
        ),
      );
      try {
        await _platform.prepareStorage();
        cancellation.check();
        await _job(
          'verify',
          arguments: _preparedMap(prepared),
          cancellation: cancellation,
        );
        cancellation.check();
        _providerId = prepared.id;
        // Platform completion, even a non-success result, must mean that its
        // picker/reader has settled. Cancel alone never releases this lease.
        final result = await _platform.save(
          operationId: prepared.id,
          scope: DocumentTransferScope.notebook,
          path: prepared.path,
          suggestedName: prepared.format == CoreExportFormat.filesAndAssets
              ? 'vnote-files-assets-${prepared.id}.zip'
              : 'vnote-${prepared.id}.zip',
        );
        _providerId = null;
        if (result.status == DocumentExportStatus.saved) {
          await _job(
            'discard',
            arguments: {'location': p.dirname(prepared.path)},
          );
          _publish(
            _recovered(
              await _job('scan'),
              message: 'The system completed the saved copy. Remote sync is not guaranteed.',
            ),
          );
        } else {
          final incomplete = result.externalMayBeIncomplete
              ? ' The external copy may be incomplete.'
              : '';
          _publish(
            NotebookExportState(
              prepared: prepared,
              leftovers: leftovers,
              error: switch (result.status) {
                DocumentExportStatus.failed =>
                  'The copy could not be saved.$incomplete',
                DocumentExportStatus.unavailable =>
                  'System Save As is unavailable.$incomplete',
                _ => null,
              },
              message: 'The ZIP is retained for retry.$incomplete',
            ),
          );
        }
      } catch (error) {
        _publish(
          NotebookExportState(
            prepared: prepared,
            leftovers: leftovers,
            error: error is _ExportCancelled ? null : _message(error),
            message: _providerId == null
                ? 'The ZIP is retained for retry.'
                : 'The ZIP is retained. The external copy may be incomplete.',
          ),
        );
      } finally {
        _providerId = null;
      }
    });
  }

  Future<ShareExportStatus> share(PreparedNotebookExport prepared, ShareInbox inbox) {
    _admit();
    _requirePrepared(prepared);
    return _operation(() async {
      final previous = value;
      _publish(NotebookExportState(phase: NotebookExportPhase.saving,
        prepared: prepared, leftovers: previous.leftovers));
      ShareExportStatus result;
      try {
        await _job('verify', arguments: _preparedMap(prepared));
        result = await inbox.shareExport(operationId: prepared.id,
          scope: DocumentTransferScope.notebook, path: prepared.path,
          suggestedName: prepared.format == CoreExportFormat.filesAndAssets
            ? 'vnote-files-assets-${prepared.id}.zip' : 'vnote-${prepared.id}.zip');
      } catch (_) {
        result = ShareExportStatus.failed;
      }
      // Share-to-system never consumes the original or becomes Save As success.
      _publish(NotebookExportState(prepared: prepared, leftovers: previous.leftovers,
        message: inbox.value.error ?? shareExportMessage(result)));
      return result;
    });
  }

  void _requirePrepared(PreparedNotebookExport prepared) {
    if (!identical(value.prepared, prepared)) {
      throw StateError('This prepared export is no longer current.');
    }
  }

  Future<void> discard(PreparedNotebookExport prepared) {
    _admit();
    _requirePrepared(prepared);
    return _discard(p.dirname(prepared.path));
  }

  Future<void> discardLeftover(ExportLeftover leftover) {
    _admit();
    if (!value.leftovers.any((item) => identical(item, leftover))) {
      throw StateError('This cleanup item is no longer current.');
    }
    return _discard(leftover.location);
  }

  Future<void> _discard(String location) => _operation(() async {
    final previous = value;
    _publish(
      NotebookExportState(
        phase: NotebookExportPhase.reconciling,
        prepared: previous.prepared,
        leftovers: previous.leftovers,
      ),
    );
    try {
      await _job('discard', arguments: {'location': location});
      _publish(
        _recovered(await _job('scan'), message: 'Export staging discarded.'),
      );
    } catch (error) {
      _publish(
        NotebookExportState(
          prepared: previous.prepared,
          leftovers: previous.leftovers,
          error: _message(error),
        ),
      );
    }
  });

  void cancel() {
    _cancellation?._cancel();
    final id = _providerId;
    if (id != null) {
      // A cancellation transport failure does not settle the source lease.
      unawaited(
        Future<void>.sync(
          () => _platform.cancel(id, scope: DocumentTransferScope.notebook),
        ).catchError((Object _) {}),
      );
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();

  Future<void> _close() async {
    _closing = true;
    cancel();
    await _active;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

class _ExportCancelled implements Exception {
  const _ExportCancelled();
}

class _ExportFailure implements Exception {
  const _ExportFailure(this.message);
  final String message;
}

String _message(Object error) => error is _ExportFailure
    ? error.message
    : 'Export could not be completed. The notebook was not changed.';

PreparedNotebookExport _prepared(Map<String, Object?> map) =>
    PreparedNotebookExport(
      id: map['id'] as String,
      notebookId: map['notebookId'] as String,
      notebookName: map['notebookName'] as String,
      format: _exportFormat(map['format'])!,
      path: map['path'] as String,
      bytes: map['bytes'] as int,
      sha256: map['sha256'] as String,
    );

Map<String, Object?> _preparedMap(PreparedNotebookExport prepared) => {
  'id': prepared.id,
  'notebookId': prepared.notebookId,
  'notebookName': prepared.notebookName,
  'format': prepared.format.name,
  'path': prepared.path,
  'bytes': prepared.bytes,
  'sha256': prepared.sha256,
};

Future<Map<String, Object?>> _runExportWorker(
  String root,
  String command,
  Map<String, Object?> arguments,
  ExportCancellation? cancellation,
) async {
  final messages = ReceivePort();
  final reply = Completer<Map<String, Object?>>();
  final exited = Completer<void>();
  final subscription = messages.listen((Object? message) {
    if (message is SendPort) {
      cancellation?.onCancel = () => message.send(null);
    } else if (message is Map<String, Object?>) {
      if (!reply.isCompleted) reply.complete(message);
    } else if (message == null) {
      if (!reply.isCompleted) {
        reply.complete({'error': 'The export worker stopped unexpectedly.'});
      }
      if (!exited.isCompleted) exited.complete();
    } else if (message is List && !reply.isCompleted) {
      reply.complete({'error': 'The export worker stopped unexpectedly.'});
    }
  });
  try {
    await Isolate.spawn(
      _exportWorker,
      (messages.sendPort, root, command, arguments),
      onExit: messages.sendPort,
      onError: messages.sendPort,
      errorsAreFatal: true,
    );
    final result = await reply.future;
    await exited.future;
    if (result['cancelled'] == true) throw const _ExportCancelled();
    if (result['error'] case final String error) throw _ExportFailure(error);
    return result['result'] as Map<String, Object?>;
  } finally {
    cancellation?.onCancel = null;
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _exportWorker(
  (SendPort, String, String, Map<String, Object?>) request,
) async {
  final (reply, root, command, arguments) = request;
  final cancellation = ExportCancellation();
  final control = ReceivePort();
  control.listen((_) => cancellation._cancel());
  reply.send(control.sendPort);
  Map<String, Object?> response;
  try {
    final store = _ExportStore(root, cancellation);
    await store.validateRoot(create: command == 'scan');
    final result = switch (command) {
      'scan' => await store.scan(),
      'allocate' => await store.allocate(arguments),
      'archive' => await store.archive(arguments),
      'verify' => await store.verify(arguments),
      'abandon' => await store.abandon(arguments['id'] as String),
      'discard' => await store.discard(arguments['location'] as String),
      _ => throw const _ExportFailure('Unsupported export operation.'),
    };
    response = {'result': result};
  } on _ExportCancelled {
    response = {'cancelled': true};
  } catch (error) {
    response = {'error': _message(error)};
  }
  control.close();
  Isolate.exit(reply, response);
}

String _pathKey(String value) {
  final normalized = p.normalize(value);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _samePath(String left, String right) => _pathKey(left) == _pathKey(right);

final _transactionId = RegExp(r'^[0-9a-f]{32}$');
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _controls = RegExp(r'[\x00-\x1f\x7f]');

bool _text(Object? value, int maximum) {
  if (value is! String || value.isEmpty || _controls.hasMatch(value)) {
    return false;
  }
  final bytes = utf8.encode(value);
  return bytes.length <= maximum && utf8.decode(bytes) == value;
}

bool _keys(Map<String, Object?> map, Set<String> expected) =>
    map.length == expected.length && map.keys.every(expected.contains);

CoreExportFormat? _exportFormat(Object? value) => switch (value) {
  'notebook' => CoreExportFormat.notebook,
  'filesAndAssets' => CoreExportFormat.filesAndAssets,
  _ => null,
};

// Only exact historical schema-1 markers qualify for this interpretation;
// callers validate their version-specific keys before returning an artifact.
CoreExportFormat? _markerFormat(Map<String, Object?> marker) =>
    marker['version'] == 1
    ? CoreExportFormat.notebook
    : _exportFormat(marker['format']);

class _ExportStore {
  _ExportStore(this.root, this.cancellation);
  final String root;
  final ExportCancellation cancellation;

  Future<void> validateRoot({bool create = false}) async {
    if (!p.isAbsolute(root) || p.normalize(root) != root) {
      throw const _ExportFailure(
        'Export storage must be a canonical absolute directory.',
      );
    }
    if (await FileSystemEntity.type(root, followLinks: false) ==
            FileSystemEntityType.notFound &&
        create) {
      final parent = Directory(p.dirname(root));
      await _directory(parent.path);
      await Directory(root).create();
    }
    await _directory(root);
  }

  Future<void> _directory(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_samePath(await Directory(path).resolveSymbolicLinks(), path)) {
      throw const _ExportFailure(
        'Export storage is linked, changed, or unavailable.',
      );
    }
  }

  String _child(String location) {
    if (!p.isAbsolute(location) ||
        !_samePath(p.dirname(location), root) ||
        p.normalize(location) != location ||
        _samePath(location, root)) {
      throw const _ExportFailure(
        'Cleanup is restricted to a direct export-staging child.',
      );
    }
    return location;
  }

  String _transaction(String id) {
    if (!_transactionId.hasMatch(id)) {
      throw const _ExportFailure('Export ownership marker is invalid.');
    }
    return _child(p.join(root, id));
  }

  Future<void> _regular(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        !_samePath(await File(path).resolveSymbolicLinks(), path)) {
      throw const _ExportFailure(
        'An export file is missing, linked, or unavailable.',
      );
    }
  }

  Future<Map<String, Object?>> _readMarker(
    String directory,
    String name,
  ) async {
    await _directory(directory);
    final path = p.join(directory, name);
    await _regular(path);
    final file = File(path).openSync();
    try {
      if (file.lengthSync() > _markerLimit) {
        throw const _ExportFailure('Export ownership marker is too large.');
      }
      final decoded = jsonDecode(utf8.decode(file.readSync(_markerLimit + 1)));
      if (decoded is! Map<String, dynamic>) {
        throw const _ExportFailure('Export ownership marker is invalid.');
      }
      return decoded.cast<String, Object?>();
    } finally {
      file.closeSync();
    }
  }

  bool _identity(Map<String, Object?> marker, String id) =>
      marker['version'] is int &&
      (marker['version'] == 1 || marker['version'] == 2) &&
      _markerFormat(marker) != null &&
      marker['id'] == id &&
      _text(marker['notebookId'], 127) &&
      _text(marker['notebookName'], 16384);

  Future<Map<String, Object?>> _request(String directory) async {
    final marker = await _readMarker(directory, 'request.json');
    if (!_identity(marker, p.basename(directory)) ||
        !_keys(marker, {
          'version',
          'id',
          'notebookId',
          'notebookName',
          if (marker['version'] == 2) 'format',
          'snapshot',
          'archive',
        }) ||
        marker['snapshot'] != 'snapshot' ||
        marker['archive'] != 'notebook.zip') {
      throw const _ExportFailure(
        'Export ownership marker is invalid or unsupported.',
      );
    }
    return marker;
  }

  Future<Map<String, Object?>> _ready(
    String directory,
    Map<String, Object?> request,
  ) async {
    final marker = await _readMarker(directory, 'ready.json');
    if (!_identity(marker, p.basename(directory)) ||
        marker['version'] != request['version'] ||
        _markerFormat(marker) != _markerFormat(request) ||
        marker['notebookId'] != request['notebookId'] ||
        marker['notebookName'] != request['notebookName'] ||
        !_keys(marker, {
          'version',
          'id',
          'notebookId',
          'notebookName',
          if (marker['version'] == 2) 'format',
          'archive',
          'bytes',
          'sha256',
          'sourceBytes',
          'files',
          'directories',
          'archiveLimit',
        }) ||
        marker['archive'] != 'notebook.zip' ||
        marker['bytes'] is! int ||
        (marker['bytes'] as int) < 22 ||
        marker['sha256'] is! String ||
        !_digestPattern.hasMatch(marker['sha256'] as String)) {
      throw const _ExportFailure(
        'Ready export marker is invalid or unsupported.',
      );
    }
    _summary(marker, historical: true);
    if ((marker['bytes'] as int) > (marker['archiveLimit'] as int)) {
      throw const _ExportFailure('Ready export exceeds its reserved size.');
    }
    return marker;
  }

  void _summary(Map<String, Object?> summary, {bool historical = false}) {
    for (final name in [
      'sourceBytes',
      'files',
      'directories',
      'archiveLimit',
    ]) {
      if (summary[name] is! int || (summary[name] as int) < 0) {
        throw const _ExportFailure('The snapshot size summary is invalid.');
      }
    }
    final bytes = summary['sourceBytes'] as int;
    final files = summary['files'] as int;
    final directories = summary['directories'] as int;
    final archiveLimit = summary['archiveLimit'] as int;
    if (bytes > _sourceLimit ||
        files + directories > _entryLimit ||
        archiveLimit < 22 ||
        bytes + archiveLimit > (historical ? _legacyStagingBudget : _stagingBudget) - _markerAllowance) {
      throw const _ExportFailure(
        'The snapshot exceeds the export resource limits.',
      );
    }
  }

  Future<void> _layout(String directory, {required bool ready}) async {
    const names = {
      'request.json',
      'request.json.tmp',
      'snapshot',
      'notebook.zip.part',
      'notebook.zip',
      'ready.json.tmp',
      'ready.json',
    };
    await for (final entry in Directory(directory).list(followLinks: false)) {
      final name = p.basename(entry.path);
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (!names.contains(name) ||
          (name == 'snapshot'
              ? type != FileSystemEntityType.directory
              : type != FileSystemEntityType.file) ||
          (!ready && name == 'ready.json')) {
        throw const _ExportFailure(
          'Export staging contains unexpected entries.',
        );
      }
      if (name == 'snapshot') {
        await _directory(entry.path);
      } else {
        await _regular(entry.path);
      }
    }
  }

  Future<void> _publishMarker(
    String directory,
    String name,
    Map<String, Object?> marker,
  ) async {
    final path = p.join(directory, name);
    final temporary = '$path.tmp';
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(temporary, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const _ExportFailure(
        'An export marker already exists. Nothing was replaced.',
      );
    }
    final bytes = utf8.encode(jsonEncode(marker));
    if (bytes.length > _markerLimit) {
      throw const _ExportFailure('Export metadata is too large.');
    }
    final file = File(temporary).openSync(mode: FileMode.writeOnly);
    try {
      file.writeFromSync(bytes);
      file.flushSync();
    } finally {
      file.closeSync();
    }
    await File(temporary).rename(path);
  }

  Future<Map<String, Object?>> allocate(Map<String, Object?> arguments) async {
    if (!_text(arguments['notebookId'], 127) ||
        !_text(arguments['notebookName'], 16384) ||
        _exportFormat(arguments['format']) == null) {
      throw const _ExportFailure('Notebook export metadata is invalid.');
    }
    // Recheck the root: another process or unrecognized residue must not be
    // silently absorbed into a new transaction.
    if (!await Directory(root).list(followLinks: false).isEmpty) {
      throw const _ExportFailure(
        'Export staging already exists. Refresh and discard it first.',
      );
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final directory = _transaction(id);
    if (await FileSystemEntity.type(directory, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _ExportFailure('The export staging location already exists.');
    }
    await Directory(directory).create();
    await _publishMarker(directory, 'request.json', {
      'version': 2,
      'id': id,
      'notebookId': arguments['notebookId'],
      'notebookName': arguments['notebookName'],
      'format': arguments['format'],
      'snapshot': 'snapshot',
      'archive': 'notebook.zip',
    });
    return {'id': id, 'destination': p.join(directory, 'snapshot')};
  }

  Map<String, Object?> _artifact(
    String directory,
    Map<String, Object?> marker,
  ) => {
    'id': marker['id'],
    'notebookId': marker['notebookId'],
    'notebookName': marker['notebookName'],
    'format': _markerFormat(marker)!.name,
    'path': p.join(directory, 'notebook.zip'),
    'bytes': marker['bytes'],
    'sha256': marker['sha256'],
  };

  Future<Map<String, Object?>> scan() async {
    final ready = <Map<String, Object?>>[];
    final leftovers = <Map<String, Object?>>[];
    final corruption = <String, String>{};
    await for (final child in Directory(root).list(followLinks: false)) {
      final location = _child(child.path);
      final label = p.basename(location);
      try {
        _transaction(label);
        await _directory(location);
        final request = await _request(location);
        final hasReady =
            await FileSystemEntity.type(
              p.join(location, 'ready.json'),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound;
        await _layout(location, ready: hasReady);
        if (!hasReady) {
          await _remove(location);
          continue;
        }
        final marker = await _ready(location, request);
        final artifact = _artifact(location, marker);
        ready.add(artifact);
        try {
          await _verifyArtifact(artifact);
        } catch (_) {
          corruption[label] = 'The prepared ZIP is missing or corrupt. Discard it and export again.';
        }
      } catch (_) {
        leftovers.add({
          'location': location,
          'label': label,
          'reason': 'Unrecognized or unsafe export staging. Preserved for explicit discard.',
        });
      }
    }
    if (ready.length > 1) {
      for (final artifact in ready) {
        leftovers.add({
          'location': p.dirname(artifact['path'] as String),
          'label': artifact['id'],
          'reason': 'Multiple ready exports were found. Discard extras to recover one.',
        });
      }
    }
    final single = ready.length == 1 ? ready.single : null;
    return {
      'prepared': single,
      'leftovers': leftovers,
      'error': single == null
          ? (leftovers.isEmpty
                ? null
                : 'Export staging needs explicit cleanup.')
          : corruption[single['id']],
    };
  }

  Future<Map<String, Object?>> abandon(String id) async {
    final directory = _transaction(id);
    await _request(directory);
    if (await FileSystemEntity.type(
          p.join(directory, 'ready.json'),
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      await _layout(directory, ready: false);
      await _remove(directory);
    }
    return {};
  }

  Future<Map<String, Object?>> discard(String location) async {
    await validateRoot();
    await _remove(_child(location));
    return {};
  }

  Future<void> _remove(String path) async {
    // Never use recursive:true: a link is unlinked, not traversed. Each real
    // directory is revalidated before visiting its immediate children.
    await validateRoot();
    await _directory(p.dirname(path));
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await _directory(path);
      await for (final child in Directory(path).list(followLinks: false)) {
        if (!_samePath(p.dirname(child.path), path)) {
          throw const _ExportFailure(
            'Export cleanup encountered an unsafe path.',
          );
        }
        await _remove(child.path);
      }
      await _directory(path);
      await Directory(path).delete();
    } else {
      await File(path).delete();
    }
  }

  Future<Map<String, Object?>> verify(Map<String, Object?> expected) async {
    final directory = _transaction(expected['id'] as String);
    final request = await _request(directory);
    await _layout(directory, ready: true);
    final ready = _artifact(directory, await _ready(directory, request));
    if (ready.length != expected.length ||
        ready.keys.any((key) => ready[key] != expected[key])) {
      throw const _ExportFailure('The prepared export is no longer current.');
    }
    await _verifyArtifact(ready);
    return {};
  }

  Future<void> _verifyArtifact(Map<String, Object?> artifact) async {
    final path = artifact['path'] as String;
    await _regular(path);
    final hash = await _hash(path, artifact['bytes'] as int);
    if (hash != artifact['sha256']) {
      throw const _ExportFailure(
        'The prepared ZIP is corrupt. Discard it and export again.',
      );
    }
  }

  Future<String> _hash(String path, int expectedBytes) async {
    final input = File(path).openSync();
    final digest = _DigestSink();
    final sink = crypto.sha256.startChunkedConversion(digest);
    final buffer = Uint8List(128 * 1024);
    try {
      if (input.lengthSync() != expectedBytes) {
        throw const _ExportFailure(
          'The prepared ZIP size changed. Discard it and export again.',
        );
      }
      var read = 0;
      while (true) {
        cancellation.check();
        final count = input.readIntoSync(buffer);
        if (count == 0) break;
        read += count;
        if (read > expectedBytes) {
          throw const _ExportFailure('The prepared ZIP size changed.');
        }
        sink.add(Uint8List.sublistView(buffer, 0, count));
        await Future<void>.delayed(Duration.zero);
      }
      if (read != expectedBytes || input.lengthSync() != expectedBytes) {
        throw const _ExportFailure('The prepared ZIP size changed.');
      }
      sink.close();
      return digest.value!.toString();
    } finally {
      input.closeSync();
    }
  }

  Future<Map<String, Object?>> archive(Map<String, Object?> summary) async {
    _summary(summary);
    final directory = _transaction(summary['id'] as String);
    final request = await _request(directory);
    if (request['version'] != 2 || summary['format'] != request['format']) {
      throw const _ExportFailure(
        'The snapshot format does not match the requested export.',
      );
    }
    await _layout(directory, ready: false);
    final snapshot = p.join(directory, 'snapshot');
    await _directory(snapshot);
    final temporary = p.join(directory, 'notebook.zip.part');
    final archive = p.join(directory, 'notebook.zip');
    for (final path in [temporary, archive]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const _ExportFailure(
          'Archive output already exists. Nothing was replaced.',
        );
      }
    }
    final output = _BoundedZipOutput(temporary, summary['archiveLimit'] as int);
    final encoder = ZipEncoder(streamed: true)..startEncode(output, level: 1);
    var files = 0;
    var directories = 0;
    var bytes = 0;

    Future<void> visit(String path, List<String> parents) async {
      await _directory(path);
      await for (final child in Directory(path).list(followLinks: false)) {
        cancellation.check();
        final component = p.basename(child.path);
        final parts = [...parents, component];
        final relative = parts.join('/');
        if (component == '.' ||
            component == '..' ||
            component.contains('\\') ||
            component.contains('/') ||
            component.contains(':') ||
            !_text(component, 255) ||
            parts.length > 32 ||
            utf8.encode(relative).length > 1024) {
          throw const _ExportFailure(
            'A snapshot filename is not safe to export unchanged.',
          );
        }
        final type = await FileSystemEntity.type(
          child.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          directories++;
          if (directories > (summary['directories'] as int)) {
            throw const _ExportFailure('The snapshot directory count changed.');
          }
          await _directory(child.path);
          encoder.addHeader(ArchiveFile.directory('$relative/'));
          await Future<void>.delayed(Duration.zero);
          await visit(child.path, parts);
        } else if (type == FileSystemEntityType.file) {
          files++;
          if (files > (summary['files'] as int)) {
            throw const _ExportFailure('The snapshot file count changed.');
          }
          await _regular(child.path);
          final before = await File(child.path).stat();
          bytes += before.size;
          if (bytes > (summary['sourceBytes'] as int)) {
            throw const _ExportFailure('The snapshot size changed.');
          }
          final input = InputFileStream(child.path, bufferSize: 64 * 1024);
          ZipEntryBody? body;
          try {
            if (input.length != before.size) {
              throw const _ExportFailure('A snapshot file changed.');
            }
            body = encoder.addHeader(
              ArchiveFile.stream(relative, input),
              autoClose: false,
              level: 1,
            );
            while (body?.step() ?? false) {
              // archive 4.6.0 processes at most 64 KiB per step. A timer turn
              // admits cancellation messages even for a single very large file.
              await Future<void>.delayed(Duration.zero);
              cancellation.check();
            }
            body?.finish();
            body = null;
          } finally {
            try {
              body?.cancel();
            } finally {
              input.closeSync();
            }
          }
          final after = await File(child.path).stat();
          if (after.size != before.size || after.modified != before.modified) {
            throw const _ExportFailure(
              'A snapshot file changed while archiving.',
            );
          }
          await Future<void>.delayed(Duration.zero);
        } else {
          throw const _ExportFailure(
            'A snapshot entry is linked or is not a regular file.',
          );
        }
      }
    }

    try {
      await visit(snapshot, const []);
      cancellation.check();
      if (files != summary['files'] ||
          directories != summary['directories'] ||
          bytes != summary['sourceBytes']) {
        throw const _ExportFailure(
          'The snapshot contents no longer match their size summary.',
        );
      }
      // The maintained codec's central-directory finalizer is synchronous:
      // cancellation can wait for up to 100000 entries with 1024-byte paths.
      // This is the one exception to cooperative per-body-chunk cancellation.
      encoder.endEncode();
      await Future<void>.delayed(Duration.zero);
      cancellation.check();
    } finally {
      output.closeSync();
    }
    await Future<void>.delayed(Duration.zero);
    cancellation.check();
    final hash = await _hash(temporary, output.length);
    cancellation.check();
    await File(temporary).rename(archive);
    final marker = <String, Object?>{
      'version': 2,
      'id': request['id'],
      'notebookId': request['notebookId'],
      'notebookName': request['notebookName'],
      'format': request['format'],
      'archive': 'notebook.zip',
      'bytes': output.length,
      'sha256': hash,
      'sourceBytes': bytes,
      'files': files,
      'directories': directories,
      'archiveLimit': summary['archiveLimit'],
    };
    cancellation.check();
    await _publishMarker(directory, 'ready.json', marker);
    // The ready marker is authoritative now. Cancellation or an interrupted
    // snapshot cleanup must never destroy the retryable committed ZIP.
    try {
      await _remove(snapshot);
    } on FileSystemException {
      // Reconciliation retains this owned residue with the ready export.
    } on _ExportFailure {
      // Unsafe residue is surfaced by the next scan, not followed/deleted.
    }
    return _artifact(directory, marker);
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// A fixed-buffer output with an enforced limit before every write, including
/// central-directory output. It never keeps the ZIP body in memory.
class _BoundedZipOutput extends OutputStream {
  _BoundedZipOutput(String path, this.limit)
    : _file = File(path).openSync(mode: FileMode.writeOnly),
      super(byteOrder: ByteOrder.littleEndian);
  final RandomAccessFile _file;
  final int limit;
  final Uint8List _buffer = Uint8List(64 * 1024);
  int _used = 0;
  int _length = 0;
  bool _closed = false;
  @override
  int get length => _length;

  void _reserve(int count) {
    if (_closed || count < 0 || count > limit - _length) {
      throw const _ExportFailure('The ZIP exceeds its reserved output size.');
    }
    _length += count;
  }

  void _flushBuffer() {
    if (_used == 0) return;
    _file.writeFromSync(_buffer, 0, _used);
    _used = 0;
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _buffer[_used++] = value;
    if (_used == _buffer.length) _flushBuffer();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    var at = 0;
    while (at < count) {
      final take = min(count - at, _buffer.length - _used);
      _buffer.setRange(_used, _used + take, bytes, at);
      _used += take;
      at += take;
      if (_used == _buffer.length) _flushBuffer();
    }
  }

  @override
  void writeStream(InputStream stream) {
    final position = stream.position;
    final buffer = Uint8List(64 * 1024);
    try {
      while (!stream.isEOS) {
        final count = stream.readInto(buffer, 0, buffer.length);
        if (count == 0) break;
        writeBytes(buffer, length: count);
      }
    } finally {
      stream.setPosition(position);
    }
  }

  @override
  void flush() => _flushBuffer();

  @override
  void closeSync() {
    if (_closed) return;
    try {
      _flushBuffer();
      _file.flushSync();
    } finally {
      _closed = true;
      _file.closeSync();
    }
  }

  @override
  void clear() => throw UnsupportedError('ZIP output is append-only.');
  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('ZIP output is not buffered in memory.');
}
