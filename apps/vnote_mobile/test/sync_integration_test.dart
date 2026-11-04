// SPDX-License-Identifier: LGPL-3.0-only
@Tags(['webdav-integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/managed_notebook_storage.dart';
import 'package:vnote_mobile/services/notebook_import.dart';
import 'package:vnote_mobile/services/notebook_library.dart';
import 'package:vnote_mobile/services/notebook_sync.dart';
import 'package:vnote_mobile/services/sync_credentials.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import '../../../packages/vxcore_bridge/test/sync_fixture.dart';
import 'sync_credentials_test.dart' show TestSyncVault;

/// No WebView or outstanding private drafts exist in this headless fixture.
/// The participant drains ACTUAL native body writes and reloads ACTUAL core
/// source after refresh; it does not simulate storage or echo sync commands.
class _Source implements NotebookSyncParticipant {
  _Source(this.core, this.nodeId, this.text, this.baseHash);
  final CoreNotebook core;
  final String nodeId;
  String text;
  String baseHash;
  bool dirty = false;
  bool recovery = false;
  Future<void>? writer;
  _SourceReservation? reservation;
  int reloads = 0;
  @override
  NotebookSyncReservation installSyncReservation(SyncReservationRequest request) {
    if (reservation != null) throw StateError('Overlapping source reservation');
    final installed = _SourceReservation(this, request);
    reservation = installed;
    return installed;
  }
  @override
  Future<bool> recoverSyncSources() async {
    if (!dirty) {
      final actual = await core.read();
      text = actual.text; baseHash = actual.baseHash; reloads++;
    }
    recovery = false;
    return true;
  }
  Future<void> save(String source, int revision) async {
    if (reservation != null) throw StateError('Save admitted during a source reservation');
    final write = () async {
      final written = await core.write(source, revision: revision, baseHash: baseHash);
      text = source;
      baseHash = written.baseHash;
    }();
    writer = write;
    try { await write; }
    finally { if (identical(writer, write)) writer = null; }
  }
}

class _SourceReservation implements NotebookSyncReservation {
  _SourceReservation(this.source, this.request);
  final _Source source;
  final SyncReservationRequest request;
  bool retired = false;
  void _owned() {
    if (retired || !identical(source.reservation, this)) throw StateError('Retired source reservation');
  }
  void _release() {
    _owned();
    retired = true;
    source.reservation = null;
  }
  @override
  Future<void> drainWriters() async { _owned(); await source.writer; }
  @override
  Future<SyncProtection> quiesceAndDrainDrafts() async {
    _owned();
    await source.writer;
    return SyncProtection(dirtyNodeIds: source.dirty ? [source.nodeId] : const []);
  }
  @override
  Future<SyncSettlement> settle(SyncRefreshReport? report) async {
    _owned();
    if (report != null && (!report.metadataRefreshed || report.changedPaths == null)) {
      source.recovery = true;
      _release();
      return const SyncSettlement(safe: false, recoveryRequired: true);
    }
    if (report != null && !source.dirty && report.changedPaths!.contains('Welcome.md')) {
      final actual = await source.core.read();
      source.text = actual.text;
      source.baseHash = actual.baseHash;
      source.reloads++;
    }
    _release();
    return const SyncSettlement(safe: true);
  }
  @override
  Future<bool> abort() async {
    if (!retired) _release();
    await source.writer;
    return true;
  }
  @override
  void retainRecovery(String code) {
    source.recovery = true;
    if (!retired) _release();
  }
}

class _Notebook {
  _Notebook(this.fixture, this.core, this.id, this.nodeId, this.vault, this.credentials,
    this.source, this.sync);
  final SyncFixture fixture;
  final CoreNotebook core;
  final String id;
  final String nodeId;
  final TestSyncVault vault;
  final SyncCredentials credentials;
  final _Source source;
  final NotebookSync sync;
  bool closed = false;

  static Future<_Notebook> create(SyncFixture fixture) async {
    final catalog = await fixture.createCatalog();
    final id = catalog.initialDirectory.notebookId;
    final nodeId = await catalog.createNote(catalog.initialDirectory.folderId, 'Welcome.md');
    await catalog.close();
    final core = await CoreNotebook.openNote(appDataPath: fixture.path('book-app'),
      localDataPath: fixture.path('book-local'), notebookPath: fixture.path('book'),
      notebookId: id, nodeId: nodeId);
    final empty = await core.read();
    await core.write('base\r\n', revision: 1, baseHash: empty.baseHash);
    final initial = await core.read();
    final source = _Source(core, nodeId, initial.text, initial.baseHash);
    final vault = TestSyncVault();
    final credentials = SyncCredentials(vault: vault);
    final sync = NotebookSync(notebookId: id, credentials: credentials);
    await sync.attach(core: core, participant: source);
    return _Notebook(fixture, core, id, nodeId, vault, credentials, source, sync);
  }

  Future<void> enable() async {
    final configured = await sync.configure(endpoint: fixture.endpoint,
      username: fixture.username, password: fixture.password, autoSyncEnabled: false);
    expect(configured.success, isTrue, reason: configured.error);
  }
  Future<void> syncSuccessfully() async {
    final result = await sync.syncNow();
    expect(result.success, isTrue, reason: '${result.error} (${result.code})');
  }
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await sync.close();
    sync.dispose();
    await core.close();
  }
}

// Only the vault is an injected protocol fixture, not evidence of platform
// encryption. Do not initialize TestWidgetsFlutterBinding: its HTTP override
// would replace the real HTTPS fixture client with synthetic 400 responses.
class _CloneVault extends TestSyncVault {
  Future<void> Function(String key, Uint8List data)? beforeWrite;

  @override
  Future<String> write(String key, String? expectedRevision, Uint8List data) async {
    await beforeWrite?.call(key, data);
    return super.write(key, expectedRevision, data);
  }
}

Future<Map<String, String>> _treeBytes(String root) async {
  final result = <String, String>{};
  await for (final entity in Directory(root).list(recursive: true, followLinks: false)) {
    if (entity is File) {
      result[p.relative(entity.path, from: root)] = base64Encode(await entity.readAsBytes());
    }
  }
  return result;
}

class _LibraryClone {
  _LibraryClone(this.source, this.storage, this.vault, this.credentials, this.library);
  final _Notebook source;
  final ManagedNotebookStorage storage;
  final _CloneVault vault;
  final SyncCredentials credentials;
  final NotebookLibrary library;
  static const assetBytes = [0, 1, 2, 127, 128, 255];

  static Future<_LibraryClone> create(_Notebook source) async {
    await File(source.fixture.path('book/unknown.bin')).writeAsBytes(assetBytes, flush: true);
    await source.enable();
    await source.syncSuccessfully();
    await source.close();
    final support = await Directory(source.fixture.path('managed')).create();
    final root = await Directory(p.join(support.path, 'notebooks')).create();
    final app = await Directory(p.join(support.path, 'app')).create();
    final local = await Directory(p.join(support.path, 'local')).create();
    final storage = ManagedNotebookStorage(app: await app.resolveSymbolicLinks(),
      local: await local.resolveSymbolicLinks(), root: await root.resolveSymbolicLinks());
    final vault = _CloneVault();
    final credentials = SyncCredentials(vault: vault);
    final library = NotebookLibrary(obtainStorage: () async => storage, syncCredentials: credentials);
    addTearDown(() async { await library.shutdown(); library.dispose(); });
    await library.initialize();
    expect(library.value.error, isNull);
    expect(library.value.stale, isFalse);
    expect(library.value.entries, isEmpty);
    expect(library.value.transferReserved, isFalse);
    return _LibraryClone(source, storage, vault, credentials, library);
  }

  String destination(ImportAttempt attempt) => p.join(storage.root, 'nb-${attempt.id}');
  String transaction(ImportAttempt attempt) => p.join(p.dirname(storage.root), 'imports', attempt.id);

  Future<ImportAttempt> prepare() async {
    await library.connectWebDav(endpoint: source.fixture.endpoint,
      username: source.fixture.username, password: source.fixture.password, autoSyncEnabled: false);
    expect(library.value.error, isNull);
    expect(library.value.importState.error, isNull);
    final attempt = library.value.importState.current!;
    expect(attempt.isWebDavClone, isTrue);
    expect(attempt.cloneComplete, isTrue);
    expect(attempt.phase, NotebookImportPhase.prepared);
    final projected = jsonDecode(await File(p.join(transaction(attempt),
      attempt.treeRelative!, 'vx_notebook', 'config.json')).readAsString()) as Map<String, dynamic>;
    expect(projected['id'], source.id);
    expect(attempt.bytes, greaterThan(0));
    expect(attempt.entries, greaterThan(0));
    expect(await storage.candidates(), isEmpty);
    final provisional = SyncCredentialScope.provisional(source.fixture.endpoint, attempt.operationId!);
    expect(vault.records.keys, unorderedEquals([provisional.key]));
    final staged = await credentials.read(provisional);
    expect(staged.pending, isTrue);
    expect(staged.candidateCredentials!.username, source.fixture.username);
    expect(staged.candidateCredentials!.password, source.fixture.password);
    return attempt;
  }

  Future<void> expectPublished(ImportAttempt attempt) async {
    expect(library.value.error, isNull);
    expect(library.value.importState.error, isNull);
    expect(library.value.importState.hasStaging, isFalse);
    expect(library.value.transferReserved, isFalse);
    final entry = library.value.entries.single;
    expect(entry.canOpen, isTrue, reason: entry.error);
    expect(entry.notebookId, source.id);
    expect(entry.location, destination(attempt));
    expect((await storage.candidates()).single.paths.notebook, entry.location);
    expect(await File(p.join(entry.location, 'Welcome.md')).readAsBytes(),
      await File(source.fixture.path('book/Welcome.md')).readAsBytes());
    expect(await File(p.join(entry.location, 'unknown.bin')).readAsBytes(), assetBytes);
    final core = await CoreNotebook.openCatalog(appDataPath: storage.app,
      localDataPath: storage.local, notebookPath: entry.location, expectedNotebookId: source.id);
    try {
      expect(core.initialDirectory.notebookId, source.id);
      expect(await core.collectNodeIds(), contains(source.nodeId));
      final facts = await core.inspectSync();
      expect(facts.notebookId, source.id);
      expect(facts.enabled, isTrue);
      expect(facts.backend, 'webdav');
      expect(facts.endpoint, canonicalSyncEndpoint(source.fixture.endpoint));
      expect(facts.autoSyncEnabled, isFalse);
      expect(facts.registered, isFalse);
    } finally { await core.close(); }
    final scope = SyncCredentialScope.notebook(source.fixture.endpoint, source.id);
    expect(vault.records.keys, unorderedEquals([scope.key]));
    final record = await credentials.read(scope);
    expect(record.present, isTrue);
    expect(record.pending, isFalse);
    expect(record.hasUsableCredentials, isTrue);
    expect(record.active!.username, source.fixture.username);
    expect(record.active!.password, source.fixture.password);
    expect(await credentials.findClone(attempt.operationId!), isNull);
    expect(await Directory(transaction(attempt)).exists(), isFalse);
  }

  Future<void> openAndReconcile() async {
    expect(await library.openNotebook(library.value.entries.single), isTrue,
      reason: library.value.error);
    final workspace = library.value.workspace!;
    expect(workspace.value.directory!.notebookId, source.id);
    await workspace.synchronization.reconcile();
    final state = workspace.synchronization.value;
    expect(state.error, isNull);
    expect(state.recoveryRequired, isFalse);
    expect(state.readiness, NotebookSyncReadiness.ready);
    expect(state.facts!.notebookId, source.id);
    expect(state.facts!.registered, isTrue);
    expect(state.facts!.endpoint, canonicalSyncEndpoint(source.fixture.endpoint));
    expect(state.facts!.autoSyncEnabled, isFalse);
    final synced = await workspace.synchronization.syncNow();
    expect(synced.success, isTrue, reason: synced.error);
    expect(await source.fixture.remoteText('Welcome.md'), 'base\r\n');
    expect(await File(p.join(workspace.notebookLocation, 'Welcome.md')).readAsBytes(),
      await File(source.fixture.path('book/Welcome.md')).readAsBytes());
    expect(await File(p.join(workspace.notebookLocation, 'unknown.bin')).readAsBytes(), assetBytes);
  }
}

class _RealHttpBinding extends AutomatedTestWidgetsFlutterBinding {
  // Native channels need a binding; the owned HTTPS fixture needs real sockets.
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _RealHttpBinding();
  group('real app coordinator/core HTTPS boundary', () {
    late SyncFixture fixture;
    late _Notebook notebook;
    setUp(() async {
      // The helper refuses production mobile and requires a fresh fixture process.
      SyncFixture.enableNativeFixtureMode();
      fixture = await SyncFixture.create();
      addTearDown(fixture.dispose);
      notebook = await _Notebook.create(fixture);
      addTearDown(notebook.close);
    });

    test('library Connect publishes one original notebook and settles credentials before real open', () async {
      final clone = await _LibraryClone.create(notebook);
      final attempt = await clone.prepare();
      var prepublicationRekeys = 0;
      var postpublicationPromotions = 0;
      clone.vault.beforeWrite = (key, data) async {
        final record = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
        final transaction = record['transaction'] as Map<String, dynamic>?;
        if (key != SyncCredentialScope.notebook(fixture.endpoint, notebook.id).key) return;
        if (transaction?['phase'] == 'rekeyed') {
          prepublicationRekeys++;
          expect(await clone.storage.candidates(), isEmpty);
          expect(await File(p.join(clone.transaction(attempt), 'committed.json')).exists(), isFalse);
        }
        if (transaction?['phase'] == 'published') {
          postpublicationPromotions++;
          final committed = jsonDecode(await File(p.join(clone.transaction(attempt),
            'committed.json')).readAsString()) as Map<String, dynamic>;
          expect(committed['id'], attempt.id);
          expect(committed['notebookId'], notebook.id);
          expect(committed['destination'], p.basename(clone.destination(attempt)));
        }
      };
      await clone.library.commitImport(attempt);
      expect(prepublicationRekeys, 1);
      expect(postpublicationPromotions, 1);
      await clone.expectPublished(attempt);
      await clone.openAndReconcile();
    });

    test('library finish retries a postpublication vault failure without republishing or replacing bytes', () async {
      final clone = await _LibraryClone.create(notebook);
      final attempt = await clone.prepare();
      final committedFile = File(p.join(clone.transaction(attempt), 'committed.json'));
      final publicationFile = File(p.join(clone.transaction(attempt), 'publication.json'));
      String? committedBytes;
      Map<String, String>? publishedTree;
      var promotionAttempts = 0;
      clone.vault.beforeWrite = (key, data) async {
        final record = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
        final transaction = record['transaction'] as Map<String, dynamic>?;
        if (transaction?['phase'] != 'published') return;
        promotionAttempts++;
        committedBytes = await committedFile.readAsString();
        expect(await publicationFile.readAsString(), committedBytes);
        final receipt = jsonDecode(committedBytes!) as Map<String, dynamic>;
        expect(receipt['id'], attempt.id);
        expect(receipt['notebookId'], notebook.id);
        expect(receipt['destination'], p.basename(clone.destination(attempt)));
        expect(receipt['sourceIdentity'], isA<Map<String, dynamic>>());
        publishedTree = await _treeBytes(clone.destination(attempt));
        clone.vault.failure = 'vault_unavailable';
        throw const SyncVaultException('vault_unavailable');
      };
      await clone.library.commitImport(attempt);
      expect(promotionAttempts, 1);
      expect(committedBytes, isNotNull, reason: 'Failure must occur after genuine native commit and routing.');
      expect(publishedTree, isNotNull);
      final retained = clone.library.value.importState.current!;
      expect(retained.id, attempt.id);
      expect(retained.phase, NotebookImportPhase.finishing);
      expect(retained.notebookId, notebook.id);
      expect(retained.destination, clone.destination(attempt));
      expect(retained.credentialsSettled, isFalse);
      expect(clone.library.value.importState.error, isNotNull);
      expect(clone.library.value.entries.single.canOpen, isFalse);
      expect((await clone.storage.candidates()).single.paths.notebook, clone.destination(attempt));
      expect(await Directory(p.join(clone.transaction(attempt), attempt.treeRelative!)).exists(), isFalse);
      final vaultBeforeRetry = clone.vault.records.map((key, value) =>
        MapEntry(key, (revision: value.revision, bytes: base64Encode(value.data))));
      expect(vaultBeforeRetry.keys, unorderedEquals([
        SyncCredentialScope.provisional(fixture.endpoint, attempt.operationId!).key,
        SyncCredentialScope.notebook(fixture.endpoint, notebook.id).key,
      ]));

      // The same explicit Finish action remains available while the vault is
      // unavailable; it must retain the existing committed destination unchanged.
      await clone.library.commitImport(retained);
      expect(clone.library.value.importState.current!.phase, NotebookImportPhase.finishing);
      expect(await committedFile.readAsString(), committedBytes);
      expect(await publicationFile.readAsString(), committedBytes);
      expect(await _treeBytes(clone.destination(attempt)), publishedTree);
      expect(clone.vault.records.map((key, value) =>
        MapEntry(key, (revision: value.revision, bytes: base64Encode(value.data)))), vaultBeforeRetry);

      clone.vault.failure = null;
      clone.vault.beforeWrite = (key, data) async {
        final record = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
        final transaction = record['transaction'] as Map<String, dynamic>?;
        expect(transaction?['phase'], isNot('rekeyed'), reason: 'Finish must not repeat prepublication rekey.');
        if (transaction?['phase'] != 'published') return;
        promotionAttempts++;
        // Native recover/configure has revalidated the original object identity;
        // both receipt bytes and the entire destination tree remain unchanged.
        expect(await committedFile.readAsString(), committedBytes);
        expect(await publicationFile.readAsString(), committedBytes);
        expect(await _treeBytes(clone.destination(attempt)), publishedTree);
      };
      await clone.library.commitImport(clone.library.value.importState.current!);
      expect(promotionAttempts, 2);
      expect(await _treeBytes(clone.destination(attempt)), publishedTree);
      await clone.expectPublished(attempt);
      await clone.openAndReconcile();
    });

    test('bootstrap uploads actual bytes; disable persists routing without deleting remote', () async {
      final asset = File(fixture.path('book/unknown.bin'));
      await asset.writeAsBytes([0, 1, 2, 127, 128, 255], flush: true);
      await notebook.enable();
      await notebook.syncSuccessfully();
      expect(await fixture.remoteText('Welcome.md'), 'base\r\n');
      final remoteAsset = await fixture.control({'action': 'inspect', 'path': 'unknown.bin', 'content': true});
      expect(base64Decode(remoteAsset['content_base64']! as String), [0, 1, 2, 127, 128, 255]);
      final enabled = await notebook.core.inspectSync();
      expect(enabled.notebookId, notebook.id);
      expect(enabled.registered, isTrue);
      expect(enabled.lastSuccessUtcMillis, greaterThan(0));
      final config = File(fixture.path('book/vx_notebook/config.json'));
      final localConfig = await config.readAsString();
      expect(localConfig, isNot(contains(fixture.password)));
      expect(localConfig, isNot(contains('"password"')));
      final disabled = await notebook.sync.disable();
      expect(disabled.success, isTrue, reason: disabled.error);
      expect(notebook.vault.records, isEmpty);
      await notebook.close();
      final reopened = await CoreNotebook.openCatalog(appDataPath: fixture.path('book-app'),
        localDataPath: fixture.path('book-local'), notebookPath: fixture.path('book'), expectedNotebookId: notebook.id);
      try {
        final facts = await reopened.inspectSync();
        expect(facts.enabled, isFalse);
        expect(facts.backend, isEmpty);
        expect(facts.endpoint, isEmpty);
        expect(facts.autoSyncEnabled, isFalse);
        expect(facts.notebookId, notebook.id);
      } finally { await reopened.close(); }
      expect(await fixture.remoteText('Welcome.md'), 'base\r\n');
      expect(await asset.readAsBytes(), [0, 1, 2, 127, 128, 255]);
    });

    test('disabled retained binding is retired before a confirmed new endpoint', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      final baseline = await File(fixture.path('book/vx_notebook/vx_sync/webdav/state.json')).readAsBytes();
      expect((await notebook.sync.disable()).success, isTrue);
      final disabled = await File(fixture.path('book/vx_notebook/config.json')).readAsBytes();
      await fixture.control({'action': 'mkdir', 'path': 'replacement', 'parents': true});
      final endpoint = '${fixture.endpoint}replacement/';
      final refused = await notebook.sync.configure(endpoint: endpoint,
        username: fixture.username, password: fixture.password);
      expect(refused.success, isFalse);
      expect(await File(fixture.path('book/vx_notebook/config.json')).readAsBytes(), disabled);
      expect(await File(fixture.path('book/vx_notebook/vx_sync/webdav/state.json')).readAsBytes(), baseline);
      final configured = await notebook.sync.configure(endpoint: endpoint,
        username: fixture.username, password: fixture.password, confirmEndpointChange: true);
      expect(configured.success, isTrue, reason: configured.error);
      final facts = await notebook.core.inspectSync();
      expect(facts.endpoint, endpoint); expect(facts.registered, isTrue);
      expect(facts.provider.retired, isTrue);
      final archives = await Directory(fixture.path('book/vx_notebook/vx_sync/webdav/retired'))
        .list(recursive: true, followLinks: false).where((entry) => entry is File && entry.path.endsWith('state.json')).toList();
      expect(archives, hasLength(1));
      expect(await (archives.single as File).readAsBytes(), baseline);
      await notebook.syncSuccessfully();
      expect(await fixture.remoteText('Welcome.md'), 'base\r\n');
      expect(await fixture.remoteText('replacement/Welcome.md'), 'base\r\n');
      final newConfig = jsonDecode((await fixture.remoteText('replacement/vx_notebook/config.json'))!) as Map<String, dynamic>;
      expect(newConfig['id'], notebook.id);
      expect((await notebook.credentials.read(SyncCredentialScope.notebook(endpoint, notebook.id))).hasUsableCredentials, isTrue);
    });

    test('logical close removes credentials while real core routing survives reopen', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      final before = await notebook.core.inspectSync();
      final closed = await notebook.sync.closeNotebook();
      expect(closed.success, isTrue, reason: closed.error);
      expect(notebook.vault.records, isEmpty);
      final retired = await notebook.core.inspectSync();
      expect(retired.enabled, isTrue);
      expect(retired.registered, isFalse);
      expect(retired.endpoint, before.endpoint);
      expect(retired.autoSyncEnabled, before.autoSyncEnabled);
      await notebook.close();
      final reopened = await CoreNotebook.openCatalog(appDataPath: fixture.path('book-app'),
        localDataPath: fixture.path('book-local'), notebookPath: fixture.path('book'), expectedNotebookId: notebook.id);
      try {
        final facts = await reopened.inspectSync();
        expect(facts.enabled, isTrue);
        expect(facts.registered, isFalse);
        expect(facts.endpoint, before.endpoint);
        expect(facts.notebookId, notebook.id);
      } finally { await reopened.close(); }
      expect(await fixture.remoteText('Welcome.md'), 'base\r\n');
    });

    test('wrong password rotation recovers retained candidate without replacing the old binding', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      final before = await notebook.core.inspectSync();
      final scope = SyncCredentialScope.notebook(fixture.endpoint, notebook.id);
      final retained = await notebook.credentials.read(scope);
      final rotated = await notebook.sync.rotateCredentials(username: fixture.username,
        password: '${fixture.password}-known-wrong');
      expect(rotated.success, isFalse);
      final record = await notebook.credentials.read(scope);
      expect(record.active!.password, retained.active!.password);
      final pending = await notebook.core.inspectSync();
      expect(pending.provider.credentialRecovery, isTrue);
      expect(rotated.recoveryRequired, isTrue);
      final recovered = await notebook.sync.recover();
      expect(recovered.success, isTrue, reason: recovered.error);
      final settled = await notebook.credentials.read(scope);
      expect(settled.pending, isFalse);
      expect(settled.active!.password, retained.active!.password);
      final after = await notebook.core.inspectSync();
      expect(after.enabled, isTrue);
      expect(after.registered, isTrue);
      expect(after.provider.baselineHash, before.provider.baselineHash);
      expect(after.lastSuccessUtcMillis, before.lastSuccessUtcMillis);
      await notebook.source.save('saved after rejected rotation\r\n', 2);
      await notebook.syncSuccessfully();
      expect(await fixture.remoteText('Welcome.md'), 'saved after rejected rotation\r\n');
    });

    test('incoming clean source reloads only after actual refresh and keeps UUID', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      final reloads = notebook.source.reloads;
      await fixture.put('Welcome.md', 'incoming desktop content\r\n');
      await notebook.syncSuccessfully();
      expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'incoming desktop content\r\n');
      expect(notebook.source.text, 'incoming desktop content\r\n');
      expect(notebook.source.reloads, greaterThan(reloads));
      final actual = await notebook.core.read();
      expect(actual.notebookId, notebook.id);
      expect(actual.nodeId, notebook.nodeId);
      expect(notebook.source.recovery, isFalse);
    });

    test('dirty source and durable body remain protected from incoming apply', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      final lastSuccess = (await notebook.core.inspectSync()).lastSuccessUtcMillis;
      final reloads = notebook.source.reloads;
      notebook.source.dirty = true;
      notebook.source.text = 'unsaved revision R+1';
      final oldBytes = await File(fixture.path('book/Welcome.md')).readAsBytes();
      await fixture.put('Welcome.md', 'incoming concurrent content\r\n');
      final result = await notebook.sync.syncNow();
      expect(notebook.source.text, 'unsaved revision R+1');
      expect(await File(fixture.path('book/Welcome.md')).readAsBytes(), oldBytes);
      expect(await fixture.remoteText('Welcome.md'), 'incoming concurrent content\r\n');
      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(notebook.source.reloads, reloads);
      expect((await notebook.core.inspectSync()).lastSuccessUtcMillis, lastSuccess);
      expect((await notebook.core.read()).notebookId, notebook.id);
    });

    test('real save admitted in network is drained before apply and survives next snapshot', () async {
      await notebook.enable();
      await notebook.syncSuccessfully();
      Future<void>? save;
      void listener() {
        if (notebook.sync.value.phase == NotebookSyncPhase.network && save == null) {
          save = notebook.source.save('saved revision R+1\r\n', 2);
        }
      }
      notebook.sync.addListener(listener);
      try {
        await notebook.syncSuccessfully();
        expect(save, isNotNull);
        await save;
      } finally { notebook.sync.removeListener(listener); }
      expect(await File(fixture.path('book/Welcome.md')).readAsString(), 'saved revision R+1\r\n');
      await notebook.syncSuccessfully();
      expect(await fixture.remoteText('Welcome.md'), 'saved revision R+1\r\n');
    });
  }, skip: SyncFixture.available ? false : 'Requires the isolated owned real-HTTPS fixture process');
}
