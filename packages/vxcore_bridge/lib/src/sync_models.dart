// SPDX-License-Identifier: LGPL-3.0-only
import 'core_notebook.dart' show CoreException;
import 'generated/core_sync_json_keys.dart';

abstract interface class SyncCore {
  Future<CoreSyncFacts> inspectSync();
  Future<CoreSyncResult> sync(CoreSyncCommand command, {CoreSyncCredentials? credentials});
  void cancelSync(String operationId);
}

/// Transient input only. Never retain this in notifier state or portable metadata.
final class CoreSyncCredentials {
  const CoreSyncCredentials({required this.username, required this.password});
  final String username;
  final String password;
  Map<String, Object> toNativeJson() => {CoreSyncJsonKeys.extra: {CoreSyncJsonKeys.username: username, CoreSyncJsonKeys.password: password}};
  @override
  String toString() => 'CoreSyncCredentials(redacted)';
}

final class CoreSyncConfiguration {
  const CoreSyncConfiguration({required this.endpoint, this.enabled = true, this.autoSyncEnabled = true});
  final String endpoint;
  final bool enabled;
  final bool autoSyncEnabled;
  Map<String, Object> toJson() => {'endpoint': endpoint, 'enabled': enabled, CoreSyncJsonKeys.autoSyncEnabled: autoSyncEnabled};
}

enum CoreSyncAction {
  begin, stage, network, apply, refresh, finish, enable, credentials,
  credentialRecovery, disable, unregister, configure, providerInspect,
  providerBegin, providerCommit, providerRestore, providerRecover, resolve, clone,
}
enum CoreSyncResolution { keepBoth, keepLocal, keepRemote }

final class CoreSyncCommand {
  CoreSyncCommand({required this.action, required this.operationId,
    this.configuration, List<String> protectedNodeIds = const [],
    this.protectMetadata = true, this.settled = false, this.path,
    this.resolution, this.recoveryOperationId, this.stagingBudgetBytes, this.cloneImportId,
  }) : protectedNodeIds = List.unmodifiable(protectedNodeIds);
  final CoreSyncAction action;
  final String operationId;
  final CoreSyncConfiguration? configuration;
  final List<String> protectedNodeIds;
  final bool protectMetadata;
  final bool settled;
  final String? path;
  final CoreSyncResolution? resolution;
  final String? recoveryOperationId;
  final int? stagingBudgetBytes;
  /// Native committed clone receipt, accepted only by configure before settlement.
  final String? cloneImportId;
  Map<String, Object?> toJson() => {
    'action': action.name, 'operationId': operationId,
    if (configuration != null) 'configuration': configuration!.toJson(),
    if (action == CoreSyncAction.apply) ...{'protectedNodeIds': protectedNodeIds, 'protectMetadata': protectMetadata},
    if (action == CoreSyncAction.finish) 'settled': settled,
    if (path != null) CoreSyncJsonKeys.path: path,
    if (resolution != null) 'resolution': switch (resolution!) {
      CoreSyncResolution.keepBoth => 'keep_both',
      CoreSyncResolution.keepLocal => 'keep_local',
      CoreSyncResolution.keepRemote => 'keep_remote',
    },
    if (recoveryOperationId != null) 'recoveryOperationId': recoveryOperationId,
    if (stagingBudgetBytes != null) 'stagingBudgetBytes': stagingBudgetBytes,
    if (cloneImportId != null) 'cloneImportId': cloneImportId,
  };
}

Never _bad() => throw const CoreException(8, 'Malformed native synchronization response');
Map<String, Object?> _map(Object? value) => value is Map<String, dynamic> ? value : _bad();
String _string(Object? value, {bool empty = false}) => value is String &&
    (empty || value.isNotEmpty) && !value.contains('\u0000') && value.length <= 16384 ? value : _bad();
bool _bool(Object? value) => value is bool ? value : _bad();
int _int(Object? value) => value is int && value >= 0 && value <= 9007199254740991 ? value : _bad();
String? _nullableString(Object? value) => value == null ? null : _string(value);

final class CoreSyncConflict {
  const CoreSyncConflict({required this.path, required this.binary, required this.canKeepBoth});
  final String path;
  final bool binary;
  final bool canKeepBoth;
  factory CoreSyncConflict.fromJson(Object? value) {
    final j = _map(value);
    return CoreSyncConflict(path: _string(j[CoreSyncJsonKeys.path]), binary: _bool(j['binary']), canKeepBoth: _bool(j[CoreSyncJsonKeys.canKeepBoth]));
  }
}

final class CoreSyncProviderFacts {
  const CoreSyncProviderFacts({this.bindingEndpoint, this.accountHash, this.baselineHash,
    this.pending = false, this.conflicts = false, this.probe = false,
    this.credentialRecovery = false, this.retirement = false, this.retired = false,
    this.cleanCloneBaseline = false, this.retirementOperationId});
  final String? bindingEndpoint;
  final String? accountHash;
  final String? baselineHash;
  final String? retirementOperationId;
  final bool pending, conflicts, probe, credentialRecovery, retirement, retired, cleanCloneBaseline;
  factory CoreSyncProviderFacts.fromJson(Object? value) {
    final j = _map(value);
    return CoreSyncProviderFacts(bindingEndpoint: _nullableString(j[CoreSyncJsonKeys.remoteUrl]),
      accountHash: _nullableString(j['usernameHash']), baselineHash: _nullableString(j['baselineSha256']),
      pending: _bool(j['pending']), conflicts: _bool(j['conflicts']), probe: _bool(j['probe']),
      credentialRecovery: _bool(j['credentialValidation']), retirement: _bool(j['retirement']),
      retired: _bool(j['retired']), cleanCloneBaseline: _bool(j['cleanCloneBaseline']),
      retirementOperationId: _nullableString(j['retirementOperationId']));
  }
}

final class CoreSyncFacts {
  CoreSyncFacts({required this.notebookId, this.enabled = false, this.backend = '',
    this.endpoint = '', this.autoSyncEnabled = true, this.registered = false,
    this.ready = false, this.capabilities = 0, this.lastSuccessUtcMillis = 0,
    this.refreshRequired = false, this.recoveryRequired = false, this.pending = false,
    List<CoreSyncConflict> conflicts = const [], this.provider = const CoreSyncProviderFacts(),
  }) : conflicts = List.unmodifiable(conflicts);
  final String notebookId, backend, endpoint;
  final bool enabled, autoSyncEnabled, registered, ready, refreshRequired, recoveryRequired, pending;
  final int capabilities, lastSuccessUtcMillis;
  final List<CoreSyncConflict> conflicts;
  final CoreSyncProviderFacts provider;
  factory CoreSyncFacts.fromJson(Object? value) {
    final j = _map(value);
    final conflicts = j['conflicts'];
    if (conflicts is! List || conflicts.length > 100000) _bad();
    return CoreSyncFacts(notebookId: _string(j['notebookId']), enabled: _bool(j['enabled']),
      backend: _string(j[CoreSyncJsonKeys.backend], empty: true), endpoint: _string(j['endpoint'], empty: true),
      autoSyncEnabled: _bool(j[CoreSyncJsonKeys.autoSyncEnabled]), registered: _bool(j['registered']), ready: _bool(j['ready']),
      capabilities: _int(j['capabilities']), lastSuccessUtcMillis: _int(j['lastSuccessUtcMillis']),
      refreshRequired: _bool(j['refreshRequired']), recoveryRequired: _bool(j['recoveryRequired']),
      pending: _bool(j['pending']), provider: CoreSyncProviderFacts.fromJson(j['provider']),
      conflicts: conflicts.map(CoreSyncConflict.fromJson).toList());
  }
}

final class CoreSyncCloneReceipt {
  const CoreSyncCloneReceipt({required this.importId, required this.operationId,
    required this.notebookId, required this.endpoint, required this.accountHash,
    required this.baselineHash, required this.treeHash, this.autoSyncEnabled = false});
  final String importId, operationId, notebookId, endpoint, accountHash, baselineHash, treeHash;
  final bool autoSyncEnabled;
  factory CoreSyncCloneReceipt.fromJson(Object? value) {
    final j = _map(value);
    return CoreSyncCloneReceipt(importId: _string(j['importId']), operationId: _string(j['operationId']),
      notebookId: _string(j['notebookId']), endpoint: _string(j['endpoint']), accountHash: _string(j['accountHash']),
      baselineHash: _string(j['baselineHash']), treeHash: _string(j['treeHash']),
      autoSyncEnabled: _bool(j[CoreSyncJsonKeys.autoSyncEnabled]));
  }
}

/// A dispatched error is an outcome, not evidence that no effects occurred.
final class CoreSyncResult {
  CoreSyncResult({required this.operationId, required this.action, required this.code,
    this.executed = false, this.committed = false, this.cleanupRequired = false,
    this.refreshRequired = false, List<String>? changedPaths, this.refreshCode,
    this.didCommit = false, this.settled = false, this.notebookId, this.cloneReceipt,
    this.providerPhase, this.provider,
  }) : changedPaths = changedPaths == null ? null : List.unmodifiable(changedPaths);
  final String operationId;
  final CoreSyncAction action;
  final int code;
  final bool executed, committed, cleanupRequired, refreshRequired, didCommit, settled;
  /// Null means unavailable, NEVER an empty affected set.
  final List<String>? changedPaths;
  final int? refreshCode;
  final String? notebookId;
  final CoreSyncCloneReceipt? cloneReceipt;
  final String? providerPhase;
  final CoreSyncProviderFacts? provider;
  bool get success => code == 0;
  factory CoreSyncResult.fromJson(Object? value) {
    final j = _map(value);
    final action = _string(j['action']);
    final matches = CoreSyncAction.values.where((v) => v.name == action);
    if (matches.length != 1) _bad();
    final paths = j['changedPaths'];
    if (paths != null && (paths is! List || paths.length > 100000)) _bad();
    return CoreSyncResult(operationId: _string(j['operationId']), action: matches.single,
      code: _int(j['code']), executed: _bool(j['executed']), committed: _bool(j['committed']),
      cleanupRequired: _bool(j['cleanupRequired']), refreshRequired: _bool(j['refreshRequired']),
      changedPaths: paths == null ? null : (paths as List).map((v) => _string(v)).toList(),
      refreshCode: j['refreshCode'] == null ? null : _int(j['refreshCode']), didCommit: _bool(j['didCommit']),
      settled: _bool(j['settled']), notebookId: _nullableString(j['notebookId']),
      cloneReceipt: j['cloneReceipt'] == null ? null : CoreSyncCloneReceipt.fromJson(j['cloneReceipt']),
      providerPhase: _nullableString(j['providerPhase']),
      provider: j['provider'] == null ? null : CoreSyncProviderFacts.fromJson(j['provider']));
  }
}
