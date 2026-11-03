// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

final _hex = RegExp(r'^[0-9a-f]{64}$');
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The only diagnostic exposed by the vault boundary is a fixed, nonsecret code.
class SyncVaultException implements Exception {
  const SyncVaultException(this.code, {this.revision});
  final String code;
  final String? revision;
  @override
  String toString() => 'SyncVaultException($code)';
}

class SyncVaultValue {
  SyncVaultValue.absent() : revision = null, data = null;
  SyncVaultValue.present(this.revision, Uint8List bytes)
      : data = Uint8List.fromList(bytes) {
    if (revision == null || !_hex.hasMatch(revision!) || bytes.length > 65536) {
      throw const SyncVaultException('vault_corrupt');
    }
  }
  final String? revision;
  final Uint8List? data;
  bool get present => data != null;
}

abstract interface class SyncVault {
  Future<List<String>> list();
  Future<SyncVaultValue> read(String key);
  Future<String> write(String key, String? expectedRevision, Uint8List data);
  Future<void> delete(String key, String expectedRevision);
  Future<bool> trustAvailable();
}

class MethodChannelSyncVault implements SyncVault {
  MethodChannelSyncVault({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('vnote.mobile/sync_security');
  final MethodChannel _channel;
  static const _codes = {
    'vault_locked', 'vault_unavailable', 'vault_corrupt', 'vault_changed',
    'vault_invalid', 'vault_limit',
  };

  Future<Object?> _call(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      final details = error.details;
      final revision = details is Map ? details['revision'] : null;
      throw SyncVaultException(
        _codes.contains(error.code) ? error.code : 'vault_unavailable',
        revision: revision is String && _hex.hasMatch(revision) ? revision : null,
      );
    } on MissingPluginException {
      throw const SyncVaultException('vault_unavailable');
    }
  }

  void _key(String key) {
    if (!_hex.hasMatch(key)) throw const SyncVaultException('vault_invalid');
  }

  @override
  Future<List<String>> list() async {
    final result = await _call('vaultList', const {});
    if (result is! Map || result['keys'] is! List) {
      throw const SyncVaultException('vault_corrupt');
    }
    final keys = result['keys'] as List;
    if (keys.length > 1000 || keys.toSet().length != keys.length ||
        keys.any((key) => key is! String || !_hex.hasMatch(key))) {
      throw const SyncVaultException('vault_corrupt');
    }
    return List<String>.unmodifiable(keys.cast<String>());
  }

  @override
  Future<SyncVaultValue> read(String key) async {
    _key(key);
    final result = await _call('vaultRead', {'key': key});
    if (result is! Map) throw const SyncVaultException('vault_corrupt');
    if (result['present'] == false && result.length == 1) return SyncVaultValue.absent();
    if (result['present'] != true || result['revision'] is! String || result['data'] is! Uint8List) {
      throw const SyncVaultException('vault_corrupt');
    }
    return SyncVaultValue.present(result['revision'] as String, result['data'] as Uint8List);
  }

  @override
  Future<String> write(String key, String? expectedRevision, Uint8List data) async {
    _key(key);
    if ((expectedRevision != null && !_hex.hasMatch(expectedRevision)) || data.length > 65536) {
      throw const SyncVaultException('vault_invalid');
    }
    final result = await _call('vaultWrite', {
      'key': key, 'expectedRevision': expectedRevision, 'data': data,
    });
    if (result is! Map || result['revision'] is! String || !_hex.hasMatch(result['revision'] as String)) {
      throw const SyncVaultException('vault_corrupt');
    }
    return result['revision'] as String;
  }

  @override
  Future<void> delete(String key, String expectedRevision) async {
    _key(key);
    if (!_hex.hasMatch(expectedRevision)) throw const SyncVaultException('vault_invalid');
    await _call('vaultDelete', {'key': key, 'expectedRevision': expectedRevision});
  }

  @override
  Future<bool> trustAvailable() async {
    final result = await _call('trustStatus', const {});
    if (result is! Map || result['available'] is! bool) {
      throw const SyncVaultException('vault_unavailable');
    }
    return result['available'] as bool;
  }
}

bool _wellFormedUnicode(String value) {
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final next = value.codeUnitAt(index);
      if (next < 0xdc00 || next > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

String canonicalSyncEndpoint(String endpoint) {
  try {
    if (endpoint.length > 4096 || !_wellFormedUnicode(endpoint) || utf8.encode(endpoint).length > 4096 ||
        endpoint.contains(RegExp(r'[\x00-\x20\x7f\\]'))) {
      throw const SyncVaultException('vault_invalid');
    }
    final match = RegExp(r'^https://([^/?#]+)(/[^?#]*)?$', caseSensitive: false).firstMatch(endpoint);
    if (match == null) throw const SyncVaultException('vault_invalid');
    final authority = RegExp(r'^(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?$').firstMatch(match[1]!);
    final uri = Uri.tryParse(endpoint);
    if (authority == null || uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const SyncVaultException('vault_invalid');
    }
    final port = authority[2] == null ? 443 : int.parse(authority[2]!);
    if (port < 1 || port > 65535) throw const SyncVaultException('vault_invalid');
    final rawPath = match[2] ?? '/';
    if (RegExp(r'%(2f|5c)', caseSensitive: false).hasMatch(rawPath)) {
      throw const SyncVaultException('vault_invalid');
    }
    final parts = rawPath.split('/');
    final encoded = <String>[];
    for (var index = 1; index < parts.length; index++) {
      if (parts[index].isEmpty && index == parts.length - 1) continue;
      final part = Uri.decodeComponent(parts[index]);
      if (part.isEmpty || part == '.' || part == '..' ||
          part.contains(RegExp(r'[\x00-\x1f\x7f/\\]'))) {
        throw const SyncVaultException('vault_invalid');
      }
      final output = StringBuffer();
      for (final byte in utf8.encode(part)) {
        final unreserved = byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 ||
            byte >= 48 && byte <= 57 || byte == 45 || byte == 46 || byte == 95 || byte == 126;
        output.write(unreserved ? String.fromCharCode(byte) : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
      encoded.add(output.toString());
    }
    return 'https://${authority[1]!.toLowerCase()}${port == 443 ? '' : ':$port'}/${encoded.isEmpty ? '' : '${encoded.join('/')}/'}';
  } on SyncVaultException { rethrow; }
  on Object { throw const SyncVaultException('vault_invalid'); }
}

String newSyncOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class SyncCredentialScope {
  SyncCredentialScope.notebook(String endpoint, String notebookId)
      : this._(canonicalSyncEndpoint(endpoint), notebookId, false);
  SyncCredentialScope.provisional(String endpoint, String operationId)
      : this._(canonicalSyncEndpoint(endpoint), operationId, true);
  SyncCredentialScope._(this.endpoint, this.subject, this.provisional) {
    if (!_uuid.hasMatch(subject)) throw const SyncVaultException('vault_invalid');
  }
  final String endpoint;
  final String subject;
  final bool provisional;
  late final String key = sha256.convert(utf8.encode(jsonEncode([
    1, 'webdav', endpoint, provisional ? 'clone' : 'notebook', subject,
  ]))).toString();
  Map<String, Object?> _json() => {
    'backend': 'webdav', 'endpoint': endpoint,
    'kind': provisional ? 'clone' : 'notebook', 'subject': subject,
  };
  @override
  bool operator ==(Object other) => other is SyncCredentialScope &&
      endpoint == other.endpoint && subject == other.subject && provisional == other.provisional;
  @override
  int get hashCode => Object.hash(endpoint, subject, provisional);
}

enum SyncCredentialKind { enable, rotation, endpoint, disable, clone, close }
enum SyncCredentialPhase {
  staged, coreCommitted, routingCommitted, promoted, recoveryRequired,
  rekeyed, published, disabling, orphaned, closing,
}

class _Secret {
  _Secret(this.id, this.username, this.password) {
    if (!_uuid.hasMatch(id) || username.length > 4096 || password.length > 8192 ||
        !_wellFormedUnicode(username) || !_wellFormedUnicode(password) ||
        utf8.encode(username).length > 4096 ||
        utf8.encode(password).length > 8192 || username.contains('\u0000') || password.contains('\u0000')) {
      throw const SyncVaultException('vault_invalid');
    }
  }
  final String id;
  final String username;
  final String password;
  CoreSyncCredentials get value => CoreSyncCredentials(username: username, password: password);
  Map<String, Object?> get json => {'id': id, 'username': username, 'password': password};
  static _Secret decode(Object? value) {
    final map = _map(value, const {'id', 'username', 'password'});
    return _Secret(_string(map, 'id'), _string(map, 'username'), _string(map, 'password'));
  }
}

Map<String, dynamic> _map(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> || value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw const SyncVaultException('vault_corrupt');
  }
  return value;
}
String _string(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String) throw const SyncVaultException('vault_corrupt');
  return value;
}

class _CloseTarget {
  const _CloseTarget(this.key, this.revision);
  final String key;
  final String revision;
  Map<String, Object?> get json => {'key': key, 'revision': revision};
  static _CloseTarget decode(Object? value) {
    final map = _map(value, const {'key', 'revision'});
    final key = _string(map, 'key');
    final revision = _string(map, 'revision');
    if (!_hex.hasMatch(key) || !_hex.hasMatch(revision)) throw const SyncVaultException('vault_corrupt');
    return _CloseTarget(key, revision);
  }
}

/// Contains secrets: keep local to the immediate transaction, never notifier state.
class SyncCredentialRecord {
  SyncCredentialRecord._({required this.scope, required this.revision,
    this._old, this._candidate, this.operationId, this.kind, this.phase,
    this.previousEndpoint, this.previousRevision, this.importId, this.targetNotebookId,
    this.targetKey, this.originKey, this.autoSyncEnabled = false,
    List<_CloseTarget> closeTargets = const []})
      : _closeTargets = List.unmodifiable(closeTargets);
  final SyncCredentialScope scope;
  final String? revision;
  final _Secret? _old;
  final _Secret? _candidate;
  final String? operationId;
  final SyncCredentialKind? kind;
  final SyncCredentialPhase? phase;
  final String? previousEndpoint;
  final String? previousRevision;
  final String? importId;
  final String? targetNotebookId;
  final String? targetKey;
  final String? originKey;
  final bool autoSyncEnabled;
  final List<_CloseTarget> _closeTargets;
  bool get present => revision != null;
  bool get pending => operationId != null;
  bool get hasUsableCredentials => _old != null ||
      (_candidate != null && phase == SyncCredentialPhase.promoted);
  CoreSyncCredentials? get active => phase == SyncCredentialPhase.promoted
      ? _candidate?.value : _old?.value;
  CoreSyncCredentials? get candidateCredentials => _candidate?.value;
  CoreSyncCredentials? get oldCredentials => _old?.value;
  @override
  String toString() => 'SyncCredentialRecord(redacted)';

  Uint8List _encode() {
    final encoded = Uint8List.fromList(utf8.encode(jsonEncode({
      'version': 1, 'scope': scope._json(), 'old': _old?.json,
      'candidate': _candidate?.json,
      'transaction': operationId == null ? null : {
        'id': operationId, 'kind': kind!.name, 'phase': phase!.name,
        'previousEndpoint': previousEndpoint, 'previousRevision': previousRevision, 'importId': importId,
        'targetNotebookId': targetNotebookId, 'targetKey': targetKey,
        'originKey': originKey, 'autoSyncEnabled': autoSyncEnabled,
        'closeTargets': _closeTargets.map((target) => target.json).toList(),
      },
    })));
    if (encoded.length > 65536) throw const SyncVaultException('vault_limit');
    return encoded;
  }

  static SyncCredentialRecord _decode(SyncCredentialScope scope, SyncVaultValue value) {
    if (!value.present) return SyncCredentialRecord._(scope: scope, revision: null);
    try {
      final map = _map(jsonDecode(utf8.decode(value.data!, allowMalformed: false)),
        const {'version', 'scope', 'old', 'candidate', 'transaction'});
      if (map['version'] != 1) throw const SyncVaultException('vault_corrupt');
      final binding = _map(map['scope'], const {'backend', 'endpoint', 'kind', 'subject'});
      if (jsonEncode(binding) != jsonEncode(scope._json())) {
        // JSON key order is not authority; compare each independently.
        for (final entry in scope._json().entries) {
          if (binding[entry.key] != entry.value) throw const SyncVaultException('vault_corrupt');
        }
      }
      final old = map['old'] == null ? null : _Secret.decode(map['old']);
      final candidate = map['candidate'] == null ? null : _Secret.decode(map['candidate']);
      if (map['transaction'] == null) {
        if (old == null || candidate != null || scope.provisional) throw const SyncVaultException('vault_corrupt');
        return SyncCredentialRecord._(scope: scope, revision: value.revision, old: old);
      }
      final tx = _map(map['transaction'], const {
        'id', 'kind', 'phase', 'previousEndpoint', 'previousRevision', 'importId',
        'targetNotebookId', 'targetKey', 'originKey', 'autoSyncEnabled', 'closeTargets',
      });
      final id = _string(tx, 'id');
      if (!_uuid.hasMatch(id)) throw const SyncVaultException('vault_corrupt');
      final kind = SyncCredentialKind.values.byName(_string(tx, 'kind'));
      final phase = SyncCredentialPhase.values.byName(_string(tx, 'phase'));
      if (tx['autoSyncEnabled'] is! bool || tx['closeTargets'] is! List ||
          (tx['closeTargets'] as List).length > 999) { throw const SyncVaultException('vault_corrupt'); }
      final closeTargets = (tx['closeTargets'] as List).map(_CloseTarget.decode).toList();
      if (closeTargets.map((target) => target.key).toSet().length != closeTargets.length ||
          closeTargets.any((target) => target.key == scope.key) ||
          (kind != SyncCredentialKind.close && closeTargets.isNotEmpty) ||
          (kind == SyncCredentialKind.close && (scope.provisional || candidate != null || phase != SyncCredentialPhase.closing))) {
        throw const SyncVaultException('vault_corrupt');
      }
      for (final key in ['previousEndpoint', 'previousRevision', 'importId', 'targetNotebookId', 'targetKey', 'originKey']) {
        if (tx[key] != null && tx[key] is! String) throw const SyncVaultException('vault_corrupt');
      }
      if ((candidate == null && kind != SyncCredentialKind.disable && kind != SyncCredentialKind.close) ||
          (old == null && (kind == SyncCredentialKind.disable || kind == SyncCredentialKind.close)) ||
          (scope.provisional && (kind != SyncCredentialKind.clone || id != scope.subject)) ||
          (tx['previousRevision'] != null && !_hex.hasMatch(tx['previousRevision'] as String)) ||
          (tx['targetKey'] != null && !_hex.hasMatch(tx['targetKey'] as String)) ||
          (tx['originKey'] != null && !_hex.hasMatch(tx['originKey'] as String)) ||
          (tx['targetNotebookId'] != null && !_uuid.hasMatch(tx['targetNotebookId'] as String))) {
        throw const SyncVaultException('vault_corrupt');
      }
      return SyncCredentialRecord._(scope: scope, revision: value.revision,
        old: old, candidate: candidate, operationId: id, kind: kind, phase: phase,
        previousEndpoint: tx['previousEndpoint'] as String?, previousRevision: tx['previousRevision'] as String?,
        importId: tx['importId'] as String?,
        targetNotebookId: tx['targetNotebookId'] as String?, targetKey: tx['targetKey'] as String?,
        originKey: tx['originKey'] as String?, autoSyncEnabled: tx['autoSyncEnabled'] as bool,
        closeTargets: closeTargets);
    } on Object {
      throw SyncVaultException('vault_corrupt', revision: value.revision);
    }
  }
}

class SyncCloneCredentials {
  SyncCloneCredentials._(this.provisionalScope, this.operationId, this.importId, this.notebookId, this.autoSyncEnabled);
  final SyncCredentialScope provisionalScope;
  final String operationId;
  final String? importId;
  final String? notebookId;
  final bool autoSyncEnabled;
  SyncCredentialScope? get notebookScope => notebookId == null ? null :
      SyncCredentialScope.notebook(provisionalScope.endpoint, notebookId!);
}

/// Supplied only by the managed importer after native receipt/recovery inspection.
class SyncClonePublicationReceipt {
  const SyncClonePublicationReceipt({required this.operationId, required this.importId,
    required this.notebookId, required this.endpoint, required this.published});
  final String operationId;
  final String importId;
  final String? notebookId;
  final String endpoint;
  final bool published;
}

class SyncCredentials {
  SyncCredentials({SyncVault? vault}) : vault = vault ?? MethodChannelSyncVault();
  final SyncVault vault;

  Future<SyncCredentialRecord> read(SyncCredentialScope scope) async =>
      SyncCredentialRecord._decode(scope, await vault.read(scope.key));

  SyncCredentialRecord _decodeListed(String key, SyncVaultValue value) {
    try {
      final map = jsonDecode(utf8.decode(value.data!, allowMalformed: false));
      if (map is! Map<String, dynamic> || map['scope'] is! Map<String, dynamic>) {
        throw const SyncVaultException('vault_corrupt');
      }
      final binding = map['scope'] as Map<String, dynamic>;
      final scope = binding['kind'] == 'clone'
          ? SyncCredentialScope.provisional(_string(binding, 'endpoint'), _string(binding, 'subject'))
          : SyncCredentialScope.notebook(_string(binding, 'endpoint'), _string(binding, 'subject'));
      if (scope.key != key) throw const SyncVaultException('vault_corrupt');
      return SyncCredentialRecord._decode(scope, value);
    } on SyncVaultException { rethrow; }
    on Object { throw SyncVaultException('vault_corrupt', revision: value.revision); }
  }

  Stream<SyncCredentialRecord> _scan() async* {
    final keys = await vault.list();
    if (keys.length > 1000 || keys.toSet().length != keys.length ||
        keys.any((key) => !_hex.hasMatch(key))) { throw const SyncVaultException('vault_corrupt'); }
    // Decode one secret record at a time; no bulk credential body leaves this
    // boundary. Locked/unavailable/corrupt reads never become absence.
    for (final key in keys) {
      final value = await vault.read(key);
      if (value.present) yield _decodeListed(key, value);
    }
  }

  Future<List<SyncCredentialScope>> notebookScopes(String notebookId) async {
    final scopes = <SyncCredentialScope>[];
    await for (final record in _scan()) {
      final scope = record.scope;
      if ((!scope.provisional && scope.subject == notebookId) || record.targetNotebookId == notebookId) scopes.add(scope);
    }
    return List.unmodifiable(scopes);
  }

  /// A null result proves a completed bounded scan, never a failed vault read.
  Future<SyncCloneCredentials?> findClone(String operationId) async {
    if (!_uuid.hasMatch(operationId)) throw const SyncVaultException('vault_invalid');
    SyncCloneCredentials? found;
    await for (final record in _scan()) {
      if (record.scope.provisional && record.kind == SyncCredentialKind.clone && record.operationId == operationId) {
        if (found != null) throw const SyncVaultException('vault_changed');
        found = SyncCloneCredentials._(record.scope, operationId, record.importId,
          record.targetNotebookId, record.autoSyncEnabled);
      }
    }
    return found;
  }

  Future<SyncCredentialRecord> _put(SyncCredentialRecord record) async {
    final bytes = record._encode();
    try {
      final revision = await vault.write(record.scope.key, record.revision, bytes);
      return SyncCredentialRecord._(scope: record.scope, revision: revision,
        old: record._old, candidate: record._candidate, operationId: record.operationId,
        kind: record.kind, phase: record.phase, previousEndpoint: record.previousEndpoint,
        previousRevision: record.previousRevision,
        importId: record.importId, targetNotebookId: record.targetNotebookId,
        targetKey: record.targetKey, originKey: record.originKey,
        autoSyncEnabled: record.autoSyncEnabled, closeTargets: record._closeTargets);
    } finally { bytes.fillRange(0, bytes.length, 0); }
  }

  Future<SyncCredentialRecord> stage({required SyncCredentialScope scope,
    required String operationId, required SyncCredentialKind kind,
    required String username, required String password, String? previousEndpoint, String? previousRevision,
    bool autoSyncEnabled = false}) async {
    if (!_uuid.hasMatch(operationId) || kind == SyncCredentialKind.disable || kind == SyncCredentialKind.close ||
        (previousRevision != null && !_hex.hasMatch(previousRevision))) {
      throw const SyncVaultException('vault_invalid');
    }
    final before = await read(scope);
    if (before.pending) throw const SyncVaultException('vault_changed');
    if (scope.provisional && before.present) throw const SyncVaultException('vault_changed');
    return _put(SyncCredentialRecord._(scope: scope, revision: before.revision,
      old: before._old, candidate: _Secret(newSyncOperationId(), username, password),
      operationId: operationId, kind: kind, phase: SyncCredentialPhase.staged,
      previousEndpoint: previousEndpoint == null ? null : canonicalSyncEndpoint(previousEndpoint),
      previousRevision: previousRevision, autoSyncEnabled: autoSyncEnabled));
  }

  Future<SyncCredentialRecord> mark(SyncCredentialRecord record, SyncCredentialPhase phase) async {
    if (!record.pending || record.kind == SyncCredentialKind.close ||
        phase == SyncCredentialPhase.promoted) { throw const SyncVaultException('vault_invalid'); }
    final allowed = switch (record.phase!) {
      SyncCredentialPhase.staged => {SyncCredentialPhase.coreCommitted, SyncCredentialPhase.rekeyed, SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.coreCommitted => {SyncCredentialPhase.routingCommitted, SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.routingCommitted => {SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.promoted => <SyncCredentialPhase>{},
      SyncCredentialPhase.recoveryRequired => {SyncCredentialPhase.coreCommitted, SyncCredentialPhase.routingCommitted, SyncCredentialPhase.staged},
      SyncCredentialPhase.rekeyed => {SyncCredentialPhase.published, SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.published => {SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.disabling => {SyncCredentialPhase.orphaned, SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.orphaned => {SyncCredentialPhase.recoveryRequired},
      SyncCredentialPhase.closing => <SyncCredentialPhase>{},
    };
    if (phase != record.phase && !allowed.contains(phase)) throw const SyncVaultException('vault_invalid');
    return _put(SyncCredentialRecord._(scope: record.scope, revision: record.revision,
      old: record._old, candidate: record._candidate, operationId: record.operationId,
      kind: record.kind, phase: phase, previousEndpoint: record.previousEndpoint,
      previousRevision: record.previousRevision,
      importId: record.importId, targetNotebookId: record.targetNotebookId,
      targetKey: record.targetKey, originKey: record.originKey,
      autoSyncEnabled: record.autoSyncEnabled, closeTargets: record._closeTargets));
  }

  Future<SyncCredentialRecord> promote(SyncCredentialRecord record) {
    if (record.kind == SyncCredentialKind.clone) throw const SyncVaultException('vault_invalid');
    return _promote(record);
  }

  Future<SyncCredentialRecord> _promote(SyncCredentialRecord record) async {
    final admitted = switch (record.kind) {
      SyncCredentialKind.rotation => record.phase == SyncCredentialPhase.coreCommitted || record.phase == SyncCredentialPhase.routingCommitted,
      SyncCredentialKind.enable || SyncCredentialKind.endpoint => record.phase == SyncCredentialPhase.routingCommitted,
      SyncCredentialKind.clone => record.phase == SyncCredentialPhase.published,
      _ => false,
    };
    if (record._candidate == null || !admitted) throw const SyncVaultException('vault_invalid');
    return _put(SyncCredentialRecord._(scope: record.scope, revision: record.revision,
      old: record._old, candidate: record._candidate, operationId: record.operationId,
      kind: record.kind, phase: SyncCredentialPhase.promoted,
      previousEndpoint: record.previousEndpoint, previousRevision: record.previousRevision, importId: record.importId,
      targetNotebookId: record.targetNotebookId, targetKey: record.targetKey,
      originKey: record.originKey, autoSyncEnabled: record.autoSyncEnabled));
  }

  Future<void> retire(SyncCredentialRecord record) async {
    if (record.phase != SyncCredentialPhase.promoted || record._candidate == null || record.scope.provisional) {
      throw const SyncVaultException('vault_invalid');
    }
    // Remove only the pre-transaction old generation. Keep the promoted record
    // (and its recovery references) until cross-scope cleanup is durable.
    if (record.previousEndpoint != null && record.previousRevision != null &&
        record.previousEndpoint != record.scope.endpoint) {
      final oldScope = SyncCredentialScope.notebook(record.previousEndpoint!, record.scope.subject);
      await vault.delete(oldScope.key, record.previousRevision!);
    }
    await _put(SyncCredentialRecord._(scope: record.scope, revision: record.revision, old: record._candidate));
  }

  /// Only after core cleanup/compensation is proved. CAS protects newer writers.
  Future<void> rollback(SyncCredentialRecord record) async {
    if (!record.pending || record.kind == SyncCredentialKind.clone || record.kind == SyncCredentialKind.close ||
        record.phase == SyncCredentialPhase.promoted ||
        record.phase == SyncCredentialPhase.published) { throw const SyncVaultException('vault_invalid'); }
    if (record._old == null) {
      await remove(record);
    } else {
      await _put(SyncCredentialRecord._(scope: record.scope, revision: record.revision, old: record._old));
    }
  }

  /// One CAS creates the entire deletion intent before runtime unregister. The
  /// anchor is deleted last; a crash cannot lose the remaining target revisions.
  Future<SyncCredentialRecord?> beginClose(List<SyncCredentialRecord> records,
      String operationId, {required String notebookId, SyncCredentialScope? preferredScope}) async {
    if (!_uuid.hasMatch(operationId) || !_uuid.hasMatch(notebookId)) throw const SyncVaultException('vault_invalid');
    if (records.length > 1000) throw const SyncVaultException('vault_limit');
    if (records.isEmpty) return null;
    if (records.map((record) => record.scope.key).toSet().length != records.length ||
        records.any((record) => !record.present || record.pending || record._old == null ||
          record.scope.provisional || record.scope.subject != notebookId)) {
      throw const SyncVaultException('vault_changed');
    }
    final anchor = records.where((record) => record.scope == preferredScope).firstOrNull ?? records.first;
    final targets = records.where((record) => record.scope != anchor.scope)
      .map((record) => _CloseTarget(record.scope.key, record.revision!)).toList();
    // _put encodes/bounds the complete anchor BEFORE any write. Excessive intent
    // is a visible limit error, never a partially recorded close transaction.
    return _put(SyncCredentialRecord._(scope: anchor.scope, revision: anchor.revision,
      old: anchor._old, operationId: operationId, kind: SyncCredentialKind.close,
      phase: SyncCredentialPhase.closing, closeTargets: targets));
  }

  /// Caller must first prove selected runtime unregistered. No routing is changed.
  Future<void> completeClose(SyncCredentialRecord anchor) async {
    if (anchor.kind != SyncCredentialKind.close || anchor.phase != SyncCredentialPhase.closing ||
        anchor.revision == null || anchor.scope.provisional) { throw const SyncVaultException('vault_invalid'); }
    final current = await read(anchor.scope);
    if (!current.present) return; // A prior terminal deletion reply was lost.
    if (current.revision != anchor.revision || current.operationId != anchor.operationId ||
        current.kind != SyncCredentialKind.close) { throw const SyncVaultException('vault_changed'); }
    for (final target in anchor._closeTargets) {
      final value = await vault.read(target.key);
      if (!value.present) continue;
      if (value.revision != target.revision) throw const SyncVaultException('vault_changed');
      final record = _decodeListed(target.key, value);
      if (record.scope.provisional || record.scope.subject != anchor.scope.subject || record.pending) {
        throw const SyncVaultException('vault_changed');
      }
      await vault.delete(target.key, target.revision);
    }
    await _remove(anchor);
  }

  Future<SyncCredentialRecord> beginDisable(SyncCredentialRecord record, String operationId) {
    if (!record.present || record.pending || record._old == null || !_uuid.hasMatch(operationId)) {
      throw const SyncVaultException('vault_changed');
    }
    return _put(SyncCredentialRecord._(scope: record.scope, revision: record.revision,
      old: record._old, operationId: operationId, kind: SyncCredentialKind.disable,
      phase: SyncCredentialPhase.disabling));
  }

  Future<void> remove(SyncCredentialRecord record) {
    if (record.kind == SyncCredentialKind.clone || record.kind == SyncCredentialKind.close) {
      throw const SyncVaultException('vault_invalid');
    }
    return _remove(record);
  }

  Future<void> _remove(SyncCredentialRecord record) async {
    if (record.revision != null) await vault.delete(record.scope.key, record.revision!);
  }

  Future<SyncCloneCredentials> stageClone({required String operationId,
    required String endpoint, required String username, required String password, bool autoSyncEnabled = false}) async {
    final scope = SyncCredentialScope.provisional(endpoint, operationId);
    await stage(scope: scope, operationId: operationId, kind: SyncCredentialKind.clone,
      username: username, password: password, autoSyncEnabled: autoSyncEnabled);
    return SyncCloneCredentials._(scope, operationId, null, null, autoSyncEnabled);
  }

  Future<CoreSyncCredentials> cloneCredentials(SyncCloneCredentials clone) async {
    final record = await read(clone.provisionalScope);
    if (record.operationId != clone.operationId || record.kind != SyncCredentialKind.clone ||
        record.candidateCredentials == null) { throw const SyncVaultException('vault_changed'); }
    return record.candidateCredentials!;
  }

  /// Call only after native clone receipt validation and duplicate preflight.
  /// Destination admission is absent-only, including another pending candidate.
  Future<SyncCloneCredentials> rekeyClone(SyncCloneCredentials clone,
      {required String notebookId, required String importId,
      required CoreSyncCloneReceipt cloneReceipt}) async {
    if (importId.isEmpty || importId.length > 128) throw const SyncVaultException('vault_invalid');
    if (cloneReceipt.importId != importId || cloneReceipt.operationId != clone.operationId ||
        cloneReceipt.notebookId != notebookId ||
        canonicalSyncEndpoint(cloneReceipt.endpoint) != clone.provisionalScope.endpoint ||
        !_hex.hasMatch(cloneReceipt.accountHash) || !_hex.hasMatch(cloneReceipt.baselineHash) ||
        !_hex.hasMatch(cloneReceipt.treeHash)) { throw const SyncVaultException('vault_changed'); }
    final source = await read(clone.provisionalScope);
    if (source.operationId != clone.operationId || source.kind != SyncCredentialKind.clone || source._candidate == null) {
      throw const SyncVaultException('vault_changed');
    }
    if (cloneReceipt.autoSyncEnabled != source.autoSyncEnabled ||
        cloneReceipt.accountHash != sha256.convert(utf8.encode(source._candidate.username)).toString()) {
      throw const SyncVaultException('vault_changed');
    }
    final targetScope = SyncCredentialScope.notebook(source.scope.endpoint, notebookId);
    if (source.targetKey != null && (source.targetKey != targetScope.key || source.importId != importId)) {
      throw const SyncVaultException('vault_changed');
    }
    // Persist the target reference first: a lost write reply can be recovered.
    final linked = await _put(SyncCredentialRecord._(scope: source.scope,
      revision: source.revision, candidate: source._candidate,
      operationId: source.operationId, kind: source.kind, phase: SyncCredentialPhase.rekeyed,
      importId: importId, targetNotebookId: notebookId, targetKey: targetScope.key,
      autoSyncEnabled: source.autoSyncEnabled));
    final target = await read(targetScope);
    if (target.present) {
      if (target.operationId != clone.operationId || target.originKey != source.scope.key ||
          target.importId != importId || target.autoSyncEnabled != linked.autoSyncEnabled ||
          target._candidate?.id != linked._candidate!.id || target._old != null) {
        throw const SyncVaultException('vault_changed');
      }
    } else {
      await _put(SyncCredentialRecord._(scope: targetScope, revision: null,
        candidate: linked._candidate, operationId: clone.operationId,
        kind: SyncCredentialKind.clone, phase: SyncCredentialPhase.rekeyed,
        importId: importId, targetNotebookId: notebookId, originKey: source.scope.key,
        autoSyncEnabled: linked.autoSyncEnabled));
    }
    return SyncCloneCredentials._(source.scope, clone.operationId, importId, notebookId, source.autoSyncEnabled);
  }

  Future<SyncCloneCredentials> recoverClone(String endpoint, String operationId) async {
    final scope = SyncCredentialScope.provisional(endpoint, operationId);
    final record = await read(scope);
    if (record.operationId != operationId || record.kind != SyncCredentialKind.clone) {
      throw const SyncVaultException('vault_changed');
    }
    return SyncCloneCredentials._(scope, operationId, record.importId, record.targetNotebookId, record.autoSyncEnabled);
  }

  void _receipt(SyncCloneCredentials clone, SyncClonePublicationReceipt receipt) {
    if (receipt.operationId != clone.operationId || (clone.importId != null && receipt.importId != clone.importId) ||
        receipt.notebookId != clone.notebookId ||
        canonicalSyncEndpoint(receipt.endpoint) != clone.provisionalScope.endpoint) {
      throw const SyncVaultException('vault_changed');
    }
  }

  Future<void> promoteClone(SyncCloneCredentials clone,
      {required Future<SyncClonePublicationReceipt> Function() readPublicationReceipt}) async {
    final receipt = await readPublicationReceipt();
    _receipt(clone, receipt);
    if (!receipt.published || clone.notebookScope == null) throw const SyncVaultException('vault_changed');
    final source = await read(clone.provisionalScope);
    var target = await read(clone.notebookScope!);
    if (!source.present && target.present && !target.pending && target.active != null) {
      // Provisional deletion committed before its reply was lost. A later
      // credential generation is preserved; receipt reconciliation is read-only.
      return;
    }
    if (source.operationId != clone.operationId || source.targetKey != target.scope.key ||
        source._candidate == null) { throw const SyncVaultException('vault_changed'); }
    if (!target.pending && target._old?.id == source._candidate.id) {
      await _remove(source); // Previous promotion settled; reply was lost.
      return;
    }
    if (target.operationId != clone.operationId || target.originKey != source.scope.key ||
        target.importId != clone.importId || target.autoSyncEnabled != source.autoSyncEnabled ||
        target._candidate?.id != source._candidate.id || target._old != null) {
      throw const SyncVaultException('vault_changed');
    }
    if (target.phase != SyncCredentialPhase.promoted) {
      target = await mark(target, SyncCredentialPhase.published);
      target = await _promote(target);
    }
    // Keep provisional recovery references until destination retirement is durable.
    await retire(target);
    await _remove(source);
  }

  Future<void> abandonClone(SyncCloneCredentials clone,
      {required Future<SyncClonePublicationReceipt> Function() readPublicationReceipt}) async {
    final receipt = await readPublicationReceipt();
    _receipt(clone, receipt);
    if (receipt.published) throw const SyncVaultException('vault_changed');
    final source = await read(clone.provisionalScope);
    if (source.operationId != clone.operationId) throw const SyncVaultException('vault_changed');
    final scope = clone.notebookScope;
    if (scope != null) {
      final target = await read(scope);
      if (target.present && target.operationId == clone.operationId && target.originKey == source.scope.key) {
        if (target._old != null || target.phase == SyncCredentialPhase.promoted ||
            target.phase == SyncCredentialPhase.published) { throw const SyncVaultException('vault_changed'); }
        await _remove(target);
      }
      // A foreign destination is never ours to delete, even after duplicate or
      // publication races. The proved nonpublished provisional scope is ours.
    }
    await _remove(source);
  }
}
