// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'sync_credentials.dart';

enum NotebookSyncReadiness {
  disabled, invalidEndpoint, missingCredentials, unsupported, unregistered,
  ready, orphan, credentialsUnknown,
}

enum SyncCredentialPresence { absent, present, unknown }

enum NotebookSyncPhase {
  idle, reconciling, staging, network, reserving, applying, refreshing,
  settling, configuring, rotating, disabling, recovering, conflicts, closing,
}

enum SyncReservationKind { stage, apply, lifecycle }

@immutable
class SyncReservationRequest {
  const SyncReservationRequest({required this.operationId,
    required this.ownerGeneration, required this.kind});
  final String operationId;
  final int ownerGeneration;
  final SyncReservationKind kind;
}

@immutable
class SyncProtection {
  SyncProtection({required List<String> dirtyNodeIds, this.ownershipKnown = true})
      : dirtyNodeIds = List.unmodifiable(dirtyNodeIds);
  final List<String> dirtyNodeIds;
  final bool ownershipKnown;
}

@immutable
class SyncRefreshReport {
  SyncRefreshReport({required this.metadataRefreshed,
    required this.operationSucceeded, required List<String>? changedPaths})
      : changedPaths = changedPaths == null ? null : List.unmodifiable(changedPaths);
  final bool metadataRefreshed;
  final bool operationSucceeded;
  /// Unavailable is deliberately distinct from an authoritative empty report.
  final List<String>? changedPaths;
}

@immutable
class SyncSettlement {
  const SyncSettlement({required this.safe, this.recoveryRequired = false});
  final bool safe;
  final bool recoveryRequired;
}

abstract interface class NotebookSyncReservation {
  Future<void> drainWriters();
  Future<SyncProtection> quiesceAndDrainDrafts();
  Future<SyncSettlement> settle(SyncRefreshReport? report);
  /// Invalidates quiesce immediately; joins acknowledged abort and both drains.
  Future<bool> abort();
  /// Retires this token into an explicit source-recovery block, never a successor.
  void retainRecovery(String code);
}

abstract interface class NotebookSyncParticipant {
  /// Must install exclusion synchronously, before returning or starting any await.
  NotebookSyncReservation installSyncReservation(SyncReservationRequest request);
  Future<bool> recoverSyncSources();
}

NotebookSyncReadiness classifyNotebookSync({required bool enabled,
  required String backend, required String endpoint,
  required SyncCredentialPresence credentials, required bool registered,
  required SyncCredentialPresence orphanCredentials}) {
  if (!enabled) {
    return switch (orphanCredentials) {
      SyncCredentialPresence.present => NotebookSyncReadiness.orphan,
      SyncCredentialPresence.absent => NotebookSyncReadiness.disabled,
      SyncCredentialPresence.unknown => NotebookSyncReadiness.credentialsUnknown,
    };
  }
  if (backend != 'webdav') return NotebookSyncReadiness.unsupported;
  try { canonicalSyncEndpoint(endpoint); }
  on Object { return NotebookSyncReadiness.invalidEndpoint; }
  if (credentials == SyncCredentialPresence.unknown) return NotebookSyncReadiness.credentialsUnknown;
  if (credentials == SyncCredentialPresence.absent) return NotebookSyncReadiness.missingCredentials;
  return registered ? NotebookSyncReadiness.ready : NotebookSyncReadiness.unregistered;
}

@immutable
class NotebookSyncResolution {
  const NotebookSyncResolution({required this.path, required this.resolution,
    required this.ownerGeneration});
  final String path;
  final CoreSyncResolution resolution;
  final int ownerGeneration;
}

@immutable
class NotebookSyncConflictOutcome {
  const NotebookSyncConflictOutcome({required this.path, required this.resolution,
    required this.success, this.code, this.error});
  final String path;
  final CoreSyncResolution resolution;
  final bool success;
  final int? code;
  final String? error;
}

@immutable
class NotebookSyncOutcome {
  const NotebookSyncOutcome({required this.success, this.cancelled = false,
    this.recoveryRequired = false, this.error, this.code,
    this.conflicts = const []});
  final bool success;
  final bool cancelled;
  final bool recoveryRequired;
  final String? error;
  final int? code;
  final List<NotebookSyncConflictOutcome> conflicts;
}

@immutable
class NotebookSyncState {
  const NotebookSyncState({this.readiness = NotebookSyncReadiness.credentialsUnknown,
    this.facts, this.busy = false, this.queued = false,
    this.phase = NotebookSyncPhase.idle, this.recoveryRequired = false,
    this.error, this.ownerGeneration = 0, this.conflictOutcomes = const [],
    this.closingNotebook = false});
  final NotebookSyncReadiness readiness;
  final CoreSyncFacts? facts;
  final bool busy;
  final bool queued;
  final NotebookSyncPhase phase;
  final bool recoveryRequired;
  final String? error;
  final int ownerGeneration;
  final List<NotebookSyncConflictOutcome> conflictOutcomes;
  final bool closingNotebook;
  int? get lastSuccessUtcMillis {
    final last = facts?.lastSuccessUtcMillis;
    return last == null || last == 0 ? null : last;
  }
  bool get canSync => !busy && !closingNotebook && !recoveryRequired && readiness == NotebookSyncReadiness.ready;
  bool get allowsLocalWrites => !busy || phase == NotebookSyncPhase.network;
  int? get readinessNumber => switch (readiness) {
    NotebookSyncReadiness.disabled => 0,
    NotebookSyncReadiness.invalidEndpoint => 1,
    NotebookSyncReadiness.missingCredentials => 2,
    NotebookSyncReadiness.unsupported => 3,
    NotebookSyncReadiness.unregistered => 4,
    NotebookSyncReadiness.ready => 5,
    NotebookSyncReadiness.orphan => 6,
    NotebookSyncReadiness.credentialsUnknown => null,
  };
}

class _SyncFailure implements Exception {
  const _SyncFailure(this.error, {this.code, this.recovery = false});
  final String error;
  final int? code;
  final bool recovery;
}

/// Owns policy, not storage/sync mechanics. The selected NOTE/CATALOG owner is
/// borrowed until detach drains it; no competing native context is created.
class NotebookSync extends ValueNotifier<NotebookSyncState> {
  NotebookSync({required this.notebookId, SyncCredentials? credentials,
    this.autoDelay = const Duration(seconds: 30),
    this.freshness = const Duration(minutes: 2),
    this.reservationTimeout = const Duration(seconds: 5),
    DateTime Function()? clock})
      : credentials = credentials ?? SyncCredentials(),
        _clock = clock ?? DateTime.now, super(const NotebookSyncState());
  final String notebookId;
  final SyncCredentials credentials;
  final Duration autoDelay;
  final Duration freshness;
  final Duration reservationTimeout;
  final DateTime Function() _clock;
  SyncCore? _core;
  NotebookSyncParticipant? _participant;
  CoreSyncFacts? _facts;
  NotebookSyncReadiness _readiness = NotebookSyncReadiness.credentialsUnknown;
  NotebookSyncPhase _phase = NotebookSyncPhase.idle;
  bool _recovery = false;
  bool _sourceRecovery = false;
  bool _logicalClosing = false;
  bool _logicalCloseRunning = false;
  String? _error;
  int _generation = 0;
  bool _foreground = true;
  bool _closing = false;
  bool _detaching = false;
  bool _disposed = false;
  bool _autoPending = false;
  bool _manualPending = false;
  Timer? _timer;
  Future<NotebookSyncOutcome>? _active;
  Future<void>? _closeFuture;
  Future<void>? _detachFuture;
  Future<NotebookSyncOutcome>? _notebookCloseFuture;
  Completer<NotebookSyncOutcome>? _pending;
  Completer<void>? _cancelled;
  String? _operationId;
  NotebookSyncReservation? _reservation;
  List<NotebookSyncConflictOutcome> _conflictOutcomes = const [];
  final Queue<List<NotebookSyncResolution>> _batches = Queue();
  final Queue<Completer<NotebookSyncOutcome>> _batchReplies = Queue();

  void _publish() {
    if (_disposed) return;
    value = NotebookSyncState(readiness: _readiness, facts: _facts,
      busy: _active != null || _logicalCloseRunning, queued: _pending != null || _timer != null || _batches.isNotEmpty,
      phase: _phase, recoveryRequired: _recovery, error: _error,
      ownerGeneration: _generation, conflictOutcomes: _conflictOutcomes, closingNotebook: _logicalClosing);
  }

  void _setPhase(NotebookSyncPhase phase) { _phase = phase; _publish(); }
  void _checkCancelled() {
    if (_cancelled?.isCompleted == true || _closing || _detaching) {
      throw const _SyncFailure('sync_cancelled');
    }
  }
  void _requireOwner() {
    if (_core == null || _participant == null || _closing || _detaching) {
      throw const _SyncFailure('sync_owner_unavailable');
    }
  }
  void _requireResult(CoreSyncResult result, {String error = 'sync_failed'}) {
    if (!result.success) {
      throw _SyncFailure(error, code: result.code, recovery: result.cleanupRequired || result.refreshRequired);
    }
  }

  Future<void> attach({required SyncCore core, required NotebookSyncParticipant participant}) async {
    if (_closing || _disposed) throw StateError('Sync coordinator is closed.');
    if (_logicalCloseRunning) await _notebookCloseFuture;
    if (_core != null) await detach();
    if (_closing || _disposed) throw StateError('Sync coordinator is closed.');
    _core = core;
    _participant = participant;
    _logicalClosing = false;
    _notebookCloseFuture = null;
    _generation++;
    await reconcile(requestFreshness: true);
  }

  Future<void> detach() => _detachFuture ??= _detach().whenComplete(() => _detachFuture = null);

  Future<void> _detach() async {
    _detaching = true;
    _stopQueued('sync_owner_changed');
    await cancel();
    final core = _core;
    if (core != null) {
      try {
        final result = await core.sync(CoreSyncCommand(
          action: CoreSyncAction.unregister, operationId: newSyncOperationId()));
        _requireResult(result, error: 'sync_unregister_failed');
      } on Object {
        _recovery = true;
        _error = 'sync_unregister_failed';
      }
    }
    _core = null;
    _participant = null;
    _facts = null;
    _readiness = NotebookSyncReadiness.credentialsUnknown;
    _generation++;
    _detaching = false;
    _publish();
  }

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    return _closeFuture = _shutdown();
  }

  Future<void> _shutdown() async {
    await cancel();
    if (_logicalCloseRunning) await _notebookCloseFuture;
    await detach();
  }

  /// Explicit user close, unlike shutdown/owner transitions. Persisted routing
  /// and remote data remain intact; only the captured credential generations go.
  Future<NotebookSyncOutcome> closeNotebook() {
    if (_notebookCloseFuture != null) return _notebookCloseFuture!;
    if (_closing || _detaching || _core == null) {
      return Future.value(const NotebookSyncOutcome(success: false, error: 'sync_owner_unavailable'));
    }
    _logicalClosing = true;
    _logicalCloseRunning = true;
    _stopQueued('sync_notebook_closing');
    final reply = Completer<NotebookSyncOutcome>();
    _notebookCloseFuture = reply.future;
    _setPhase(NotebookSyncPhase.closing);
    unawaited(() async {
      NotebookSyncOutcome outcome;
      try {
        await cancel();
        outcome = await _start((id) async {
          _setPhase(NotebookSyncPhase.closing);
          await _inspect();
          await _lifecycleReservation(id);
          final records = await _notebookCredentialRecords();
          if (_facts!.refreshRequired || _facts!.provider.credentialRecovery || _facts!.provider.retirement ||
              records.any((record) => record.pending && record.kind != SyncCredentialKind.close)) {
            throw const _SyncFailure('sync_recovery_required', recovery: true);
          }
          final anchors = records.where((record) => record.kind == SyncCredentialKind.close).toList();
          if (anchors.isEmpty) {
            SyncCredentialScope? preferred;
            if (_facts!.backend == 'webdav' && _facts!.endpoint.isNotEmpty) {
              try { preferred = _scope(_facts!); }
              on SyncVaultException { preferred = null; }
            }
            final anchor = await credentials.beginClose(records, id,
              notebookId: notebookId, preferredScope: preferred);
            if (anchor != null) anchors.add(anchor);
          }
          try {
            _requireResult(await _command(CoreSyncAction.unregister, id), error: 'sync_unregister_failed');
            if ((await _core!.inspectSync()).registered) throw const _SyncFailure('sync_unregister_failed', recovery: true);
            for (final anchor in anchors) { await credentials.completeClose(anchor); }
            await _settleReservation(null);
            _recovery = _sourceRecovery;
            await _inspect();
            return NotebookSyncOutcome(success: !_recovery, recoveryRequired: _recovery,
              error: _recovery ? 'sync_recovery_required' : null);
          } on Object {
            _recovery = true; // Durable anchor retains every unfinished CAS target.
            rethrow;
          }
        }, closingNotebook: true);
      } on Object {
        _recovery = true;
        outcome = const NotebookSyncOutcome(success: false, recoveryRequired: true,
          error: 'sync_close_recovery');
      }
      _logicalCloseRunning = false;
      if (!outcome.success) _notebookCloseFuture = null;
      reply.complete(outcome);
      _publish();
    }());
    return reply.future;
  }

  Future<List<SyncCredentialRecord>> _notebookCredentialRecords() async {
    final records = <SyncCredentialRecord>[];
    for (final scope in await credentials.notebookScopes(notebookId)) {
      final record = await credentials.read(scope);
      if (record.present) records.add(record);
    }
    return records;
  }

  /// Startup closes the old generation before any new credential ingress/enable.
  Future<bool> _completePendingClose(String id, {bool recoverSources = false}) async {
    final records = await _notebookCredentialRecords();
    final anchors = records.where((record) => record.kind == SyncCredentialKind.close).toList();
    if (anchors.isEmpty) return false;
    if (_facts!.refreshRequired || _facts!.provider.credentialRecovery || _facts!.provider.retirement ||
        records.any((record) => record.pending && record.kind != SyncCredentialKind.close)) { return false; }
    if (_reservation == null) await _lifecycleReservation(id);
    try {
      _requireResult(await _command(CoreSyncAction.unregister, id), error: 'sync_unregister_failed');
      if ((await _core!.inspectSync()).registered) throw const _SyncFailure('sync_unregister_failed', recovery: true);
      for (final anchor in anchors) { await credentials.completeClose(anchor); }
      if (recoverSources && !await _participant!.recoverSyncSources()) {
        _sourceRecovery = true;
        throw const _SyncFailure('sync_source_recovery', recovery: true);
      }
      await _settleReservation(null);
      if (recoverSources) _sourceRecovery = false;
      _recovery = _sourceRecovery;
      await _inspect();
      return true;
    } on Object {
      _recovery = true;
      rethrow;
    }
  }

  @override
  void dispose() {
    // Native lifetime belongs to close/detach, not synchronous notifier disposal.
    if (_core != null || _active != null) throw StateError('Await sync close before dispose.');
    _timer?.cancel();
    _disposed = true;
    super.dispose();
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground || _closing || _logicalClosing) return;
    _foreground = foreground;
    if (!foreground) {
      _timer?.cancel(); _timer = null;
      unawaited(cancel());
    } else if (_core != null) {
      unawaited(reconcile(requestFreshness: true));
      _schedule();
    }
    _publish();
  }

  /// A fixed trailing window starts once; bursts never postpone it indefinitely.
  void localSaved() { _autoPending = true; _schedule(); }
  void _schedule() {
    if (_closing || _logicalClosing || _detaching || !_foreground || _facts?.autoSyncEnabled != true || !_autoPending || _timer != null) return;
    _timer = Timer(autoDelay, () {
      _timer = null;
      if (!_foreground || _closing || _logicalClosing || _detaching) return;
      _autoPending = false;
      _enqueueSync(manual: false);
    });
    _publish();
  }

  Future<NotebookSyncOutcome> syncNow() {
    _timer?.cancel(); _timer = null; _autoPending = false;
    return _enqueueSync(manual: true);
  }

  Future<NotebookSyncOutcome> _enqueueSync({required bool manual}) {
    if (_closing || _logicalClosing || _detaching || _core == null) {
      return Future.value(const NotebookSyncOutcome(success: false, error: 'sync_owner_unavailable'));
    }
    _manualPending = _manualPending || manual;
    _pending ??= Completer<NotebookSyncOutcome>();
    final reply = _pending!.future;
    _drainQueue();
    _publish();
    return reply;
  }

  void _drainQueue() {
    if (_active != null || _closing || _logicalClosing || _detaching || _core == null) return;
    if (_batches.isNotEmpty) {
      final batch = _batches.removeFirst();
      final reply = _batchReplies.removeFirst();
      _resolvingBatch = batch;
      _start(_resolveBatch).then(reply.complete);
      return;
    }
    if (_pending == null || (!_manualPending && !_foreground)) return;
    final reply = _pending!;
    _pending = null; _manualPending = false;
    _start(_regular).then(reply.complete);
  }

  void _stopQueued(String error) {
    _timer?.cancel(); _timer = null;
    _autoPending = false; _manualPending = false;
    _pending?.complete(NotebookSyncOutcome(success: false, error: error));
    _pending = null;
    while (_batchReplies.isNotEmpty) {
      final batch = _batches.removeFirst();
      _batchReplies.removeFirst().complete(NotebookSyncOutcome(success: false, error: error,
        conflicts: List.unmodifiable(batch.map((request) => NotebookSyncConflictOutcome(
          path: request.path, resolution: request.resolution, success: false, error: error)))));
    }
  }

  Future<void> cancel() async {
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    final id = _operationId;
    if (id != null) _core?.cancelSync(id);
    await _active;
  }

  Future<NotebookSyncOutcome> _start(Future<NotebookSyncOutcome> Function(String) action,
      {bool closingNotebook = false}) {
    if (_logicalClosing && !closingNotebook) {
      return Future.value(const NotebookSyncOutcome(success: false, error: 'sync_notebook_closing'));
    }
    if (_active != null) return Future.value(const NotebookSyncOutcome(success: false, error: 'sync_busy'));
    try { _requireOwner(); }
    on _SyncFailure catch (error) { return Future.value(NotebookSyncOutcome(success: false, error: error.error)); }
    final id = newSyncOperationId();
    final reply = Completer<NotebookSyncOutcome>();
    _active = reply.future;
    _operationId = id; _cancelled = Completer<void>(); _error = null;
    _publish();
    unawaited(() async {
      NotebookSyncOutcome outcome;
      try {
        outcome = await action(id);
      } on _SyncFailure catch (error) {
        outcome = NotebookSyncOutcome(success: false, error: error.error, code: error.code,
          cancelled: error.error == 'sync_cancelled', recoveryRequired: error.recovery || _recovery);
      } on SyncVaultException catch (error) {
        if (_phase == NotebookSyncPhase.configuring || _phase == NotebookSyncPhase.rotating ||
            _phase == NotebookSyncPhase.disabling || _phase == NotebookSyncPhase.recovering ||
            _phase == NotebookSyncPhase.closing) {
          _recovery = true; // A lost durable CAS reply is an unknown transaction outcome.
        }
        if (error.code == 'vault_locked' || error.code == 'vault_unavailable' || error.code == 'vault_corrupt') {
          _readiness = NotebookSyncReadiness.credentialsUnknown;
        }
        outcome = NotebookSyncOutcome(success: false, error: error.code, recoveryRequired: _recovery);
      } on Object {
        outcome = NotebookSyncOutcome(success: false, error: 'sync_failed', recoveryRequired: _recovery);
      }
      if (_reservation != null) {
        final safe = await _abortReservation('sync_reservation_recovery');
        if (!safe) {
          outcome = NotebookSyncOutcome(success: false,
            error: outcome.error ?? 'sync_reservation_recovery', recoveryRequired: true,
            cancelled: outcome.cancelled, code: outcome.code, conflicts: outcome.conflicts);
        }
      }
      _error = outcome.error;
      _recovery = _recovery || outcome.recoveryRequired;
      _active = null; _operationId = null; _cancelled = null;
      _phase = NotebookSyncPhase.idle;
      reply.complete(outcome);
      _publish();
      scheduleMicrotask(_drainQueue);
      _schedule();
    }());
    return reply.future;
  }

  Future<void> reconcile({bool requestFreshness = false}) async {
    if (_active != null || _core == null || _closing || _logicalClosing || _detaching) return;
    await _start((id) async {
      _setPhase(NotebookSyncPhase.reconciling);
      await _inspect();
      await _completePendingClose(id);
      final facts = _facts!;
      if (facts.registered && (!facts.enabled || _readiness == NotebookSyncReadiness.unsupported ||
          _readiness == NotebookSyncReadiness.invalidEndpoint || _readiness == NotebookSyncReadiness.missingCredentials)) {
        await _lifecycleReservation(id);
        _requireResult(await _command(CoreSyncAction.unregister, id));
        await _settleReservation(null);
        await _inspect();
      }
      if (_readiness == NotebookSyncReadiness.unregistered && !_recovery) {
        await _lifecycleReservation(id);
        final record = await credentials.read(_scope(_facts!));
        _checkCancelled();
        final result = await _command(CoreSyncAction.enable, id,
          configuration: _configuration(_facts!), secret: record.active);
        _requireResult(result, error: 'sync_enable_failed');
        await _settleReservation(null);
        await _inspect();
      }
      return NotebookSyncOutcome(success: !_recovery && _readiness != NotebookSyncReadiness.credentialsUnknown,
        recoveryRequired: _recovery,
        error: _recovery ? 'sync_recovery_required' :
          _readiness == NotebookSyncReadiness.credentialsUnknown ? _error ?? 'vault_unavailable' : null);
    });
    if (requestFreshness && _foreground && _facts?.autoSyncEnabled == true && !_recovery &&
        _readiness == NotebookSyncReadiness.ready) {
      final last = _facts!.lastSuccessUtcMillis;
      if (last == 0 || _clock().millisecondsSinceEpoch - last >= freshness.inMilliseconds) {
        unawaited(_enqueueSync(manual: false));
      }
    }
  }

  SyncCredentialScope _scope(CoreSyncFacts facts) => SyncCredentialScope.notebook(facts.endpoint, notebookId);
  CoreSyncConfiguration _configuration(CoreSyncFacts facts) => CoreSyncConfiguration(
    endpoint: facts.endpoint, enabled: facts.enabled, autoSyncEnabled: facts.autoSyncEnabled);

  Future<void> _inspect() async {
    final facts = await _core!.inspectSync();
    if (facts.notebookId != notebookId) throw const _SyncFailure('sync_identity_changed', recovery: true);
    _facts = facts;
    var presence = SyncCredentialPresence.unknown;
    var orphans = SyncCredentialPresence.unknown;
    var transaction = false;
    try {
      final scopes = await credentials.notebookScopes(notebookId);
      orphans = scopes.isEmpty ? SyncCredentialPresence.absent : SyncCredentialPresence.present;
      for (final scope in scopes) {
        if ((await credentials.read(scope)).pending) transaction = true;
      }
      if (facts.enabled && facts.backend == 'webdav') {
        try {
          final record = await credentials.read(_scope(facts));
          presence = record.hasUsableCredentials ? SyncCredentialPresence.present : SyncCredentialPresence.absent;
          transaction = transaction || record.pending;
        } on SyncVaultException catch (error) {
          if (error.code != 'vault_invalid') rethrow;
        }
      } else {
        presence = SyncCredentialPresence.absent;
      }
    } on SyncVaultException catch (error) {
      _error = error.code;
    }
    _readiness = classifyNotebookSync(enabled: facts.enabled, backend: facts.backend,
      endpoint: facts.endpoint, credentials: presence, registered: facts.registered,
      orphanCredentials: orphans);
    _recovery = _recovery || facts.refreshRequired || facts.recoveryRequired ||
      facts.provider.credentialRecovery || facts.provider.retirement || transaction;
    _publish();
  }

  Future<CoreSyncResult> _command(CoreSyncAction action, String id,
      {CoreSyncConfiguration? configuration, CoreSyncCredentials? secret,
      List<String> protectedNodeIds = const [], bool settled = false,
      String? path, CoreSyncResolution? resolution, String? recoveryOperationId, bool allowCancelled = false}) async {
    if (action == CoreSyncAction.enable || action == CoreSyncAction.credentials ||
        action == CoreSyncAction.credentialRecovery || action == CoreSyncAction.network) {
      if (!await credentials.vault.trustAvailable()) throw const _SyncFailure('sync_trust_unavailable');
      if (!allowCancelled) _checkCancelled();
    }
    return _core!.sync(CoreSyncCommand(action: action, operationId: id,
      configuration: configuration, protectedNodeIds: protectedNodeIds,
      protectMetadata: protectedNodeIds.isNotEmpty, settled: settled, path: path, resolution: resolution,
      recoveryOperationId: recoveryOperationId), credentials: secret);
  }

  void _install(String id, SyncReservationKind kind) {
    _checkCancelled();
    if (_reservation != null) throw const _SyncFailure('sync_reservation_busy', recovery: true);
    // The participant installs exclusion in this synchronous call, not prepare().
    _reservation = _participant!.installSyncReservation(SyncReservationRequest(
      operationId: id, ownerGeneration: _generation, kind: kind));
  }

  Future<T> _deadline<T>(Future<T> work) async {
    Timer? timer;
    final deadline = Completer<T>();
    timer = Timer(reservationTimeout, () => deadline.completeError(
      const _SyncFailure('sync_reservation_timeout')));
    final cancelled = _cancelled!.future.then<T>((_) => throw const _SyncFailure('sync_cancelled'));
    try { return await Future.any([work, deadline.future, cancelled]); }
    finally { timer.cancel(); }
  }

  Future<SyncProtection> _prepareReservation(String id, SyncReservationKind kind) async {
    _install(id, kind);
    final reservation = _reservation!;
    try {
      return await _deadline(() async {
        await reservation.drainWriters();
        if (!identical(_reservation, reservation)) throw const _SyncFailure('sync_cancelled');
        _checkCancelled();
        if (kind == SyncReservationKind.stage) return SyncProtection(dirtyNodeIds: const []);
        final protection = await reservation.quiesceAndDrainDrafts();
        if (!identical(_reservation, reservation)) throw const _SyncFailure('sync_cancelled');
        _checkCancelled();
        // Quiesce is not a durability receipt. Drain again after its captured revision.
        await reservation.drainWriters();
        if (!protection.ownershipKnown) throw const _SyncFailure('sync_ownership_unknown', recovery: true);
        return protection;
      }());
    } on Object {
      await _abortReservation('sync_reservation_recovery');
      rethrow;
    }
  }

  Future<void> _lifecycleReservation(String id) async {
    await _prepareReservation(id, SyncReservationKind.lifecycle);
    _checkCancelled();
  }

  Future<bool> _abortReservation(String error) async {
    final reservation = _reservation;
    if (reservation == null) return true;
    // Drop coordinator ownership before awaits; participant abort invalidates its
    // correlation synchronously. A late reply cannot acquire another reservation.
    _reservation = null;
    var safe = false;
    try { safe = await reservation.abort().timeout(reservationTimeout); }
    on Object { safe = false; }
    if (!safe) {
      _sourceRecovery = true;
      _recovery = true;
      try { reservation.retainRecovery(error); }
      on Object { _error = 'sync_source_recovery'; }
    }
    return safe;
  }

  Future<SyncSettlement> _settleReservation(SyncRefreshReport? report) async {
    final reservation = _reservation!;
    try {
      final settled = await reservation.settle(report).timeout(reservationTimeout);
      _reservation = null;
      if (!settled.safe || settled.recoveryRequired) {
        _sourceRecovery = true;
        _recovery = true;
        reservation.retainRecovery('sync_source_recovery');
        if (report == null) throw const _SyncFailure('sync_source_recovery', recovery: true);
      }
      return settled;
    } on Object {
      _sourceRecovery = true;
      _recovery = true;
      await _abortReservation('sync_source_recovery');
      try { reservation.retainRecovery('sync_source_recovery'); }
      on Object { _error = 'sync_source_recovery'; }
      throw const _SyncFailure('sync_source_recovery', recovery: true);
    }
  }

  Future<NotebookSyncOutcome> _regular(String id) async {
    await _inspect();
    if (_readiness != NotebookSyncReadiness.ready || _recovery) {
      throw _SyncFailure(_recovery ? 'sync_recovery_required' : 'sync_not_ready', recovery: _recovery);
    }
    var begun = false;
    var dispatchedApply = false;
    var finished = false;
    CoreSyncResult? applied;
    CoreSyncResult? refreshed;
    try {
      _setPhase(NotebookSyncPhase.staging);
      await _prepareReservation(id, SyncReservationKind.stage);
      _checkCancelled();
      _requireResult(await _command(CoreSyncAction.begin, id));
      begun = true;
      _requireResult(await _command(CoreSyncAction.stage, id));
      final stageSettlement = await _settleReservation(null);
      if (!stageSettlement.safe || stageSettlement.recoveryRequired) throw const _SyncFailure('sync_source_recovery', recovery: true);
      _checkCancelled();
      _setPhase(NotebookSyncPhase.network);
      _requireResult(await _command(CoreSyncAction.network, id));
      _checkCancelled();
      _setPhase(NotebookSyncPhase.reserving);
      final protection = await _prepareReservation(id, SyncReservationKind.apply);
      _checkCancelled();
      _setPhase(NotebookSyncPhase.applying);
      // Native persists the private refresh-required marker before applying.
      dispatchedApply = true;
      try {
        applied = await _command(CoreSyncAction.apply, id, protectedNodeIds: protection.dirtyNodeIds);
      } finally {
        // Cancellation never skips actual refresh after a dispatched apply.
        _setPhase(NotebookSyncPhase.refreshing);
        refreshed = await _command(CoreSyncAction.refresh, id);
      }
      final complete = applied.success && refreshed.success && refreshed.refreshCode == 0 &&
          applied.changedPaths != null && !_cancelled!.isCompleted;
      _setPhase(NotebookSyncPhase.settling);
      final settlement = await _settleReservation(SyncRefreshReport(
        metadataRefreshed: refreshed.refreshCode == 0,
        operationSucceeded: complete, changedPaths: applied.changedPaths));
      // Safe source retirement is independent of operation success. Native
      // finish retains the original failure and alone gates last-success writes.
      final safe = !_cancelled!.isCompleted && settlement.safe && !settlement.recoveryRequired;
      final result = await _command(CoreSyncAction.finish, id, settled: safe);
      finished = true;
      await _inspect();
      _requireResult(result, error: 'sync_finish_failed');
      if (!complete || !safe || !result.settled) {
        return NotebookSyncOutcome(success: false, cancelled: _cancelled!.isCompleted,
          recoveryRequired: _recovery || refreshed.refreshCode != 0 || applied.changedPaths == null,
          code: !applied.success ? applied.code : !refreshed.success ? refreshed.code : null,
          error: _cancelled!.isCompleted ? 'sync_cancelled' :
              applied.changedPaths == null ? 'sync_changed_paths_unavailable' : 'sync_incomplete');
      }
      return const NotebookSyncOutcome(success: true);
    } finally {
      if (begun && !finished) {
        _setPhase(NotebookSyncPhase.settling);
        if (dispatchedApply && refreshed == null) {
          try { refreshed = await _command(CoreSyncAction.refresh, id); }
          on Object { _recovery = true; }
        }
        if (dispatchedApply && _reservation != null) {
          try {
            await _settleReservation(SyncRefreshReport(
              metadataRefreshed: refreshed?.refreshCode == 0,
              operationSucceeded: false, changedPaths: applied?.changedPaths));
          } on Object { _recovery = true; }
        }
        try {
          final retirement = await _command(CoreSyncAction.finish, id);
          await _inspect();
          // A failed network/apply code is not itself an unretired lease.
          // Preserve the primary error; actual retained flags require recovery.
          _recovery = _recovery || retirement.cleanupRequired || retirement.refreshRequired;
        } on Object { _recovery = true; }
      }
    }
  }

  Future<NotebookSyncOutcome> configure({required String endpoint,
    required String username, required String password, bool autoSyncEnabled = false,
    bool confirmEndpointChange = false}) => _start((id) => _configure(id,
      endpoint: endpoint, username: username, password: password,
      autoSyncEnabled: autoSyncEnabled, confirmEndpointChange: confirmEndpointChange));

  Future<NotebookSyncOutcome> _configure(String id, {required String endpoint,
    required String username, required String password, required bool autoSyncEnabled,
    required bool confirmEndpointChange}) async {
    _setPhase(NotebookSyncPhase.configuring);
    final canonical = canonicalSyncEndpoint(endpoint);
    await _inspect();
    final before = _facts!;
    if (_recovery) throw const _SyncFailure('sync_recovery_required', recovery: true);
    if (before.enabled && before.backend != 'webdav') throw const _SyncFailure('sync_unsupported_backend');
    final previousEndpoint = before.provider.bindingEndpoint ?? (before.enabled ? before.endpoint : null);
    final changingEndpoint = previousEndpoint != null && previousEndpoint.isNotEmpty &&
        canonicalSyncEndpoint(previousEndpoint) != canonical;
    if (changingEndpoint && !confirmEndpointChange) throw const _SyncFailure('sync_endpoint_confirmation_required');
    if (before.enabled && !changingEndpoint && _readiness == NotebookSyncReadiness.ready) {
      final rotated = await _rotate(id, username: username, password: password);
      if (!rotated.success) return rotated;
      await _lifecycleReservation(id);
      _requireResult(await _command(CoreSyncAction.configure, id,
        configuration: CoreSyncConfiguration(endpoint: canonical, autoSyncEnabled: autoSyncEnabled)));
      await _settleReservation(null);
      await _inspect();
      return const NotebookSyncOutcome(success: true);
    }
    await _lifecycleReservation(id);
    final targetScope = SyncCredentialScope.notebook(canonical, notebookId);
    final oldRecord = changingEndpoint
        ? await credentials.read(SyncCredentialScope.notebook(previousEndpoint, notebookId)) : null;
    // Disabled orphan generations must settle before a new enable can write.
    if (!before.enabled) {
      if (before.registered) {
        _requireResult(await _command(CoreSyncAction.disable, id));
        if ((await _core!.inspectSync()).registered) throw const _SyncFailure('sync_disable_recovery', recovery: true);
      }
      for (final scope in await credentials.notebookScopes(notebookId)) {
        final orphan = await credentials.read(scope);
        if (orphan.pending) throw const _SyncFailure('sync_recovery_required', recovery: true);
        await credentials.remove(orphan);
      }
    }
    var record = await credentials.stage(scope: targetScope, operationId: id,
      kind: changingEndpoint ? SyncCredentialKind.endpoint : SyncCredentialKind.enable,
      username: username, password: password,
      previousEndpoint: changingEndpoint ? previousEndpoint : null, previousRevision: oldRecord?.revision);
    var coreCommitted = false;
    var archived = false;
    var oldUnregistered = false;
    try {
      if (!await credentials.vault.trustAvailable()) throw const _SyncFailure('sync_trust_unavailable');
      _checkCancelled();
      if (changingEndpoint) {
        _requireResult(await _command(CoreSyncAction.providerInspect, id));
        _requireResult(await _command(CoreSyncAction.unregister, id));
        oldUnregistered = before.enabled && before.registered;
        _requireResult(await _command(CoreSyncAction.providerBegin, id));
        archived = true;
        _requireResult(await _command(CoreSyncAction.configure, id,
          configuration: CoreSyncConfiguration(endpoint: '', enabled: false,
            autoSyncEnabled: before.autoSyncEnabled)));
        _requireResult(await _command(CoreSyncAction.providerCommit, id));
      }
      final configuration = CoreSyncConfiguration(endpoint: canonical,
        autoSyncEnabled: autoSyncEnabled);
      final enabled = await _command(CoreSyncAction.enable, id,
        configuration: configuration, secret: record.candidateCredentials);
      coreCommitted = enabled.committed;
      if (enabled.cleanupRequired) throw _SyncFailure('sync_credential_recovery', code: enabled.code, recovery: true);
      _requireResult(enabled, error: 'sync_enable_failed');
      if (!enabled.committed) throw const _SyncFailure('sync_enable_uncommitted', recovery: true);
      record = await credentials.mark(record, SyncCredentialPhase.coreCommitted);
      _requireResult(await _command(CoreSyncAction.configure, id, configuration: configuration));
      record = await credentials.mark(record, SyncCredentialPhase.routingCommitted);
      record = await credentials.promote(record);
      await credentials.retire(record);
      await _settleReservation(null);
      _recovery = false;
      await _inspect();
      return const NotebookSyncOutcome(success: true);
    } on Object {
      var compensated = !coreCommitted && !archived;
      try {
        final actual = await _core!.inspectSync();
        if (actual.provider.credentialRecovery || actual.provider.probe || actual.provider.retirement) compensated = false;
        if (oldUnregistered && !archived && compensated) {
          if (oldRecord?.active == null) throw const _SyncFailure('sync_credential_recovery', recovery: true);
          final restored = await _command(CoreSyncAction.enable, id,
            configuration: _configuration(before), secret: oldRecord!.active, allowCancelled: true);
          _requireResult(restored);
          if (!restored.committed || restored.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
        }
        if (coreCommitted && record.phase != SyncCredentialPhase.promoted) {
          _requireResult(await _command(CoreSyncAction.disable, id));
          if (before.enabled && !archived) {
            if (record.oldCredentials == null) throw const _SyncFailure('sync_credential_recovery', recovery: true);
            final restored = await _command(CoreSyncAction.enable, id,
              configuration: _configuration(before), secret: record.oldCredentials, allowCancelled: true);
            _requireResult(restored);
            if (!restored.committed || restored.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
            _requireResult(await _command(CoreSyncAction.configure, id, configuration: _configuration(before)));
          } else {
            _requireResult(await _command(CoreSyncAction.configure, id,
              configuration: CoreSyncConfiguration(endpoint: '', enabled: false,
                autoSyncEnabled: before.autoSyncEnabled)));
          }
          compensated = !archived && !actual.provider.credentialRecovery && !actual.provider.probe;
        }
        if (compensated) { await credentials.rollback(record); }
        else { await credentials.mark(record, SyncCredentialPhase.recoveryRequired); _recovery = true; }
      } on Object { _recovery = true; }
      rethrow;
    }
  }

  Future<NotebookSyncOutcome> rotateCredentials({required String username, required String password}) =>
      _start((id) => _rotate(id, username: username, password: password));

  Future<NotebookSyncOutcome> _rotate(String id, {required String username, required String password}) async {
    _setPhase(NotebookSyncPhase.rotating);
    await _inspect();
    if (_recovery || _readiness != NotebookSyncReadiness.ready) throw _SyncFailure('sync_not_ready', recovery: _recovery);
    await _lifecycleReservation(id);
    var record = await credentials.stage(scope: _scope(_facts!), operationId: id,
      kind: SyncCredentialKind.rotation, username: username, password: password);
    var committed = false;
    try {
      _checkCancelled();
      final result = await _command(CoreSyncAction.credentials, id, secret: record.candidateCredentials);
      committed = result.committed;
      if (result.cleanupRequired) throw _SyncFailure('sync_credential_recovery', code: result.code, recovery: true);
      _requireResult(result, error: 'sync_rotation_failed');
      if (!committed) throw const _SyncFailure('sync_rotation_uncommitted', recovery: true);
      record = await credentials.mark(record, SyncCredentialPhase.coreCommitted);
      record = await credentials.promote(record);
      await credentials.retire(record);
      await _settleReservation(null);
      _recovery = false;
      await _inspect();
      return const NotebookSyncOutcome(success: true);
    } on Object {
      try {
        final actual = await _core!.inspectSync();
        if (actual.provider.credentialRecovery || actual.provider.probe || record.phase == SyncCredentialPhase.promoted) {
          _recovery = true;
        } else {
          if (committed) {
            final old = record.oldCredentials;
            if (old == null) throw const _SyncFailure('sync_credential_recovery', recovery: true);
            final restored = await _command(CoreSyncAction.credentials, id, secret: old, allowCancelled: true);
            _requireResult(restored);
            if (!restored.committed || restored.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
          }
          await credentials.rollback(record);
        }
        if (_recovery && record.phase != SyncCredentialPhase.promoted) {
          await credentials.mark(record, SyncCredentialPhase.recoveryRequired);
        }
      } on Object { _recovery = true; }
      rethrow;
    }
  }

  Future<NotebookSyncOutcome> disable() {
    _stopQueued('sync_disabled');
    return _start((id) async {
      _setPhase(NotebookSyncPhase.disabling);
      await _inspect();
      final before = _facts!;
      if (before.enabled && before.backend != 'webdav') throw const _SyncFailure('sync_unsupported_backend');
      if (_recovery) throw const _SyncFailure('sync_recovery_required', recovery: true);
      await _lifecycleReservation(id);
      final records = <SyncCredentialRecord>[];
      for (final scope in await credentials.notebookScopes(notebookId)) {
        final record = await credentials.read(scope);
        if (record.pending) throw const _SyncFailure('sync_recovery_required', recovery: true);
        records.add(await credentials.beginDisable(record, id));
      }
      var disabled = false;
      try {
        _requireResult(await _command(CoreSyncAction.disable, id), error: 'sync_disable_failed');
        disabled = true;
        _requireResult(await _command(CoreSyncAction.configure, id,
          configuration: CoreSyncConfiguration(endpoint: '', enabled: false,
            autoSyncEnabled: before.autoSyncEnabled)), error: 'sync_configuration_failed');
        for (final record in records) { await credentials.remove(record); }
        await _settleReservation(null);
        _recovery = false;
        await _inspect();
        return const NotebookSyncOutcome(success: true);
      } on Object {
        try {
          final actual = await _core!.inspectSync();
          if (disabled && actual.enabled) {
            final active = records.where((record) => record.scope.endpoint == canonicalSyncEndpoint(before.endpoint)).firstOrNull;
            if (active?.oldCredentials == null) throw const _SyncFailure('sync_disable_recovery', recovery: true);
            final restored = await _command(CoreSyncAction.enable, id,
              configuration: _configuration(before), secret: active!.oldCredentials, allowCancelled: true);
            _requireResult(restored);
            if (!restored.committed) throw const _SyncFailure('sync_disable_recovery', recovery: true);
          }
          if (actual.enabled) {
            for (final record in records) { await credentials.rollback(record); }
          } else {
            _recovery = true;
          }
        } on Object { _recovery = true; }
        rethrow;
      }
    });
  }

  Future<NotebookSyncOutcome> setAutoSyncEnabled(bool enabled) => _start((id) async {
    await _inspect();
    if (_facts!.enabled && _facts!.backend != 'webdav') throw const _SyncFailure('sync_unsupported_backend');
    await _lifecycleReservation(id);
    _requireResult(await _command(CoreSyncAction.configure, id,
      configuration: CoreSyncConfiguration(endpoint: _facts!.endpoint,
        enabled: _facts!.enabled, autoSyncEnabled: enabled)));
    if (!enabled) { _timer?.cancel(); _timer = null; _autoPending = false; }
    await _settleReservation(null);
    await _inspect();
    return const NotebookSyncOutcome(success: true);
  });

  Future<NotebookSyncOutcome> recover({String? username, String? password}) =>
      _recover(username: username, password: password);

  Future<NotebookSyncOutcome> _recover({String? username, String? password}) => _start((id) async {
    _setPhase(NotebookSyncPhase.recovering);
    await _inspect();
    final closed = await _completePendingClose(id, recoverSources: true);
    if (closed) {
      return NotebookSyncOutcome(success: !_recovery, recoveryRequired: _recovery,
        error: _recovery ? 'sync_recovery_required' : null);
    }
    await _lifecycleReservation(id);
    var facts = _facts!;
    if (facts.refreshRequired) {
      var settled = false;
      try {
        final refreshed = await _command(CoreSyncAction.refresh, id);
        if (refreshed.refreshCode != 0) throw const _SyncFailure('sync_refresh_recovery', recovery: true);
        if (!await _participant!.recoverSyncSources()) throw const _SyncFailure('sync_source_recovery', recovery: true);
        await _settleReservation(null);
        settled = true;
      } on Object {
        if (_reservation != null) {
          try {
            await _settleReservation(SyncRefreshReport(metadataRefreshed: false,
              operationSucceeded: false, changedPaths: null));
          } on Object { _recovery = true; }
        }
        rethrow;
      } finally {
        // A recovery-only lease never advances last-success. It retains the
        // private marker unless actual refresh AND source retirement are proved.
        _requireResult(await _command(CoreSyncAction.finish, id, settled: settled));
      }
      facts = await _core!.inspectSync();
      await _lifecycleReservation(id);
    }
    if (!facts.enabled && facts.registered) {
      _requireResult(await _command(CoreSyncAction.disable, id));
      facts = await _core!.inspectSync();
      if (facts.registered) throw const _SyncFailure('sync_disable_recovery', recovery: true);
    }
    var providerRecovered = false;
    if (facts.provider.retirement) {
      _requireResult(await _command(CoreSyncAction.providerRecover, id));
      providerRecovered = true;
      facts = await _core!.inspectSync();
    }
    final scopes = await credentials.notebookScopes(notebookId);
    final retainedPredecessors = <String>{};
    for (final scope in scopes) {
      final transaction = await credentials.read(scope);
      if (transaction.pending && transaction.previousEndpoint != null) {
        retainedPredecessors.add(SyncCredentialScope.notebook(transaction.previousEndpoint!, notebookId).key);
      }
    }
    for (final scope in scopes) {
      var record = await credentials.read(scope);
      if (!record.present || record.kind == SyncCredentialKind.close) continue;
      if (!record.pending && retainedPredecessors.contains(scope.key)) continue;
      if (record.kind == SyncCredentialKind.clone) {
        throw const _SyncFailure('sync_clone_publication_recovery', recovery: true);
      }
      if (facts.provider.credentialRecovery) {
        if (!record.pending || record.candidateCredentials == null) continue;
        final secret = username != null && password != null
            ? CoreSyncCredentials(username: username, password: password) : record.candidateCredentials;
        final cleanup = await _command(CoreSyncAction.credentialRecovery, id,
          configuration: CoreSyncConfiguration(endpoint: scope.endpoint, autoSyncEnabled: facts.autoSyncEnabled),
          secret: secret, recoveryOperationId: record.operationId);
        _requireResult(cleanup, error: 'sync_credential_recovery');
        if (cleanup.committed || cleanup.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
        // Cleanup is not provider publication. Keep the old binding, discard only
        // our proved candidate, and require a separate fresh configure/rotation.
        await credentials.rollback(record);
        facts = await _core!.inspectSync();
        continue;
      }
      if (facts.enabled && record.kind == SyncCredentialKind.disable) {
        if (canonicalSyncEndpoint(facts.endpoint) == scope.endpoint && !facts.registered) {
          final enabled = await _command(CoreSyncAction.enable, id,
            configuration: _configuration(facts), secret: record.oldCredentials);
          _requireResult(enabled);
          if (!enabled.committed || enabled.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
          facts = await _core!.inspectSync();
        }
        await credentials.rollback(record);
        continue;
      }
      if (!facts.enabled) {
        if (record.kind == SyncCredentialKind.disable || !record.pending) {
          await credentials.remove(record);
        } else if (record.oldCredentials != null) {
          await credentials.rollback(record);
        } else {
          // Disabled endpoint failures retain the candidate until an explicit
          // recovery retries authentication and routing under the new lease.
          final config = CoreSyncConfiguration(endpoint: scope.endpoint,
            autoSyncEnabled: facts.autoSyncEnabled);
          final enabled = await _command(CoreSyncAction.enable, id,
            configuration: config, secret: record.candidateCredentials);
          _requireResult(enabled);
          if (!enabled.committed || enabled.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
          if (record.phase != SyncCredentialPhase.promoted && record.phase != SyncCredentialPhase.routingCommitted) {
            record = await credentials.mark(record, SyncCredentialPhase.coreCommitted);
          }
          _requireResult(await _command(CoreSyncAction.configure, id, configuration: config));
          if (record.phase != SyncCredentialPhase.promoted) {
            record = await credentials.mark(record, SyncCredentialPhase.routingCommitted);
            record = await credentials.promote(record);
          }
          await credentials.retire(record);
          facts = await _core!.inspectSync();
        }
      } else if (canonicalSyncEndpoint(facts.endpoint) == scope.endpoint && record.pending) {
        // Durable phases alone are not proof: authenticate the retained version
        // against actual routing/identity before promotion or retirement.
        final enabled = await _command(facts.registered ? CoreSyncAction.credentials : CoreSyncAction.enable, id,
          configuration: facts.registered ? null : _configuration(facts), secret: record.candidateCredentials);
        _requireResult(enabled);
        if (!enabled.committed || enabled.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
        if (record.phase != SyncCredentialPhase.promoted) {
          if (record.phase == SyncCredentialPhase.staged || record.phase == SyncCredentialPhase.recoveryRequired) {
            record = await credentials.mark(record, SyncCredentialPhase.coreCommitted);
          }
          record = await credentials.mark(record, SyncCredentialPhase.routingCommitted);
          record = await credentials.promote(record);
        }
        await credentials.retire(record);
        facts = await _core!.inspectSync();
      } else if (record.pending) {
        final restoredBinding = facts.provider.bindingEndpoint;
        final restoredOldEndpoint = providerRecovered && record.kind == SyncCredentialKind.endpoint &&
          record.phase != SyncCredentialPhase.promoted && record.previousEndpoint != null &&
          canonicalSyncEndpoint(facts.endpoint) == record.previousEndpoint &&
          (restoredBinding == null || canonicalSyncEndpoint(restoredBinding) == record.previousEndpoint) &&
          !facts.provider.credentialRecovery && !facts.provider.probe && !facts.provider.retirement;
        if (!restoredOldEndpoint) throw const _SyncFailure('sync_routing_recovery', recovery: true);
        // The core proved restoration of the pre-archive binding, not candidate
        // publication. Retain the old scope and discard only our staged target.
        await credentials.rollback(record);
      }
    }
    facts = await _core!.inspectSync();
    if (facts.provider.credentialRecovery || facts.provider.retirement || facts.refreshRequired) {
      throw const _SyncFailure('sync_recovery_required', recovery: true);
    }
    _facts = facts;
    if (await _completePendingClose(id, recoverSources: true)) {
      return NotebookSyncOutcome(success: !_recovery, recoveryRequired: _recovery,
        error: _recovery ? 'sync_recovery_required' : null);
    }
    if (facts.enabled && facts.backend == 'webdav' && !facts.registered && !_logicalClosing) {
      final retained = await credentials.read(_scope(facts));
      if (retained.pending) throw const _SyncFailure('sync_credential_recovery', recovery: true);
      if (retained.active != null) {
        final enabled = await _command(CoreSyncAction.enable, id,
          configuration: _configuration(facts), secret: retained.active);
        _requireResult(enabled);
        if (!enabled.committed || enabled.cleanupRequired) throw const _SyncFailure('sync_credential_recovery', recovery: true);
      }
    }
    if (!await _participant!.recoverSyncSources()) {
      _sourceRecovery = true;
      throw const _SyncFailure('sync_source_recovery', recovery: true);
    }
    await _settleReservation(null);
    _sourceRecovery = false;
    _recovery = false;
    await _inspect();
    return NotebookSyncOutcome(success: !_recovery, recoveryRequired: _recovery,
      error: _recovery ? 'sync_recovery_required' : null);
  }, closingNotebook: true);

  List<NotebookSyncResolution>? _resolvingBatch;
  Future<NotebookSyncOutcome> resolveConflicts(List<NotebookSyncResolution> resolutions) {
    if (resolutions.isEmpty || resolutions.length > 256 || _batches.length >= 16 ||
        _closing || _logicalClosing || _detaching || _core == null) {
      return Future.value(const NotebookSyncOutcome(success: false, error: 'sync_conflict_batch_invalid'));
    }
    final reply = Completer<NotebookSyncOutcome>();
    _batches.add(List.unmodifiable(resolutions));
    _batchReplies.add(reply);
    _drainQueue();
    _publish();
    return reply.future;
  }

  Future<NotebookSyncOutcome> _resolveBatch(String id) async {
    final resolutions = _resolvingBatch!;
    _resolvingBatch = null;
    _setPhase(NotebookSyncPhase.conflicts);
    try {
      await _inspect();
      if (_recovery || _readiness != NotebookSyncReadiness.ready) throw _SyncFailure('sync_not_ready', recovery: _recovery);
      await _lifecycleReservation(id);
    } on Object catch (failure) {
      final error = failure is _SyncFailure ? failure.error : 'sync_conflict_admission_failed';
      _conflictOutcomes = List.unmodifiable(resolutions.map((request) => NotebookSyncConflictOutcome(
        path: request.path, resolution: request.resolution, success: false, error: error)));
      return NotebookSyncOutcome(success: false, error: error, recoveryRequired: _recovery,
        conflicts: _conflictOutcomes);
    }
    final outcomes = <NotebookSyncConflictOutcome>[];
    for (final request in resolutions) {
      if (_cancelled!.isCompleted) {
        outcomes.add(NotebookSyncConflictOutcome(path: request.path,
          resolution: request.resolution, success: false, error: 'sync_cancelled'));
        continue;
      }
      if (request.ownerGeneration != _generation) {
        outcomes.add(NotebookSyncConflictOutcome(path: request.path,
          resolution: request.resolution, success: false, error: 'sync_stale_conflict'));
        continue;
      }
      try {
        final actual = await _core!.inspectSync();
        final conflict = actual.conflicts.where((item) => item.path == request.path).firstOrNull;
        if (conflict == null || (request.resolution == CoreSyncResolution.keepBoth && !conflict.canKeepBoth)) {
          throw const _SyncFailure('sync_conflict_choice_unavailable');
        }
        final result = await _command(CoreSyncAction.resolve, id, path: request.path,
          resolution: request.resolution);
        outcomes.add(NotebookSyncConflictOutcome(path: request.path,
          resolution: request.resolution, success: result.success, code: result.code,
          error: result.success ? null : 'sync_conflict_failed'));
      } on _SyncFailure catch (error) {
        outcomes.add(NotebookSyncConflictOutcome(path: request.path,
          resolution: request.resolution, success: false, error: error.error));
      } on Object {
        outcomes.add(NotebookSyncConflictOutcome(path: request.path,
          resolution: request.resolution, success: false, error: 'sync_conflict_failed'));
      }
    }
    _conflictOutcomes = List.unmodifiable(outcomes);
    await _settleReservation(null);
    if (_cancelled!.isCompleted) {
      return NotebookSyncOutcome(success: false, cancelled: true,
        error: 'sync_cancelled', conflicts: _conflictOutcomes);
    }
    // Resolution changes use the same staged network/apply/refresh policy. A
    // partial batch never silently drops the failed rows or retries their choice.
    NotebookSyncOutcome synced;
    try {
      synced = outcomes.any((item) => item.success) ? await _regular(id) :
          const NotebookSyncOutcome(success: false, error: 'sync_conflict_failed');
    } on _SyncFailure catch (failure) {
      synced = NotebookSyncOutcome(success: false, error: failure.error, code: failure.code,
        cancelled: failure.error == 'sync_cancelled', recoveryRequired: failure.recovery || _recovery);
    } on Object {
      synced = NotebookSyncOutcome(success: false, error: 'sync_failed', recoveryRequired: _recovery);
    }
    return NotebookSyncOutcome(success: synced.success && outcomes.every((item) => item.success),
      cancelled: synced.cancelled, recoveryRequired: synced.recoveryRequired,
      error: outcomes.any((item) => !item.success) ? 'sync_conflict_partial' : synced.error,
      code: synced.code, conflicts: _conflictOutcomes);
  }
}
