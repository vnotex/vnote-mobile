// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'document_transfer_platform.dart';
import 'transfer_worker.dart';

export 'transfer_worker.dart'
    show TransferCancellation, TransferStage, TransferLeftover;

enum CohortImportPhase {
  idle,
  receiving,
  preparing,
  applying,
  recovering,
  discarding,
}

@immutable
class CohortTarget {
  const CohortTarget({
    required this.notebookId,
    required this.parentId,
    required this.notebookRelative,
    required this.folderName,
  });
  final String notebookId;
  final String parentId;
  final String notebookRelative;
  final String folderName;
  Map<String, Object?> marker(String id) => {
    'version': 1,
    'id': id,
    'notebookId': notebookId,
    'parentId': parentId,
    'notebookRelative': notebookRelative,
    'folderName': folderName,
  };
}

@immutable
class CohortAttempt {
  const CohortAttempt({
    required this.id,
    required this.target,
    required this.kind,
    required this.stage,
    required this.transactionRoot,
    this.sourceName,
    this.bytes = 0,
    this.entries = 0,
    this.cohortId,
    this.built = false,
    this.canApply = false,
    this.allocationComplete = true,
  });
  final String id;
  final CohortTarget target;
  final DocumentImportKind kind;
  final TransferStage stage;
  final String transactionRoot;
  final String? sourceName;
  final int bytes;
  final int entries;
  final String? cohortId;
  final bool built;
  final bool canApply;
  final bool allocationComplete;
}

@immutable
class CohortImportState {
  const CohortImportState({
    this.phase = CohortImportPhase.idle,
    this.current,
    this.attempts = const [],
    this.leftovers = const [],
    this.blockedNotebookIds = const [],
    this.blockedNotebookRelatives = const [],
    this.blocksAllNotebooks = false,
    this.error,
    this.message,
  });
  final CohortImportPhase phase;
  final CohortAttempt? current;
  final List<CohortAttempt> attempts;
  final List<TransferLeftover> leftovers;
  final List<String> blockedNotebookIds;
  final List<String> blockedNotebookRelatives;
  final bool blocksAllNotebooks;
  final String? error;
  final String? message;
  bool get busy => phase != CohortImportPhase.idle;
  bool get hasStaging =>
      attempts.isNotEmpty || leftovers.isNotEmpty || blocksAllNotebooks;
}

typedef CohortBuildCallback = Future<CoreCohortBuildResult> Function(
  CohortAttempt attempt,
  TransferCancellation cancellation,
);
typedef CohortApplyCallback = Future<CoreCohortOutcome> Function(
  CohortAttempt attempt,
  TransferCancellation cancellation,
  bool recover,
);
typedef CohortRetainedCapture = Future<DocumentImportResult> Function();


/// Private source/attempt ownership. Callbacks own and JOIN core hosts; no core
/// handle crosses a filesystem isolate and no widget callback is retained.
class CohortImporter extends TransferController<CohortImportState> {
  CohortImporter({
    required super.root,
    required super.notebooksRoot,
    required super.reserveTransfer,
    required super.releaseTransfer,
    super.platform,
  }) : super(const CohortImportState(), scope: DocumentTransferScope.cohort);

  /// Inbox tombstones must become durable before any private proof is removed.
  Future<void> Function(CohortAttempt attempt)? authorizeDiscard;

  Future<void> rescan() => operation(() async {
    await _scan();
  }, scanning: true);

  /// Only a library-verified settled inbox receipt authorizes this cleanup.
  Future<void> discardSettledInbox(String operationId, String inboxId) => operation(() async {
    await store('discard', id: operationId, arguments: {'inboxId': inboxId});
    await _scan();
  });

  /// Only the inbox allocator repairs a mkdir-before-request interruption.
  /// Its native immutable ownership record pins this ID and target forever.
  Future<CohortAttempt?> allocateInbox({required String inboxId,
      required String operationId, required CohortTarget target}) {
    return operation(() async {
      await store('allocateInbox', id: operationId, arguments: {
        'inboxId': inboxId, 'kind': DocumentImportKind.folder.name,
        'target': target.marker(operationId),
      });
      await _scan(preferredId: operationId);
      return value.current;
    }, scanning: true);
  }

  @override
  bool get hasStaging => value.hasStaging;

  void _require(CohortAttempt attempt) {
    if (!identical(value.current, attempt)) {
      throw StateError('This cohort attempt is no longer current.');
    }
  }

  void _state({
    CohortImportPhase phase = CohortImportPhase.idle,
    String? error,
    String? message,
  }) {
    final old = value;
    publish(
      CohortImportState(
        phase: phase,
        current: old.current,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
        error: error,
        message: message,
      ),
    );
  }

  void select(CohortAttempt attempt) {
    admit();
    if (!value.attempts.any((item) => identical(item, attempt))) {
      throw StateError('This cohort attempt is no longer retained.');
    }
    final old = value;
    publish(
      CohortImportState(
        current: attempt,
        attempts: old.attempts,
        leftovers: old.leftovers,
        blockedNotebookIds: old.blockedNotebookIds,
        blockedNotebookRelatives: old.blockedNotebookRelatives,
        blocksAllNotebooks: old.blocksAllNotebooks,
      ),
    );
  }

  Future<void> _scan({
    String? preferredId,
    String? error,
    String? message,
  }) async {
    final result = await store('scan');
    final attempts = <CohortAttempt>[];
    final leftovers = <TransferLeftover>[];
    for (final raw in result['entries'] as List) {
      final record = Map<String, Object?>.from(raw as Map);
      try {
        attempts.add(_attempt(record));
      } catch (_) {
        final id = record['id'];
        leftovers.add(
          TransferLeftover(
            location: id is String && p.basename(id) == id
                ? p.join(root, id)
                : root,
            label: 'Unrecognized cohort staging',
            reason: 'Ownership or recovery records are invalid. Live destinations cannot safely be ruled out.',
          ),
        );
      }
    }
    final selectedId = preferredId ?? value.current?.id;
    final current =
        attempts.where((item) => item.id == selectedId).firstOrNull ??
        attempts.firstOrNull;
    final blocked = attempts.where(
      (item) =>
          item.stage == TransferStage.intent ||
          item.stage == TransferStage.quarantined,
    );
    initialized = true;
    publish(
      CohortImportState(
        current: current,
        attempts: List.unmodifiable(attempts),
        leftovers: List.unmodifiable(leftovers),
        blockedNotebookIds: List.unmodifiable(
          blocked.map((item) => item.target.notebookId).toSet(),
        ),
        blockedNotebookRelatives: List.unmodifiable(
          blocked.map((item) => item.target.notebookRelative).toSet(),
        ),
        blocksAllNotebooks: leftovers.isNotEmpty,
        error: error,
        message: message,
      ),
    );
  }

  CohortAttempt _attempt(Map<String, Object?> record) {
    if (!validTransferId(record['id']) || record['scope'] != 'cohort') {
      throw const FormatException();
    }
    final id = record['id'] as String;
    final target = Map<String, Object?>.from(record['target'] as Map);
    if (target['version'] != 1 || target['id'] != id || target.length != 6) {
      throw const FormatException();
    }
    final kind = DocumentImportKind.values.byName(record['kind'] as String);
    if (kind == DocumentImportKind.image) throw const FormatException();
    final relative = target['notebookRelative'] as String;
    if (relative.isEmpty ||
        relative == '.' ||
        relative == '..' ||
        p.basename(relative) != relative ||
        relative.contains('\\') ||
        relative.contains('/')) {
      throw const FormatException();
    }
    final bytes = record['bytes'] as int;
    final entries = record['entries'] as int;
    if (bytes < 0 || bytes > (2 << 30) || entries < 0 || entries > 100000) {
      throw const FormatException();
    }
    return CohortAttempt(
      id: id,
      target: CohortTarget(
        notebookId: target['notebookId'] as String,
        parentId: target['parentId'] as String,
        notebookRelative: relative,
        folderName: target['folderName'] as String,
      ),
      kind: kind,
      stage: transferStage(record),
      transactionRoot: p.join(root, id),
      sourceName: record['sourceName'] as String?,
      bytes: bytes,
      entries: entries,
      cohortId: record['cohortId'] as String?,
      built: record['phase'] == 'built',
      canApply: record['canApply'] == true,
      allocationComplete: record['allocationComplete'] != false,
    );
  }

  Future<void> _failure(Object error, {String? id}) async {
    final cancelled = error is TransferCancelled || cancellation.isCancelled;
    try {
      await _scan(
        preferredId: id,
        error: cancelled ? null : transferError(error),
        message: cancelled
            ? 'Cancelled. Completed private bytes are retained.'
            : value.current?.kind == DocumentImportKind.file
            ? 'A Markdown file that refers to sibling assets must be selected through its containing folder or ZIP. Private bytes are retained; no live rollback is assumed.'
            : 'Retained for recovery or explicit private discard; no live rollback is assumed.',
      );
    } catch (_) {
      initialized = false;
      final old = value;
      publish(
        CohortImportState(
          current: old.current,
          attempts: old.attempts,
          leftovers: old.leftovers,
          blockedNotebookIds: old.blockedNotebookIds,
          blockedNotebookRelatives: old.blockedNotebookRelatives,
          blocksAllNotebooks: true,
          error: 'Cohort storage cannot be reconciled. Notebook writers remain blocked.',
        ),
      );
    }
  }

  Future<void> initialize() {
    if (initialized) return Future.value();
    return operation(() async {
      _state(phase: CohortImportPhase.recovering);
      try {
        await _scan();
      } catch (error) {
        await _failure(error);
      }
    }, scanning: true);
  }

  Future<CohortAttempt?> start({
    required CohortTarget target,
    required DocumentImportKind kind,
  }) {
    admit();
    if (hasStaging) {
      throw StateError('Resolve the retained cohort staging first.');
    }
    if (kind == DocumentImportKind.image) {
      throw StateError('Choose file, folder or ZIP for a cohort.');
    }
    return operation(() async {
      final id = newTransferId();
      _state(phase: CohortImportPhase.receiving);
      try {
        cancellation.check();
        await store(
          'allocate',
          id: id,
          arguments: {'kind': kind.name, 'target': target.marker(id)},
        );
        await _scan(preferredId: id);
        await _capture(value.current!);
      } catch (error) {
        await _failure(error, id: id);
      }
      return value.current;
    });
  }

  Future<void> _capture(CohortAttempt attempt, {CohortRetainedCapture? retained}) async {
    _state(phase: CohortImportPhase.receiving);
    final result = await (retained == null ? pick(attempt.id, attempt.kind) : retained());
    if (result.status == DocumentImportStatus.cancelled) {
      throw const TransferCancelled();
    }
    if (result.status != DocumentImportStatus.ready) {
      throw const TransferFailure(
        'The provider did not complete its private copy. Reselect or discard it.',
      );
    }
    // The provider future releases its descriptors. Persist a ready copy even
    // when cancel raced that result, before respecting cancellation again.
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
    await _source(attempt.id, attempt.kind);
  }

  Future<void> _source(String id, DocumentImportKind kind) async {
    _state(phase: CohortImportPhase.preparing);
    await store('resetWork', id: id);
    cancellation.check();
    final source = await prepareSource(id, kind);
    await store('source', id: id, arguments: source);
    await _scan(
      preferredId: id,
      message: kind == DocumentImportKind.file
          ? 'Source preserved. A Markdown file requiring sibling assets needs its containing folder or ZIP. VNote identity links are not rewritten.'
          : 'Source preserved with its original layout. Prepare one new child folder; VNote identity links are not rewritten.',
    );
  }

  Future<CohortAttempt?> capture(CohortAttempt attempt) {
    admit();
    _require(attempt);
    if (attempt.stage != TransferStage.receiving &&
        attempt.stage != TransferStage.captured) {
      throw StateError('This source cannot be replaced.');
    }
    return operation(() async {
      try {
        if (attempt.stage == TransferStage.captured) {
          await _source(attempt.id, attempt.kind);
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

  Future<void> setFolderName(CohortAttempt attempt, String folderName) {
    admit();
    _require(attempt);
    if (!const [
      TransferStage.receiving,
      TransferStage.captured,
      TransferStage.source,
    ].contains(attempt.stage)) {
      throw StateError('A sealed cohort name is immutable.');
    }
    return operation(() async {
      try {
        await store(
          'resetWork',
          id: attempt.id,
          arguments: {'folderName': folderName},
        );
        await _scan(preferredId: attempt.id);
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
    });
  }

  Future<void> _prepare(
    CohortAttempt attempt,
    CohortBuildCallback build,
  ) async {
    _state(phase: CohortImportPhase.preparing);
    cancellation.check();
    if (!attempt.built) {
      await store('resetWork', id: attempt.id);
      cancellation.check();
      await build(attempt, cancellation);
    }
    // Callback MUST close/join builder before returning. Once sealed, all
    // future retries consume these exact IDs, never another private build.
    cancellation.check();
    await store('sealCohort', id: attempt.id, cancellable: true);
    await _scan(
      preferredId: attempt.id,
      message: 'Immutable cohort prepared. Apply it to the captured parent.',
    );
  }

  Future<CohortAttempt?> prepare(
    CohortAttempt attempt,
    CohortBuildCallback build,
  ) {
    admit();
    _require(attempt);
    if (attempt.stage != TransferStage.source) {
      throw StateError('Prepare the captured source first.');
    }
    return operation(() async {
      try {
        await _prepare(attempt, build);
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
      return value.current;
    });
  }

  Future<CoreCohortOutcome?> _apply(
    CohortAttempt attempt,
    CohortApplyCallback callback, {
    required bool recover,
  }) async {
    _state(
      phase: recover
          ? CohortImportPhase.recovering
          : CohortImportPhase.applying,
    );
    CoreCohortOutcome result;
    try {
      if (!recover) cancellation.check();
      result = await callback(
        attempt,
        recover ? recoveryCancellation : cancellation,
        recover,
      );
    } catch (_) {
      // A dispatch may have succeeded before its error. Join and reconcile
      // actual core state with an uncancelled owner before reporting failure.
      if (recover) rethrow;
      result = await callback(attempt, recoveryCancellation, true);
    }
    if (result.committed) await store('writeReceipt', id: attempt.id);
    await _scan(
      preferredId: attempt.id,
      message: result.committed
          ? 'Cohort committed. Discard removes only private staging, never the imported folder.'
          : 'No committed cohort was found. The immutable source is retained.',
    );
    return result;
  }

  Future<CoreCohortOutcome?> apply(
    CohortAttempt attempt,
    CohortApplyCallback callback,
  ) {
    admit();
    _require(attempt);
    if (attempt.stage != TransferStage.prepared &&
        attempt.stage != TransferStage.intent &&
        attempt.stage != TransferStage.committed) {
      throw StateError('An immutable prepared cohort is required.');
    }
    return operation(() async {
      try {
        return await _apply(attempt, callback, recover: !attempt.canApply);
      } catch (error) {
        await _failure(error, id: attempt.id);
        return null;
      }
    });
  }

  Future<CoreCohortOutcome?> recover(
    CohortAttempt attempt,
    CohortApplyCallback callback,
  ) {
    admit();
    _require(attempt);
    return operation(() async {
      try {
        await store('recoverAttempt', id: attempt.id);
        if (!const [
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

  Future<CohortAttempt?> retry(
    CohortAttempt attempt, {
    required CohortBuildCallback build,
    required CohortApplyCallback apply,
    CohortRetainedCapture? retained,
  }) {
    admit();
    _require(attempt);
    return operation(() async {
      try {
        await store('recoverAttempt', id: attempt.id);
        await _scan(preferredId: attempt.id);
        final current = value.current!;
        switch (current.stage) {
          case TransferStage.receiving:
            await store('resetWork', id: current.id);
            await _capture(current, retained: retained);
          case TransferStage.captured:
            await _source(current.id, current.kind);
          case TransferStage.source:
            await _prepare(current, build);
          case TransferStage.prepared:
            await _apply(current, apply, recover: !current.canApply);
          case TransferStage.intent ||
              TransferStage.quarantined ||
              TransferStage.committed:
            await _apply(current, apply, recover: true);
          case TransferStage.exportReady || TransferStage.exportUnavailable:
            throw const TransferFailure('Invalid cohort export state.');
        }
      } catch (error) {
        await _failure(error, id: attempt.id);
      }
      return value.current;
    });
  }

  Future<void> discard(
    CohortAttempt attempt, {
    required CohortApplyCallback recover,
  }) {
    admit();
    _require(attempt);
    return operation(() async {
      _state(phase: CohortImportPhase.discarding);
      try {
        if (attempt.stage == TransferStage.intent ||
            attempt.stage == TransferStage.quarantined) {
          await _apply(attempt, recover, recover: true);
        }
        final current = value.attempts.where((item) => item.id == attempt.id).firstOrNull;
        await authorizeDiscard?.call(current ?? attempt);
        await store('discard', id: attempt.id);
        await _scan(
          message: 'Private cohort staging discarded. Any committed live folder is unchanged.',
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
    throw StateError(
      'Unrecognized staging cannot be safely deleted while a live ownership claim may remain.',
    );
  }
}
