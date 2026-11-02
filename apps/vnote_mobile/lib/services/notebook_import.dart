// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';
import 'notebook_import_archive.dart';

enum NotebookImportPhase {
  idle,
  receiving,
  validating,
  prepared,
  publishing,
  finishing,
  reconciling,
}

enum ImportCommitStatus { imported, duplicate, quarantined }

@immutable
class ImportAttempt {
  const ImportAttempt({
    required this.id,
    required this.kind,
    required this.phase,
    this.sourceName,
    this.treeRelative,
    this.inventoryHash,
    this.bytes = 0,
    this.entries = 0,
    this.notebookId,
    this.notebookName,
    this.destination,
  });

  final String id;
  final DocumentImportKind kind;
  // Durable readiness, not a busy flag. Only NotebookImportState.phase denotes
  // activity; a retained receiving attempt has no acknowledged provider copy.
  final NotebookImportPhase phase;
  final String? sourceName;
  final String? treeRelative;
  final String? inventoryHash;
  final int bytes;
  final int entries;
  final String? notebookId;
  final String? notebookName;
  final String? destination;
}

@immutable
class ImportLeftover {
  const ImportLeftover({
    required this.location,
    required this.label,
    required this.reason,
  });

  final String location;
  final String label;
  final String reason;
}

@immutable
class NotebookImportState {
  const NotebookImportState({
    this.phase = NotebookImportPhase.idle,
    this.current,
    this.leftovers = const [],
    this.blockedLocations = const [],
    this.error,
    this.message,
    this.existingNotebookId,
  });

  final NotebookImportPhase phase;
  final ImportAttempt? current;
  final List<ImportLeftover> leftovers;
  final List<String> blockedLocations;
  final String? error;
  final String? message;
  final String? existingNotebookId;

  bool get busy => switch (phase) {
    NotebookImportPhase.receiving ||
    NotebookImportPhase.validating ||
    NotebookImportPhase.publishing ||
    NotebookImportPhase.finishing ||
    NotebookImportPhase.reconciling => true,
    NotebookImportPhase.idle || NotebookImportPhase.prepared => false,
  };

  bool get hasStaging =>
      current != null || leftovers.isNotEmpty || blockedLocations.isNotEmpty;
}

@immutable
class ImportCommitResult {
  const ImportCommitResult({
    required this.status,
    this.notebookId,
    this.notebookName,
    this.destination,
    this.message,
  });

  final ImportCommitStatus status;
  final String? notebookId;
  final String? notebookName;
  final String? destination;
  final String? message;
}

typedef ImportCommitCallback = Future<ImportCommitResult> Function(
  ImportAttempt attempt,
  int cancellationAddress,
);

/// Owns private transfer leases, not core hosts. The library's commit callback
/// must join every core owner before returning, including after publication.
/// No preparation or startup operation invokes that callback implicitly.
class NotebookImporter extends ValueNotifier<NotebookImportState> {
  NotebookImporter({
    required this.root,
    required this.notebooksRoot,
    DocumentTransferPlatform? platform,
    this._checkAdmission,
  }) : _platform = platform ?? MethodChannelDocumentTransferPlatform(),
       super(const NotebookImportState());

  final String root;
  final String notebooksRoot;
  final DocumentTransferPlatform _platform;
  final VoidCallback? _checkAdmission;
  final Set<Future<void>> _workers = {};
  Future<void>? _active;
  Future<void>? _shutdown;
  Future<void>? _providerCancellation;
  int _cancellationAddress = 0;
  String? _providerId;
  bool _initialized = false;
  bool _closing = false;
  bool _disposed = false;

  bool get initialized => _initialized;

  void _publish(NotebookImportState state) {
    if (!_disposed) value = state;
  }

  void _admit() {
    if (_closing || _disposed) throw StateError('Importer is closed.');
    if (_active != null) {
      throw StateError('An import operation is still active.');
    }
  }

  void _requireCurrent(ImportAttempt attempt) {
    if (!identical(value.current, attempt)) {
      throw StateError('This import attempt is no longer current.');
    }
  }

  Future<T> _operation<T>(
    Future<T> Function() body, {
    bool cancellable = false,
  }) async {
    _admit();
    final settled = Completer<void>();
    _active = settled.future;
    try {
      if (cancellable) {
        _cancellationAddress = CoreImportStore.createCancellation();
      }
      return await body();
    } finally {
      // A caller may have started a helper just before its own future failed.
      // Join worker exits as well as replies before freeing the borrowed token.
      while (_workers.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(_workers));
      }
      await _providerCancellation;
      _providerCancellation = null;
      _providerId = null;
      final address = _cancellationAddress;
      _cancellationAddress = 0;
      try {
        if (address != 0) CoreImportStore.freeCancellation(address);
      } finally {
        _active = null;
        settled.complete();
      }
    }
  }

  Future<Map<String, Object?>> _job(
    String command, {
    Map<String, Object?> arguments = const {},
    int cancellationAddress = 0,
  }) {
    final job = _runImportWorker(
      root,
      notebooksRoot,
      command,
      arguments,
      cancellationAddress,
    );
    late final Future<void> joined;
    joined = job
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _workers.remove(joined));
    _workers.add(joined);
    return job;
  }

  /// Executes the closed native command set in a worker. Root arguments are
  /// always supplied by this owner, never by display text or callback input.
  Future<Map<String, Object?>> runStore(
    Map<String, Object?> request, {
    required int cancellationAddress,
  }) {
    if ((_disposed || _closing) && _active == null) {
      throw StateError('Importer is closed.');
    }
    if (cancellationAddress != 0 &&
        cancellationAddress != _cancellationAddress) {
      throw StateError('The import cancellation lease is no longer current.');
    }
    return _job(
      'store',
      arguments: request,
      cancellationAddress: cancellationAddress,
    );
  }

  /// Caller must close/join its previous inspection host first. These paths are
  /// disposable and never the application's normal core app/local namespace.
  Future<void> resetInspection(ImportAttempt attempt) async {
    _requireCurrent(attempt);
    if (_active == null) {
      throw StateError('Inspection requires an admitted import operation.');
    }
    await _job('resetInspection', arguments: {'id': attempt.id});
  }

  void _checkCancelled() {
    if (_cancellationAddress != 0 &&
        CoreImportStore.queryCancellation(_cancellationAddress)) {
      throw const _ImportCancelled();
    }
  }

  NotebookImportState _state(
    Map<String, Object?> scan, {
    String? error,
    String? message,
    String? existingNotebookId,
  }) {
    final current = scan['current'] as Map<String, Object?>?;
    final attempt = current == null ? null : _attempt(current);
    return NotebookImportState(
      phase: attempt?.phase == NotebookImportPhase.prepared
          ? NotebookImportPhase.prepared
          : NotebookImportPhase.idle,
      current: attempt,
      leftovers: List.unmodifiable(
        (scan['leftovers'] as List<Object?>).map((value) {
          final item = value as Map<String, Object?>;
          return ImportLeftover(
            location: item['location'] as String,
            label: item['label'] as String,
            reason: item['reason'] as String,
          );
        }),
      ),
      blockedLocations: List.unmodifiable(
        (scan['blockedLocations'] as List<Object?>).cast<String>(),
      ),
      error: error ?? scan['error'] as String?,
      message: message,
      existingNotebookId: existingNotebookId,
    );
  }

  void _busy(NotebookImportPhase phase) {
    final previous = value;
    _publish(
      NotebookImportState(
        phase: phase,
        current: previous.current,
        leftovers: previous.leftovers,
        blockedLocations: previous.blockedLocations,
      ),
    );
  }

  Future<Map<String, Object?>> _scan({String? preferredId}) async {
    try {
      final result = await _job(
        'scan',
        arguments: {'preferredId': preferredId},
      );
      _initialized = true;
      return result;
    } catch (_) {
      _initialized = false;
      rethrow;
    }
  }

  Future<void> _recoverFailure(Object error, {String? preferredId}) async {
    final cancelled =
        error is _ImportCancelled ||
        (_cancellationAddress != 0 &&
            CoreImportStore.queryCancellation(_cancellationAddress));
    try {
      final scan = await _scan(preferredId: preferredId);
      _publish(
        _state(
          scan,
          error: cancelled ? null : _message(error),
          message: (scan['blockedLocations'] as List<Object?>).isNotEmpty
              ? 'The import requires recovery. Any published copy remains quarantined.'
              : cancelled
              ? 'Import cancelled. Any completed private copy is retained.'
              : 'Private import data is retained for retry or explicit discard.',
        ),
      );
    } catch (_) {
      final previous = value;
      _publish(
        NotebookImportState(
          current: previous.current,
          leftovers: previous.leftovers,
          blockedLocations: List.unmodifiable({
            ...previous.blockedLocations,
            if (preferredId != null) p.join(notebooksRoot, 'nb-$preferredId'),
          }),
          error: 'Import storage could not be reconciled. Publication remains unavailable.',
        ),
      );
    }
  }

  /// No core contexts are opened here. Pending destinations remain quarantined
  /// until the library explicitly admits the normal commit callback.
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _operation(() async {
      _busy(NotebookImportPhase.reconciling);
      try {
        final scan = await _scan();
        _publish(_state(scan));
      } catch (error) {
        final previous = value;
        _publish(
          NotebookImportState(
            current: previous.current,
            leftovers: previous.leftovers,
            blockedLocations: previous.blockedLocations,
            error: _message(error),
          ),
        );
      }
    });
  }

  Future<ImportAttempt?> prepare(DocumentImportKind kind) {
    _admit();
    _checkAdmission?.call();
    if (!_initialized) throw StateError('Initialize import storage first.');
    if (value.hasStaging) {
      throw StateError('Resolve the existing import staging first.');
    }
    return _operation(() async {
      _busy(NotebookImportPhase.receiving);
      String? id;
      try {
        _checkCancelled();
        final request = await _job('allocate', arguments: {'kind': kind.name});
        id = request['id'] as String;
        final attempt = _attempt(request);
        _publish(
          NotebookImportState(
            phase: NotebookImportPhase.receiving,
            current: attempt,
          ),
        );
        await _capture(attempt);
      } catch (error) {
        await _recoverFailure(error, preferredId: id);
      }
      return value.current;
    }, cancellable: true);
  }

  Future<void> _capture(ImportAttempt attempt) async {
    _checkCancelled();
    // Reserve before the provider lease: input, bounded escaped JSONL records
    // for folder entries, and markers. Native adds the shared 64 MiB headroom.
    await runStore({
      'op': 'checkSpace',
      'id': attempt.id,
      'requiredBytes':
          (attempt.kind == DocumentImportKind.zip
              ? 1024 * 1024 * 1024
              : 2 * 1024 * 1024 * 1024 + 100000 * 8192) +
          64 * 1024,
    }, cancellationAddress: _cancellationAddress);
    _checkCancelled();
    await _platform.prepareStorage();
    _checkCancelled();
    _providerId = attempt.id;
    DocumentImportResult result;
    try {
      // Cancellation acknowledgement is advisory. This future is the provider
      // descriptor/security-scope lease and must settle before any cleanup.
      result = await _platform.pickImport(
        operationId: attempt.id,
        scope: DocumentTransferScope.notebook,
        kind: attempt.kind,
      );
    } finally {
      await _providerCancellation;
      _providerCancellation = null;
      _providerId = null;
    }
    if (result.status != DocumentImportStatus.ready) {
      if (result.status == DocumentImportStatus.cancelled) {
        throw const _ImportCancelled();
      }
      throw _ImportFailure(
        result.status == DocumentImportStatus.unavailable
            ? 'System import is unavailable. The private attempt can be retried or discarded.'
            : 'The provider could not complete its private copy. Reselect or discard it.',
      );
    }
    if (result.bytes < 0 ||
        result.entries < 0 ||
        result.entries > 100000 ||
        result.bytes >
            (attempt.kind == DocumentImportKind.zip
                ? 1024 * 1024 * 1024
                : 2 * 1024 * 1024 * 1024)) {
      throw const _ImportFailure(
        'The provider copy exceeds the import limits.',
      );
    }
    // Record a fully closed successful copy even if cancellation raced the
    // provider result. It must not be mistaken for an incomplete copy on retry.
    await runStore({
      'op': 'writeMarker',
      'id': attempt.id,
      'marker': 'captured',
      'data': {
        'version': 1,
        'id': attempt.id,
        'kind': attempt.kind.name,
        'sourceName': _displayName(result.sourceName, attempt.kind),
        'bytes': result.bytes,
        'entries': result.entries,
      },
    }, cancellationAddress: 0);
    _checkCancelled();
    await _extract(attempt.id);
  }

  Future<void> _extract(String id) async {
    _busy(NotebookImportPhase.validating);
    await _job(
      'extract',
      arguments: {'id': id},
      cancellationAddress: _cancellationAddress,
    );
    final cancelled = CoreImportStore.queryCancellation(_cancellationAddress);
    _publish(
      _state(
        await _scan(preferredId: id),
        message: cancelled
            ? 'Import cancelled. The completed prepared copy is retained.'
            : 'Private copy prepared. Validate and import to publish it.',
      ),
    );
  }

  Future<ImportAttempt?> retry(ImportAttempt attempt) {
    _admit();
    _checkAdmission?.call();
    _requireCurrent(attempt);
    return _operation(() async {
      _busy(NotebookImportPhase.reconciling);
      try {
        final recovered = await runStore({
          'op': 'recover',
          'id': attempt.id,
        }, cancellationAddress: 0);
        final phase = recovered['phase'];
        if (phase == 'staged' && recovered['prepared'] != true) {
          _checkCancelled();
          if (recovered['captured'] == true) {
            await _extract(attempt.id);
          } else {
            await _job('resetCapture', arguments: {'id': attempt.id});
            _busy(NotebookImportPhase.receiving);
            await _capture(attempt);
          }
        } else {
          // In particular, a publication intent is not evidence that a rename
          // happened. Only native recover decides between these two outcomes.
          _publish(
            _state(
              await _scan(preferredId: attempt.id),
              message: phase == 'published'
                  ? 'The published copy is quarantined. Validate and finish the import.'
                  : phase == 'committed'
                  ? 'The completed import was recovered.'
                  : 'Private copy prepared. Validate and import to publish it.',
            ),
          );
        }
      } catch (error) {
        await _recoverFailure(error, preferredId: attempt.id);
      }
      return value.current;
    }, cancellable: true);
  }

  Future<ImportCommitResult?> commit(
    ImportAttempt attempt,
    ImportCommitCallback callback,
  ) {
    _admit();
    _checkAdmission?.call();
    _requireCurrent(attempt);
    if (attempt.phase != NotebookImportPhase.prepared &&
        attempt.phase != NotebookImportPhase.finishing) {
      throw StateError('Prepare the captured source before importing it.');
    }
    return _operation(() async {
      _busy(
        attempt.phase == NotebookImportPhase.finishing
            ? NotebookImportPhase.finishing
            : NotebookImportPhase.publishing,
      );
      ImportCommitResult? result;
      Object? failure;
      try {
        result = await callback(attempt, _cancellationAddress);
      } catch (error) {
        failure = error;
      }
      // Never infer rollback from callback failure/cancellation, nor success
      // from its return value. The journal and actual directory identities win.
      try {
        final scan = await _scan(preferredId: attempt.id);
        final committed = (scan['committed'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .where((item) => item['id'] == attempt.id)
            .firstOrNull;
        if (committed != null) {
          result = ImportCommitResult(
            status: ImportCommitStatus.imported,
            notebookId: committed['notebookId'] as String?,
            notebookName: committed['notebookName'] as String?,
            destination: committed['destination'] as String?,
            message: 'Notebook imported.',
          );
          _publish(_state(scan, message: result.message));
          return result;
        }
        final duplicate =
            failure == null &&
            result?.status == ImportCommitStatus.duplicate &&
            result?.notebookId != null &&
            (scan['blockedLocations'] as List<Object?>).isEmpty;
        final cancelled = CoreImportStore.queryCancellation(
          _cancellationAddress,
        );
        const retainedMessage =
            'The import is retained. Any published copy remains quarantined.';
        final message = duplicate
            ? result?.message ?? 'This notebook already exists in the library.'
            : failure == null &&
                  result?.status == ImportCommitStatus.quarantined
            ? result?.message ?? retainedMessage
            : retainedMessage;
        _publish(
          _state(
            scan,
            error: failure == null || cancelled ? null : _message(failure),
            message: message,
            existingNotebookId: duplicate ? result?.notebookId : null,
          ),
        );
        if (duplicate) return result;
        return ImportCommitResult(
          status: ImportCommitStatus.quarantined,
          notebookId: value.current?.notebookId,
          notebookName: value.current?.notebookName,
          destination: value.current?.destination,
          message: message,
        );
      } catch (error) {
        await _recoverFailure(failure ?? error, preferredId: attempt.id);
        return const ImportCommitResult(
          status: ImportCommitStatus.quarantined,
          message:
              'The import outcome requires recovery. No rollback is assumed.',
        );
      }
    }, cancellable: true);
  }

  /// The UI must explicitly confirm this action when a published destination
  /// is shown. Native discard rechecks the journal and directory identity;
  /// committed notebook roots are never deleted, even with allowPublished.
  Future<void> discard(ImportAttempt attempt) {
    _admit();
    _requireCurrent(attempt);
    return _discard('discard', {'id': attempt.id});
  }

  Future<void> discardLeftover(ImportLeftover item) {
    _admit();
    if (!value.leftovers.any((candidate) => identical(candidate, item))) {
      throw StateError('This import cleanup item is no longer current.');
    }
    return _discard('discardLeftover', {'location': item.location});
  }

  Future<void> _discard(String command, Map<String, Object?> arguments) =>
      _operation(() async {
        _busy(NotebookImportPhase.reconciling);
        try {
          await _job(command, arguments: arguments);
          _publish(
            _state(await _scan(), message: 'Private import staging discarded.'),
          );
        } catch (error) {
          await _recoverFailure(error, preferredId: value.current?.id);
        }
      });

  void cancel() {
    final address = _cancellationAddress;
    if (address != 0) CoreImportStore.requestCancellation(address);
    final id = _providerId;
    if (id != null && _providerCancellation == null) {
      // Join this transport before reusing the same durable transaction ID;
      // a delayed cancellation must not cancel the next picker retry.
      _providerCancellation = Future<void>.sync(
        () => _platform.cancelImport(id, scope: DocumentTransferScope.notebook),
      ).catchError((Object _) {});
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();

  Future<void> _close() async {
    _closing = true;
    cancel();
    await _active;
    while (_workers.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_workers));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

class _ImportCancelled implements Exception {
  const _ImportCancelled();
}

class _ImportFailure implements Exception {
  const _ImportFailure(this.message);
  final String message;
}

String _message(Object error) => error is _ImportFailure
    ? error.message
    : error is NotebookImportArchiveException
    ? error.message
    : 'Import could not be completed. Private source bytes are retained.';

String _displayName(String? name, DocumentImportKind kind) {
  final safe = name?.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  if (safe == null || safe.isEmpty || utf8.encode(safe).length > 1024) {
    return kind == DocumentImportKind.zip ? 'ZIP file' : 'Notebook folder';
  }
  return safe;
}

ImportAttempt _attempt(Map<String, Object?> record) => ImportAttempt(
  id: record['id'] as String,
  kind: DocumentImportKind.values.byName(record['kind'] as String),
  phase: record['phase'] == 'published'
      ? NotebookImportPhase.finishing
      : record['prepared'] == true
      ? NotebookImportPhase.prepared
      : record['captured'] == true
      ? NotebookImportPhase.validating
      : NotebookImportPhase.receiving,
  sourceName: record['sourceName'] as String?,
  treeRelative: record['treeRelative'] as String?,
  inventoryHash: record['inventoryHash'] as String?,
  bytes: record['bytes'] as int,
  entries: record['entries'] as int,
  notebookId: record['notebookId'] as String?,
  notebookName: record['notebookName'] as String?,
  destination: record['destination'] as String?,
);

Future<Map<String, Object?>> _runImportWorker(
  String root,
  String notebooksRoot,
  String command,
  Map<String, Object?> arguments,
  int cancellationAddress,
) async {
  final messages = ReceivePort();
  final reply = Completer<Map<String, Object?>>();
  final exited = Completer<void>();
  final subscription = messages.listen((Object? message) {
    if (message is Map<String, Object?>) {
      if (!reply.isCompleted) reply.complete(message);
    } else if (message == null) {
      if (!reply.isCompleted) {
        reply.complete({'error': 'The import worker stopped unexpectedly.'});
      }
      if (!exited.isCompleted) exited.complete();
    } else if (message is List && !reply.isCompleted) {
      reply.complete({'error': 'The import worker stopped unexpectedly.'});
    }
  });
  try {
    await Isolate.spawn(
      _importWorker,
      (
        messages.sendPort,
        root,
        notebooksRoot,
        command,
        arguments,
        cancellationAddress,
      ),
      onExit: messages.sendPort,
      onError: messages.sendPort,
      errorsAreFatal: true,
    );
    final response = await reply.future;
    await exited.future;
    if (response['cancelled'] == true) throw const _ImportCancelled();
    if (response['error'] case final String error) throw _ImportFailure(error);
    return response['result'] as Map<String, Object?>;
  } finally {
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _importWorker(
  (SendPort, String, String, String, Map<String, Object?>, int) request,
) async {
  final (reply, root, notebooksRoot, command, arguments, cancellation) =
      request;
  Map<String, Object?> response;
  try {
    final store = _ImportStore(root, notebooksRoot);
    final result = switch (command) {
      'store' => store.run(arguments, cancellation),
      'scan' => await store.scan(arguments['preferredId'] as String?),
      'allocate' => await store.allocate(arguments['kind'] as String),
      'resetCapture' => await store.resetCapture(arguments['id'] as String),
      'extract' => await store.extract(arguments['id'] as String, cancellation),
      'resetInspection' => await store.resetInspection(
        arguments['id'] as String,
      ),
      'discard' => store.run({
        'op': 'discard',
        'id': arguments['id'],
        'allowPublished': true,
      }, 0),
      'discardLeftover' => await store.discardLeftover(
        arguments['location'] as String,
      ),
      _ => throw const _ImportFailure('Unsupported import operation.'),
    };
    response = {'result': result};
  } catch (error) {
    response =
        cancellation != 0 && CoreImportStore.queryCancellation(cancellation)
        ? {'cancelled': true}
        : {'error': _message(error)};
  }
  Isolate.exit(reply, response);
}

final _transactionId = RegExp(r'^[0-9a-f]{32}$');
final _inventoryHash = RegExp(r'^[0-9a-f]{64}$');

bool _samePath(String left, String right) {
  final a = p.normalize(left);
  final b = p.normalize(right);
  return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
}

class _ImportStore {
  _ImportStore(this.root, this.notebooksRoot);

  final String root;
  final String notebooksRoot;

  Map<String, Object?> run(Map<String, Object?> request, int cancellation) =>
      CoreImportStore.run({
        ...request,
        'importsRoot': root,
        'notebooksRoot': notebooksRoot,
      }, cancellationAddress: cancellation);

  Future<void> validateRoot({bool create = false}) async {
    if (!p.isAbsolute(root) ||
        p.normalize(root) != root ||
        !p.isAbsolute(notebooksRoot) ||
        p.normalize(notebooksRoot) != notebooksRoot ||
        p.basename(root) != 'imports' ||
        p.basename(notebooksRoot) != 'notebooks' ||
        !_samePath(p.dirname(root), p.dirname(notebooksRoot)) ||
        _samePath(root, notebooksRoot) ||
        p.isWithin(root, notebooksRoot) ||
        p.isWithin(notebooksRoot, root)) {
      throw const _ImportFailure(
        'Import storage must use separate canonical private directories.',
      );
    }
    if (create &&
        await FileSystemEntity.type(root, followLinks: false) ==
            FileSystemEntityType.notFound) {
      await _directory(p.dirname(root));
      await Directory(root).create();
    }
    await _directory(root);
    await _directory(notebooksRoot);
  }

  Future<void> _directory(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_samePath(await Directory(path).resolveSymbolicLinks(), path)) {
      throw const _ImportFailure(
        'Import storage is linked, changed, or unavailable.',
      );
    }
  }

  String _child(String location) {
    if (!p.isAbsolute(location) ||
        p.normalize(location) != location ||
        !_samePath(p.dirname(location), root) ||
        _samePath(location, root)) {
      throw const _ImportFailure(
        'Cleanup is restricted to a direct private import child.',
      );
    }
    return location;
  }

  String _transaction(String id) {
    if (!_transactionId.hasMatch(id)) {
      throw const _ImportFailure('Invalid import ownership identifier.');
    }
    return _child(p.join(root, id));
  }

  String _destination(String id) => p.join(notebooksRoot, 'nb-$id');

  Map<String, Object?> _recover(String id) {
    final result = run({'op': 'recover', 'id': id}, 0);
    final phase = result['phase'];
    final tree = result['treeRelative'];
    final hash = result['inventoryHash'];
    if (result['id'] != id ||
        !const ['zip', 'folder'].contains(result['kind']) ||
        !const ['staged', 'published', 'committed'].contains(phase) ||
        result['captured'] is! bool ||
        result['prepared'] is! bool ||
        result['bytes'] is! int ||
        (result['bytes'] as int) < 0 ||
        result['entries'] is! int ||
        (result['entries'] as int) < 0 ||
        (result['destination'] != null &&
            result['destination'] != _destination(id)) ||
        (result['prepared'] == true &&
            (result['captured'] != true ||
                tree is! String ||
                !(tree == 'unpacked' ||
                    (tree.startsWith('unpacked/') &&
                        tree.split('/').length == 2 &&
                        !const ['', '.', '..'].contains(tree.split('/').last) &&
                        !tree.contains('\\'))) ||
                hash is! String ||
                !_inventoryHash.hasMatch(hash))) ||
        (phase != 'staged' &&
            (result['prepared'] != true ||
                result['destination'] != _destination(id) ||
                result['notebookId'] is! String ||
                (result['notebookId'] as String).isEmpty ||
                result['notebookName'] is! String))) {
      throw const _ImportFailure(
        'Import recovery returned an invalid ownership record.',
      );
    }
    return result;
  }

  Future<String?> _sourceName(String id) async {
    try {
      final path = p.join(_transaction(id), 'captured.json');
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          !_samePath(await File(path).resolveSymbolicLinks(), path)) {
        return null;
      }
      final file = File(path).openSync();
      try {
        if (file.lengthSync() > 16 * 1024) return null;
        final marker = jsonDecode(utf8.decode(file.readSync(16 * 1024 + 1)));
        if (marker is! Map || marker['id'] != id || marker['version'] != 1) {
          return null;
        }
        return marker['sourceName'] is String
            ? marker['sourceName'] as String
            : null;
      } finally {
        file.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> scan(String? preferredId) async {
    await validateRoot(create: true);
    final retained = <Map<String, Object?>>[];
    final leftovers = <Map<String, Object?>>[];
    final blocked = <String>{};
    final committed = <Map<String, Object?>>[];
    // Finish enumeration before retiring any receipt. An enumeration failure
    // must not lose a committed result after this scan has erased its receipt.
    final children = await Directory(root).list(followLinks: false).toList();
    for (final entity in children) {
      final location = _child(entity.path);
      final id = p.basename(location);
      try {
        _transaction(id);
        await _directory(location);
        final recovered = _recover(id);
        if (recovered['phase'] == 'committed') {
          committed.add(recovered);
          try {
            // A valid receipt permits private cleanup after legitimate edits.
            // Native discard never replays input or deletes committed roots.
            run({'op': 'discard', 'id': id}, 0);
          } catch (_) {
            String? residue = location;
            try {
              if (await FileSystemEntity.type(location, followLinks: false) ==
                  FileSystemEntityType.notFound) {
                final retired = p.join(root, 'done-$id');
                residue =
                    await FileSystemEntity.type(retired, followLinks: false) ==
                        FileSystemEntityType.notFound
                    ? null
                    : retired;
              }
            } catch (_) {
              // Keep a private cleanup item if its current location is unknown.
            }
            if (residue != null) {
              leftovers.add({
                'location': residue,
                'label': p.basename(residue),
                'reason': 'Completed import has private cleanup remaining. Its notebook is not deleted by cleanup.',
              });
            }
          }
        } else {
          retained.add({
            ...recovered,
            'sourceName': recovered['sourceName'] ?? await _sourceName(id),
          });
          if (recovered['phase'] == 'published') blocked.add(_destination(id));
        }
      } catch (_) {
        if (_transactionId.hasMatch(id)) blocked.add(_destination(id));
        leftovers.add({
          'location': location,
          'label': id,
          'reason': 'Unrecognized, incomplete, or ambiguous private import data. No live notebook deletion is authorized.',
        });
      }
    }
    retained.sort((a, b) {
      final aPreferred = a['id'] == preferredId;
      final bPreferred = b['id'] == preferredId;
      if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
      final aPublished = a['phase'] == 'published';
      final bPublished = b['phase'] == 'published';
      if (aPublished != bPublished) return aPublished ? -1 : 1;
      return (a['id'] as String).compareTo(b['id'] as String);
    });
    for (final extra in retained.skip(1)) {
      leftovers.add({
        'location': _transaction(extra['id'] as String),
        'label': extra['id'],
        'reason': extra['phase'] == 'published'
            ? 'Another published import is quarantined. Resolve the current attempt to recover it.'
            : 'Another private import is retained. Resolve the current attempt or explicitly discard this copy.',
      });
    }
    leftovers.sort(
      (a, b) => (a['label'] as String).compareTo(b['label'] as String),
    );
    return {
      'current': retained.isEmpty ? null : retained.first,
      'leftovers': leftovers,
      'blockedLocations': blocked.toList()..sort(),
      'committed': committed,
      'error': leftovers.isEmpty
          ? null
          : 'Some import staging requires explicit cleanup or recovery.',
    };
  }

  Future<Map<String, Object?>> allocate(String kind) async {
    await validateRoot();
    if (!const ['zip', 'folder'].contains(kind)) {
      throw const _ImportFailure('Unsupported import source kind.');
    }
    if (!await Directory(root).list(followLinks: false).isEmpty) {
      throw const _ImportFailure(
        'Existing import staging must be resolved first.',
      );
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final location = _transaction(id);
    if (await FileSystemEntity.type(location, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _ImportFailure(
        'Import staging already exists. Nothing was replaced.',
      );
    }
    await Directory(location).create();
    run({
      'op': 'writeMarker',
      'id': id,
      'marker': 'request',
      'data': {'version': 1, 'id': id, 'kind': kind},
    }, 0);
    return _recover(id);
  }

  Future<Map<String, Object?>> resetCapture(String id) async {
    await validateRoot();
    final recovered = _recover(id);
    if (recovered['phase'] != 'staged' || recovered['captured'] == true) {
      throw const _ImportFailure(
        'An acknowledged source cannot be replaced by a picker retry.',
      );
    }
    final transaction = _transaction(id);
    for (final name in ['input.zip', 'unpacked', 'accepted.jsonl']) {
      await _remove(p.join(transaction, name));
    }
    return {};
  }

  Future<Map<String, Object?>> extract(String id, int cancellation) async {
    await validateRoot();
    final recovered = _recover(id);
    if (recovered['phase'] != 'staged' ||
        recovered['captured'] != true ||
        recovered['prepared'] == true) {
      throw const _ImportFailure(
        'Only an acknowledged private source can be prepared.',
      );
    }
    final transaction = _transaction(id);
    final kind = DocumentImportKind.values.byName(recovered['kind'] as String);
    if (kind == DocumentImportKind.zip) {
      await _remove(p.join(transaction, 'unpacked'));
    }
    for (final name in ['inventory.jsonl', 'inventory.jsonl.tmp']) {
      await _remove(p.join(transaction, name));
    }
    if (CoreImportStore.queryCancellation(cancellation)) {
      throw const _ImportCancelled();
    }
    final prepared = await NotebookImportArchive.prepare(
      transactionRoot: transaction,
      kind: kind,
      scope: DocumentTransferScope.notebook,
      format: ImportPreparationFormat.notebook,
      cancellationAddress: cancellation,
    );
    // The archive worker has closed all files. Preserve completed preparation
    // durably even if cancellation arrives after its last streamed boundary.
    run({
      'op': 'writeMarker',
      'id': id,
      'marker': 'prepared',
      'data': {
        'version': 1,
        'id': id,
        'kind': kind.name,
        'treeRelative': prepared.treeRelative,
        'inventoryHash': prepared.inventoryHash,
        'bytes': prepared.bytes,
        'entries': prepared.entries,
      },
    }, 0);
    return _recover(id);
  }

  Future<Map<String, Object?>> resetInspection(String id) async {
    await validateRoot();
    final transaction = _transaction(id);
    await _directory(transaction);
    final inspection = p.join(transaction, 'inspection');
    await _remove(inspection);
    await Directory(p.join(inspection, 'app')).create(recursive: true);
    await Directory(p.join(inspection, 'local')).create();
    return {};
  }

  Future<Map<String, Object?>> discardLeftover(String location) async {
    await validateRoot();
    _child(location);
    final id = p.basename(location);
    if (_transactionId.hasMatch(id)) {
      try {
        // This also permits cleaning a valid committed receipt whose target
        // has subsequently gone missing. It cannot remove a published target.
        run({'op': 'discard', 'id': id}, 0);
        return {};
      } catch (_) {
        if (await FileSystemEntity.type(_destination(id), followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const _ImportFailure(
            'Private cleanup cannot forget an unresolved live destination. Recover its ownership first.',
          );
        }
      }
    }
    await _remove(location);
    return {};
  }

  Future<void> _remove(String path) async {
    // Never recursive:true: a symbolic link is unlinked, never traversed.
    await validateRoot();
    if (!p.isWithin(root, path) || p.normalize(path) != path) {
      throw const _ImportFailure('Import cleanup encountered an unsafe path.');
    }
    await _directory(p.dirname(path));
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await _directory(path);
      await for (final child in Directory(path).list(followLinks: false)) {
        if (!_samePath(p.dirname(child.path), path)) {
          throw const _ImportFailure(
            'Import cleanup encountered an unsafe path.',
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
}
