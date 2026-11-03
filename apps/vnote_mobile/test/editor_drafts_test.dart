// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vnote_mobile/services/editor_drafts.dart';
import 'package:vnote_mobile/services/editor_session.dart';
import 'package:vnote_mobile/services/notebook_session.dart';
import 'package:vnote_mobile/services/transfer_worker.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

import 'notebook_session_test.dart' as protocol show ready, insert, answer;

class _Fixture {
  _Fixture(this.root);
  final Directory root;
  late String notebookId;
  late String nodeId;
  late CoreNotebook core;
  late CoreNote note;
  late EditorDrafts drafts;
  EditorSession? editor;
  EditorDraftCapture? capture;
  String get draftRoot => p.join(root.path, 'drafts');
  File get disk => File(p.join(root.path, 'book', 'note.md'));
  Future<void> initialize() async {
    await Directory(draftRoot).create();
    final catalog = await CoreNotebook.createCatalog(appDataPath: p.join(root.path, 'app'),
      localDataPath: p.join(root.path, 'local'), notebookPath: p.join(root.path, 'book'), notebookName: 'Draft fixture');
    notebookId = catalog.initialDirectory.notebookId;
    nodeId = await catalog.createNote(catalog.initialDirectory.folderId, 'note.md');
    await catalog.close();
    core = await open();
    final empty = await core.read();
    await core.write('base\r\n😀 tail\r\n', revision: 1, baseHash: empty.baseHash);
    await core.close();
    core = await open();
    note = await core.read();
    drafts = EditorDrafts(root: draftRoot);
    await drafts.initialize(reconcile: reconcile);
  }
  Future<CoreNotebook> open() => CoreNotebook.openNote(appDataPath: p.join(root.path, 'app'),
    localDataPath: p.join(root.path, 'local'), notebookPath: p.join(root.path, 'book'),
    notebookId: notebookId, nodeId: nodeId);
  Future<CoreDraftInspection> reconcile(DraftRecoveryEntry entry) => core.reconcileDraft(
    draftsRoot: draftRoot, documentKey: entry.documentKey, token: entry.token);
  void attach({EditorDrafts? store, void Function(EditorCapture)? durable,
      void Function(Object)? failed}) {
    editor = EditorSession(initialText: note.text,
      documentId: EditorDrafts.documentKey(note.notebookId, note.nodeId),
      baseVersion: note.baseHash, language: 'markdown');
    capture = (store ?? drafts).attach(editor!, note, 'book');
    editor!.onEdit = (batch) => (store ?? drafts).accept(capture!, batch,
      durable: durable ?? (_) {}, failed: failed ?? (error) => fail('$error'));
    protocol.ready(editor!);
  }
  Future<void> dispose() async {
    await drafts.shutdown(); drafts.dispose(); editor?.dispose(); await core.close();
    await root.delete(recursive: true);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture(await Directory.systemTemp.createTemp('editor-drafts-'));
    await fixture.initialize();
  });
  tearDown(() => fixture.dispose());

  test('opening and no-edit close allocate no source journal', () async {
    fixture.attach();
    await fixture.drafts.detach(fixture.capture!);
    await fixture.drafts.scan();
    expect(fixture.drafts.value.entries, isEmpty);
    expect(await fixture.disk.readAsString(), fixture.note.text);
  });

  test('accepted deltas retain original UTF16 source and only native commit releases credit', () async {
    final acknowledged = <int>[];
    fixture.attach(durable: (capture) => acknowledged.add(capture.revision));
    protocol.insert(fixture.editor!, 'one\r\n');
    protocol.insert(fixture.editor!, 'two😀');
    expect(fixture.capture!.durableRevision, 0);
    expect(acknowledged, isEmpty);
    await fixture.drafts.flushCapture(fixture.capture!);
    expect(fixture.capture!.durableRevision, 2);
    final retained = await fixture.drafts.readSource(DraftRecoveryEntry(fixture.capture!.summary!));
    expect(retained['source'], '${fixture.note.text}one\r\ntwo😀');
    expect(retained['savedRevision'], isNull);
    expect(await fixture.disk.readAsString(), fixture.note.text);
  });

  test('lost append reply does not invent durability; retry proves exact committed prefix', () async {
    var loseReply = true;
    final store = EditorDrafts(root: fixture.draftRoot,
      runStore: (Map<String, Object?> request, {Uint8List? payload}) async {
        final result = await runDraftStore(request, payload: payload);
        if (request['op'] == 'append' && loseReply) {
          loseReply = false;
          throw StateError('Worker reply lost after native commit');
        }
        return result;
      });
    fixture.attach(store: store);
    protocol.insert(fixture.editor!, 'first');
    await expectLater(store.flushCapture(fixture.capture!), throwsStateError);
    expect(fixture.capture!.durableRevision, 0);
    protocol.insert(fixture.editor!, 'later');
    await store.flushCapture(fixture.capture!);
    expect(fixture.capture!.durableRevision, 2);
    expect((await store.readSource(DraftRecoveryEntry(fixture.capture!.summary!)))['source'],
      '${fixture.note.text}firstlater');
    await store.detach(fixture.capture!); await store.shutdown(); store.dispose();
  });

  test('lost prepare reply retries the same immutable prefix after later edits', () async {
    var loseReply = true;
    String? pinned;
    final store = EditorDrafts(root: fixture.draftRoot,
      runStore: (Map<String, Object?> request, {Uint8List? payload}) async {
        final result = await runDraftStore(request, payload: payload);
        if (request['op'] == 'prepareSave' && loseReply) {
          pinned = result['candidateId'] as String;
          loseReply = false;
          throw StateError('Preparation reply lost after immutable intent commit');
        }
        return result;
      });
    fixture.attach(store: store);
    protocol.insert(fixture.editor!, 'candidate');
    await expectLater(store.prepareSave(fixture.capture!), throwsStateError);
    protocol.insert(fixture.editor!, 'newer');
    final recovered = await store.prepareSave(fixture.capture!);
    expect(recovered['candidateId'], pinned);
    expect(recovered['revision'], 1);
    expect(fixture.capture!.durableRevision, 2);
    final saved = await fixture.core.writeDraft(draftsRoot: fixture.draftRoot,
      documentKey: fixture.capture!.documentKey, token: fixture.capture!.token,
      candidateId: recovered['candidateId'] as String);
    expect(saved.summary.savedRevision, 1);
    expect(await fixture.disk.readAsString(), '${fixture.note.text}candidate');
    expect((await store.readSource(DraftRecoveryEntry(fixture.capture!.summary!)))['source'],
      '${fixture.note.text}candidatenewer');
    await store.detach(fixture.capture!); await store.shutdown(); store.dispose();
  });

  test('saved disk prefix retains later original CRLF source across recovery and dirty zero rebase', () async {
    fixture.attach();
    protocol.insert(fixture.editor!, 'saved\r\n');
    final candidate = await fixture.drafts.prepareSave(fixture.capture!);
    protocol.insert(fixture.editor!, 'later😀\r\n');
    await fixture.drafts.flushCapture(fixture.capture!);
    final result = await fixture.core.writeDraft(draftsRoot: fixture.draftRoot,
      documentKey: fixture.capture!.documentKey, token: fixture.capture!.token,
      candidateId: candidate['candidateId'] as String);
    expect(result.summary.savedRevision, 1);
    expect(await fixture.disk.readAsString(), '${fixture.note.text}saved\r\n');
    await fixture.drafts.detach(fixture.capture!);
    await fixture.drafts.scan();
    final entry = fixture.drafts.value.entries.single;
    final inspection = await fixture.drafts.inspect(entry, fixture.reconcile);
    expect(inspection.outcome, 'saved'); expect(inspection.savedRevision, 1);
    expect(inspection.source, '${fixture.note.text}saved\r\nlater😀\r\n');
    final rebased = await fixture.drafts.rebase(inspection.entry, 'd' * 32);
    final proof = await fixture.reconcile(DraftRecoveryEntry(rebased));
    expect(proof.summary.revision, 0); expect(proof.summary.savedRevision, isNull);
    expect((await fixture.drafts.readSource(DraftRecoveryEntry(proof.record)))['source'], inspection.source);
    await fixture.drafts.scan();
    expect(fixture.drafts.value.entries.where((item) => !item.resolved), hasLength(1));
  });

  test('disk reverted to opening bytes after a later save remains a retained conflict', () async {
    fixture.attach();
    final token = fixture.capture!.token;
    protocol.insert(fixture.editor!, 'saved prefix');
    final candidate = await fixture.drafts.prepareSave(fixture.capture!);
    await fixture.core.writeDraft(draftsRoot: fixture.draftRoot,
      documentKey: fixture.capture!.documentKey, token: token,
      candidateId: candidate['candidateId'] as String);
    protocol.insert(fixture.editor!, ' later draft');
    await fixture.drafts.detach(fixture.capture!);
    await fixture.disk.writeAsString(fixture.note.text, flush: true);
    await fixture.core.close();
    fixture.core = await fixture.open();
    await fixture.drafts.scan();
    final inspection = await fixture.drafts.inspect(
      fixture.drafts.value.entries.single, fixture.reconcile);
    expect(inspection.outcome, 'conflict');
    expect(inspection.canRestore, isFalse);
    expect(inspection.canRetry, isFalse);
    expect(inspection.savedRevision, 1);
    expect(inspection.entry.revision, 2);
    expect(inspection.source, '${fixture.note.text}saved prefix later draft');
    expect(await fixture.disk.readAsString(), fixture.note.text);
    await fixture.drafts.scan();
    final retained = fixture.drafts.value.entries.single;
    expect(retained.token, token);
    expect(retained.resolved, isFalse);
  });

  test('newer disk conflicts preserve both disk and replayable acknowledged source', () async {
    fixture.attach(); protocol.insert(fixture.editor!, 'private draft');
    await fixture.drafts.flushCapture(fixture.capture!);
    await fixture.disk.writeAsString('newer external disk\n', flush: true);
    final inspection = await fixture.drafts.inspect(DraftRecoveryEntry(fixture.capture!.summary!), fixture.reconcile);
    expect(inspection.outcome, 'conflict'); expect(inspection.canRestore, isFalse);
    expect(inspection.source, '${fixture.note.text}private draft');
    expect(await fixture.disk.readAsString(), 'newer external disk\n');
  });

  test('external write before lazy first edit never substitutes a newer opening checkpoint', () async {
    fixture.attach();
    await fixture.disk.writeAsString('external before edit', flush: true);
    protocol.insert(fixture.editor!, 'received from original base');
    await fixture.drafts.flushCapture(fixture.capture!);
    final inspection = await fixture.drafts.inspect(DraftRecoveryEntry(fixture.capture!.summary!), fixture.reconcile);
    expect(inspection.baseSource, fixture.note.text);
    expect(inspection.source, '${fixture.note.text}received from original base');
    expect(inspection.outcome, 'conflict');
    expect(await fixture.disk.readAsString(), 'external before edit');
  });

  test('application real durable save and reopen start fresh token without low-level fallback', () async {
    await fixture.core.close();
    final session = NotebookSession(openCore: fixture.open, drafts: fixture.drafts,
      notebookRelative: 'book');
    await session.initialize(); final first = session.value.editor!; protocol.ready(first);
    protocol.insert(first, 'app saved');
    expect(await session.write((message) => protocol.answer(first, message)), isTrue);
    expect(session.value.onDiskRevision, 1); expect(session.value.dirty, isFalse);
    expect(await session.reopen(NotebookDisposition.write,
      (message) => protocol.answer(first, message)), isTrue);
    expect(session.value.editor!.generation, isNot(first.generation));
    expect(session.value.editor!.value.text, '${fixture.note.text}app saved');
    expect(session.value.onDiskRevision, 0); expect(session.value.dirty, isFalse);
    await session.shutdown(); session.dispose();
  });
}
