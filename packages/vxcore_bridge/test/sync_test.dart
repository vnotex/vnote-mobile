// SPDX-License-Identifier: LGPL-3.0-only
@Tags(['webdav-integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vxcore_bridge/src/generated/vxcore_host_bindings.dart' as native;
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'sync_fixture.dart';

Future<CoreSyncResult> invoke(SyncCore owner, CoreSyncAction action, String id,
    {CoreSyncConfiguration? configuration, CoreSyncCredentials? credentials,
    bool settled = false, List<String> protected = const [], String? cloneImportId}) => owner.sync(CoreSyncCommand(
      action: action, operationId: id, configuration: configuration, settled: settled, cloneImportId: cloneImportId,
      protectedNodeIds: protected, protectMetadata: protected.isNotEmpty), credentials: credentials);
Future<void> successful(Future<CoreSyncResult> future) async {
  final result = await future;
  expect(result.code, 0, reason: '${result.action.name} must report actual core success');
  expect(result.cleanupRequired, isFalse);
}
Future<void> connect(SyncFixture fixture, SyncCore owner) async {
  final id = fixture.operationId();
  final enabled = await invoke(owner, CoreSyncAction.enable, id,
    configuration: fixture.configuration, credentials: fixture.credentials);
  expect(enabled.code, 0); expect(enabled.executed, isTrue); expect(enabled.committed, isTrue);
  await successful(invoke(owner, CoreSyncAction.configure, id, configuration: fixture.configuration));
}
Future<CoreSyncResult> cycle(SyncFixture fixture, SyncCore owner,
    {List<String> protected = const [], Future<void> Function(CoreSyncResult)? afterRefresh}) async {
  final id = fixture.operationId();
  await successful(invoke(owner, CoreSyncAction.begin, id));
  await successful(invoke(owner, CoreSyncAction.stage, id));
  await successful(invoke(owner, CoreSyncAction.network, id));
  final applied = await invoke(owner, CoreSyncAction.apply, id, protected: protected);
  final refreshed = await invoke(owner, CoreSyncAction.refresh, id);
  expect(refreshed.refreshCode, 0);
  if (afterRefresh != null) await afterRefresh(applied);
  final finished = await invoke(owner, CoreSyncAction.finish, id, settled: applied.code == 0);
  if (applied.code == 0) expect(finished.code, 0);
  return applied;
}
Future<({CoreNotebook owner, String notebookId, String nodeId})> note(SyncFixture fixture) async {
  final catalog = await fixture.createCatalog();
  final book = catalog.initialDirectory.notebookId;
  final node = await catalog.createNote(catalog.initialDirectory.folderId, 'Welcome.md');
  await catalog.close();
  final owner = await CoreNotebook.openNote(appDataPath: fixture.path('book-app'),
    localDataPath: fixture.path('book-local'), notebookPath: fixture.path('book'), notebookId: book, nodeId: node);
  final source = await owner.read();
  await owner.write('first saved snapshot\n', revision: 1, baseHash: source.baseHash);
  return (owner: owner, notebookId: book, nodeId: node);
}
Future<Map<String, Object?>> fsCommand(SyncFixture fixture, String importId, String op,
    [Map<String, Object?> extra = const {}]) {
  final request = <String, Object?>{
    'op': op, 'importsRoot': fixture.path('imports'), 'notebooksRoot': fixture.path('notebooks'),
    'id': importId, ...extra};
  return Isolate.run(() => CoreImportStore.run(request));
}
Future<String> cloneWrapper(SyncFixture fixture, String operation, {bool origin = true}) async {
  final id = fixture.importId();
  await Directory(fixture.path('imports/$id')).create(recursive: true);
  await Directory(fixture.path('notebooks')).create(recursive: true);
  await fsCommand(fixture, id, 'writeMarker', {'marker': 'request', 'data': {
    'version': 1, 'id': id, 'kind': 'folder', if (origin) ...{'origin': 'webdavClone', 'operationId': operation}}});
  return id;
}
Future<CoreSyncResult> clone(SyncFixture fixture, String id, String operation,
    {int stagingBudgetBytes = 512 * 1024 * 1024}) async {
  final owner = await CoreNotebook.createSyncClone(transactionRoot: fixture.path('imports/$id'));
  try { return await owner.cloneSync(operationId: operation, configuration: fixture.configuration,
    credentials: fixture.credentials, stagingBudgetBytes: stagingBudgetBytes); }
  finally { await owner.close(); }
}
Future<void> copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(source.path.length + 1);
    if (entity is Directory) await Directory('${target.path}/$relative').create(recursive: true);
    else if (entity is File) { final file = File('${target.path}/$relative'); await file.parent.create(recursive: true); await entity.copy(file.path); }
    else throw StateError('Fixture copy refuses linked content');
  }
}
Future<Map<String, Object?>> ordinaryPrepare(SyncFixture fixture, String id) async {
  final root = fixture.path('imports/$id/unpacked');
  final records = <Map<String, Object?>>[];
  var bytes = 0;
  await for (final entity in Directory(root).list(recursive: true, followLinks: false)) {
    final path = entity.path.substring(root.length + 1).replaceAll('\\', '/');
    final directory = entity is Directory;
    final size = directory ? 0 : await File(entity.path).length(); bytes += size;
    records.add({'path': path, 'type': directory ? 'directory' : 'file', 'size': size,
      'sha256': directory ? '' : (await sha256.bind(File(entity.path).openRead()).first).toString()});
  }
  records.sort((a, b) => (a['path']! as String).compareTo(b['path']! as String));
  final manifest = records.map(jsonEncode).map((row) => '$row\n').join();
  await File(fixture.path('imports/$id/inventory.jsonl')).writeAsString(manifest, flush: true);
  await fsCommand(fixture, id, 'writeMarker', {'marker': 'captured', 'data': {'version': 1,
    'id': id, 'kind': 'folder', 'sourceName': 'Untrusted folder', 'bytes': bytes, 'entries': records.length}});
  final inventoryHash = sha256.convert(utf8.encode(manifest)).toString();
  await fsCommand(fixture, id, 'writeMarker', {'marker': 'prepared', 'data': {'version': 1,
    'id': id, 'kind': 'folder', 'treeRelative': 'unpacked', 'inventoryHash': inventoryHash,
    'bytes': bytes, 'entries': records.length}});
  return {'treeRelative': 'unpacked', 'inventoryHash': inventoryHash};
}

Future<({String id, String operation, String notebookId})> committedClone(SyncFixture fixture) async {
  final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
  final result = await clone(fixture, id, operation);
  expect(result.code, 0); expect(result.cloneReceipt, isNotNull);
  final prepared = await fsCommand(fixture, id, 'prepareClone', {'operationId': operation});
  final descriptor = {'treeRelative': prepared['treeRelative'], 'inventoryHash': prepared['inventoryHash']};
  final inspected = await fsCommand(fixture, id, 'inspect', descriptor);
  final publication = await fsCommand(fixture, id, 'publish', {...descriptor,
    'notebookId': inspected['notebookId'], 'notebookName': inspected['notebookName']});
  expect(publication['phase'], 'published');
  final committed = await fsCommand(fixture, id, 'commit');
  expect(committed['phase'], 'committed'); expect(committed['credentialsSettled'], isFalse);
  expect(committed['notebookId'], result.notebookId);
  return (id: id, operation: operation, notebookId: result.notebookId!);
}
Future<CoreNotebook> openClone(SyncFixture fixture, String id, String notebookId) =>
    CoreNotebook.openCatalog(appDataPath: fixture.path('published-app'), localDataPath: fixture.path('published-local'),
      notebookPath: fixture.path('notebooks/nb-$id'), expectedNotebookId: notebookId);
Future<Map<String, Object?>> cloneRoutingSnapshot(SyncFixture fixture, String id) async {
  final snapshot = <String, Object?>{};
  for (final relativeRoot in ['imports/$id', 'notebooks/nb-$id']) {
    final root = Directory(fixture.path(relativeRoot));
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final path = '$relativeRoot/${entity.path.substring(root.path.length + 1).replaceAll('\\', '/')}';
      if (entity is Directory) snapshot[path] = 'directory';
      else if (entity is File) snapshot[path] = {
        'bytes': base64Encode(await entity.readAsBytes()),
        'modified': (await entity.lastModified()).microsecondsSinceEpoch,
      };
      else throw StateError('Routing fixture refuses linked content');
    }
  }
  return snapshot;
}
Future<void> unchangedCloneRouting(SyncFixture fixture, String id, Future<CoreSyncResult> Function() command,
    {bool success = false, bool admissionFailure = false, bool intactReceipt = true, int? code}) async {
  // recover invokes native Store.state, including the actual wrapper/root object
  // identities; equal bytes or equal notebook UUIDs alone are not enough.
  final recovered = intactReceipt ? await fsCommand(fixture, id, 'recover') : null;
  final before = await cloneRoutingSnapshot(fixture, id);
  final requests = (await fixture.control({'action': 'requests', 'limit': 1}))['total'];
  if (admissionFailure) {
    await expectLater(command(), throwsA(isA<CoreException>()));
  } else {
    final result = await command();
    expect(result.code, code ?? (success ? 0 : isNot(0)));
    expect(result.committed, success);
  }
  expect(await cloneRoutingSnapshot(fixture, id), before);
  expect((await fixture.control({'action': 'requests', 'limit': 1}))['total'], requests,
    reason: 'Receipt-bound routing must never contact WebDAV');
  if (intactReceipt) expect(await fsCommand(fixture, id, 'recover'), recovered);
}

void main() {
  if (!SyncFixture.available) {
    test('real HTTPS synchronization requires the owned fixture runner', () {}, skip: 'Run via scripts/verify_sync.py in a fresh desktop process');
    return;
  }
  late SyncFixture fixture;
  final owners = <CoreNotebook>[];
  setUp(() async { fixture = await SyncFixture.create(); });
  tearDown(() async {
    await fixture.control({'action': 'clear_faults'});
    for (final owner in owners) { await owner.close(); }
    owners.clear(); await fixture.dispose();
  });

  test('NOTE owner bootstraps, applies incoming bytes, refreshes before settlement', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner);
    final first = await cycle(fixture, selected.owner);
    expect(first.code, 0); expect(first.changedPaths, isNotNull);
    expect(await fixture.remoteText('Welcome.md'), 'first saved snapshot\n');
    final before = await selected.owner.inspectSync();
    expect(before.registered, isTrue); expect(before.lastSuccessUtcMillis, greaterThan(0));
    await fixture.put('Welcome.md', 'incoming saved bytes\n');
    final incoming = await cycle(fixture, selected.owner, afterRefresh: (result) async {
      expect(result.changedPaths, contains('Welcome.md'));
      expect((await selected.owner.read()).text, 'incoming saved bytes\n');
    });
    expect(incoming.code, 0);
    expect((await selected.owner.inspectSync()).refreshRequired, isFalse);
    expect(enableSyncFixtureForTesting(), native.VxCoreError.VXCORE_ERR_INVALID_STATE);
  });

  test('staged/network snapshot permits owner saves and leaves a newer snapshot unsent', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final id = fixture.operationId();
    await successful(invoke(selected.owner, CoreSyncAction.begin, id));
    await successful(invoke(selected.owner, CoreSyncAction.stage, id));
    // This is the stage-terminal/network-submit window, not a second owner.
    final source = await selected.owner.read();
    await selected.owner.write('newer local snapshot\n', revision: 2, baseHash: source.baseHash);
    await fixture.control({'action': 'barrier', 'id': 'network', 'method': 'PROPFIND', 'path': ''});
    final network = invoke(selected.owner, CoreSyncAction.network, id);
    expect((await fixture.control({'action': 'wait', 'id': 'network', 'timeout_ms': 10000}))['reached'], isTrue);
    final latest = await selected.owner.read();
    await selected.owner.write('newest local snapshot\n', revision: 3, baseHash: latest.baseHash);
    await fixture.control({'action': 'release', 'id': 'network'});
    await successful(network);
    final applied = await invoke(selected.owner, CoreSyncAction.apply, id, protected: [selected.nodeId]);
    final refreshed = await invoke(selected.owner, CoreSyncAction.refresh, id);
    expect(refreshed.refreshCode, 0);
    await invoke(selected.owner, CoreSyncAction.finish, id, settled: applied.code == 0);
    expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'newest local snapshot\n');
    expect(await fixture.remoteText('Welcome.md'), 'first saved snapshot\n');
  });

  test('global lifecycle workers are bounded while ordinary owner reads stay live', () async {
    final first = await fixture.createCatalog(directory: 'first'); owners.add(first);
    final second = await fixture.createCatalog(directory: 'second'); owners.add(second);
    final third = await fixture.createCatalog(directory: 'third'); owners.add(third);
    final firstId = fixture.operationId(), secondId = fixture.operationId();
    await fixture.control({'action': 'barrier', 'id': 'first-worker', 'method': 'PROPFIND', 'path': ''});
    final one = invoke(first, CoreSyncAction.enable, firstId,
      configuration: fixture.configuration, credentials: fixture.credentials);
    expect((await fixture.control({'action': 'wait', 'id': 'first-worker', 'timeout_ms': 10000}))['reached'], isTrue);
    await fixture.control({'action': 'barrier', 'id': 'second-worker', 'method': 'PROPFIND', 'path': ''});
    final two = invoke(second, CoreSyncAction.enable, secondId,
      configuration: fixture.configuration, credentials: fixture.credentials);
    expect((await fixture.control({'action': 'wait', 'id': 'second-worker', 'timeout_ms': 10000}))['reached'], isTrue);
    final refused = await invoke(third, CoreSyncAction.enable, fixture.operationId(),
      configuration: fixture.configuration, credentials: fixture.credentials);
    expect(refused.code, native.VxCoreError.VXCORE_ERR_SYNC_IN_PROGRESS);
    expect(refused.executed, isFalse); expect(refused.committed, isFalse);
    expect((await third.list()).notebookId, third.initialDirectory.notebookId);
    first.cancelSync(firstId); second.cancelSync(secondId);
    await fixture.control({'action': 'release', 'id': 'first-worker'});
    await fixture.control({'action': 'release', 'id': 'second-worker'});
    expect((await one).committed, isFalse); expect((await two).committed, isFalse);
    expect((await third.inspectSync()).registered, isFalse);
  });

  test('wrong candidate credentials cannot replace an established account or baseline', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final state = File(fixture.path('book/vx_notebook/vx_sync/webdav/state.json'));
    final bytes = await state.readAsBytes();
    await fixture.control({'action': 'configure', 'anonymous_read': true});
    final failed = await invoke(selected.owner, CoreSyncAction.credentials, fixture.operationId(),
      credentials: CoreSyncCredentials(username: fixture.username, password: 'deliberately-wrong'));
    expect(failed.code, isNot(0)); expect(failed.committed, isFalse);
    expect(await state.readAsBytes(), bytes);
    final facts = await selected.owner.inspectSync(); expect(facts.registered, isTrue);
    expect(facts.provider.accountHash, sha256.convert(utf8.encode(fixture.username)).toString());
  });

  test('provider archive lease excludes writers and fresh invocation recovers original journal', () async {
    final owner = await fixture.createCatalog(); owners.add(owner);
    final book = owner.initialDirectory.notebookId;
    await owner.createNote(owner.initialDirectory.folderId, 'Welcome.md');
    await File(fixture.path('book/Welcome.md')).writeAsString('archived baseline\n', flush: true);
    await connect(fixture, owner); await cycle(fixture, owner);
    final baseline = await File(fixture.path('book/vx_notebook/vx_sync/webdav/state.json')).readAsBytes();
    final archive = fixture.operationId();
    await successful(invoke(owner, CoreSyncAction.unregister, archive));
    final begun = await invoke(owner, CoreSyncAction.providerBegin, archive);
    expect(begun.code, 0); expect(begun.cleanupRequired, isTrue);
    expect(begun.providerPhase, 'archived');
    await expectLater(owner.createNote(owner.initialDirectory.folderId, 'forbidden.md'), throwsA(isA<CoreException>()));
    final archived = await owner.inspectSync();
    expect(archived.provider.retirement, isTrue);
    expect(archived.provider.retirementOperationId, archive);
    await owner.close();
    final reopened = await CoreNotebook.openCatalog(appDataPath: fixture.path('book-app'),
      localDataPath: fixture.path('book-local'), notebookPath: fixture.path('book'), expectedNotebookId: book);
    owners.add(reopened);
    final invocation = fixture.operationId();
    final recovered = await invoke(reopened, CoreSyncAction.providerRecover, invocation);
    expect(recovered.operationId, invocation); expect(recovered.code, 0);
    expect(recovered.cleanupRequired, isFalse); expect(recovered.provider!.retirement, isFalse);
    expect(await File(fixture.path('book/vx_notebook/vx_sync/webdav/state.json')).readAsBytes(), baseline);
    expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'archived baseline\n');
    expect((await reopened.inspectSync()).registered, isFalse);
  });

  test('persistent refresh marker survives reopen until explicit source settlement', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final last = (await selected.owner.inspectSync()).lastSuccessUtcMillis;
    await selected.owner.close();
    final notebookPath = fixture.path('book');
    final key = sha256.convert(utf8.encode('$notebookPath\n${selected.notebookId}')).toString();
    final marker = File(fixture.path('book-local/sync-refresh/$key.json'));
    await marker.writeAsString(jsonEncode({'version': 1, 'notebookId': selected.notebookId,
      'root': notebookPath, 'operationId': fixture.operationId()}), flush: true);
    final reopened = await CoreNotebook.openNote(appDataPath: fixture.path('book-app'),
      localDataPath: fixture.path('book-local'), notebookPath: notebookPath,
      notebookId: selected.notebookId, nodeId: selected.nodeId);
    owners.add(reopened);
    expect((await reopened.inspectSync()).refreshRequired, isTrue);
    final captured = await reopened.read();
    await expectLater(reopened.write('unsafe save', revision: 1, baseHash: captured.baseHash), throwsA(isA<CoreException>()));
    final recovery = fixture.operationId();
    final refreshed = await invoke(reopened, CoreSyncAction.refresh, recovery);
    expect(refreshed.refreshCode, 0); expect(refreshed.refreshRequired, isTrue);
    expect(await marker.exists(), isTrue);
    expect((await reopened.read()).text, 'first saved snapshot\n');
    final retired = await invoke(reopened, CoreSyncAction.finish, recovery, settled: true);
    expect(retired.code, 0); expect(retired.committed, isFalse);
    expect(await marker.exists(), isFalse);
    expect((await reopened.inspectSync()).lastSuccessUtcMillis, last);
  });

  test('failed last-success persistence cannot report a successful round trip', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final last = (await selected.owner.inspectSync()).lastSuccessUtcMillis;
    await fixture.put('Welcome.md', 'incoming saved source\n');
    final id = fixture.operationId();
    for (final action in [CoreSyncAction.begin, CoreSyncAction.stage, CoreSyncAction.network,
      CoreSyncAction.apply, CoreSyncAction.refresh]) {
      await successful(invoke(selected.owner, action, id));
    }
    final locker = await Process.start(Platform.environment['VXCORE_WEBDAV_TEST_PYTHON']!, [
      '-u', '-c',
      'import sqlite3,sys; db=sqlite3.connect(sys.argv[1],timeout=10); '
      'db.execute("BEGIN IMMEDIATE"); print("locked",flush=True); '
      'sys.stdin.readline(); db.rollback(); db.close()',
      fixture.path('book-local/notebooks/${selected.notebookId}/metadata.db'),
    ]);
    final errors = locker.stderr.transform(utf8.decoder).join();
    try {
      expect(await locker.stdout.transform(utf8.decoder).transform(const LineSplitter()).first
        .timeout(const Duration(seconds: 15)), 'locked');
      final finished = await invoke(selected.owner, CoreSyncAction.finish, id, settled: true)
        .timeout(const Duration(seconds: 20));
      expect(finished.code, native.VxCoreError.VXCORE_ERR_IO);
      expect(finished.committed, isFalse);
    } finally {
      locker.stdin.writeln('release');
      await locker.stdin.close();
      expect(await locker.exitCode.timeout(const Duration(seconds: 15)), 0, reason: await errors);
    }
    expect((await selected.owner.inspectSync()).lastSuccessUtcMillis, last);
    expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'incoming saved source\n');
  });

  test('partial apply error keeps original code alongside successful actual refresh', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final last = (await selected.owner.inspectSync()).lastSuccessUtcMillis;
    await fixture.put('Welcome.md', 'incoming concurrent edit\n');
    final id = fixture.operationId();
    await successful(invoke(selected.owner, CoreSyncAction.begin, id));
    await successful(invoke(selected.owner, CoreSyncAction.stage, id));
    await successful(invoke(selected.owner, CoreSyncAction.network, id));
    await File(fixture.path('book/Welcome.md')).writeAsString('outside writer\n', flush: true);
    final applied = await invoke(selected.owner, CoreSyncAction.apply, id);
    expect(applied.code, isNot(0)); expect(applied.executed, isTrue);
    final refreshed = await invoke(selected.owner, CoreSyncAction.refresh, id);
    expect(refreshed.refreshCode, 0); expect(refreshed.code, applied.code);
    await invoke(selected.owner, CoreSyncAction.finish, id, settled: true);
    expect((await selected.owner.inspectSync()).lastSuccessUtcMillis, last);
    expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'outside writer\n');
  });

  test('cancel and close join a blocked network without stranding terminals', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner);
    final id = fixture.operationId();
    await successful(invoke(selected.owner, CoreSyncAction.begin, id));
    await successful(invoke(selected.owner, CoreSyncAction.stage, id));
    await fixture.control({'action': 'barrier', 'id': 'close', 'method': 'PROPFIND', 'path': ''});
    final network = invoke(selected.owner, CoreSyncAction.network, id);
    expect((await fixture.control({'action': 'wait', 'id': 'close', 'timeout_ms': 10000}))['reached'], isTrue);
    selected.owner.cancelSync(id);
    final closing = selected.owner.close();
    await fixture.control({'action': 'release', 'id': 'close'});
    final result = await network.timeout(const Duration(seconds: 30));
    expect(result.code, isNot(0));
    await closing.timeout(const Duration(seconds: 30));
    expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'first saved snapshot\n');
  });

  test('clone with insufficient body budget fails before downloading or granting a receipt', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    // A positive one-byte clone allowance is valid admission, but cannot hold
    // the real remote inventory. This must fail in the worker, not prepare.
    final result = await clone(fixture, id, operation, stagingBudgetBytes: 128 * 1024 + 2);
    expect(result.code, isNot(0)); expect(result.executed, isTrue);
    expect(result.committed, isFalse); expect(result.cloneReceipt, isNull);
    expect(await Directory(fixture.path('imports/$id/unpacked')).list().isEmpty, isTrue);
    expect(await File(fixture.path('imports/$id/clone-complete.json')).exists(), isFalse);
    await expectLater(fsCommand(fixture, id, 'prepareClone', {'operationId': operation}), throwsA(isA<CoreException>()));
    expect(await Directory(fixture.path('notebooks/nb-$id')).exists(), isFalse);
    expect(await fixture.remoteText('Welcome.md'), 'first saved snapshot\n');
  });

  test('clone admission accounts for runtime files created after the quota snapshot', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    final space = await fsCommand(fixture, id, 'checkSpace', {'requiredBytes': 0});
    final remaining = space['remainingBytes'] as int;
    final available = (space['availableBytes'] as int) - 64 * 1024 * 1024;
    final budget = remaining < available ? remaining : available;
    final result = await clone(fixture, id, operation, stagingBudgetBytes: budget);
    expect(result.code, 0); expect(result.cloneReceipt!.notebookId, selected.notebookId);
    expect(await File(fixture.path('imports/$id/unpacked/Welcome.md')).readAsString(), 'first saved snapshot\n');
    expect(await fixture.remoteText('Welcome.md'), 'first saved snapshot\n');
  });

  test('managed clone preserves proved baseline and UUID through real publication', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    final result = await clone(fixture, id, operation);
    expect(result.code, 0); expect(result.cloneReceipt, isNotNull);
    expect(result.notebookId, selected.notebookId);
    final baseline = await File(fixture.path('imports/$id/unpacked/vx_notebook/vx_sync/webdav/state.json')).readAsBytes();
    final prepared = await fsCommand(fixture, id, 'prepareClone', {'operationId': operation});
    final descriptor = {'treeRelative': prepared['treeRelative'], 'inventoryHash': prepared['inventoryHash']};
    final inspected = await fsCommand(fixture, id, 'inspect', descriptor);
    expect(inspected['notebookId'], selected.notebookId);
    final published = await fsCommand(fixture, id, 'publish', {...descriptor,
      'notebookId': inspected['notebookId'], 'notebookName': inspected['notebookName']});
    expect(published['phase'], 'published');
    expect(await File(fixture.path('notebooks/nb-$id/vx_notebook/vx_sync/webdav/state.json')).readAsBytes(), baseline);
    final live = await CoreNotebook.openCatalog(appDataPath: fixture.path('published-app'),
      localDataPath: fixture.path('published-local'), notebookPath: fixture.path('notebooks/nb-$id'),
      expectedNotebookId: selected.notebookId);
    owners.add(live); await live.close();
    final committed = await fsCommand(fixture, id, 'commit');
    expect(committed['phase'], 'committed'); expect(committed['credentialsSettled'], isFalse);
    expect(committed['endpoint'], fixture.endpoint); expect(committed['autoSyncEnabled'], isFalse);
    await expectLater(fsCommand(fixture, id, 'discard'), throwsA(isA<CoreException>()));
    final liveBody = File(fixture.path('notebooks/nb-$id/Welcome.md'));
    await liveBody.writeAsString('legitimate edit after publication\n', flush: true);
    final original = await fsCommand(fixture, id, 'inspectClone', {'operationId': operation});
    expect(original['baselineHash'], result.cloneReceipt!.baselineHash);
    await expectLater(fsCommand(fixture, id, 'finishCloneCredentials', {'operationId': fixture.operationId()}), throwsA(isA<CoreException>()));
    // This closed post-promotion acknowledgement records only this real managed
    // publication. The app suite separately exercises its secure-vault gate.
    expect((await fsCommand(fixture, id, 'finishCloneCredentials', {'operationId': operation}))['credentialsSettled'], isTrue);
    expect((await fsCommand(fixture, id, 'recover'))['credentialsSettled'], isTrue);
    expect((await fsCommand(fixture, id, 'discard'))['discarded'], isTrue);
    expect(await liveBody.readAsString(), 'legitimate edit after publication\n');
  });

  test('committed clone routes projected defaults offline and matching registered retries are no-ops', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final imported = await committedClone(fixture);
    expect(imported.notebookId, selected.notebookId);
    final live = await openClone(fixture, imported.id, imported.notebookId); owners.add(live);
    final configFile = File(fixture.path('notebooks/nb-${imported.id}/vx_notebook/config.json'));
    final projected = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    for (final key in ['syncEnabled', 'syncBackend', 'syncRemoteUrl', 'autoSyncEnabled']) {
      expect(projected.containsKey(key), isFalse, reason: 'Core clone projects every routing key out');
    }
    final blank = await live.inspectSync();
    expect(blank.enabled, isFalse); expect(blank.registered, isFalse); expect(blank.autoSyncEnabled, isTrue);
    Future<CoreSyncResult> route() => invoke(live, CoreSyncAction.configure, imported.operation,
      configuration: fixture.configuration, cloneImportId: imported.id);
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
      imported.operation, configuration: fixture.configuration), code: native.VxCoreError.VXCORE_ERR_SYNC_NOT_ENABLED);

    final before = await cloneRoutingSnapshot(fixture, imported.id);
    final requests = (await fixture.control({'action': 'requests', 'limit': 1}))['total'];
    await successful(route());
    expect((await fixture.control({'action': 'requests', 'limit': 1}))['total'], requests);
    final routed = await live.inspectSync();
    expect(routed.enabled, isTrue); expect(routed.backend, 'webdav'); expect(routed.endpoint, fixture.endpoint);
    expect(routed.autoSyncEnabled, isFalse); expect(routed.registered, isFalse);
    // Core ready denotes persisted route completeness, not authentication.
    expect(routed.ready, isTrue);
    final after = await cloneRoutingSnapshot(fixture, imported.id);
    final configPath = 'notebooks/nb-${imported.id}/vx_notebook/config.json';
    before.remove(configPath); after.remove(configPath);
    expect(after, before, reason: 'First routing changes only the owner configuration, never clone data or receipts');
    expect(await File(fixture.path('notebooks/nb-${imported.id}/Welcome.md')).readAsString(), 'first saved snapshot\n');
    expect((await fsCommand(fixture, imported.id, 'recover'))['credentialsSettled'], isFalse);

    // Give even a byte-identical config rewrite an unmistakable timestamp change.
    await configFile.setLastModified(DateTime.utc(2001));
    await unchangedCloneRouting(fixture, imported.id, route, success: true);
    expect((await live.inspectSync()).registered, isFalse);
    await successful(invoke(live, CoreSyncAction.enable, fixture.operationId(),
      configuration: fixture.configuration, credentials: fixture.credentials));
    final registered = await live.inspectSync();
    expect(registered.registered, isTrue); expect(registered.ready, isTrue);
    await configFile.setLastModified(DateTime.utc(2001));
    await unchangedCloneRouting(fixture, imported.id, route, success: true);
    final retried = await live.inspectSync();
    expect(retried.registered, isTrue); expect(retried.ready, registered.ready);
    expect(retried.lastSuccessUtcMillis, registered.lastSuccessUtcMillis);
    for (final configuration in [
      CoreSyncConfiguration(endpoint: '${fixture.endpoint}different/', autoSyncEnabled: false),
      CoreSyncConfiguration(endpoint: fixture.endpoint, autoSyncEnabled: true),
      CoreSyncConfiguration(endpoint: fixture.endpoint, enabled: false, autoSyncEnabled: false),
    ]) {
      await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
        imported.operation, configuration: configuration, cloneImportId: imported.id));
      expect((await live.inspectSync()).registered, isTrue);
    }
    expect((await fsCommand(fixture, imported.id, 'finishCloneCredentials',
      {'operationId': imported.operation}))['credentialsSettled'], isTrue);
    await unchangedCloneRouting(fixture, imported.id, route);
    expect((await live.inspectSync()).registered, isTrue);
    await successful(invoke(live, CoreSyncAction.unregister, fixture.operationId()));
    await unchangedCloneRouting(fixture, imported.id, route);
  });

  test('receipt routing refuses mismatched commands and established routes without changing bytes or identity', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final imported = await committedClone(fixture);
    var live = await openClone(fixture, imported.id, imported.notebookId); owners.add(live);
    final configFile = File(fixture.path('notebooks/nb-${imported.id}/vx_notebook/config.json'));
    final projected = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    await configFile.setLastModified(DateTime.utc(2001));
    for (final configuration in [
      CoreSyncConfiguration(endpoint: fixture.endpoint, enabled: false, autoSyncEnabled: false),
      CoreSyncConfiguration(endpoint: '${fixture.endpoint}different/', autoSyncEnabled: false),
      CoreSyncConfiguration(endpoint: fixture.endpoint, autoSyncEnabled: true),
    ]) {
      await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
        imported.operation, configuration: configuration, cloneImportId: imported.id));
    }
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
      fixture.operationId(), configuration: fixture.configuration, cloneImportId: imported.id));
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
      imported.operation, configuration: fixture.configuration, cloneImportId: fixture.importId()));
    for (final invalid in ['', 'A' * 32, 'f' * 31, 'f' * 33, '../${imported.id}']) {
      await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
        imported.operation, configuration: fixture.configuration, cloneImportId: invalid), admissionFailure: true);
    }
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.unregister,
      imported.operation, cloneImportId: imported.id), admissionFailure: true);
    await unchangedCloneRouting(fixture, imported.id, () => live.sync(CoreSyncCommand(
      action: CoreSyncAction.configure, operationId: imported.operation, configuration: fixture.configuration,
      cloneImportId: imported.id, path: 'Welcome.md')), admissionFailure: true);
    expect((await live.inspectSync()).enabled, isFalse);
    expect((await live.inspectSync()).registered, isFalse);

    // A runtime registration alone cannot authorize this special first route.
    await successful(invoke(live, CoreSyncAction.enable, fixture.operationId(),
      configuration: fixture.configuration, credentials: fixture.credentials));
    expect((await live.inspectSync()).registered, isTrue);
    expect((await live.inspectSync()).enabled, isFalse);
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
      imported.operation, configuration: fixture.configuration, cloneImportId: imported.id));
    await successful(invoke(live, CoreSyncAction.unregister, fixture.operationId()));

    for (final route in <Map<String, Object>>[
      {'syncEnabled': true, 'syncBackend': 'webdav', 'syncRemoteUrl': '${fixture.endpoint}different/', 'autoSyncEnabled': false},
      {'syncEnabled': false, 'syncBackend': 'webdav', 'syncRemoteUrl': fixture.endpoint, 'autoSyncEnabled': false},
      {'syncEnabled': true, 'syncBackend': 'other', 'syncRemoteUrl': fixture.endpoint, 'autoSyncEnabled': false},
      {'syncEnabled': true, 'syncBackend': 'webdav', 'syncRemoteUrl': fixture.endpoint, 'autoSyncEnabled': true},
    ]) {
      await live.close();
      await configFile.writeAsString(jsonEncode({...projected, ...route}), flush: true);
      live = await openClone(fixture, imported.id, imported.notebookId); owners.add(live);
      await configFile.setLastModified(DateTime.utc(2001));
      await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
        imported.operation, configuration: fixture.configuration, cloneImportId: imported.id));
    }
    // The last established route has the receipt endpoint but another stored
    // preference. Registration must not turn it into an authorized overwrite.
    await successful(invoke(live, CoreSyncAction.enable, fixture.operationId(),
      configuration: CoreSyncConfiguration(endpoint: fixture.endpoint, autoSyncEnabled: true), credentials: fixture.credentials));
    expect((await live.inspectSync()).registered, isTrue);
    await configFile.setLastModified(DateTime.utc(2001));
    await unchangedCloneRouting(fixture, imported.id, () => invoke(live, CoreSyncAction.configure,
      imported.operation, configuration: fixture.configuration, cloneImportId: imported.id));
    final retained = await live.inspectSync();
    expect(retained.registered, isTrue); expect(retained.autoSyncEnabled, isTrue);
  });

  test('routing requires the original committed clone wrapper receipt and destination object', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final imported = await committedClone(fixture);
    var live = await openClone(fixture, imported.id, imported.notebookId); owners.add(live);
    Future<CoreSyncResult> route() => invoke(live, CoreSyncAction.configure, imported.operation,
      configuration: fixture.configuration, cloneImportId: imported.id);
    final wrapper = fixture.path('imports/${imported.id}');
    final configFile = File(fixture.path('notebooks/nb-${imported.id}/vx_notebook/config.json'));
    final requestFile = File('$wrapper/request.json');
    final receiptFile = File('$wrapper/clone-complete.json');
    final originalState = await fsCommand(fixture, imported.id, 'recover');

    for (final name in ['committed.json', 'clone-complete.json']) {
      final marker = File('$wrapper/$name');
      final held = await marker.rename(fixture.path('held-$name'));
      try { await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false); }
      finally { await held.rename(marker.path); }
      expect(await fsCommand(fixture, imported.id, 'recover'), originalState);
    }
    final originalRequest = await requestFile.readAsBytes();
    final request = jsonDecode(utf8.decode(originalRequest)) as Map<String, dynamic>;
    for (final replacement in [
      {'version': 1, 'id': imported.id, 'kind': 'folder'},
      {...request, 'operationId': fixture.operationId()},
    ]) {
      await requestFile.writeAsString(jsonEncode(replacement), flush: true);
      try { await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false); }
      finally { await requestFile.writeAsBytes(originalRequest, flush: true); }
      expect(await fsCommand(fixture, imported.id, 'recover'), originalState);
    }
    final originalConfig = await configFile.readAsBytes();
    final config = jsonDecode(utf8.decode(originalConfig)) as Map<String, dynamic>;
    await configFile.writeAsString(jsonEncode({...config, 'id': fixture.operationId()}), flush: true);
    try { await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false); }
    finally { await configFile.writeAsBytes(originalConfig, flush: true); }
    expect(await fsCommand(fixture, imported.id, 'recover'), originalState);

    final originalReceipt = await receiptFile.readAsBytes();
    final receipt = jsonDecode(utf8.decode(originalReceipt)) as Map<String, dynamic>;
    for (final replacement in [
      {...receipt, 'notebookId': fixture.operationId()},
      {...receipt, 'endpoint': '${fixture.endpoint}different/'},
      {...receipt, 'autoSyncEnabled': true},
    ]) {
      await receiptFile.writeAsString(jsonEncode(replacement), flush: true);
      try { await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false); }
      finally { await receiptFile.writeAsBytes(originalReceipt, flush: true); }
      expect(await fsCommand(fixture, imported.id, 'recover'), originalState);
    }
    final heldReceipt = await receiptFile.rename(fixture.path('original-receipt.json'));
    try {
      await heldReceipt.copy(receiptFile.path);
      await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false);
    } finally {
      if (await receiptFile.exists()) await receiptFile.delete();
      await heldReceipt.rename(receiptFile.path);
    }
    expect(await fsCommand(fixture, imported.id, 'recover'), originalState);

    await live.close();
    final destination = Directory(fixture.path('notebooks/nb-${imported.id}'));
    final heldRoot = await destination.rename(fixture.path('original-clone-root'));
    try {
      await copyTree(heldRoot, destination);
      live = await openClone(fixture, imported.id, imported.notebookId); owners.add(live);
      await unchangedCloneRouting(fixture, imported.id, route, intactReceipt: false);
      await live.close();
    } finally {
      await live.close();
      if (await destination.exists()) await destination.delete(recursive: true);
      await heldRoot.rename(destination.path);
    }
    expect(await fsCommand(fixture, imported.id, 'recover'), originalState);
    expect(await File('${destination.path}/Welcome.md').readAsString(), 'first saved snapshot\n');
  });

  test('clean synced managed notebook does not block unrelated ordinary import', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final incoming = await cloneWrapper(fixture, fixture.operationId(), origin: false);
    final existing = fixture.path('notebooks/nb-${fixture.importId()}');
    await Directory(fixture.path('book')).rename(existing);
    final baseline = File('$existing/vx_notebook/vx_sync/webdav/state.json');
    final before = await baseline.readAsBytes();
    final current = await fsCommand(fixture, incoming, 'inspectManaged', {
      'location': existing, 'expectedNotebookId': selected.notebookId});
    expect(current['notebookId'], selected.notebookId);
    expect(current['nodeIds'], contains(selected.nodeId));
    final unrelated = await fixture.createCatalog(directory: 'unrelated'); owners.add(unrelated);
    final unrelatedId = unrelated.initialDirectory.notebookId;
    await unrelated.createNote(unrelated.initialDirectory.folderId, 'Other.md');
    await unrelated.close();
    await copyTree(Directory(fixture.path('unrelated')), Directory(fixture.path('imports/$incoming/unpacked')));
    final descriptor = await ordinaryPrepare(fixture, incoming);
    final inspected = await fsCommand(fixture, incoming, 'inspect', descriptor);
    expect(inspected['notebookId'], unrelatedId); expect(unrelatedId, isNot(selected.notebookId));
    final publication = await fsCommand(fixture, incoming, 'publish', {...descriptor,
      'notebookId': inspected['notebookId'], 'notebookName': inspected['notebookName']});
    expect(publication['phase'], 'published');
    expect(await baseline.readAsBytes(), before);
    expect(await File('$existing/Welcome.md').readAsString(), 'first saved snapshot\n');
  });

  test('ordinary baseline with absent entry and forged in-tree receipt is refused', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    expect((await clone(fixture, id, operation)).code, 0);
    final ordinary = await cloneWrapper(fixture, fixture.operationId(), origin: false);
    await copyTree(Directory(fixture.path('imports/$id/unpacked')), Directory(fixture.path('imports/$ordinary/unpacked')));
    final stateFile = File(fixture.path('imports/$ordinary/unpacked/vx_notebook/vx_sync/webdav/state.json'));
    final state = jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    final entries = state['entries'] as Map<String, dynamic>;
    entries['absent-from-source.md'] = entries['Welcome.md'];
    await stateFile.writeAsString(jsonEncode(state), flush: true);
    await File(fixture.path('imports/$id/clone-complete.json')).copy(fixture.path('imports/$ordinary/unpacked/clone-complete.json'));
    final descriptor = await ordinaryPrepare(fixture, ordinary);
    await expectLater(fsCommand(fixture, ordinary, 'inspect', descriptor), throwsA(isA<CoreException>()));
    expect(await Directory(fixture.path('notebooks/nb-$ordinary')).exists(), isFalse);
    expect(await fixture.remoteText('Welcome.md'), 'first saved snapshot\n');
  });

  test('prepared clone refuses a byte-identical replacement sibling receipt', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    expect((await clone(fixture, id, operation)).code, 0);
    final prepared = await fsCommand(fixture, id, 'prepareClone', {'operationId': operation});
    final descriptor = {'treeRelative': prepared['treeRelative'], 'inventoryHash': prepared['inventoryHash']};
    expect((await fsCommand(fixture, id, 'inspect', descriptor))['notebookId'], selected.notebookId);
    final receipt = File(fixture.path('imports/$id/clone-complete.json'));
    final replacement = await receipt.copy(fixture.path('imports/$id/replaced-receipt.json'));
    await receipt.delete(); await replacement.rename(receipt.path);
    await expectLater(fsCommand(fixture, id, 'inspect', descriptor), throwsA(isA<CoreException>()));
    expect(await Directory(fixture.path('notebooks/nb-$id')).exists(), isFalse);
  });

  test('clone source replacement, wrong wrapper and lost receipt never grant a permit', () async {
    final selected = await note(fixture); owners.add(selected.owner);
    await connect(fixture, selected.owner); await cycle(fixture, selected.owner); await selected.owner.close();
    final operation = fixture.operationId(), id = await cloneWrapper(fixture, operation);
    expect((await clone(fixture, id, operation)).code, 0);
    final otherOperation = fixture.operationId(), other = await cloneWrapper(fixture, otherOperation);
    await copyTree(Directory(fixture.path('imports/$id/unpacked')), Directory(fixture.path('imports/$other/unpacked')));
    await File(fixture.path('imports/$id/clone-complete.json')).copy(fixture.path('imports/$other/clone-complete.json'));
    await expectLater(fsCommand(fixture, other, 'inspectClone', {'operationId': otherOperation}), throwsA(isA<CoreException>()));
    await expectLater(fsCommand(fixture, id, 'inspectClone', {'operationId': fixture.operationId()}), throwsA(isA<CoreException>()));
    await File(fixture.path('imports/$id/unpacked/Welcome.md')).writeAsString('changed source', flush: true);
    await expectLater(fsCommand(fixture, id, 'prepareClone', {'operationId': operation}), throwsA(isA<CoreException>()));
    await File(fixture.path('imports/$id/clone-complete.json')).delete();
    await expectLater(fsCommand(fixture, id, 'inspectClone', {'operationId': operation}), throwsA(isA<CoreException>()));
    expect(await Directory(fixture.path('notebooks/nb-$id')).exists(), isFalse);
  });
}
