// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';
import 'notebook_import_archive.dart';

enum TransferStage {
  receiving,
  captured,
  source,
  prepared,
  intent,
  committed,
  exportReady,
  quarantined,
}

@immutable
class TransferLeftover {
  const TransferLeftover({
    required this.location,
    required this.label,
    required this.reason,
    this.notebookId,
    this.notebookRelative,
    this.canDiscard = false,
  });
  final String location;
  final String label;
  final String reason;
  final String? notebookId;
  final String? notebookRelative;
  final bool canDiscard;
}

class TransferFailure implements Exception {
  const TransferFailure(this.message);
  final String message;
}

class TransferCancelled implements Exception {
  const TransferCancelled();
}

/// The cancellation token is borrowed only until the admitted operation and all
/// filesystem workers exit. Core callbacks must drain their owner before return.
class TransferCancellation {
  TransferCancellation._(this._address);
  final int _address;
  bool _cancelled = false;
  VoidCallback? _onCancel;
  bool get isCancelled => _cancelled;
  set onCancel(VoidCallback? value) {
    _onCancel = value;
    if (_cancelled) _notify();
  }

  void check() {
    if (_cancelled) throw const TransferCancelled();
  }

  void _notify() {
    try {
      _onCancel?.call();
    } catch (_) {
      // A retired owner may reject the advisory cancellation. Still join it.
    }
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    CoreImportStore.requestCancellation(_address);
    _notify();
  }
}

String transferError(Object error) => switch (error) {
  TransferFailure(:final message) => message,
  NotebookImportArchiveException(:final message) => message,
  CoreException(:final message) => message,
  _ => 'Transfer could not be completed. Private bytes and any uncertain live outcome are retained.',
};

String newTransferId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool validTransferId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

String transferSourceName(String? value, DocumentImportKind kind) {
  final safe = value?.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  return safe != null && safe.isNotEmpty && utf8.encode(safe).length <= 1024
      ? safe
      : switch (kind) {
          DocumentImportKind.zip => 'ZIP file',
          DocumentImportKind.folder => 'Folder',
          DocumentImportKind.file => 'File',
          DocumentImportKind.image => 'Image',
        };
}

TransferStage transferStage(Map<String, Object?> state) =>
    switch (state['phase']) {
      'allocated' => TransferStage.receiving,
      'captured' => TransferStage.captured,
      'source' || 'built' => TransferStage.source,
      'prepared' => TransferStage.prepared,
      'pending' => TransferStage.intent,
      'committed' => TransferStage.committed,
      'exportReady' => TransferStage.exportReady,
      'quarantined' => TransferStage.quarantined,
      _ => throw const FormatException('Unknown transfer phase.'),
    };

/// A library-owned ledger call; the returned future includes worker exit.
/// A nonzero cancellation address remains caller-owned until this settles.
Future<Map<String, Object?>> runTransferStore(
  Map<String, Object?> request, {
  int cancellationAddress = 0,
}) => _runWorker('store', request, cancellationAddress);

/// Shared lease mechanics only; durable decisions belong to each native store.
abstract class TransferController<S> extends ValueNotifier<S> {
  TransferController(
    super.value, {
    required this.root,
    required this.notebooksRoot,
    required this.scope,
    required void Function(Object) reserveTransfer,
    required void Function(Object) releaseTransfer,
    DocumentTransferPlatform? platform,
  }) : _reserve = reserveTransfer,
       _release = releaseTransfer,
       platform = platform ?? const MethodChannelDocumentTransferPlatform();

  final String root;
  final String notebooksRoot;
  final DocumentTransferScope scope;
  final DocumentTransferPlatform platform;
  final void Function(Object) _reserve;
  final void Function(Object) _release;
  final Set<Future<void>> _workers = {};
  Future<void>? _active;
  Future<void>? _shutdown;
  Future<void>? _providerCancellation;
  String? _providerId;
  bool _providerSaving = false;
  bool _closing = false;
  TransferCancellation get recoveryCancellation => TransferCancellation._(0);
  bool _disposed = false;
  bool _reserved = false;
  bool initialized = false;
  TransferCancellation? _cancellation;
  bool get hasStaging;
  TransferCancellation get cancellation => _cancellation!;

  void publish(S state) {
    if (!_disposed) value = state;
  }

  void admit({bool needsInitialization = true}) {
    if (_closing || _disposed) {
      throw StateError('Transfer controller is closed.');
    }
    if (_active != null) throw StateError('A transfer lease is still active.');
    if (needsInitialization && !initialized) {
      throw StateError('Initialize transfer storage first.');
    }
  }

  /// Synchronous reservation precedes token allocation, providers and workers.
  Future<T> operation<T>(Future<T> Function() body, {bool scanning = false}) {
    admit(needsInitialization: !scanning);
    if (!scanning) {
      _reserve(this);
      _reserved = true;
    }
    final settled = Completer<void>();
    _active = settled.future;
    return _execute(body, settled);
  }

  Future<T> _execute<T>(
    Future<T> Function() body,
    Completer<void> settled,
  ) async {
    try {
      _cancellation = TransferCancellation._(
        CoreImportStore.createCancellation(),
      );
      return await body();
    } finally {
      while (_workers.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(_workers));
      }
      await _providerCancellation;
      _providerCancellation = null;
      _providerId = null;
      final token = _cancellation;
      _cancellation = null;
      try {
        if (token != null) {
          token.onCancel = null;
          CoreImportStore.freeCancellation(token._address);
        }
        if (hasStaging && !_reserved) {
          _reserve(this);
          _reserved = true;
        } else if (!hasStaging && _reserved) {
          _reserved = false;
          _release(this);
        }
      } finally {
        _active = null;
        settled.complete();
      }
    }
  }

  Future<Map<String, Object?>> store(
    String op, {
    String? id,
    Map<String, Object?> arguments = const {},
    bool cancellable = false,
  }) => _worker('store', {
    ...arguments,
    'op': op,
    'scope': scope.name,
    'root': root,
    'notebooksRoot': notebooksRoot,
    'id': id ?? '00000000000000000000000000000000',
  }, cancellable ? cancellation._address : 0);

  Future<Map<String, Object?>> prepareSource(
    String id,
    DocumentImportKind kind,
  ) => _worker('source', {
    'transactionRoot': p.join(root, id),
    'scope': scope.name,
    'kind': kind.name,
  }, cancellation._address);

  Future<Map<String, Object?>> _worker(
    String command,
    Map<String, Object?> request,
    int address,
  ) {
    if (_active == null) {
      throw StateError('Filesystem work requires an admitted lease.');
    }
    final job = _runWorker(command, request, address);
    late final Future<void> joined;
    joined = job
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _workers.remove(joined));
    _workers.add(joined);
    return job;
  }

  Future<DocumentImportResult> pick(String id, DocumentImportKind kind) async {
    cancellation.check();
    final maximum = switch (kind) {
      DocumentImportKind.zip => (1 << 30) + (128 << 10),
      DocumentImportKind.folder => (2 << 30) + 100000 * 8192 + (128 << 10),
      DocumentImportKind.file ||
      DocumentImportKind.image => (256 << 20) + (128 << 10),
    };
    await store(
      'checkSpace',
      id: id,
      arguments: {'requiredBytes': maximum},
      cancellable: true,
    );
    cancellation.check();
    await platform.prepareStorage();
    cancellation.check();
    _providerId = id;
    _providerSaving = false;
    try {
      return await platform.pickImport(
        operationId: id,
        scope: scope,
        kind: kind,
      );
    } finally {
      await _providerCancellation;
      _providerCancellation = null;
      _providerId = null;
    }
  }

  Future<DocumentExportResult> saveSnapshot(
    String id,
    CoreResourceExport snapshot,
  ) async {
    cancellation.check();
    await platform.prepareStorage();
    cancellation.check();
    _providerId = id;
    _providerSaving = true;
    try {
      return await platform.save(
        operationId: id,
        scope: scope,
        path: snapshot.path,
        suggestedName: snapshot.name,
      );
    } finally {
      await _providerCancellation;
      _providerCancellation = null;
      _providerId = null;
    }
  }

  void cancel() {
    _cancellation?._cancel();
    final id = _providerId;
    if (id != null && _providerCancellation == null) {
      _providerCancellation = Future<void>.sync(
        () => _providerSaving
            ? platform.cancel(id, scope: scope)
            : platform.cancelImport(id, scope: scope),
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

Future<Map<String, Object?>> _runWorker(
  String command,
  Map<String, Object?> request,
  int address,
) async {
  final messages = ReceivePort();
  final reply = Completer<Map<String, Object?>>();
  final exited = Completer<void>();
  final subscription = messages.listen((Object? message) {
    if (message is Map<String, Object?>) {
      if (!reply.isCompleted) reply.complete(message);
    } else if (message == null) {
      if (!reply.isCompleted) {
        reply.complete({'error': 'Transfer worker exited without a result.'});
      }
      if (!exited.isCompleted) exited.complete();
    } else if (message is List && !reply.isCompleted) {
      reply.complete({'error': 'Transfer worker stopped unexpectedly.'});
    }
  });
  try {
    await Isolate.spawn(
      _transferWorker,
      (messages.sendPort, command, request, address),
      onExit: messages.sendPort,
      onError: messages.sendPort,
      errorsAreFatal: true,
    );
    final response = await reply.future;
    await exited.future;
    if (response['cancelled'] == true) throw const TransferCancelled();
    if (response['error'] case final String error) throw TransferFailure(error);
    return Map<String, Object?>.from(response['result'] as Map);
  } finally {
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _transferWorker(
  (SendPort, String, Map<String, Object?>, int) input,
) async {
  final (reply, command, request, address) = input;
  Map<String, Object?> response;
  try {
    final Map<String, Object?> result;
    if (command == 'store') {
      result = CoreImportStore.runTransfer(
        request,
        cancellationAddress: address,
      );
    } else if (command == 'source') {
      final prepared = await NotebookImportArchive.prepare(
        transactionRoot: request['transactionRoot'] as String,
        scope: DocumentTransferScope.values.byName(request['scope'] as String),
        format: ImportPreparationFormat.files,
        kind: DocumentImportKind.values.byName(request['kind'] as String),
        cancellationAddress: address,
      );
      result = {
        'treeRelative': prepared.treeRelative,
        'inventoryHash': prepared.inventoryHash,
        'bytes': prepared.bytes,
        'entries': prepared.entries,
      };
    } else {
      throw const TransferFailure('Unsupported transfer worker command.');
    }
    response = {'result': result};
  } catch (error) {
    response = address != 0 && CoreImportStore.queryCancellation(address)
        ? {'cancelled': true}
        : {'error': transferError(error)};
  }
  Isolate.exit(reply, response);
}
