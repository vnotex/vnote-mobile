// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';
import 'transfer_worker.dart';

export 'transfer_worker.dart'
    show TransferCancellation, TransferStage, TransferLeftover;

enum ResourceOperation { add, image, track, untrack, rename, remove, export }

enum ResourceTransferPhase {
  idle,
  receiving,
  preparing,
  applying,
  recovering,
  listing,
  saving,
  discarding,
}

@immutable
class ResourceTarget {
  const ResourceTarget({
    required this.notebookId,
    required this.nodeId,
    required this.notebookRelative,
  });
  final String notebookId;
  final String nodeId;
  final String notebookRelative;
  Map<String, Object?> marker(String id) => {
    'version': 1,
    'id': id,
    'notebookId': notebookId,
    'nodeId': nodeId,
    'notebookRelative': notebookRelative,
  };
}

@immutable
class ResourceAttempt {
  const ResourceAttempt({
    required this.id,
    required this.target,
    required this.operation,
    required this.name,
    required this.stage,
    required this.transactionRoot,
    this.newName,
    this.sourceName,
    this.bytes = 0,
    this.entries = 0,
  });
  final String id;
  final ResourceTarget target;
  final ResourceOperation operation;
  final String name;
  final String? newName;
  final TransferStage stage;
  final String transactionRoot;
  final String? sourceName;
  final int bytes;
  final int entries;
  DocumentImportKind get kind => operation == ResourceOperation.image
      ? DocumentImportKind.image
      : DocumentImportKind.file;
}

@immutable
class ResourceTransferState {
  const ResourceTransferState({
    this.phase = ResourceTransferPhase.idle,
    this.current,
    this.attempts = const [],
    this.leftovers = const [],
    this.blockedNotebookIds = const [],
    this.blockedNotebookRelatives = const [],
    this.blocksAllNotebooks = false,
    this.listing,
    this.lastResult,
    this.export,
    this.externalMayBeIncomplete = false,
    this.error,
    this.message,
  });
  final ResourceTransferPhase phase;
  final ResourceAttempt? current;
  final List<ResourceAttempt> attempts;
  final List<TransferLeftover> leftovers;
  final List<String> blockedNotebookIds;
  final List<String> blockedNotebookRelatives;
  final bool blocksAllNotebooks;
  final CoreResourceListing? listing;
  final CoreResourceResult? lastResult;
  final CoreResourceExport? export;
  final bool externalMayBeIncomplete;
  final String? error;
  final String? message;
  bool get busy => phase != ResourceTransferPhase.idle;
  bool get hasStaging =>
      attempts.isNotEmpty || leftovers.isNotEmpty || blocksAllNotebooks;
}

typedef ResourceApplyCallback = Future<CoreResourceResult> Function(
  ResourceAttempt attempt,
  TransferCancellation cancellation,
  bool recover,
);
typedef ResourceExportCallback = Future<CoreResourceExport> Function(
  ResourceAttempt attempt,
  TransferCancellation cancellation,
);
typedef ResourceListCallback = Future<CoreResourceListing> Function(
  ResourceTarget target,
  TransferCancellation cancellation,
);

const _externalWarning =
    'A previous external copy may have completed or may be incomplete. Save As creates another chosen copy.';

/// The private source and export snapshot outlive provider/core failures. A
/// requested operation is durable before capture; only native dispatch records
/// authorize recovery, never a Dart exception or missing desired filename.
class ResourceTransfer extends TransferController<ResourceTransferState> {
  ResourceTransfer({
    required super.root,
    required super.notebooksRoot,
    required super.reserveTransfer,
    required super.releaseTransfer,
    super.platform,
  }) : super(
         const ResourceTransferState(),
         scope: DocumentTransferScope.resource,
       );

  @override
  bool get hasStaging => value.hasStaging;

  void _require(ResourceAttempt attempt) {
    if (!identical(value.current, attempt)) {
      throw StateError('This resource attempt is no longer current.');
    }
  }

  void _state({
    ResourceTransferPhase phase = ResourceTransferPhase.idle,
    CoreResourceResult? result,
    CoreResourceExport? snapshot,
    bool? externalMayBeIncomplete,
    String? error,
    String? message,
  }) {
    final old = value;
    publish(
      ResourceTransferState(
        phase: phase,
        current: old.current,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
        listing: old.listing,
        lastResult: result ?? old.lastResult,
        export: snapshot ?? old.export,
        externalMayBeIncomplete:
            externalMayBeIncomplete ?? old.externalMayBeIncomplete,
        error: error,
        message: message,
      ),
    );
  }

  void select(ResourceAttempt attempt) {
    admit();
    if (!value.attempts.any((item) => identical(item, attempt))) {
      throw StateError('This resource attempt is no longer retained.');
    }
    final old = value;
    publish(
      ResourceTransferState(
        current: attempt,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
        listing: _matchesListing(attempt.target, old.listing)
            ? old.listing
            : null,
        externalMayBeIncomplete: attempt.stage == TransferStage.exportReady,
      ),
    );
  }

  bool _matchesListing(ResourceTarget target, CoreResourceListing? listing) =>
      listing != null &&
      listing.notebookId == target.notebookId &&
      listing.nodeId == target.nodeId;

  /// Library can refresh on the SAME note owner in an apply callback's finally.
  /// An unrelated/retired target cannot replace the visible resource listing.
  void setListing(ResourceTarget target, CoreResourceListing listing) {
    if (!_matchesListing(target, listing)) {
      throw StateError('The resource listing belongs to a different target.');
    }
    final current = value.current;
    if (current != null &&
        (current.target.notebookId != target.notebookId ||
            current.target.nodeId != target.nodeId)) {
      throw StateError('The resource target is no longer current.');
    }
    final old = value;
    publish(
      ResourceTransferState(
        phase: old.phase,
        current: old.current,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
        listing: listing,
        lastResult: old.lastResult,
        export: old.export,
        externalMayBeIncomplete: old.externalMayBeIncomplete,
        error: old.error,
        message: old.message,
      ),
    );
  }

  void clearListing(ResourceTarget target) {
    final old = value;
    if (old.listing != null && !_matchesListing(target, old.listing)) {
      throw StateError('The resource listing belongs to a different target.');
    }
    _clearListing();
  }

  void _clearListing() {
    final old = value;
    publish(
      ResourceTransferState(
        phase: old.phase,
        current: old.current,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
        lastResult: old.lastResult,
        export: old.export,
        externalMayBeIncomplete: old.externalMayBeIncomplete,
        error: old.error,
        message: old.message,
      ),
    );
  }

  Future<void> _scan({
    String? preferredId,
    String? error,
    String? message,
    CoreResourceResult? result,
    CoreResourceExport? snapshot,
    bool? externalMayBeIncomplete,
  }) async {
    final scan = await store('scan');
    final attempts = <ResourceAttempt>[];
    final leftovers = <TransferLeftover>[];
    for (final raw in scan['entries'] as List) {
      final record = Map<String, Object?>.from(raw as Map);
      try {
        attempts.add(_attempt(record));
      } catch (_) {
        final id = record['id'];
        final privateAllocation =
            validTransferId(id) &&
            record['scope'] == 'resource' &&
            record['phase'] == 'allocated' &&
            record['intent'] == false &&
            record['target'] is Map &&
            record['operation'] == null;
        leftovers.add(
          TransferLeftover(
            location: id is String && p.basename(id) == id
                ? p.join(root, id)
                : root,
            label: privateAllocation
                ? 'Interrupted resource allocation'
                : 'Unrecognized resource staging',
            reason: privateAllocation
                ? 'No mutation was dispatched. Explicitly discard this private allocation.'
                : 'Ownership or recovery records are invalid. Live destinations cannot safely be ruled out.',
            canDiscard: privateAllocation,
          ),
        );
      }
    }
    final selectedId = preferredId ?? value.current?.id;
    final current =
        attempts.where((item) => item.id == selectedId).firstOrNull ??
        attempts.firstOrNull;
    final same = current != null && current.id == value.current?.id;
    final outcomeMatches = current != null && current.id == preferredId;
    final blocked = attempts.where(
      (item) =>
          item.stage == TransferStage.intent ||
          item.stage == TransferStage.quarantined,
    );
    initialized = true;
    publish(
      ResourceTransferState(
        current: current,
        attempts: List.unmodifiable(attempts),
        leftovers: List.unmodifiable(leftovers),
        blockedNotebookIds: List.unmodifiable(
          blocked.map((item) => item.target.notebookId).toSet(),
        ),
        blockedNotebookRelatives: List.unmodifiable(
          blocked.map((item) => item.target.notebookRelative).toSet(),
        ),
        blocksAllNotebooks: leftovers.any((item) => !item.canDiscard),
        listing:
            current == null || _matchesListing(current.target, value.listing)
            ? value.listing
            : null,
        lastResult:
            (outcomeMatches ? result : null) ??
            (same ? value.lastResult : null),
        export:
            (outcomeMatches ? snapshot : null) ?? (same ? value.export : null),
        externalMayBeIncomplete:
            (outcomeMatches ? externalMayBeIncomplete : null) ??
            (same
                ? value.externalMayBeIncomplete
                : current?.stage == TransferStage.exportReady),
        error: error,
        message:
            message ??
            (current?.stage == TransferStage.exportReady
                ? _externalWarning
                : null),
      ),
    );
  }

  ResourceAttempt _attempt(Map<String, Object?> record) {
    if (!validTransferId(record['id']) || record['scope'] != 'resource') {
      throw const FormatException();
    }
    final id = record['id'] as String;
    final target = Map<String, Object?>.from(record['target'] as Map);
    if (target['version'] != 1 || target['id'] != id || target.length != 5) {
      throw const FormatException();
    }
    final relative = target['notebookRelative'] as String;
    if (relative.isEmpty ||
        relative == '.' ||
        relative == '..' ||
        p.basename(relative) != relative ||
        relative.contains('\\') ||
        relative.contains('/')) {
      throw const FormatException();
    }
    final operation = ResourceOperation.values.byName(
      record['operation'] as String,
    );
    final name = record['name'] as String;
    final newName = record['newName'] as String?;
    final kind = record['kind'];
    if (name.isEmpty ||
        (operation == ResourceOperation.rename) != (newName != null) ||
        kind != (operation == ResourceOperation.image ? 'image' : 'file')) {
      throw const FormatException();
    }
    final bytes = record['bytes'] as int;
    final entries = record['entries'] as int;
    if (bytes < 0 || bytes > (1 << 30) || entries < 0 || entries > 1) {
      throw const FormatException();
    }
    return ResourceAttempt(
      id: id,
      target: ResourceTarget(
        notebookId: target['notebookId'] as String,
        nodeId: target['nodeId'] as String,
        notebookRelative: relative,
      ),
      operation: operation,
      name: name,
      newName: newName,
      stage: transferStage(record),
      transactionRoot: p.join(root, id),
      sourceName: record['sourceName'] as String?,
      bytes: bytes,
      entries: entries,
    );
  }

  Future<void> _failure(Object error, {String? id}) async {
    final cancelled = error is TransferCancelled || cancellation.isCancelled;
    try {
      await _scan(
        preferredId: id,
        error: cancelled ? null : transferError(error),
        message: cancelled
            ? 'Cancelled. Private bytes and any uncertain live outcome are retained.'
            : 'Retained for recovery. No copy, move or link is replayed after an uncertain dispatch.',
      );
    } catch (_) {
      initialized = false;
      final old = value;
      publish(
        ResourceTransferState(
          current: old.current,
          attempts: old.attempts,
          leftovers: old.leftovers,
          blockedNotebookIds: old.blockedNotebookIds,
          blockedNotebookRelatives: old.blockedNotebookRelatives,
          blocksAllNotebooks: true,
          listing: old.listing,
          lastResult: old.lastResult,
          export: old.export,
          externalMayBeIncomplete: old.externalMayBeIncomplete,
          error: 'Resource storage cannot be reconciled. Notebook writers remain blocked.',
        ),
      );
    }
  }

  Future<void> initialize() {
    if (initialized) return Future.value();
    return operation(() async {
      _state(phase: ResourceTransferPhase.recovering);
      try {
        await _scan();
      } catch (error) {
        await _failure(error);
      }
    }, scanning: true);
  }

  Future<ResourceAttempt?> start({
    required ResourceTarget target,
    required ResourceOperation operation,
    required String name,
    String? newName,
  }) {
    admit();
    if (hasStaging) {
      throw StateError('Resolve the retained resource staging first.');
    }
    if ((operation == ResourceOperation.rename) != (newName != null)) {
      throw StateError('Rename requires exactly one new name.');
    }
    return this.operation(() async {
      final id = newTransferId();
      _state(phase: ResourceTransferPhase.preparing);
      try {
        cancellation.check();
        final kind = operation == ResourceOperation.image
            ? DocumentImportKind.image
            : DocumentImportKind.file;
        await store(
          'allocate',
          id: id,
          arguments: {'kind': kind.name, 'target': target.marker(id)},
        );
        // Requested names are immutable and durable before any provider await.
        // This is NOT a native physical dispatch/no-replay record.
        await store(
          'writeResourceIntent',
          id: id,
          arguments: {
            'operation': operation.name,
            'name': name,
            'newName': newName,
          },
        );
        await _scan(preferredId: id);
        if (operation == ResourceOperation.add ||
            operation == ResourceOperation.image) {
          await _capture(value.current!);
        }
      } catch (error) {
        await _failure(error, id: id);
      }
      return value.current;
    });
  }

  Future<void> _capture(ResourceAttempt attempt) async {
    _state(phase: ResourceTransferPhase.receiving);
    final result = await pick(attempt.id, attempt.kind);
    if (result.status == DocumentImportStatus.cancelled) {
      throw const TransferCancelled();
    }
    if (result.status != DocumentImportStatus.ready) {
      throw const TransferFailure(
        'The provider did not complete its private copy. Reselect or discard it.',
      );
    }
    await store(
      'capture',
      id: attempt.id,
      arguments: {
        'sourceName': transferSourceName(result.sourceName, attempt.kind),
        'bytes': result.bytes,
        'entries': result.entries,
      },
    );
    cancellation.check();
    await _source(attempt);
  }

  Future<void> _source(ResourceAttempt attempt) async {
    _state(phase: ResourceTransferPhase.preparing);
    await store('resetWork', id: attempt.id);
    cancellation.check();
    final source = await prepareSource(attempt.id, attempt.kind);
    await store('source', id: attempt.id, arguments: source);
    await store('inspectResource', id: attempt.id);
    await _scan(
      preferredId: attempt.id,
      message: 'Source bytes prepared. Apply the exact requested name; existing files are never replaced.',
    );
  }

  Future<ResourceAttempt?> capture(ResourceAttempt attempt) {
    admit();
    _require(attempt);
    if ((attempt.operation != ResourceOperation.add &&
            attempt.operation != ResourceOperation.image) ||
        (attempt.stage != TransferStage.receiving &&
            attempt.stage != TransferStage.captured)) {
      throw StateError('This resource source cannot be replaced.');
    }
    return operation(() async {
      try {
        if (attempt.stage == TransferStage.captured) {
          await _source(attempt);
        } else {
          await store('resetWork', id: attempt.id);
          await _capture(attempt);
        }
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
      return value.current;
    });
  }

  Future<CoreResourceResult> _apply(
    ResourceAttempt attempt,
    ResourceApplyCallback callback, {
    required bool recover,
  }) async {
    _state(
      phase: recover
          ? ResourceTransferPhase.recovering
          : ResourceTransferPhase.applying,
    );
    _clearListing();
    CoreResourceResult result;
    try {
      if (!recover) cancellation.check();
      result = await callback(
        attempt,
        recover ? recoveryCancellation : cancellation,
        recover,
      );
    } catch (_) {
      if (recover) rethrow;
      result = await callback(attempt, recoveryCancellation, true);
    }
    if (result.committed) await store('finishResource', id: attempt.id);
    await _scan(
      preferredId: attempt.id,
      result: result,
      message: result.committed
          ? 'Resource operation committed. Source links are unchanged until you explicitly insert a link and Write.'
          : 'No completed mutation was proved. Private input remains retained.',
    );
    return result;
  }

  Future<CoreResourceResult?> apply(
    ResourceAttempt attempt,
    ResourceApplyCallback callback,
  ) {
    admit();
    _require(attempt);
    if (attempt.operation == ResourceOperation.export ||
        !const [
          TransferStage.source,
          TransferStage.prepared,
          TransferStage.intent,
          TransferStage.quarantined,
          TransferStage.committed,
        ].contains(attempt.stage)) {
      throw StateError('Prepare this resource operation before applying it.');
    }
    return operation(() async {
      try {
        return await _apply(
          attempt,
          callback,
          recover: const [
            TransferStage.intent,
            TransferStage.quarantined,
            TransferStage.committed,
          ].contains(attempt.stage),
        );
      } catch (error) {
        await _failure(error, id: attempt.id);
        return null;
      }
    });
  }

  Future<CoreResourceResult?> recover(
    ResourceAttempt attempt,
    ResourceApplyCallback callback,
  ) {
    admit();
    _require(attempt);
    return operation(() async {
      try {
        await store('recoverAttempt', id: attempt.id);
        if (attempt.operation == ResourceOperation.export ||
            !const [
              TransferStage.intent,
              TransferStage.quarantined,
              TransferStage.committed,
            ].contains(attempt.stage)) {
          await _scan(preferredId: attempt.id);
          return null;
        }
        return await _apply(attempt, callback, recover: true);
      } catch (error) {
        await _failure(error, id: attempt.id);
        return null;
      }
    });
  }

  Future<ResourceAttempt?> retry(
    ResourceAttempt attempt,
    ResourceApplyCallback callback,
  ) {
    admit();
    _require(attempt);
    if (attempt.operation == ResourceOperation.export) {
      throw StateError(
        'Use Prepare export or Save As for the retained snapshot.',
      );
    }
    return operation(() async {
      try {
        await store('recoverAttempt', id: attempt.id);
        await _scan(preferredId: attempt.id);
        final current = value.current!;
        switch (current.stage) {
          case TransferStage.receiving:
            await store('resetWork', id: current.id);
            await _capture(current);
          case TransferStage.captured:
            await _source(current);
          case TransferStage.source || TransferStage.prepared:
            await _apply(current, callback, recover: false);
          case TransferStage.intent ||
              TransferStage.quarantined ||
              TransferStage.committed:
            await _apply(current, callback, recover: true);
          case TransferStage.exportReady:
            throw const TransferFailure('Invalid mutation export state.');
        }
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
      return value.current;
    });
  }

  CoreResourceExport _export(
    Map<String, Object?> raw,
    ResourceAttempt attempt,
  ) {
    final name = raw['name'] as String;
    final path = raw['path'] as String;
    final bytes = raw['bytes'] as int;
    final hash = raw['sha256'] as String;
    if (name != attempt.name ||
        path != p.join(attempt.transactionRoot, 'output', name) ||
        bytes < 0 ||
        bytes > (1 << 30) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const TransferFailure(
        'The retained export no longer matches its owned snapshot.',
      );
    }
    return CoreResourceExport(
      name: name,
      path: path,
      bytes: bytes,
      sha256: hash,
    );
  }

  Future<CoreResourceExport?> prepareExport(
    ResourceAttempt attempt,
    ResourceExportCallback callback,
  ) {
    admit();
    _require(attempt);
    if (attempt.operation != ResourceOperation.export ||
        !const [
          TransferStage.receiving,
          TransferStage.exportReady,
        ].contains(attempt.stage)) {
      throw StateError('This is not an export snapshot request.');
    }
    return operation(() async {
      _state(phase: ResourceTransferPhase.preparing);
      try {
        if (attempt.stage != TransferStage.exportReady) {
          cancellation.check();
          // Callback closes/releases its native snapshot owner before returning.
          await callback(attempt, cancellation);
        }
        final snapshot = _export(
          await store('exportReady', id: attempt.id),
          attempt,
        );
        await _scan(
          preferredId: attempt.id,
          snapshot: snapshot,
          externalMayBeIncomplete: attempt.stage == TransferStage.exportReady,
          message: 'Private snapshot ready. Save As uses these exact bytes without retaining a notebook owner.',
        );
        return snapshot;
      } catch (error) {
        await _failure(error, id: attempt.id);
        return null;
      }
    });
  }

  Future<DocumentExportResult?> save(ResourceAttempt attempt) {
    admit();
    _require(attempt);
    if (attempt.operation != ResourceOperation.export ||
        attempt.stage != TransferStage.exportReady) {
      throw StateError('Capture a complete resource snapshot first.');
    }
    return operation(() async {
      _state(phase: ResourceTransferPhase.saving);
      try {
        final snapshot = _export(
          await store('verifyExport', id: attempt.id),
          attempt,
        );
        cancellation.check();
        // Any lost provider result is ambiguous; retain the immutable snapshot.
        _state(
          phase: ResourceTransferPhase.saving,
          snapshot: snapshot,
          externalMayBeIncomplete: true,
        );
        final result = await saveSnapshot(attempt.id, snapshot);
        await _scan(
          preferredId: attempt.id,
          snapshot: snapshot,
          externalMayBeIncomplete: result.externalMayBeIncomplete,
          message: result.status == DocumentExportStatus.saved
              ? 'External copy saved. The private snapshot remains until explicitly discarded.'
              : result.externalMayBeIncomplete
              ? _externalWarning
              : 'No completed external copy was reported. The private snapshot is retained.',
        );
        return result;
      } catch (error) {
        await _failure(error, id: attempt.id);
        return null;
      }
    });
  }

  Future<CoreResourceListing?> refresh(
    ResourceTarget target,
    ResourceListCallback callback,
  ) {
    admit();
    final current = value.current;
    if (current != null &&
        (current.target.notebookId != target.notebookId ||
            current.target.nodeId != target.nodeId)) {
      throw StateError('Resolve the retained resource target first.');
    }
    return operation(() async {
      _state(phase: ResourceTransferPhase.listing);
      _clearListing();
      try {
        cancellation.check();
        final listing = await callback(target, cancellation);
        cancellation.check();
        setListing(target, listing);
        _state();
        return listing;
      } catch (error) {
        _state(
          error: cancellation.isCancelled ? null : transferError(error),
          message: cancellation.isCancelled
              ? 'Resource listing cancelled.'
              : null,
        );
        return null;
      }
    });
  }

  Future<void> discard(
    ResourceAttempt attempt, {
    required ResourceApplyCallback recover,
    bool abandon = false,
  }) {
    admit();
    _require(attempt);
    return operation(() async {
      _state(phase: ResourceTransferPhase.discarding);
      try {
        if (!abandon &&
            (attempt.stage == TransferStage.intent ||
                attempt.stage == TransferStage.quarantined)) {
          await _apply(attempt, recover, recover: true);
        }
        await store(
          attempt.operation == ResourceOperation.export
              ? 'discardExport'
              : 'discard',
          id: attempt.id,
          arguments: abandon && attempt.operation != ResourceOperation.export
              ? {'abandon': true}
              : const {},
        );
        await _scan(
          message: abandon
              ? 'Private staging abandoned. Any live resource, including an unexpected filename, is unchanged. No link was inserted.'
              : 'Private resource staging discarded. Live resources are unchanged.',
        );
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
    });
  }

  Future<void> discardLeftover(TransferLeftover item) {
    admit();
    if (!value.leftovers.any((candidate) => identical(candidate, item))) {
      throw StateError('This cleanup item is no longer current.');
    }
    if (!item.canDiscard ||
        p.dirname(item.location) != root ||
        !validTransferId(p.basename(item.location))) {
      throw StateError(
        'Unrecognized staging cannot be safely deleted while a live ownership claim may remain.',
      );
    }
    return operation(() async {
      _state(phase: ResourceTransferPhase.discarding);
      try {
        await store('discard', id: p.basename(item.location));
        await _scan(message: 'Interrupted private allocation discarded.');
      } catch (error) {
        await _failure(error);
      }
    });
  }
}
