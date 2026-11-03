// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/sync_credentials.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

const syncTestNotebook = '12345678-1234-4234-8234-123456789abc';
const syncTestOperation = 'abcdef01-1234-4234-8234-123456789abc';
const syncTestEndpoint = 'https://example.test/notebook/';

/// Protocol test storage, NOT evidence of platform encryption or persistence.
/// Copies bytes, enforces real CAS, and supports lost replies after mutation.
class TestSyncVault implements SyncVault {
  final Map<String, ({String revision, Uint8List data})> records = {};
  int sequence = 0;
  String? failure;
  bool loseNextWriteReply = false;
  bool loseNextDeleteReply = false;
  bool trust = true;
  Future<void> Function(String key, String revision)? beforeDelete;
  void _available() {
    if (failure != null) throw SyncVaultException(failure!);
  }
  @override
  Future<List<String>> list() async { _available(); return records.keys.toList(); }
  @override
  Future<SyncVaultValue> read(String key) async {
    _available();
    final value = records[key];
    return value == null ? SyncVaultValue.absent() : SyncVaultValue.present(value.revision, value.data);
  }
  @override
  Future<String> write(String key, String? expectedRevision, Uint8List data) async {
    _available();
    if (records[key]?.revision != expectedRevision) throw const SyncVaultException('vault_changed');
    final revision = sha256.convert([...data, ...utf8.encode('${++sequence}')]).toString();
    records[key] = (revision: revision, data: Uint8List.fromList(data));
    if (loseNextWriteReply) {
      loseNextWriteReply = false;
      throw const SyncVaultException('vault_unavailable');
    }
    return revision;
  }
  @override
  Future<void> delete(String key, String expectedRevision) async {
    _available();
    await beforeDelete?.call(key, expectedRevision);
    if (records.containsKey(key) && records[key]!.revision != expectedRevision) {
      throw const SyncVaultException('vault_changed');
    }
    records.remove(key);
    if (loseNextDeleteReply) {
      loseNextDeleteReply = false;
      throw const SyncVaultException('vault_unavailable');
    }
  }
  @override
  Future<bool> trustAvailable() async { _available(); return trust; }
}

Future<void> seedSyncCredentials(SyncCredentials credentials, {
  String endpoint = syncTestEndpoint, String notebookId = syncTestNotebook,
  String username = 'alice', String password = 'old-secret',
}) async {
  var record = await credentials.stage(scope: SyncCredentialScope.notebook(endpoint, notebookId),
    operationId: newSyncOperationId(), kind: SyncCredentialKind.enable,
    username: username, password: password);
  record = await credentials.mark(record, SyncCredentialPhase.coreCommitted);
  record = await credentials.mark(record, SyncCredentialPhase.routingCommitted);
  record = await credentials.promote(record);
  await credentials.retire(record);
}

CoreSyncCloneReceipt cloneProof({String notebookId = syncTestNotebook,
  String operationId = syncTestOperation, String importId = 'import-owned',
  String endpoint = syncTestEndpoint, bool autoSyncEnabled = false}) => CoreSyncCloneReceipt(
    importId: importId, operationId: operationId, notebookId: notebookId,
    endpoint: endpoint, accountHash: sha256.convert(utf8.encode('clone')).toString(),
    baselineHash: 'b' * 64, treeHash: 'c' * 64, autoSyncEnabled: autoSyncEnabled);

Matcher vaultError(String code) => isA<SyncVaultException>().having((error) => error.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('endpoint canonicalization matches core byte and scope rules', () {
    expect(canonicalSyncEndpoint('HTTPS://EXAMPLE.test:0443/a%20b/%c3%a9'),
      'https://example.test/a%20b/%C3%A9/');
    expect(canonicalSyncEndpoint('https://EXAMPLE.test'), 'https://example.test/');
    expect(canonicalSyncEndpoint('https://[::1]:8443/book'), 'https://[::1]:8443/book/');
    final scope = SyncCredentialScope.notebook('https://EXAMPLE.test:443/notebook', syncTestNotebook);
    expect(scope.key, SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook).key);
    expect(scope.key, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(scope.key, isNot(SyncCredentialScope.provisional(syncTestEndpoint, syncTestNotebook).key));
    for (final endpoint in ['http://example.test/', 'https://user:pass@example.test/',
      'https://example.test/?secret=x', 'https://example.test/#secret',
      'https://example.test/a/../b', 'https://example.test/%2e/',
      'https://example.test//a', 'https://example.test/a%2fb',
      'https://example.test/a%5cb', 'https://example.test/%00',
      'https://example.test/%ff', 'https://example.test:0/',
      'https://example.test:65536/', 'https://example.test/\\unsafe']) {
      expect(() => canonicalSyncEndpoint(endpoint), throwsA(vaultError('vault_invalid')), reason: endpoint);
    }
  });

  test('candidate staging never replaces usable credentials until validated promotion', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    await seedSyncCredentials(service);
    var transaction = await service.stage(scope: scope, operationId: syncTestOperation,
      kind: SyncCredentialKind.rotation, username: 'bob', password: 'candidate-secret');
    expect(transaction.active!.username, 'alice');
    expect(transaction.active!.password, 'old-secret');
    expect(transaction.candidateCredentials!.password, 'candidate-secret');
    expect(transaction.toString(), isNot(contains('secret')));
    await expectLater(service.promote(transaction), throwsA(vaultError('vault_invalid')));
    transaction = await service.mark(transaction, SyncCredentialPhase.coreCommitted);
    transaction = await service.promote(transaction);
    final reopened = await SyncCredentials(vault: vault).read(scope);
    expect(reopened.active!.username, 'bob');
    expect(reopened.oldCredentials!.password, 'old-secret');
    await service.retire(transaction);
    final finalRecord = await service.read(scope);
    expect(finalRecord.pending, isFalse);
    expect(finalRecord.candidateCredentials, isNull);
    expect(finalRecord.active!.password, 'candidate-secret');
  });

  test('enable cannot promote after authentication before routing persistence', () async {
    final service = SyncCredentials(vault: TestSyncVault());
    var record = await service.stage(scope: SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook),
      operationId: syncTestOperation, kind: SyncCredentialKind.enable, username: '', password: 'x');
    record = await service.mark(record, SyncCredentialPhase.coreCommitted);
    await expectLater(service.promote(record), throwsA(vaultError('vault_invalid')));
    await expectLater(service.mark(record, SyncCredentialPhase.rekeyed), throwsA(vaultError('vault_invalid')));
    expect((await service.read(record.scope)).candidateCredentials!.password, 'x');
  });

  test('stale transaction rollback and delete cannot erase a new generation', () async {
    final service = SyncCredentials(vault: TestSyncVault());
    await seedSyncCredentials(service);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final old = await service.read(scope);
    var staged = await service.stage(scope: scope, operationId: syncTestOperation,
      kind: SyncCredentialKind.rotation, username: 'new', password: 'new-secret');
    final stale = staged;
    staged = await service.mark(staged, SyncCredentialPhase.coreCommitted);
    staged = await service.promote(staged);
    await service.retire(staged);
    await expectLater(service.remove(old), throwsA(vaultError('vault_changed')));
    await expectLater(service.rollback(stale), throwsA(vaultError('vault_changed')));
    expect((await service.read(scope)).active!.username, 'new');
  });

  test('lost stage reply remains a durable pending transaction, not absent', () async {
    final vault = TestSyncVault()..loseNextWriteReply = true;
    final service = SyncCredentials(vault: vault);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    await expectLater(service.stage(scope: scope, operationId: syncTestOperation,
      kind: SyncCredentialKind.enable, username: 'alice', password: 'secret'),
      throwsA(vaultError('vault_unavailable')));
    final reopened = await service.read(scope);
    expect(reopened.operationId, syncTestOperation);
    expect(reopened.phase, SyncCredentialPhase.staged);
    expect(reopened.candidateCredentials!.password, 'secret');
  });

  test('payload binding and unknown versions are retained as corrupt', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    await seedSyncCredentials(service);
    final scope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final stored = vault.records[scope.key]!;
    final json = jsonDecode(utf8.decode(stored.data)) as Map<String, dynamic>;
    json['scope']['endpoint'] = 'https://foreign.test/';
    vault.records[scope.key] = (revision: stored.revision, data: Uint8List.fromList(utf8.encode(jsonEncode(json))));
    await expectLater(service.read(scope), throwsA(vaultError('vault_corrupt')));
    expect(vault.records.containsKey(scope.key), isTrue);
    vault.failure = 'vault_locked';
    await expectLater(service.notebookScopes(syncTestNotebook), throwsA(vaultError('vault_locked')));
    expect(vault.records.length, 1);
  });

  test('clone rekey refuses foreign active destination and forged receipt', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    await seedSyncCredentials(service);
    final clone = await service.stageClone(operationId: syncTestOperation,
      endpoint: syncTestEndpoint, username: 'clone', password: 'clone-secret');
    await expectLater(service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof(operationId: newSyncOperationId())),
      throwsA(vaultError('vault_changed')));
    await expectLater(service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof()), throwsA(vaultError('vault_changed')));
    expect((await service.read(SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook))).active!.username, 'alice');
    expect(await service.cloneCredentials(clone), isA<CoreSyncCredentials>());
  });

  test('nonpublished duplicate cleanup removes only its provisional credential', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    await seedSyncCredentials(service);
    final clone = await service.stageClone(operationId: syncTestOperation,
      endpoint: syncTestEndpoint, username: 'clone', password: 'candidate');
    await expectLater(service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof()), throwsA(vaultError('vault_changed')));
    final recovered = await service.recoverClone(syncTestEndpoint, syncTestOperation);
    await service.abandonClone(recovered, readPublicationReceipt: () async =>
      const SyncClonePublicationReceipt(operationId: syncTestOperation,
        importId: 'import-owned', notebookId: syncTestNotebook,
        endpoint: syncTestEndpoint, published: false));
    expect((await service.read(recovered.provisionalScope)).present, isFalse);
    expect((await service.read(recovered.notebookScope!)).active!.username, 'alice');
  });

  test('clone account binding must match exact staged username bytes', () async {
    final service = SyncCredentials(vault: TestSyncVault());
    final clone = await service.stageClone(operationId: syncTestOperation,
      endpoint: syncTestEndpoint, username: 'different-account', password: 'secret');
    await expectLater(service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof()), throwsA(vaultError('vault_changed')));
    expect((await service.read(SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook))).present, isFalse);
    expect((await service.read(clone.provisionalScope)).present, isTrue);
  });

  test('clone rekey survives restart and promotion requires actual exact publication', () async {
    final vault = TestSyncVault();
    var service = SyncCredentials(vault: vault);
    var clone = await service.stageClone(operationId: syncTestOperation,
      endpoint: syncTestEndpoint, username: 'clone', password: 'clone-secret');
    clone = await service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof());
    service = SyncCredentials(vault: vault);
    clone = await service.recoverClone(syncTestEndpoint, syncTestOperation);
    SyncClonePublicationReceipt receipt(bool published, {String operationId = syncTestOperation}) =>
      SyncClonePublicationReceipt(operationId: operationId, importId: 'import-owned',
        notebookId: syncTestNotebook, endpoint: syncTestEndpoint, published: published);
    await expectLater(service.promoteClone(clone, readPublicationReceipt: () async => receipt(false)),
      throwsA(vaultError('vault_changed')));
    await expectLater(service.promoteClone(clone,
      readPublicationReceipt: () async => receipt(true, operationId: newSyncOperationId())),
      throwsA(vaultError('vault_changed')));
    final pendingClone = await service.read(clone.notebookScope!);
    expect(pendingClone.active, isNull);
    expect(() => service.promote(pendingClone), throwsA(vaultError('vault_invalid')));
    await expectLater(service.rollback(pendingClone), throwsA(vaultError('vault_invalid')));
    expect(() => service.remove(pendingClone), throwsA(vaultError('vault_invalid')));
    var receiptReads = 0;
    await service.promoteClone(clone, readPublicationReceipt: () async { receiptReads++; return receipt(true); });
    expect(receiptReads, 1);
    expect((await service.read(clone.notebookScope!)).active!.password, 'clone-secret');
    expect((await service.read(clone.provisionalScope)).present, isFalse);
    expect(vault.records.length, 1);
  });

  test('lost provisional deletion reply never deletes the promoted scope', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    var clone = await service.stageClone(operationId: syncTestOperation,
      endpoint: syncTestEndpoint, username: 'clone', password: 'secret');
    clone = await service.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof());
    vault.loseNextDeleteReply = true;
    await expectLater(service.promoteClone(clone, readPublicationReceipt: () async =>
      const SyncClonePublicationReceipt(operationId: syncTestOperation,
        importId: 'import-owned', notebookId: syncTestNotebook,
        endpoint: syncTestEndpoint, published: true)), throwsA(vaultError('vault_unavailable')));
    expect((await service.read(clone.notebookScope!)).active!.username, 'clone');
    expect((await service.read(clone.provisionalScope)).present, isFalse);
    final revision = (await service.read(clone.notebookScope!)).revision;
    await service.promoteClone(clone, readPublicationReceipt: () async =>
      const SyncClonePublicationReceipt(operationId: syncTestOperation,
        importId: 'import-owned', notebookId: syncTestNotebook,
        endpoint: syncTestEndpoint, published: true));
    expect((await service.read(clone.notebookScope!)).revision, revision);
  });

  test('endpoint retirement cannot delete independently replaced old scope', () async {
    final service = SyncCredentials(vault: TestSyncVault());
    await seedSyncCredentials(service);
    final oldScope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final old = await service.read(oldScope);
    var candidate = await service.stage(scope: SyncCredentialScope.notebook('https://next.test/', syncTestNotebook),
      operationId: syncTestOperation, kind: SyncCredentialKind.endpoint,
      username: 'next', password: 'candidate', previousEndpoint: syncTestEndpoint,
      previousRevision: old.revision);
    var replacement = await service.stage(scope: oldScope, operationId: newSyncOperationId(),
      kind: SyncCredentialKind.rotation, username: 'replacement', password: 'retained');
    replacement = await service.mark(replacement, SyncCredentialPhase.coreCommitted);
    replacement = await service.promote(replacement);
    await service.retire(replacement);
    candidate = await service.mark(candidate, SyncCredentialPhase.coreCommitted);
    candidate = await service.mark(candidate, SyncCredentialPhase.routingCommitted);
    candidate = await service.promote(candidate);
    await expectLater(service.retire(candidate), throwsA(vaultError('vault_changed')));
    expect((await service.read(oldScope)).active!.username, 'replacement');
    expect((await service.read(candidate.scope)).phase, SyncCredentialPhase.promoted);
  });

  test('clone preference and provisional discovery survive restart before a receipt', () async {
    final vault = TestSyncVault();
    final first = SyncCredentials(vault: vault);
    await first.stageClone(operationId: syncTestOperation, endpoint: syncTestEndpoint,
      username: 'clone', password: 'candidate', autoSyncEnabled: true);
    final reopened = SyncCredentials(vault: vault);
    var clone = (await reopened.findClone(syncTestOperation))!;
    expect(clone.provisionalScope.endpoint, syncTestEndpoint);
    expect(clone.notebookId, isNull);
    expect(clone.autoSyncEnabled, isTrue);
    await expectLater(reopened.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof()), throwsA(vaultError('vault_changed')));
    clone = await reopened.rekeyClone(clone, notebookId: syncTestNotebook,
      importId: 'import-owned', cloneReceipt: cloneProof(autoSyncEnabled: true));
    expect(clone.autoSyncEnabled, isTrue);
    expect((await reopened.recoverClone(syncTestEndpoint, syncTestOperation)).autoSyncEnabled, isTrue);
    expect((await reopened.findClone(syncTestOperation))!.notebookId, syncTestNotebook);
    expect((await reopened.read(clone.notebookScope!)).autoSyncEnabled, isTrue);
  });

  test('findClone returns absent only after a complete successful bounded scan', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    expect(await service.findClone(syncTestOperation), isNull);
    for (final code in ['vault_locked', 'vault_unavailable', 'vault_corrupt']) {
      vault.failure = code;
      await expectLater(service.findClone(syncTestOperation), throwsA(vaultError(code)));
    }
    vault.failure = null;
    await service.stageClone(operationId: syncTestOperation, endpoint: syncTestEndpoint,
      username: 'clone', password: 'one');
    await service.stageClone(operationId: syncTestOperation, endpoint: 'https://other.test/',
      username: 'clone', password: 'two');
    await expectLater(service.findClone(syncTestOperation), throwsA(vaultError('vault_changed')));
    expect(vault.records, hasLength(2));
  });

  test('clone discovery does not return early before a later corrupt record is inspected', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    await service.stageClone(operationId: syncTestOperation, endpoint: syncTestEndpoint,
      username: 'clone', password: 'candidate');
    vault.records['f' * 64] = (revision: 'e' * 64, data: Uint8List.fromList([0xff]));
    await expectLater(service.findClone(syncTestOperation), throwsA(vaultError('vault_corrupt')));
    expect(vault.records, hasLength(2));
  });

  test('close anchor retains all remaining CAS targets after a lost deletion reply', () async {
    final vault = TestSyncVault();
    var service = SyncCredentials(vault: vault);
    final endpoints = [syncTestEndpoint, 'https://old-one.test/', 'https://old-two.test/'];
    for (final endpoint in endpoints) { await seedSyncCredentials(service, endpoint: endpoint); }
    final records = <SyncCredentialRecord>[];
    for (final scope in await service.notebookScopes(syncTestNotebook)) { records.add(await service.read(scope)); }
    final anchor = (await service.beginClose(records, syncTestOperation, notebookId: syncTestNotebook,
      preferredScope: SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook)))!;
    expect(anchor.kind, SyncCredentialKind.close);
    expect(anchor.phase, SyncCredentialPhase.closing);
    expect(() => service.remove(anchor), throwsA(vaultError('vault_invalid')));
    vault.loseNextDeleteReply = true;
    await expectLater(service.completeClose(anchor), throwsA(vaultError('vault_unavailable')));
    expect((await service.read(anchor.scope)).kind, SyncCredentialKind.close);
    expect(vault.records, hasLength(2));
    service = SyncCredentials(vault: vault);
    await service.completeClose(await service.read(anchor.scope));
    expect(vault.records, isEmpty);
    await service.completeClose(anchor); // Lost final reply is idempotent.
    expect(vault.records, isEmpty);
  });

  test('close intent never deletes a replaced target or a successor anchor generation', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    await seedSyncCredentials(service);
    await seedSyncCredentials(service, endpoint: 'https://old.test/');
    final currentScope = SyncCredentialScope.notebook(syncTestEndpoint, syncTestNotebook);
    final oldScope = SyncCredentialScope.notebook('https://old.test/', syncTestNotebook);
    final anchor = (await service.beginClose([await service.read(currentScope), await service.read(oldScope)],
      syncTestOperation, notebookId: syncTestNotebook, preferredScope: currentScope))!;
    var replacement = await service.stage(scope: oldScope, operationId: newSyncOperationId(),
      kind: SyncCredentialKind.rotation, username: 'successor', password: 'retained');
    replacement = await service.mark(replacement, SyncCredentialPhase.coreCommitted);
    replacement = await service.promote(replacement);
    await service.retire(replacement);
    await expectLater(service.completeClose(anchor), throwsA(vaultError('vault_changed')));
    expect((await service.read(oldScope)).active!.username, 'successor');
    expect((await service.read(currentScope)).kind, SyncCredentialKind.close);

    final separateVault = TestSyncVault();
    final separate = SyncCredentials(vault: separateVault);
    await seedSyncCredentials(separate);
    final retired = (await separate.beginClose([await separate.read(currentScope)], newSyncOperationId(),
      notebookId: syncTestNotebook))!;
    await separate.completeClose(retired);
    await seedSyncCredentials(separate, username: 'new-generation');
    await expectLater(separate.completeClose(retired), throwsA(vaultError('vault_changed')));
    expect((await separate.read(currentScope)).active!.username, 'new-generation');
  });

  test('oversized close intent is refused before any credential generation mutates', () async {
    final vault = TestSyncVault();
    final service = SyncCredentials(vault: vault);
    final records = <SyncCredentialRecord>[];
    for (var index = 0; index < 500; index++) {
      final endpoint = 'https://old-$index.test/';
      await seedSyncCredentials(service, endpoint: endpoint);
      records.add(await service.read(SyncCredentialScope.notebook(endpoint, syncTestNotebook)));
    }
    final before = {for (final entry in vault.records.entries) entry.key: entry.value.revision};
    await expectLater(service.beginClose(records, syncTestOperation, notebookId: syncTestNotebook),
      throwsA(vaultError('vault_limit')));
    expect({for (final entry in vault.records.entries) entry.key: entry.value.revision}, before);
  });

  test('platform adapter preserves locked, unavailable and corrupt distinctions', () async {
    const channel = MethodChannel('vnote.mobile/sync_security');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final vault = MethodChannelSyncVault(channel: channel);
    final key = 'a' * 64;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final code in ['vault_locked', 'vault_unavailable', 'vault_corrupt', 'vault_changed']) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code, message: 'must-not-leak-password', details: {'revision': key});
      });
      await expectLater(vault.read(key), throwsA(isA<SyncVaultException>()
        .having((error) => error.code, 'fixed code', code)
        .having((error) => error.revision, 'CAS deletion fingerprint', key)
        .having((error) => error.toString(), 'redaction', isNot(contains('password')))));
    }
    messenger.setMockMethodCallHandler(channel, (_) async => {'present': false});
    expect((await vault.read(key)).present, isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => {'present': false, 'data': Uint8List(0)});
    await expectLater(vault.read(key), throwsA(vaultError('vault_corrupt')));
  });
}
