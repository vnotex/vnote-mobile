// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/editor_drafts.dart';
import 'package:vnote_mobile/services/editor_session.dart';
import 'package:vnote_mobile/services/notebook_session.dart';
import 'package:vnote_mobile/services/notebook_sync.dart';
import 'package:vnote_mobile/features/resources/resource_panel.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

// Presentation-only completion-order doubles. Real journal/fsync/owner proof is
// exercised by editor_drafts_test and the bridge's real native storage suites.
final firstHash = 'a' * 64;
final secondHash = 'b' * 64;
final thirdHash = 'c' * 64;
CoreNote note({String text = 'base\r\n', String? hash}) => CoreNote(
  notebookId: 'book-identity', nodeId: 'node-identity', path: 'Notes/base.md',
  notebookName: 'Personal', editorType: CoreEditorType.markdown, text: text,
  baseHash: hash ?? firstHash, coreVersion: '1.0.0', lineEnding: 0);
String _hash(String text) => crypto.sha256.convert(utf8.encode(text)).toString();
final _stores = <String, _PresentationStore>{};
int _storeSequence = 0;

EditorDrafts presentationDrafts() {
  final root = 'presentation-${_storeSequence++}';
  final store = _PresentationStore();
  _stores[root] = store;
  return EditorDrafts(root: root, runStore: store.run)
    ..value = const EditorDraftsState(initialized: true);
}

class _PresentationStore {
  final records = <String, Map<String, Object?>>{};
  final sources = <String, String>{};
  final bases = <String, String>{};
  final candidates = <String, Map<String, Object?>>{};
  final candidateSources = <String, String>{};
  int sequence = 0;
  Object? appendError;
  Object? discardError;
  Object? scanError;
  Completer<void>? rebaseGate;
  Future<Map<String, Object?>> run(Map<String, Object?> request, {Uint8List? payload}) async {
    final op = request['op'];
    final token = request['token'] as String?;
    if (op == 'scan') {
      if (scanError != null) throw scanError!;
      return {'entries': records.values.toList(), 'nextOffset': null};
    }
    if (op == 'prune') return {'removed': 0};
    if (op == 'begin') {
      final source = utf8.decode(payload!);
      sources[token!] = source;
      bases[token] = source;
      records[token] = {'documentKey': request['documentKey'], 'token': token,
        'descriptor': request['descriptor'], 'revision': 0,
        'sourceHash': _hash(source), 'baseSourceHash': _hash(source),
        'savedRevision': null, 'savedSourceHash': null, 'savedDiskHash': null,
        'candidateId': null, 'status': 'draft'};
    }
    final record = records[token];
    if (record == null) throw StateError('Unknown presentation capture.');
    if (op == 'append') {
      if (appendError != null) throw appendError!;
      expectSync(request['expectedRevision'], record['revision']);
      final frames = (jsonDecode(utf8.decode(payload!)) as Map)['frames'] as List;
      var source = sources[token]!;
      for (final raw in frames) {
        final frame = raw as Map;
        expectSync(frame['token'], token);
        expectSync(frame['baseRevision'], record['revision']);
        for (final rawChange in (frame['changes'] as List).reversed) {
          final change = rawChange as Map;
          source = source.replaceRange(change['from'] as int, change['to'] as int, change['insert'] as String);
        }
        record['revision'] = frame['revision'];
      }
      sources[token!] = source;
      record['sourceHash'] = _hash(source);
      record['status'] = record['candidateId'] == null ? 'draft' : 'pending';
    }
    if (op == 'prepareSave') {
      expectSync(record['candidateId'], isNull);
      final id = (++sequence).toRadixString(16).padLeft(32, '0');
      final candidate = {'documentKey': record['documentKey'], 'token': token,
        'candidateId': id, 'revision': record['revision'], 'sourceHash': record['sourceHash'],
        'expectedDiskHash': record['savedDiskHash'] ?? (record['descriptor'] as Map)['openingDiskHash'],
        'intendedDiskHash': record['sourceHash'], 'eol': 0};
      candidates[id] = candidate;
      candidateSources[id] = sources[token]!;
      record['candidateId'] = id;
      record['status'] = 'pending';
      return Map.of(candidate);
    }
    if (op == 'rebase' || op == 'rebaseSource') {
      await rebaseGate?.future;
      final next = request['newToken'] as String;
      final source = payload == null ? sources[token]! : utf8.decode(payload);
      final fresh = Map<String, Object?>.of(record)..addAll({'token': next,
        'revision': 0, 'sourceHash': _hash(source), 'savedRevision': null,
        'savedSourceHash': null, 'savedDiskHash': null, 'candidateId': null, 'status': 'draft'});
      record.addAll({'status': 'superseded', 'supersededBy': next});
      records[next] = fresh;
      sources[next] = source;
      bases[next] = bases[token]!;
      return fresh;
    }
    if (op == 'discard') {
      records.remove(token); sources.remove(token); bases.remove(token);
      if (discardError != null) throw discardError!;
      return {'discarded': true};
    }
    return {...record,
      if (op == 'read') 'source': sources[token],
      if (op == 'readBase') 'baseSource': bases[token]};
  }
}

class PendingWrite {
  PendingWrite(this.text, this.revision, this.baseHash);
  final String text;
  final int revision;
  final String baseHash;
  final completion = Completer<CoreWriteResult>();
}

class ControlledCore implements NotebookCore {
  CoreNote nextRead = note();
  Object? readError;
  Object? reconciliationError;
  int reads = 0;
  int closes = 0;
  int resourceCancellations = 0;
  Completer<void>? closeGate;
  Future<void>? _closing;
  final writes = <PendingWrite>[];
  Future<CoreResourceListing> Function()? onListResources;
  @override
  String get nativeNotices => 'Native license fixture';
  @override
  Future<CoreSyncFacts> inspectSync() async => CoreSyncFacts(notebookId: nextRead.notebookId, autoSyncEnabled: false);
  @override
  Future<CoreSyncResult> sync(CoreSyncCommand command, {CoreSyncCredentials? credentials}) async {
    if (command.action != CoreSyncAction.unregister) throw StateError('This offline fixture has no sync backend.');
    return CoreSyncResult(operationId: command.operationId, action: command.action, code: 0, executed: true);
  }
  @override
  void cancelSync(String operationId) {}

  @override
  Future<CoreNote> read() async { reads++; if (readError != null) throw readError!; return nextRead; }
  @override
  Future<CoreWriteResult> write(String text, {required int revision, required String baseHash}) =>
    throw StateError('Application coordinator must not use low-level writes.');
  @override
  Future<CoreDraftWriteResult> writeDraft({required String draftsRoot,
    required String documentKey, required String token, required String candidateId}) async {
    final store = _stores[draftsRoot]!;
    final candidate = store.candidates[candidateId]!;
    final pending = PendingWrite(store.candidateSources[candidateId]!,
      candidate['revision'] as int, candidate['expectedDiskHash'] as String);
    writes.add(pending);
    final result = await pending.completion.future;
    final record = store.records[token]!;
    record.addAll({'savedRevision': result.revision, 'savedSourceHash': candidate['sourceHash'],
      'savedDiskHash': result.baseHash, 'candidateId': null,
      'status': record['sourceHash'] == candidate['sourceHash'] ? 'saved' : 'draft',
      'savedCandidateId': candidateId});
    return CoreDraftWriteResult.fromJson({...record, 'outcome': 'saved',
      'canRetry': false, 'observedDiskHash': result.baseHash,
      'completedCandidateId': candidateId});
  }
  @override
  Future<CoreDraftInspection> reconcileDraft({required String draftsRoot,
    required String documentKey, required String token}) async {
    if (reconciliationError != null) throw reconciliationError!;
    final store = _stores[draftsRoot]!;
    final record = store.records[token]!;
    if (record['revision'] == 0 && record['savedRevision'] == null && record['candidateId'] == null &&
        store.sources[token] == nextRead.text) {
      record.addAll({'savedRevision': 0, 'savedSourceHash': record['sourceHash'],
        'savedDiskHash': nextRead.baseHash, 'status': 'saved'});
    }
    return CoreDraftInspection.fromJson({...record,
      'outcome': record['savedRevision'] == null ? 'base' : 'saved',
      'canRetry': record['candidateId'] != null,
      'observedDiskHash': record['savedDiskHash'] ?? nextRead.baseHash});
  }
  @override
  Future<CoreDraftInspection> inspectDraft({required String draftsRoot,
    required String documentKey, required String token}) => reconcileDraft(
      draftsRoot: draftsRoot, documentKey: documentKey, token: token);
  @override
  Future<CorePreviewSnapshot> preparePreview({required String previewsRoot,
    required String previewId, required String renderId, required String token,
    required int revision, required String source}) =>
      throw StateError('Preview authority requires the real native fixture.');
  @override
  void cancelPreview() {}
  @override
  Future<CoreResourceListing> listResources() => onListResources?.call() ?? Future.value(
    CoreResourceListing(notebookId: nextRead.notebookId, nodeId: nextRead.nodeId,
      notePath: nextRead.path, entries: const []));
  @override
  Future<CoreResourceResult> applyResource(String transactionRoot) =>
    throw StateError('Resource storage requires a real native fixture.');
  @override
  Future<CoreResourceResult> recoverResource(String transactionRoot) =>
    throw StateError('Resource recovery requires a real native fixture.');
  @override
  Future<CoreResourceExport> exportResource(String name, String transactionRoot) =>
    throw StateError('Resource export requires a real native fixture.');
  @override
  void cancelResourceRead() => resourceCancellations++;
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async { closes++; await closeGate?.future; }
}

// Unlike the ordinary presentation double, this owner retires admission before
// awaiting CLOSED and preserves its failing close future, as the native owner does.
class RetiringCloseCore extends ControlledCore {
  RetiringCloseCore(this.failure);
  final Object? failure;
  bool retired = false;
  int rejectedAdmissions = 0;
  Future<void>? _retirement;

  void _admit() {
    if (!retired) return;
    rejectedAdmissions++;
    throw StateError('The native owner has retired.');
  }

  @override
  Future<CoreNote> read() { _admit(); return super.read(); }
  @override
  Future<CoreSyncFacts> inspectSync() { _admit(); return super.inspectSync(); }
  @override
  Future<CoreDraftInspection> reconcileDraft({required String draftsRoot,
      required String documentKey, required String token}) {
    _admit();
    return super.reconcileDraft(draftsRoot: draftsRoot, documentKey: documentKey, token: token);
  }
  @override
  Future<CoreDraftWriteResult> writeDraft({required String draftsRoot,
      required String documentKey, required String token, required String candidateId}) {
    _admit();
    return super.writeDraft(draftsRoot: draftsRoot, documentKey: documentKey,
      token: token, candidateId: candidateId);
  }
  @override
  Future<void> close() => _retirement ??= _retire();
  Future<void> _retire() async {
    retired = true;
    closes++;
    await closeGate?.future;
    if (failure != null) throw failure!;
  }
}

Map<String, Object?> reply(EditorSession editor, String type, String requestId,
    Map<String, Object?> fields, {int? revision}) => {
  'v': 2, 'type': type, 'documentId': editor.documentId,
  'generation': editor.generation, 'revision': revision ?? editor.value.revision,
  'requestId': requestId, ...fields};
void ready(EditorSession editor) {
  final request = editor.beginLoad()!;
  editor.receive(jsonEncode(reply(editor, 'ready', request['requestId'] as String,
    {'textLength': editor.value.text.length})));
}
void insert(EditorSession editor, String text) {
  final revision = editor.value.revision;
  final end = editor.value.text.length;
  editor.receive(jsonEncode(reply(editor, 'edit', 'editor-${revision + 1}', {
    'baseRevision': revision,
    'changes': [{'from': end, 'to': end, 'insert': text}],
    'selection': {'anchor': end + text.length, 'head': end + text.length},
  }, revision: revision + 1)));
}
void answer(EditorSession editor, Map<String, Object?> request) {
  final type = request['type'];
  if (type != 'flush' && type != 'close') return;
  final mode = type == 'flush' ? 'ready' : switch (request['mode']) {
    'quiesce' => 'quiesced', 'complete' => 'closed', 'abort' => 'aborted',
    _ => throw StateError('Unknown barrier mode')};
  editor.receive(jsonEncode(reply(editor, type as String, request['requestId'] as String,
    {'mode': mode, if (mode == 'ready' || mode == 'quiesced') ...{
      'anchor': editor.value.anchor, 'head': editor.value.head}})));
}
Future<void> turn() => Future<void>.delayed(Duration.zero);
Future<NotebookSession> start(ControlledCore core) async {
  final drafts = presentationDrafts();
  final session = NotebookSession(openCore: () async => core,
    drafts: drafts, notebookRelative: 'book');
  addTearDown(() async { await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose(); });
  await session.initialize(); ready(session.value.editor!);
  return session;
}

void main() {
  test('inbox barrier joins an admitted source restoration before exposing its new draft epoch', () async {
    final core = ControlledCore(); final session = await start(core);
    final previous = session.value.editor!;
    insert(previous, 'restored source');
    final store = _stores[session.drafts.root]!;
    final gate = Completer<void>();
    store.rebaseGate = gate;
    final restoring = session.recoverWebView();
    await turn();
    var joined = false;
    final barrier = session.beginInboxBarrier();
    unawaited(barrier.then((_) { joined = true; }));
    await turn();
    expect(joined, isFalse);
    gate.complete();
    final restored = await restoring;
    await barrier;
    expect(session.value.editor, same(restored));
    expect(restored.generation, isNot(previous.generation));
    expect(restored.value.text, '${note().text}restored source');
    expect(session.value.inboxBlocked, isTrue);
    expect(session.value.dirty, isTrue);
    expect(core.writes, isEmpty);
    session.endInboxBarrier(foreground: false);
  });

  test('receipt and draft credits are independent before native publication', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'received');
    expect(editor.value.revision, 1);
    expect(session.value.draftRevision, 0);
    expect(session.value.onDiskRevision, 0);
    final writing = session.write((message) => answer(editor, message));
    await turn();
    expect(session.value.draftRevision, 1);
    expect(session.value.onDiskRevision, 0);
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    expect(await writing, isTrue); expect(session.value.dirty, isFalse);
  });
  test('one pinned in-flight candidate and newest pending target only', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'one');
    final first = session.write((message) => answer(editor, message)); await turn();
    insert(editor, 'two');
    final superseded = session.write((message) => answer(editor, message));
    insert(editor, 'three');
    final newest = session.write((message) => answer(editor, message));
    expect(await superseded, isFalse); expect(core.writes.length, 1);
    core.writes.first.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    expect(await first, isTrue); await turn();
    expect(session.value.onDiskRevision, 1); expect(session.value.dirty, isTrue);
    expect(core.writes.last.revision, 3); expect(core.writes.last.baseHash, secondHash);
    core.writes.last.completion.complete(CoreWriteResult(revision: 3, baseHash: thirdHash));
    expect(await newest, isTrue); expect(session.value.onDiskRevision, 3);
  });
  test('inbox barrier joins dispatched save but refuses queued receipts without losing latest source', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    void send(Map<String, Object?> message) => answer(editor, message);
    insert(editor, 'first');
    final writing = session.write(send);
    await turn();
    insert(editor, 'latest');
    final queued = session.write(send);
    var joined = false;
    final barrier = session.beginInboxBarrier();
    expect(session.beginInboxBarrier(), same(barrier));
    unawaited(barrier.then((_) { joined = true; }));
    expect(session.value.inboxBlocked, isTrue);
    expect(await queued, isFalse);
    expect(await session.write(send), isFalse);
    await turn();
    expect(joined, isFalse);
    expect(core.writes, hasLength(1));
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    expect(await writing, isTrue);
    await barrier;
    expect(joined, isTrue);
    expect(session.value.editor, same(editor));
    expect(editor.value.text, '${note().text}firstlatest');
    expect(session.value.draftRevision, 2);
    expect(session.value.onDiskRevision, 1);
    expect(session.value.dirty, isTrue);
    expect(core.writes, hasLength(1));
    session.endInboxBarrier(foreground: false);
    final latest = session.write(send);
    await turn();
    expect(core.writes.last.revision, 2);
    expect(core.writes.last.text, editor.value.text);
    core.writes.last.completion.complete(CoreWriteResult(revision: 2, baseHash: thirdHash));
    expect(await latest, isTrue);
  });

  test('inbox barrier joins borrowed resources and blocks owner replacement and new borrowers', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    final gate = Completer<void>();
    final resources = session.withResources((_) => gate.future);
    final barrier = session.beginInboxBarrier();
    var joined = false;
    unawaited(barrier.then((_) { joined = true; }));
    insert(editor, 'retained during scan');
    await expectLater(session.withResources((_) async => fail('No second borrower')), throwsStateError);
    expect(await session.close(NotebookDisposition.discard, (message) => answer(editor, message)), isFalse);
    expect(await session.reopen(NotebookDisposition.retain, (message) => answer(editor, message)), isFalse);
    await expectLater(session.recoverWebView(), throwsStateError);
    await turn();
    expect(joined, isFalse);
    expect(core.closes, 0);
    gate.complete();
    await resources;
    await barrier;
    expect(session.value.draftRevision, 1);
    expect(editor.value.text, '${note().text}retained during scan');
    expect(core.writes, isEmpty);
    session.endInboxBarrier(foreground: false);
  });

  test('inbox barrier joins an already-started note ownership transition', () async {
    final core = ControlledCore()..closeGate = Completer<void>();
    final session = await start(core);
    final editor = session.value.editor!;
    insert(editor, 'keep private');
    final closing = session.close(NotebookDisposition.retain, (message) => answer(editor, message));
    await turn();
    expect(core.closes, 1);
    var joined = false;
    final barrier = session.beginInboxBarrier();
    unawaited(barrier.then((_) { joined = true; }));
    await turn();
    expect(joined, isFalse);
    core.closeGate!.complete();
    expect(await closing, isTrue);
    await barrier;
    expect(session.value.closed, isTrue);
    expect(session.value.draftRevision, 1);
    expect(core.writes, isEmpty);
    session.endInboxBarrier(foreground: false);
  });

  testWidgets('inbox hold cannot be bypassed by foreground and paused release never autosaves', (tester) async {
    final core = ControlledCore();
    final drafts = presentationDrafts();
    final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
    await session.initialize();
    final editor = session.value.editor!;
    ready(editor);
    void send(Map<String, Object?> message) => answer(editor, message);
    session.bindTransport(send);
    insert(editor, 'latest');
    await session.beginInboxBarrier();
    session.setForeground(true);
    expect(await session.write(send), isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(core.writes, isEmpty);
    expect(session.value.draftRevision, 1);
    session.endInboxBarrier(foreground: false);
    await tester.pump(const Duration(seconds: 6));
    expect(core.writes, isEmpty);
    expect(session.value.editor, same(editor));
    await session.beginInboxBarrier();
    session.endInboxBarrier(foreground: true);
    await tester.pump(const Duration(milliseconds: 800));
    expect(core.writes.single.text, '${note().text}latest');
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    await tester.pump();
    await session.beginInboxBarrier();
    session.setResourceBlock('Unresolved inbox target');
    insert(editor, 'quarantined');
    session.endInboxBarrier(foreground: true);
    expect(await session.write(send), isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(core.writes, hasLength(1));
    expect(session.value.error, 'Unresolved inbox target');
    expect(session.value.dirty, isTrue);
    expect(session.value.draftRevision, 2);
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  test('resource barrier delays body writes but not draft persistence', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!; final gate = Completer<void>();
    final resources = session.withResources((_) => gate.future);
    insert(editor, 'during resource copy');
    final writing = session.write((message) => answer(editor, message));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.value.draftRevision, 1); expect(core.writes, isEmpty);
    await expectLater(session.withResources((_) async {}), throwsStateError);
    gate.complete(); await resources; await turn();
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    expect(await writing, isTrue);
  });
  test('retained close freezes then persists exact prefix without body write', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!; insert(editor, 'retained');
    expect(await session.close(NotebookDisposition.retain,
      (message) => answer(editor, message)), isTrue);
    expect(core.writes, isEmpty); expect(session.value.draftRevision, 1);
    expect(session.value.closed, isTrue);
  });
  for (final disposition in [NotebookDisposition.retain, NotebookDisposition.discard, NotebookDisposition.write]) {
    testWidgets('lost final ${disposition.name} close reply retains proven source for fresh-epoch recovery', (tester) async {
      final core = ControlledCore();
      final drafts = presentationDrafts();
      final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
      await session.initialize();
      final editor = session.value.editor!;
      ready(editor);
      insert(editor, 'terminal source');
      final sent = <Map<String, Object?>>[];
      var pageClosed = false;
      void send(Map<String, Object?> message) {
        sent.add(message);
        if (message['type'] == 'close' && message['mode'] == 'complete') {
          pageClosed = true; // The page closes, but its reply never reaches Dart.
          return;
        }
        // Transport callbacks run while pump owns Flutter's async guard.
        if (message['type'] != 'ack') expectSync(pageClosed, isFalse);
        answer(editor, message);
      }
      session.bindTransport(send);
      final closing = session.close(disposition, send);
      await tester.pump();
      if (disposition == NotebookDisposition.write) {
        core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
        await tester.pump();
      }
      expect(pageClosed, isTrue);
      expect(_stores[drafts.root]!.sources[editor.generation], '${note().text}terminal source');
      expect(core.closes, 0);
      await tester.pump(const Duration(seconds: 5));
      expect(await closing, isFalse);
      expect(sent.where((message) => message['mode'] == 'abort'), isEmpty);
      expect(session.value.error, 'Editor barrier timed out; source is retained.');
      expect(session.value.closed, isFalse);
      expect(session.value.restartRequired, isFalse);
      expect(editor.value.ready, isFalse);
      expect(session.canRecoverQuiescedView, isTrue);
      final late = sent.singleWhere((message) => message['mode'] == 'complete');
      answer(editor, late);
      expect(editor.value.closed, isFalse, reason: 'A timed-out reply cannot revive or close its retired correlation.');
      expect(session.canRecoverQuiescedView, isTrue);
      final replacement = await session.recoverWebView();
      expect(replacement.generation, isNot(editor.generation));
      expect(replacement.value.text, '${note().text}terminal source');
      expect(session.canRecoverQuiescedView, isFalse);
      ready(replacement);
      void nextSend(Map<String, Object?> message) => answer(replacement, message);
      session.bindTransport(nextSend);
      insert(replacement, ' new input');
      final saving = session.write(nextSend);
      await tester.pump();
      expect(core.writes.last.text, '${note().text}terminal source new input');
      core.writes.last.completion.complete(CoreWriteResult(revision: 1, baseHash: thirdHash));
      expect(await saving, isTrue);
      expect(session.value.dirty, isFalse);
      await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
    });
  }

  testWidgets('discard cleanup failure after native join retains the mirror and requires restart', (tester) async {
    final core = RetiringCloseCore(null);
    final drafts = presentationDrafts();
    final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
    await session.initialize();
    final editor = session.value.editor!;
    ready(editor); insert(editor, 'copyable after discard');
    _stores[drafts.root]!.discardError = StateError('Discard reply lost after deletion');
    final sent = <Map<String, Object?>>[];
    expect(await session.close(NotebookDisposition.discard, (message) {
      sent.add(message); answer(editor, message);
    }), isFalse);
    expect(core.retired, isTrue);
    expect(core.closes, 1);
    expect(editor.value.closed, isTrue);
    expect(session.value.closed, isFalse);
    expect(session.value.restartRequired, isTrue);
    expect(session.value.error, NotebookSession.ownerRestartRequiredMessage);
    expect(_stores[drafts.root]!.records, isEmpty);
    expect(editor.value.text, '${note().text}copyable after discard');
    expect(sent.where((message) => message['mode'] == 'abort'), isEmpty);
    await expectLater(session.recoverWebView(), throwsStateError);
    expect(core.rejectedAdmissions, 0);
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  test('retained reopen detaches only after native join and admits exactly one fresh owner', () async {
    final first = RetiringCloseCore(null)..closeGate = Completer<void>();
    final second = ControlledCore();
    final drafts = presentationDrafts();
    var opens = 0;
    final session = NotebookSession(openCore: () async => ++opens == 1 ? first : second,
      drafts: drafts, notebookRelative: 'book');
    await session.initialize();
    final editor = session.value.editor!;
    ready(editor); insert(editor, 'retained reopen');
    final reopening = session.reopen(NotebookDisposition.retain, (message) => answer(editor, message));
    await turn();
    expect(first.retired, isTrue);
    expect(opens, 1);
    expect(session.canRecoverQuiescedView, isFalse);
    expect(session.value.editor, same(editor));
    first.closeGate!.complete();
    expect(await reopening, isTrue);
    expect(opens, 2);
    expect(session.value.restartRequired, isFalse);
    expect(session.value.editor, isNot(same(editor)));
    expect(session.value.editor!.value.text, '${note().text}retained reopen');
    expect(first.rejectedAdmissions, 0);
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  for (final failScan in [false, true]) {
    test('failed ${failScan ? 'draft scan' : 'fresh owner open'} after close keeps restart mode', () async {
      final core = RetiringCloseCore(null);
      final drafts = presentationDrafts();
      var opens = 0;
      final session = NotebookSession(openCore: () async {
        if (++opens > 1) throw StateError('New owner could not open');
        return core;
      }, drafts: drafts, notebookRelative: 'book');
      await session.initialize();
      final editor = session.value.editor!;
      ready(editor); insert(editor, 'retained across failed reopen');
      if (failScan) _stores[drafts.root]!.scanError = StateError('Draft scan failed');
      final sent = <Map<String, Object?>>[];
      expect(await session.reopen(NotebookDisposition.retain, (message) {
        sent.add(message); answer(editor, message);
      }), isFalse);
      expect(core.retired, isTrue);
      expect(opens, failScan ? 1 : 2);
      expect(session.value.editor, same(editor));
      expect(session.value.restartRequired, isTrue);
      expect(session.value.error, NotebookSession.ownerRestartRequiredMessage);
      expect(editor.value.text, '${note().text}retained across failed reopen');
      expect(sent.where((message) => message['mode'] == 'abort'), isEmpty);
      await expectLater(session.recoverWebView(), throwsStateError);
      await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
    });
  }

  testWidgets('terminal recovery refuses a journal read-back that differs from its quiesced snapshot', (tester) async {
    final core = ControlledCore();
    final drafts = presentationDrafts();
    final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
    await session.initialize();
    final editor = session.value.editor!;
    ready(editor); insert(editor, 'retained');
    final closing = session.close(NotebookDisposition.retain, (message) {
      if (message['mode'] != 'complete') answer(editor, message);
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(await closing, isFalse);
    final store = _stores[drafts.root]!;
    store.sources[editor.generation] = 'different private source';
    final records = store.records.length;
    await expectLater(session.recoverWebView(), throwsStateError);
    expect(session.value.editor, same(editor));
    expect(editor.value.text, '${note().text}retained');
    expect(store.records.length, records, reason: 'No rebase before read-back equality.');
    expect(store.sources[editor.generation], 'different private source');
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  testWidgets('unquiesced and pending-abort sources never gain terminal recovery permission', (tester) async {
    final core = ControlledCore();
    final drafts = presentationDrafts();
    final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
    await session.initialize();
    final editor = session.value.editor!;
    ready(editor); insert(editor, 'live source');
    final sent = <Map<String, Object?>>[];
    session.bindTransport(sent.add);
    expect(session.canRecoverQuiescedView, isFalse);
    await expectLater(session.recoverWebView(), throwsStateError);
    final closing = session.close(NotebookDisposition.retain, sent.add);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(sent.last['mode'], 'abort');
    expect(session.canRecoverQuiescedView, isFalse);
    await expectLater(session.recoverWebView(), throwsStateError);
    answer(editor, sent.last);
    expect(await closing, isFalse);
    final resync = editor.requestResync(sent.add);
    final request = sent.last;
    expect(request['type'], 'resync');
    editor.receive(jsonEncode(reply(editor, 'resync', request['requestId'] as String,
      {'mode': 'candidate', 'text': editor.value.text, 'anchor': editor.value.anchor, 'head': editor.value.head})));
    await resync;
    expect(session.canRecoverQuiescedView, isFalse);
    expect(editor.value.text, '${note().text}live source');
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  for (final abandon in [false, true]) {
    testWidgets('native close failure ${abandon ? 'after failed-view discard' : 'after final ACK'} requires restart without deleting drafts', (tester) async {
      final failure = StateError('Native CLOSED failed');
      final core = RetiringCloseCore(failure)..closeGate = Completer<void>();
      final drafts = presentationDrafts();
      var opens = 0;
      final session = NotebookSession(openCore: () async { opens++; return core; }, drafts: drafts, notebookRelative: 'book');
      await session.initialize();
      final editor = session.value.editor!;
      ready(editor); insert(editor, 'copyable source');
      if (abandon) editor.reportTransportError('View lost');
      final sent = <Map<String, Object?>>[];
      void send(Map<String, Object?> message) { sent.add(message); answer(editor, message); }
      final closing = session.close(NotebookDisposition.discard, send);
      await tester.pump();
      expect(core.retired, isTrue);
      expect(core.closes, 1);
      expect(session.synchronizationCore, isNull, reason: 'Admission retires before CLOSED completes.');
      expect(session.canRecoverQuiescedView, isFalse);
      await expectLater(session.recoverWebView(), throwsStateError);
      expect(_stores[drafts.root]!.sources[editor.generation], '${note().text}copyable source');
      core.closeGate!.complete();
      expect(await closing, isFalse);
      expect(session.value.restartRequired, isTrue);
      expect(session.value.error, NotebookSession.ownerRestartRequiredMessage);
      expect(session.value.closed, isFalse);
      expect(sent.where((message) => message['mode'] == 'abort'), isEmpty);
      if (abandon) {
        expect(sent, isEmpty);
      } else {
        expect(editor.value.closed, isTrue);
      }
      expect(await session.write(send), isFalse);
      expect(await session.close(NotebookDisposition.discard, send), isFalse);
      expect(await session.reopen(NotebookDisposition.write, send), isFalse);
      await session.retryOpen(); await session.initialize();
      await expectLater(session.withResources((_) async => fail('Retired owner borrowed')), throwsStateError);
      expect(() => session.installSyncReservation(SyncReservationRequest(
        operationId: '12345678-0000-4000-8000-000000000001', ownerGeneration: 1, kind: SyncReservationKind.lifecycle)), throwsStateError);
      expect(await session.recoverSyncSources(), isFalse);
      editor.reportTransportError('Late transport failure');
      session.setResourceBlock('Unrelated quarantine');
      expect(session.value.error, NotebookSession.ownerRestartRequiredMessage);
      expect(opens, 1); expect(core.rejectedAdmissions, 0);
      expect(identical(core.close(), core.close()), isTrue);
      expect(_stores[drafts.root]!.sources[editor.generation], '${note().text}copyable source');
      await expectLater(session.shutdown(), throwsA(same(failure)));
      session.dispose(); await drafts.shutdown(); drafts.dispose();
    });
  }

  test('storage failure aborts close and does not erase accepted source', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!; insert(editor, 'retained');
    _stores[session.drafts.root]!.appendError = StateError('quota exhausted');
    expect(await session.close(NotebookDisposition.retain,
      (message) => answer(editor, message)), isFalse);
    expect(editor.value.quiesced, isFalse); expect(editor.value.closed, isFalse);
    expect(editor.value.text, 'base\r\nretained'); expect(session.value.onDiskRevision, 0);
    _stores[session.drafts.root]!.appendError = null;
    insert(editor, ' after abort');
    await session.beginInboxBarrier();
    expect(session.value.draftRevision, 2);
    expect(_stores[session.drafts.root]!.sources[editor.generation], '${note().text}retained after abort');
    session.endInboxBarrier(foreground: false);
  });
  test('receipt error stays visible and blocks automatic blind retry', () async {
    final core = ControlledCore()..reconciliationError = StateError('receipt fsync failed');
    final session = await start(core); final editor = session.value.editor!;
    insert(editor, 'uncertain'); final writing = session.write((message) => answer(editor, message));
    await turn(); core.writes.single.completion.completeError(StateError('core outcome uncertain'));
    expect(await writing, isFalse); expect(session.value.recoveryRequired, isTrue);
    expect(session.value.durabilityError, contains('receipt'));
    expect(session.value.onDiskRevision, 0); expect(editor.value.text, contains('uncertain'));
  });
  test('new WebView token revision zero remains dirty without saved projection proof', () async {
    final core = ControlledCore(); final session = await start(core);
    final previous = session.value.editor!; insert(previous, 'recover me');
    final replacement = await session.recoverWebView();
    expect(replacement.generation, isNot(previous.generation));
    expect(replacement.value.revision, 0); expect(replacement.value.text, 'base\r\nrecover me');
    expect(session.value.onDiskRevision, isNull); expect(session.value.dirty, isTrue);
    expect(core.writes, isEmpty);
  });
  test('shutdown joins resources and persists received prefix without claiming saved', () async {
    final core = ControlledCore(); final session = await start(core);
    insert(session.value.editor!, 'private'); final gate = Completer<void>();
    final resource = session.withResources((_) => gate.future);
    final closing = session.shutdown(); await turn(); expect(core.closes, 0);
    gate.complete(); await resource; await closing;
    expect(core.closes, 1); expect(core.writes, isEmpty);
    expect(session.value.draftRevision, 1); expect(session.value.onDiskRevision, 0);
  });
  test('foreground autosave uses bound transport and pause cancels body admission', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    session.bindTransport((message) => answer(editor, message));
    insert(editor, 'autosave');
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(core.writes.length, 1);
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    await turn(); session.setForeground(false); insert(editor, 'paused');
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(core.writes.length, 1); expect(session.value.draftRevision, 2);
    expect(session.value.dirty, isTrue);
  });
  for (final queued in [false, true]) {
    testWidgets('settled autosave retires its ${queued ? 'queued target' : 'idle timer'} without another barrier', (tester) async {
      final core = ControlledCore();
      final drafts = presentationDrafts();
      final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
      await session.initialize();
      final editor = session.value.editor!;
      ready(editor);
      final barriers = <Map<String, Object?>>[];
      session.bindTransport((message) {
        if (message['type'] != 'flush') return;
        barriers.add(message);
        if (barriers.length == 1) answer(editor, message);
      });
      insert(editor, 'focused input');
      await tester.pump(const Duration(milliseconds: 750));
      expect(core.writes, hasLength(1));
      if (queued) {
        // The first source barrier re-arms idle autosave while the native write
        // is still outstanding. That target must not outlive the saved receipt.
        await tester.pump(const Duration(milliseconds: 750));
        expect(session.value.pendingRevision, 1);
      }
      core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
      await tester.pump();
      // Do not answer an unexpected second barrier: clean source must never
      // acquire another timeout merely because its first save took time.
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump(const Duration(seconds: 5));
      expect(barriers, hasLength(1));
      expect(core.writes, hasLength(1));
      expect(session.value.receivedRevision, 1);
      expect(session.value.draftRevision, 1);
      expect(session.value.onDiskRevision, 1);
      expect(session.value.error, isNull);
      expect(session.value.dirty, isFalse);
      expect(editor.value.locallySaved, isTrue);
      expect(editor.canFlushSource, isTrue);
      session.setForeground(false);
      await session.beginInboxBarrier();
      session.endInboxBarrier(foreground: true);
      await tester.pump(const Duration(seconds: 6));
      expect(barriers, hasLength(1));
      expect(session.value.dirty, isFalse);
      expect(editor.value.text, '${note().text}focused input');
      await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
    });
  }
  for (final composing in [false, true]) {
    testWidgets('${composing ? 'composing' : 'nonresponsive'} source still fails its save barrier safely', (tester) async {
      final core = ControlledCore();
      final drafts = presentationDrafts();
      final session = NotebookSession(openCore: () async => core, drafts: drafts, notebookRelative: 'book');
      await session.initialize();
      final editor = session.value.editor!;
      ready(editor);
      final barriers = <Map<String, Object?>>[];
      session.bindTransport((message) {
        if (message['type'] == 'flush') barriers.add(message);
      });
      insert(editor, 'retained input');
      if (composing) {
        editor.receive(jsonEncode(reply(editor, 'activity', 'editor-2',
          {'sequence': 1, 'pending': false, 'composing': true})));
      }
      await tester.pump(const Duration(milliseconds: 750));
      expect(barriers, hasLength(1));
      await tester.pump(const Duration(seconds: 5));
      expect(session.value.error, 'Editor barrier timed out; source is retained.');
      expect(session.value.dirty, isTrue);
      expect(session.value.receivedRevision, 1);
      expect(session.value.draftRevision, 1);
      expect(session.value.onDiskRevision, 0);
      expect(editor.value.text, '${note().text}retained input');
      expect(editor.value.composing, composing);
      expect(core.writes, isEmpty);
      await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
    });
  }
  testWidgets('continuous input cannot postpone foreground autosave past five seconds', (tester) async {
    final core = ControlledCore();
    final drafts = presentationDrafts();
    final session = NotebookSession(openCore: () async => core, drafts: drafts,
      notebookRelative: 'book');
    await session.initialize(); final editor = session.value.editor!; ready(editor);
    session.bindTransport((message) => answer(editor, message));
    for (var revision = 0; revision < 10; revision++) {
      insert(editor, 'x');
      await tester.pump(const Duration(milliseconds: 500));
      if (revision < 9) expect(core.writes, isEmpty);
    }
    expect(core.writes.length, 1, reason: 'session=${session.value.error}, editor=${editor.value.error}, durability=${session.value.durabilityError}, writing=${session.value.writing}, durable=${session.value.draftRevision}');
    expect(core.writes.single.revision, 10);
    core.writes.single.completion.complete(CoreWriteResult(revision: 10, baseHash: secondHash));
    await tester.pump();
    expect(session.value.onDiskRevision, 10);
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  test('failed startup has no fabricated editor and retry uses the real admission factory', () async {
    final drafts = presentationDrafts(); final core = ControlledCore();
    var attempts = 0;
    final session = NotebookSession(drafts: drafts, notebookRelative: 'book', openCore: () async {
      if (++attempts == 1) throw const CoreException(8, 'Invalid existing metadata');
      return core;
    });
    await session.initialize(); expect(session.value.editor, isNull);
    expect(session.value.error, contains('8')); expect(core.reads, 0);
    await session.retryOpen(); expect(attempts, 2);
    expect(session.value.note!.nodeId, core.nextRead.nodeId); expect(session.value.error, isNull);
    await session.shutdown(); session.dispose(); await drafts.shutdown(); drafts.dispose();
  });

  test('disposal during startup joins the opened native owner without loading a view', () async {
    final drafts = presentationDrafts(); final core = ControlledCore();
    final pending = Completer<NotebookCore>();
    final session = NotebookSession(openCore: () => pending.future,
      drafts: drafts, notebookRelative: 'book');
    final initializing = session.initialize(); session.dispose(); pending.complete(core);
    await initializing; await session.shutdown();
    expect(core.reads, 0); expect(core.closes, 1);
    await drafts.shutdown(); drafts.dispose();
  });

  test('explicit failed-view discard joins native close without pretending a quiesce succeeded', () async {
    final core = ControlledCore()..closeGate = Completer<void>();
    final session = await start(core); final editor = session.value.editor!;
    insert(editor, 'copyable until discard'); editor.reportTransportError('View lost');
    final closing = session.close(NotebookDisposition.discard,
      (_) => fail('A lost transport cannot acknowledge a flush'));
    await turn(); expect(core.closes, 1); expect(session.value.closed, isFalse);
    expect(editor.value.text, 'base\r\ncopyable until discard');
    expect(_stores[session.drafts.root]!.records.containsKey(editor.generation), isTrue);
    core.closeGate!.complete(); expect(await closing, isTrue);
    expect(session.value.closed, isTrue); expect(core.writes, isEmpty);
    expect(_stores[session.drafts.root]!.records.containsKey(editor.generation), isFalse);
  });

  test('no-edit write and close create no journal and do not normalize bytes', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    expect(await session.write((message) => answer(editor, message)), isTrue);
    expect(await session.close(NotebookDisposition.write,
      (message) => answer(editor, message)), isTrue);
    expect(_stores[session.drafts.root]!.records, isEmpty); expect(core.writes, isEmpty);
  });
  test('cancel has no barrier, source discard, or notebook mutation', () async {
    final core = ControlledCore(); final session = await start(core);
    insert(session.value.editor!, 'unsaved');
    expect(await session.close(NotebookDisposition.cancel, (_) => fail('No barrier')), isFalse);
    expect(core.closes, 0); expect(session.value.dirty, isTrue);
  });
  SyncReservationRequest reservation(int number, SyncReservationKind kind) => SyncReservationRequest(
    operationId: '12345678-0000-4000-8000-${number.toString().padLeft(12, '0')}',
    ownerGeneration: 1, kind: kind);

  test('stage drains admitted writes but does not force a queued dirty save', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    void send(Map<String, Object?> value) => answer(editor, value);
    session.bindTransport(send); session.setForeground(false);
    insert(editor, 'staged later');
    final held = session.installSyncReservation(reservation(1, SyncReservationKind.stage));
    final saving = session.write(send);
    await held.drainWriters(); await turn();
    expect(core.writes, isEmpty);
    expect(editor.value.text, '${note().text}staged later');
    expect((await held.settle(null)).safe, isTrue);
    await turn();
    expect(core.writes.single.text, '${note().text}staged later');
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    expect(await saving, isTrue);
    expect(session.value.onDiskRevision, 1);
  });

  test('apply classifies the newer durable prefix after an older writer drains', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    void send(Map<String, Object?> value) => answer(editor, value);
    session.bindTransport(send); session.setForeground(false);
    insert(editor, 'one'); final saving = session.write(send); await turn();
    final held = session.installSyncReservation(reservation(2, SyncReservationKind.apply));
    final draining = held.drainWriters();
    insert(editor, 'two');
    core.writes.single.completion.complete(CoreWriteResult(revision: 1, baseHash: secondHash));
    await saving; await draining;
    final protection = await held.quiesceAndDrainDrafts();
    expect(protection.dirtyNodeIds, [note().nodeId]);
    expect(session.value.draftRevision, 2);
    expect(session.value.onDiskRevision, 1);
    expect(editor.value.quiesced, isTrue);
    expect((await held.settle(SyncRefreshReport(metadataRefreshed: true,
      operationSucceeded: true, changedPaths: const ['Other.md']))).safe, isTrue);
    expect(session.value.editor, same(editor));
    expect(editor.value.text, '${note().text}onetwo');
    expect(editor.value.quiesced, isFalse);
    expect(core.writes, hasLength(1));
  });

  test('a clean affected source installs current disk in a fresh saved epoch', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    session.bindTransport((value) => answer(editor, value)); session.setForeground(false);
    final held = session.installSyncReservation(reservation(3, SyncReservationKind.apply));
    expect((await held.quiesceAndDrainDrafts()).dirtyNodeIds, isEmpty);
    core.nextRead = note(text: 'remote\n', hash: secondHash);
    final result = await held.settle(SyncRefreshReport(metadataRefreshed: true,
      operationSucceeded: true, changedPaths: [note().path]));
    expect(result.safe, isTrue);
    expect(session.value.editor!.generation, isNot(editor.generation));
    expect(session.value.editor!.value.text, 'remote\n');
    expect(session.value.onDiskRevision, 0);
    expect(session.value.dirty, isFalse);
    expect(core.writes, isEmpty);
  });

  test('missing changed paths retains clean source and recovery joins the new token', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    session.bindTransport((value) => answer(editor, value)); session.setForeground(false);
    final first = session.installSyncReservation(reservation(4, SyncReservationKind.apply));
    await first.quiesceAndDrainDrafts();
    final result = await first.settle(SyncRefreshReport(metadataRefreshed: true,
      operationSucceeded: false, changedPaths: null));
    expect(result.recoveryRequired, isTrue);
    expect(session.value.syncRecoveryRequired, isTrue);
    expect(editor.value.quiesced, isTrue);
    expect(core.reads, 1);
    final recovery = session.installSyncReservation(reservation(5, SyncReservationKind.lifecycle));
    await recovery.quiesceAndDrainDrafts();
    core.nextRead = note(text: 'verified remote', hash: secondHash);
    expect(await session.recoverSyncSources(), isTrue);
    expect(session.value.syncReserved, isTrue);
    expect(session.value.editor!.value.text, 'verified remote');
    expect((await recovery.settle(null)).safe, isTrue);
    expect(session.value.syncReserved, isFalse);
    expect(session.value.syncRecoveryRequired, isFalse);
  });

  test('a retired abort cannot unfreeze a successor source reservation', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    session.bindTransport((value) => answer(editor, value)); session.setForeground(false);
    final old = session.installSyncReservation(reservation(6, SyncReservationKind.apply));
    await old.quiesceAndDrainDrafts();
    await old.settle(SyncRefreshReport(metadataRefreshed: true,
      operationSucceeded: true, changedPaths: const []));
    final current = session.installSyncReservation(reservation(7, SyncReservationKind.apply));
    await current.quiesceAndDrainDrafts();
    expect(await old.abort(), isTrue);
    expect(editor.value.quiesced, isTrue);
    expect(session.value.syncReserved, isTrue);
    expect(await current.abort(), isTrue);
    expect(editor.value.quiesced, isFalse);
    expect(session.value.syncReserved, isFalse);
    expect(editor.value.text, note().text);
  });

  test('Keep draft after unavailable sync refresh preserves a visible unsaved capture', () async {
    final core = ControlledCore(); final session = await start(core);
    final editor = session.value.editor!;
    void send(Map<String, Object?> value) => answer(editor, value);
    session.bindTransport(send); session.setForeground(false);
    final held = session.installSyncReservation(reservation(8, SyncReservationKind.apply));
    await held.quiesceAndDrainDrafts();
    core.nextRead = note(text: 'different remote', hash: secondHash);
    await held.settle(SyncRefreshReport(metadataRefreshed: false,
      operationSucceeded: false, changedPaths: null));
    expect(await session.close(NotebookDisposition.retain, send), isTrue);
    await session.drafts.scan();
    final entry = session.drafts.value.entries.where((entry) => !entry.resolved).single;
    expect(entry.token, isNot(editor.generation));
    expect(entry.record['savedRevision'], isNull);
    expect((await session.drafts.readSource(entry))['source'], note().text);
    expect(core.nextRead.text, 'different remote');
    expect(core.writes, isEmpty);
  });

  test('resource links remain escaped and confined', () {
    expect(resourceMarkdownLink(name: '[x]', relativeUrl: 'files/a%20(b).bin'),
      r'[\[x\]](files/a%2520%28b%29.bin)');
    for (final path in ['/root', '../asset', 'a//b', 'a/./b', 'https:asset', 'a\\b', 'a\nb']) {
      expect(() => resourceMarkdownLink(name: 'file', relativeUrl: path), throwsStateError);
    }
  });
}
