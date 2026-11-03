// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/notebook_sync.dart';
import 'package:vnote_mobile/services/sync_credentials.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'sync_credentials_test.dart' show TestSyncVault, seedSyncCredentials,
  syncTestNotebook, syncTestEndpoint;

/// These doubles exercise coordinator ordering/failure policy only. The tagged
/// integration suite exercises actual core, filesystem and HTTPS boundaries.
class _Core implements SyncCore {
  bool enabled = true;
  bool registered = true;
  bool auto = false;
  String backend = 'webdav';
  String endpoint = syncTestEndpoint;
  int lastSuccess = 0;
  bool refreshRequired = false;
  bool candidateRecovery = false;
  bool retirement = false;
  bool regularLease = false;
  bool recoveryLease = false;
  List<CoreSyncConflict> conflicts = [];
  List<String>? changedPaths = ['note.md'];
  int applyCode = 0;
  int refreshCode = 0;
  final commands = <CoreSyncCommand>[];
  final cancels = <String>[];
  final signals = <CoreSyncAction, List<Completer<void>>>{};
  final barriers = <CoreSyncAction, Queue<Completer<void>>>{};
  Future<CoreSyncResult?> Function(CoreSyncCommand, CoreSyncCredentials?)? intercept;

  Future<void> entered(CoreSyncAction action, [int occurrence = 1]) {
    final entries = signals.putIfAbsent(action, () => []);
    while (entries.length < occurrence) { entries.add(Completer<void>()); }
    if (commands.where((command) => command.action == action).length >= occurrence &&
        !entries[occurrence - 1].isCompleted) { entries[occurrence - 1].complete(); }
    return entries[occurrence - 1].future;
  }
  Completer<void> block(CoreSyncAction action) {
    final barrier = Completer<void>();
    barriers.putIfAbsent(action, () => Queue()).add(barrier);
    return barrier;
  }
  @override
  Future<CoreSyncFacts> inspectSync() async => CoreSyncFacts(notebookId: syncTestNotebook,
    enabled: enabled, backend: backend, endpoint: endpoint, autoSyncEnabled: auto,
    registered: registered, ready: registered, lastSuccessUtcMillis: lastSuccess,
    refreshRequired: refreshRequired, conflicts: conflicts,
    recoveryRequired: refreshRequired || candidateRecovery || retirement,
    provider: CoreSyncProviderFacts(credentialRecovery: candidateRecovery, retirement: retirement));
  @override
  void cancelSync(String operationId) { cancels.add(operationId); }
  @override
  Future<CoreSyncResult> sync(CoreSyncCommand command, {CoreSyncCredentials? credentials}) async {
    commands.add(command);
    final occurrence = commands.where((item) => item.action == command.action).length;
    final entries = signals[command.action];
    if (entries != null && entries.length >= occurrence && !entries[occurrence - 1].isCompleted) {
      entries[occurrence - 1].complete();
    }
    final barriersForAction = barriers[command.action];
    if (barriersForAction != null && barriersForAction.isNotEmpty) await barriersForAction.removeFirst().future;
    final override = await intercept?.call(command, credentials);
    if (override != null) return override;
    final code = command.action == CoreSyncAction.apply ? applyCode :
      command.action == CoreSyncAction.finish && regularLease ?
        (applyCode != 0 ? applyCode : refreshCode) : 0;
    switch (command.action) {
      case CoreSyncAction.begin:
        regularLease = true;
      case CoreSyncAction.enable:
        registered = true;
      case CoreSyncAction.disable || CoreSyncAction.unregister:
        registered = false;
      case CoreSyncAction.configure:
        enabled = command.configuration!.enabled;
        auto = command.configuration!.autoSyncEnabled;
        endpoint = enabled ? command.configuration!.endpoint : '';
        backend = enabled ? 'webdav' : '';
      case CoreSyncAction.apply:
        refreshRequired = true;
      case CoreSyncAction.refresh:
        if (!regularLease) recoveryLease = true;
        if (refreshCode == 0 && !recoveryLease) refreshRequired = false;
      case CoreSyncAction.finish:
        if (command.settled && !recoveryLease && code == 0 && changedPaths != null) lastSuccess++;
        if (command.settled && recoveryLease && refreshCode == 0) refreshRequired = false;
        regularLease = false;
        recoveryLease = false;
      case CoreSyncAction.credentialRecovery:
        candidateRecovery = false;
      case CoreSyncAction.providerRecover:
        retirement = false;
      default:
        break;
    }
    return CoreSyncResult(operationId: command.operationId, action: command.action,
      code: code,
      executed: true,
      committed: command.action == CoreSyncAction.enable || command.action == CoreSyncAction.credentials,
      refreshCode: command.action == CoreSyncAction.refresh ? refreshCode : null,
      changedPaths: command.action == CoreSyncAction.apply ? changedPaths : null,
      settled: command.action == CoreSyncAction.finish && command.settled);
  }
}

class _Reservation implements NotebookSyncReservation {
  _Reservation(this.owner, this.request);
  final _Participant owner;
  final SyncReservationRequest request;
  bool retired = false;
  bool recovery = false;
  int drains = 0;
  int quiesces = 0;
  int aborts = 0;
  @override
  Future<void> drainWriters() async {
    drains++;
    final gate = owner.writerGate;
    if (gate != null) await gate.future;
  }
  @override
  Future<SyncProtection> quiesceAndDrainDrafts() async {
    if (retired) throw StateError('Retired control cannot freeze a successor.');
    quiesces++;
    if (owner.quiesceEntered != null && !owner.quiesceEntered!.isCompleted) owner.quiesceEntered!.complete();
    final gate = owner.quiesceGate;
    if (gate != null) await gate.future;
    if (retired) throw StateError('Late quiesce ignored.');
    final drafts = owner.draftGate;
    if (drafts != null) await drafts.future;
    return SyncProtection(dirtyNodeIds: owner.dirtyIds, ownershipKnown: owner.ownershipKnown);
  }
  @override
  Future<bool> abort() async {
    retired = true; // Correlation retires before waiting for aborted receipt.
    aborts++;
    if (owner.abortGate != null) await owner.abortGate!.future;
    return owner.abortSafe;
  }
  @override
  void retainRecovery(String code) { retired = true; recovery = true; owner.recoveryCodes.add(code); }
  @override
  Future<SyncSettlement> settle(SyncRefreshReport? report) async {
    owner.reports.add(report);
    if (owner.settleGate != null) await owner.settleGate!.future;
    if (report != null && (!report.metadataRefreshed || report.changedPaths == null)) {
      return const SyncSettlement(safe: false, recoveryRequired: true);
    }
    retired = true;
    return SyncSettlement(safe: owner.settlementSafe, recoveryRequired: !owner.settlementSafe);
  }
}

class _Participant implements NotebookSyncParticipant {
  final reservations = <_Reservation>[];
  final reports = <SyncRefreshReport?>[];
  final recoveryCodes = <String>[];
  List<String> dirtyIds = [];
  bool ownershipKnown = true;
  bool abortSafe = true;
  bool settlementSafe = true;
  bool recoverySafe = true;
  int recoveries = 0;
  Completer<void>? writerGate;
  Completer<void>? quiesceGate;
  Completer<void>? quiesceEntered;
  Completer<void>? draftGate;
  Completer<void>? abortGate;
  Completer<void>? settleGate;
  void Function(_Reservation)? installed;
  @override
  NotebookSyncReservation installSyncReservation(SyncReservationRequest request) {
    final reservation = _Reservation(this, request);
    reservations.add(reservation);
    installed?.call(reservation);
    return reservation;
  }
  @override
  Future<bool> recoverSyncSources() async { recoveries++; return recoverySafe; }
}

class _Harness {
  _Harness({Duration timeout = const Duration(seconds: 5), Duration autoDelay = const Duration(seconds: 30)}) {
    credentials = SyncCredentials(vault: vault);
    sync = NotebookSync(notebookId: syncTestNotebook, credentials: credentials,
      reservationTimeout: timeout, autoDelay: autoDelay);
  }
  final core = _Core();
  final vault = TestSyncVault();
  final participant = _Participant();
  late final SyncCredentials credentials;
  late final NotebookSync sync;
  Future<void> attach() async {
    await seedSyncCredentials(credentials);
    await sync.attach(core: core, participant: participant);
  }
  Future<void> close() async { await sync.close(); sync.dispose(); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('readiness precedence and unknown vault are independent of busy overlay', () {
    NotebookSyncReadiness classify({bool enabled = true, String backend = 'webdav',
      String endpoint = syncTestEndpoint, SyncCredentialPresence credentials = SyncCredentialPresence.present,
      bool registered = true, SyncCredentialPresence orphan = SyncCredentialPresence.absent}) =>
      classifyNotebookSync(enabled: enabled, backend: backend, endpoint: endpoint,
        credentials: credentials, registered: registered, orphanCredentials: orphan);
    expect(classify(enabled: false, backend: 'unsupported', endpoint: ''), NotebookSyncReadiness.disabled);
    expect(classify(enabled: false, orphan: SyncCredentialPresence.present), NotebookSyncReadiness.orphan);
    expect(classify(enabled: false, orphan: SyncCredentialPresence.unknown), NotebookSyncReadiness.credentialsUnknown);
    expect(classify(backend: '', endpoint: '', credentials: SyncCredentialPresence.unknown), NotebookSyncReadiness.unsupported);
    expect(classify(endpoint: '', credentials: SyncCredentialPresence.unknown), NotebookSyncReadiness.invalidEndpoint);
    expect(classify(credentials: SyncCredentialPresence.absent), NotebookSyncReadiness.missingCredentials);
    expect(classify(credentials: SyncCredentialPresence.unknown), NotebookSyncReadiness.credentialsUnknown);
    expect(classify(registered: false), NotebookSyncReadiness.unregistered);
    expect(classify(), NotebookSyncReadiness.ready);
  });

  test('stage is installed before begin; apply drains drafts and protects dirty IDs', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.participant.dirtyIds = ['current-node', 'retained-draft-node'];
    h.core.intercept = (command, _) async {
      if (command.action == CoreSyncAction.begin) {
        expect(h.participant.reservations.last.request.kind, SyncReservationKind.stage);
        expect(h.participant.reservations.last.drains, 1);
        expect(h.sync.value.allowsLocalWrites, isFalse);
      }
      if (command.action == CoreSyncAction.network) expect(h.sync.value.allowsLocalWrites, isTrue);
      if (command.action == CoreSyncAction.apply) {
        expect(h.participant.reservations.last.drains, 2);
        expect(h.participant.reservations.last.quiesces, 1);
        expect(command.protectedNodeIds, ['current-node', 'retained-draft-node']);
        expect(command.protectMetadata, isTrue);
      }
      if (command.action == CoreSyncAction.finish) {
        expect(h.participant.reports.last!.changedPaths, ['note.md']);
        expect(h.sync.value.allowsLocalWrites, isFalse);
      }
      return null;
    };
    final outcome = await h.sync.syncNow();
    expect(outcome.success, isTrue);
    expect(h.core.commands.map((command) => command.action), [
      CoreSyncAction.begin, CoreSyncAction.stage, CoreSyncAction.network,
      CoreSyncAction.apply, CoreSyncAction.refresh, CoreSyncAction.finish,
    ]);
    expect(h.sync.value.lastSuccessUtcMillis, 1);
  });

  test('manual requests coalesce into one newest follow-up while network is active', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final network = h.core.block(CoreSyncAction.network);
    final first = h.sync.syncNow();
    await h.core.entered(CoreSyncAction.network);
    final second = h.sync.syncNow();
    final third = h.sync.syncNow();
    expect(identical(second, third), isTrue);
    expect(h.sync.value.queued, isTrue);
    network.complete();
    expect((await first).success, isTrue);
    expect((await second).success, isTrue);
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.network).length, 2);
  });

  test('automatic trailing window is not restarted by every save', () async {
    final h = _Harness(autoDelay: const Duration(milliseconds: 40));
    await h.attach();
    addTearDown(h.close);
    await h.sync.setAutoSyncEnabled(true);
    h.sync.localSaved();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    h.sync.localSaved();
    await h.core.entered(CoreSyncAction.network).timeout(const Duration(milliseconds: 35));
    await h.sync.cancel();
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.network).length, 1);
  });

  test('background cancels active work and never admits an automatic queued successor', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final gate = h.core.block(CoreSyncAction.network);
    final running = h.sync.syncNow();
    await h.core.entered(CoreSyncAction.network);
    h.sync.setForeground(false);
    h.sync.localSaved();
    gate.complete();
    final outcome = await running;
    expect(outcome.cancelled, isTrue);
    expect(h.core.cancels, hasLength(1));
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.apply), isFalse);
    expect(h.core.commands.last.action, CoreSyncAction.finish);
    expect(h.core.commands.last.settled, isFalse);
  });

  test('cancel during apply still waits actual refresh and application settlement', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final apply = h.core.block(CoreSyncAction.apply);
    final running = h.sync.syncNow();
    await h.core.entered(CoreSyncAction.apply);
    var cancelComplete = false;
    final cancelled = h.sync.cancel().then((_) => cancelComplete = true);
    await Future<void>.value();
    expect(cancelComplete, isFalse);
    apply.complete();
    final outcome = await running;
    await cancelled;
    expect(outcome.cancelled, isTrue);
    expect(h.participant.reports.last!.metadataRefreshed, isTrue);
    expect(h.participant.reports.last!.operationSucceeded, isFalse);
    expect(h.core.commands.last.action, CoreSyncAction.finish);
    expect(h.core.commands.last.settled, isFalse);
    expect(h.core.lastSuccess, 0);
  });

  test('missing changed paths stay unknown and keep recovery read-only', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.changedPaths = null;
    final outcome = await h.sync.syncNow();
    expect(outcome.success, isFalse);
    expect(outcome.recoveryRequired, isTrue);
    expect(h.participant.reports.last!.changedPaths, isNull);
    expect(h.participant.recoveryCodes, contains('sync_source_recovery'));
    expect(h.core.lastSuccess, 0);
    expect(h.core.commands.last.settled, isFalse);
    expect(h.sync.value.recoveryRequired, isTrue);
  });

  test('partial apply preserves error even when actual metadata refresh succeeds', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.applyCode = 17;
    final outcome = await h.sync.syncNow();
    expect(outcome.success, isFalse);
    expect(outcome.code, 17);
    expect(h.participant.reports.last!.metadataRefreshed, isTrue);
    expect(h.participant.reports.last!.operationSucceeded, isFalse);
    expect(h.core.lastSuccess, 0);
  });

  test('actual refresh failure never unfreezes sources or records last success', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.refreshCode = 17;
    final outcome = await h.sync.syncNow();
    expect(outcome.recoveryRequired, isTrue);
    expect(h.participant.reports.last!.metadataRefreshed, isFalse);
    expect(h.core.lastSuccess, 0);
  });

  test('writer timeout joins abort acknowledgement and ignores late continuation', () async {
    final h = _Harness(timeout: const Duration(milliseconds: 40));
    await h.attach();
    addTearDown(h.close);
    final writer = h.participant.writerGate = Completer<void>();
    final aborted = h.participant.abortGate = Completer<void>();
    var completed = false;
    final running = h.sync.syncNow().then((outcome) { completed = true; return outcome; });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.participant.reservations.single.aborts, 1);
    expect(completed, isFalse);
    aborted.complete();
    final outcome = await running;
    expect(outcome.error, 'sync_reservation_timeout');
    writer.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.participant.reservations.single.quiesces, 0);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.begin), isFalse);
    h.participant.writerGate = null;
    h.participant.abortGate = null;
    expect((await h.sync.syncNow()).success, isTrue);
  });

  test('late quiesced after acknowledged abort cannot freeze or release a successor', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final late = h.participant.quiesceGate = Completer<void>();
    final entered = h.participant.quiesceEntered = Completer<void>();
    final first = h.sync.syncNow();
    await entered.future;
    final retired = h.participant.reservations.last;
    await h.sync.cancel();
    expect((await first).cancelled, isTrue);
    expect(retired.retired, isTrue);
    expect(retired.aborts, 1);
    h.participant.quiesceGate = null;
    final successor = h.sync.syncNow();
    late.complete();
    expect((await successor).success, isTrue);
    expect(h.participant.reservations.last.request.operationId, isNot(retired.request.operationId));
    expect(h.participant.reservations.last.recovery, isFalse);
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.apply).length, 1);
  });

  test('quiesce without a draft receipt is not apply permission; failed abort retains recovery', () async {
    final h = _Harness(timeout: const Duration(milliseconds: 20));
    await h.attach();
    addTearDown(h.close);
    h.participant.draftGate = Completer<void>();
    h.participant.abortSafe = false;
    final outcome = await h.sync.syncNow();
    expect(outcome.recoveryRequired, isTrue);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.apply), isFalse);
    expect(h.participant.reservations.last.recovery, isTrue);
    h.participant.draftGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.sync.value.recoveryRequired, isTrue);
  });

  test('vault errors classify unknown and never publish secret diagnostics', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.vault.failure = 'vault_locked';
    await h.sync.reconcile();
    expect(h.sync.value.readiness, NotebookSyncReadiness.credentialsUnknown);
    expect((await h.sync.syncNow()).success, isFalse);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.network), isFalse);
    h.vault.failure = null;
  });

  test('failed credential validation retains old version without promoting candidate', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.intercept = (command, _) async => command.action == CoreSyncAction.credentials
      ? CoreSyncResult(operationId: command.operationId, action: command.action, code: 14, executed: true)
      : null;
    final outcome = await h.sync.rotateCredentials(username: 'bob', password: 'bad-password');
    expect(outcome.success, isFalse);
    final record = await h.credentials.read(SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook));
    expect(record.active!.username, 'alice');
    expect(record.pending, isFalse);
    expect(h.sync.value.error, isNot(contains('bad-password')));
  });

  test('candidate cleanup never promotes provider or vault', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    var record = await h.credentials.stage(scope: SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook),
      operationId: newSyncOperationId(), kind: SyncCredentialKind.rotation,
      username: 'candidate', password: 'candidate-secret');
    record = await h.credentials.mark(record, SyncCredentialPhase.recoveryRequired);
    h.core.candidateRecovery = true;
    final outcome = await h.sync.recover(username: 'candidate', password: 'corrected-secret');
    expect(outcome.success, isTrue);
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.credentialRecovery).single.recoveryOperationId,
      record.operationId);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.credentials || command.action == CoreSyncAction.enable), isFalse);
    final retained = await h.credentials.read(record.scope);
    expect(retained.active!.username, 'alice');
    expect(retained.pending, isFalse);
  });

  test('disable persists cleared routing before credential deletion and preserves auto preference', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.auto = true;
    h.core.intercept = (command, _) async {
      if (command.action == CoreSyncAction.configure) {
        expect(command.configuration!.enabled, isFalse);
        expect(command.configuration!.autoSyncEnabled, isTrue);
        expect(h.vault.records, isNotEmpty);
      }
      return null;
    };
    expect((await h.sync.disable()).success, isTrue);
    expect(h.core.registered, isFalse);
    expect(h.core.enabled, isFalse);
    expect(h.vault.records, isEmpty);
    expect(h.sync.value.readiness, NotebookSyncReadiness.disabled);
  });

  test('failed disable routing persistence restores old provider and keeps credentials', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.intercept = (command, _) async => command.action == CoreSyncAction.configure
      ? CoreSyncResult(operationId: command.operationId, action: command.action, code: 17)
      : null;
    expect((await h.sync.disable()).success, isFalse);
    expect(h.core.registered, isTrue);
    expect(h.core.enabled, isTrue);
    final record = await h.credentials.read(SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook));
    expect(record.active!.password, 'old-secret');
    expect(record.pending, isFalse);
  });

  test('conflict FIFO preserves failed rows and enforces capability and generation', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.conflicts = [
      const CoreSyncConflict(path: 'a.md', binary: false, canKeepBoth: true),
      const CoreSyncConflict(path: 'b.bin', binary: true, canKeepBoth: false),
      const CoreSyncConflict(path: 'c.md', binary: false, canKeepBoth: true),
    ];
    h.core.intercept = (command, _) async {
      if (command.action == CoreSyncAction.resolve && command.path == 'c.md') {
        return CoreSyncResult(operationId: command.operationId, action: command.action, code: 17, executed: true);
      }
      return null;
    };
    final outcome = await h.sync.resolveConflicts([
      NotebookSyncResolution(path: 'a.md', resolution: CoreSyncResolution.keepBoth, ownerGeneration: h.sync.value.ownerGeneration),
      NotebookSyncResolution(path: 'b.bin', resolution: CoreSyncResolution.keepBoth, ownerGeneration: h.sync.value.ownerGeneration),
      NotebookSyncResolution(path: 'c.md', resolution: CoreSyncResolution.keepRemote, ownerGeneration: h.sync.value.ownerGeneration),
      NotebookSyncResolution(path: 'a.md', resolution: CoreSyncResolution.keepLocal, ownerGeneration: h.sync.value.ownerGeneration - 1),
    ]);
    expect(outcome.success, isFalse);
    expect(outcome.conflicts.map((item) => item.success), [true, false, false, false]);
    expect(outcome.conflicts[1].error, 'sync_conflict_choice_unavailable');
    expect(outcome.conflicts[2].code, 17);
    expect(outcome.conflicts[3].error, 'sync_stale_conflict');
    expect(h.sync.value.conflictOutcomes, hasLength(4));
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.resolve).map((command) => command.path), ['a.md', 'c.md']);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.network), isTrue);
  });

  test('startup refresh marker retires only after source settlement without last-success', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.refreshRequired = true;
    final outcome = await h.sync.recover();
    expect(outcome.success, isTrue);
    final refreshIndex = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.refresh);
    final finishIndex = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.finish);
    expect(finishIndex, greaterThan(refreshIndex));
    expect(h.core.commands[finishIndex].settled, isTrue);
    expect(h.participant.recoveries, greaterThan(0));
    expect(h.core.refreshRequired, isFalse);
    expect(h.core.lastSuccess, 0);
  });

  test('failed startup source recovery retains marker and retires native lease', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.refreshRequired = true;
    h.participant.recoverySafe = false;
    final outcome = await h.sync.recover();
    expect(outcome.success, isFalse);
    expect(outcome.recoveryRequired, isTrue);
    expect(h.core.commands.last.action, CoreSyncAction.finish);
    expect(h.core.commands.last.settled, isFalse);
    expect(h.core.refreshRequired, isTrue);
    expect(h.participant.recoveryCodes, isNotEmpty);
    expect(h.core.lastSuccess, 0);
  });

  test('failed endpoint enable keeps old scope and candidate through retry', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final oldScope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final oldRevision = (await h.credentials.read(oldScope)).revision;
    var fail = true;
    h.core.intercept = (command, _) async {
      if (command.action == CoreSyncAction.enable && fail) {
        return CoreSyncResult(operationId: command.operationId, action: command.action, code: 14, executed: true);
      }
      return null;
    };
    final failed = await h.sync.configure(endpoint: 'https://next.test/', username: 'next',
      password: 'candidate', confirmEndpointChange: true);
    expect(failed.success, isFalse);
    expect(failed.recoveryRequired, isTrue);
    expect(h.core.enabled, isFalse);
    expect((await h.credentials.read(oldScope)).revision, oldRevision);
    final candidateScope = SyncCredentialScope.notebook('https://next.test/', syncTestNotebook);
    expect((await h.credentials.read(candidateScope)).pending, isTrue);
    // Repeated failed recovery must not delete the predecessor first.
    expect((await h.sync.recover()).success, isFalse);
    expect((await h.credentials.read(oldScope)).revision, oldRevision);
    fail = false;
    expect((await h.sync.recover()).success, isTrue);
    expect((await h.credentials.read(candidateScope)).active!.username, 'next');
    expect((await h.credentials.read(oldScope)).present, isFalse);
  });

  test('restored partial endpoint archive rolls back candidate without publishing it', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final usernames = <String>[];
    h.core.intercept = (command, secret) async {
      if (command.action == CoreSyncAction.providerBegin) {
        h.core.retirement = true;
        return CoreSyncResult(operationId: command.operationId, action: command.action,
          code: 17, executed: true, cleanupRequired: true);
      }
      if (command.action == CoreSyncAction.enable && secret != null) usernames.add(secret.username);
      return null;
    };
    final failed = await h.sync.configure(endpoint: 'https://candidate.test/',
      username: 'candidate', password: 'candidate-secret', confirmEndpointChange: true);
    expect(failed.recoveryRequired, isTrue);
    expect(h.core.enabled, isTrue);
    expect(h.core.registered, isFalse);
    final recovered = await h.sync.recover();
    expect(recovered.success, isTrue);
    expect(usernames, ['alice']);
    expect(h.core.endpoint, syncTestEndpoint);
    expect(h.core.registered, isTrue);
    expect((await h.credentials.read(SyncCredentialScope.notebook('https://candidate.test/', syncTestNotebook))).present, isFalse);
    expect((await h.credentials.read(SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook))).active!.username, 'alice');
  });

  test('disabled orphan cleanup cannot delete while unexpected runtime disable fails', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.enabled = false;
    h.core.intercept = (command, _) async => command.action == CoreSyncAction.disable
      ? CoreSyncResult(operationId: command.operationId, action: command.action, code: 17)
      : null;
    final result = await h.sync.recover();
    expect(result.success, isFalse);
    expect(h.core.registered, isTrue);
    expect(h.vault.records, isNotEmpty);
  });

  test('timestamp write failure is visible after refresh without claiming success', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.intercept = (command, _) async => command.action == CoreSyncAction.finish
      ? CoreSyncResult(operationId: command.operationId, action: command.action, code: 17, executed: true)
      : null;
    final outcome = await h.sync.syncNow();
    expect(outcome.success, isFalse);
    expect(outcome.error, 'sync_finish_failed');
    expect(h.participant.reports.last!.metadataRefreshed, isTrue);
    expect(h.core.lastSuccess, 0);
  });

  test('logical close unregisters and deletes captured credentials without changing routing', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.core.auto = true;
    var deletes = 0;
    h.vault.beforeDelete = (_, _) async {
      deletes++;
      expect(h.core.registered, isFalse);
      expect(h.core.enabled, isTrue);
      expect(h.core.endpoint, syncTestEndpoint);
      expect(h.core.auto, isTrue);
    };
    final first = h.sync.closeNotebook();
    final second = h.sync.closeNotebook();
    expect(identical(first, second), isTrue);
    expect((await first).success, isTrue);
    expect(deletes, 1);
    expect(h.vault.records, isEmpty);
    expect(h.core.commands.map((command) => command.action), [CoreSyncAction.unregister]);
    expect(h.sync.value.readiness, NotebookSyncReadiness.missingCredentials);
    h.sync.localSaved();
    expect(h.sync.value.queued, isFalse);
    expect((await h.sync.syncNow()).success, isFalse);
    expect((await h.sync.configure(endpoint: syncTestEndpoint, username: 'new', password: 'new')).error,
      'sync_notebook_closing');
  });

  test('shutdown close preserves secure credentials and never creates a close intent', () async {
    final h = _Harness();
    await h.attach();
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final before = await h.credentials.read(scope);
    await h.sync.close();
    final after = await h.credentials.read(scope);
    expect(after.revision, before.revision);
    expect(after.pending, isFalse);
    expect(h.core.enabled, isTrue);
    expect(h.core.endpoint, syncTestEndpoint);
    h.sync.dispose();
  });

  test('logical close drains active sync and retires queued work before staging deletion', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final network = h.core.block(CoreSyncAction.network);
    final running = h.sync.syncNow();
    await h.core.entered(CoreSyncAction.network);
    final queued = h.sync.syncNow();
    final closing = h.sync.closeNotebook();
    expect(h.sync.value.busy, isTrue);
    expect((await queued).error, 'sync_notebook_closing');
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    expect((await h.credentials.read(scope)).pending, isFalse);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.unregister), isFalse);
    network.complete();
    expect((await running).cancelled, isTrue);
    expect((await closing).success, isTrue);
    final finish = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.finish);
    final unregister = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.unregister);
    expect(unregister, greaterThan(finish));
    expect(h.vault.records, isEmpty);
    expect(h.core.enabled, isTrue);
  });

  test('lost close-anchor write reply is recovered before attach can re-enable old credentials', () async {
    final h = _Harness();
    await h.attach();
    h.vault.loseNextWriteReply = true;
    final failed = await h.sync.closeNotebook();
    expect(failed.success, isFalse);
    expect(failed.recoveryRequired, isTrue);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    expect((await h.credentials.read(scope)).kind, SyncCredentialKind.close);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.unregister), isFalse);
    await h.sync.close();
    h.sync.dispose();
    h.core.commands.clear();
    final next = NotebookSync(notebookId: syncTestNotebook, credentials: h.credentials);
    addTearDown(() async { await next.close(); next.dispose(); });
    await next.attach(core: h.core, participant: _Participant());
    expect(h.vault.records, isEmpty);
    expect(h.core.commands.map((command) => command.action), [CoreSyncAction.unregister]);
    expect(h.core.enabled, isTrue);
    expect(h.core.endpoint, syncTestEndpoint);
    expect(next.value.readiness, NotebookSyncReadiness.missingCredentials);
    expect(next.value.recoveryRequired, isFalse);
  });

  test('failed close deletion remains visible and next attach deletes only after unregister', () async {
    final h = _Harness();
    await h.attach();
    h.vault.beforeDelete = (_, _) async { throw const SyncVaultException('vault_unavailable'); };
    final failed = await h.sync.closeNotebook();
    expect(failed.success, isFalse);
    expect(failed.recoveryRequired, isTrue);
    expect(h.core.registered, isFalse);
    expect(h.core.enabled, isTrue);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    expect((await h.credentials.read(scope)).phase, SyncCredentialPhase.closing);
    h.vault.beforeDelete = null;
    await h.sync.close();
    h.sync.dispose();
    h.core.commands.clear();
    // Simulate an unexpected reopened runtime: startup must still unregister it
    // before consuming the old generation's close intent.
    h.core.registered = true;
    final next = NotebookSync(notebookId: syncTestNotebook, credentials: h.credentials);
    addTearDown(() async { await next.close(); next.dispose(); });
    h.vault.beforeDelete = (_, _) async { expect(h.core.registered, isFalse); };
    await next.attach(core: h.core, participant: _Participant());
    expect(h.vault.records, isEmpty);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.enable), isFalse);
    expect(next.value.readiness, NotebookSyncReadiness.missingCredentials);
  });

  test('source recovery after logical close does not require or restore deleted credentials', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    h.participant.settlementSafe = false;
    final closed = await h.sync.closeNotebook();
    expect(closed.success, isFalse);
    expect(closed.recoveryRequired, isTrue);
    expect(h.vault.records, isEmpty);
    expect(h.core.enabled, isTrue);
    expect(h.core.registered, isFalse);
    h.participant.settlementSafe = true;
    final recovered = await h.sync.recover();
    expect(recovered.success, isTrue);
    expect(h.participant.recoveries, greaterThan(0));
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.enable), isFalse);
    expect(h.sync.value.closingNotebook, isTrue);
    expect(h.sync.value.canSync, isFalse);
    expect(h.sync.value.readiness, NotebookSyncReadiness.missingCredentials);
  });

  test('pending close waits for actual refresh recovery before runtime unregister', () async {
    final h = _Harness();
    await h.attach();
    addTearDown(h.close);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    await h.credentials.beginClose([await h.credentials.read(scope)], newSyncOperationId(),
      notebookId: syncTestNotebook);
    h.core.refreshRequired = true;
    final result = await h.sync.recover();
    expect(result.success, isTrue);
    final refresh = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.refresh);
    final finish = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.finish);
    final unregister = h.core.commands.indexWhere((command) => command.action == CoreSyncAction.unregister);
    expect(refresh, greaterThanOrEqualTo(0));
    expect(finish, greaterThan(refresh));
    expect(unregister, greaterThan(finish));
    expect(h.vault.records, isEmpty);
    expect(h.core.enabled, isTrue);
    expect(h.core.lastSuccess, 0);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.enable), isFalse);
  });

  test('pending-close unregister failure cannot delete or enable during attach', () async {
    final h = _Harness();
    await h.attach();
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    await h.credentials.beginClose([await h.credentials.read(scope)], newSyncOperationId(),
      notebookId: syncTestNotebook);
    await h.sync.close();
    h.sync.dispose();
    h.core.commands.clear();
    h.core.registered = true;
    h.core.intercept = (command, _) async => command.action == CoreSyncAction.unregister
      ? CoreSyncResult(operationId: command.operationId, action: command.action, code: 17)
      : null;
    final next = NotebookSync(notebookId: syncTestNotebook, credentials: h.credentials);
    addTearDown(() async { await next.close(); next.dispose(); });
    await next.attach(core: h.core, participant: _Participant());
    expect((await h.credentials.read(scope)).kind, SyncCredentialKind.close);
    expect(next.value.recoveryRequired, isTrue);
    expect(h.core.commands.any((command) => command.action == CoreSyncAction.enable), isFalse);
  });

  test('repeated close shares unregister drain rather than returning early', () async {
    final h = _Harness();
    await h.attach();
    final gate = h.core.block(CoreSyncAction.unregister);
    final first = h.sync.close();
    await h.core.entered(CoreSyncAction.unregister);
    final second = h.sync.close();
    expect(identical(first, second), isTrue);
    var joined = false;
    second.then((_) => joined = true);
    await Future<void>.value();
    expect(joined, isFalse);
    gate.complete();
    await first;
    await second;
    h.sync.dispose();
  });

  test('detach drains native work and fails queued requests before owner retirement', () async {
    final h = _Harness();
    await h.attach();
    final network = h.core.block(CoreSyncAction.network);
    final running = h.sync.syncNow();
    await h.core.entered(CoreSyncAction.network);
    final queued = h.sync.syncNow();
    var detached = false;
    final detach = h.sync.detach().then((_) => detached = true);
    expect((await queued).error, 'sync_owner_changed');
    expect(detached, isFalse);
    network.complete();
    expect((await running).cancelled, isTrue);
    await detach;
    expect(h.core.commands.last.action, CoreSyncAction.unregister);
    expect(h.core.commands.where((command) => command.action == CoreSyncAction.network).length, 1);
    await h.sync.close();
    h.sync.dispose();
  });
}
