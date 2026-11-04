// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/cohort_import.dart';
import 'package:vnote_mobile/services/document_transfer_platform.dart';
import 'package:vnote_mobile/services/share_inbox.dart';
import 'package:vnote_mobile/services/notebook_library.dart';
import 'package:vnote_mobile/features/share/share_inbox_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vnote.mobile/share_inbox-test');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ShareInbox inbox;
  final id = '1' * 32;
  final operation = '2' * 32;
  final fingerprint = 'a' * 64;
  const target = CohortTarget(notebookId: 'notebook', parentId: 'root',
    notebookRelative: 'managed', folderName: 'Delivery');
  Map<String, Object?> record({String? delivery, String state = 'ready', bool duplicate = false}) => {
    'id': delivery ?? id, 'fingerprint': fingerprint, 'state': state,
    'bytes': 3, 'files': <Object?>[], 'payloadAvailable': state == 'ready',
    'duplicateAvailable': duplicate,
    if (state == 'importing' || state == 'consumed') ...{
      'operationId': operation, 'target': ShareInbox.targetMap(target),
    },
    if (state == 'consumed') 'cohortId': 'retained-cohort',
  };
  void respond(Future<Object?> Function(MethodCall) handler) =>
    messenger.setMockMethodCallHandler(channel, handler);

  setUp(() => inbox = ShareInbox(channel: channel));
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    inbox.dispose();
  });

  test('malformed rescan retains the last claim and withdraws writer readiness', () async {
    respond((_) async => {'available': true, 'records': [record(state: 'importing')]});
    await inbox.refresh();
    expect(inbox.value.initialized, isTrue);
    respond((_) async => {'available': true, 'records': [
      {...record(state: 'importing'), 'operationId': 'different'},
    ]});
    await expectLater(inbox.refresh(), throwsFormatException);
    expect(inbox.value.initialized, isFalse);
    expect(inbox.value.records.single.operationId, operation);
    expect(inbox.value.records.single.target!.folderName, 'Delivery');
  });

  test('claim rejects native target substitution and stage requires captured status', () async {
    respond((call) async {
      if (call.method == 'list') return {'available': true, 'records': [record()]};
      if (call.method == 'claim') {
        return {...record(state: 'importing'),
          'target': {...ShareInbox.targetMap(target), 'folderName': 'Other'}};
      }
      return null;
    });
    final ready = (await inbox.refresh()).records.single;
    await expectLater(inbox.claim(ready, operationId: operation, target: target), throwsFormatException);
    respond((call) async => call.method == 'list'
      ? {'available': true, 'records': [record(state: 'importing')]}
      : {'status': 'ready', 'sourceName': 'Share', 'bytes': 3, 'entries': 1});
    final importing = (await inbox.refresh()).records.single;
    await expectLater(inbox.stage(importing), throwsFormatException);
  });

  test('settled duplicate never becomes ready without explicit fresh nonce action', () async {
    var copies = 0;
    respond((call) async {
      if (call.method == 'anotherCopy') {
        copies++;
        return record(delivery: '3' * 32);
      }
      return {'available': true, 'records': [record(state: 'consumed', duplicate: true)]};
    });
    final consumed = (await inbox.refresh()).records.single;
    await inbox.refresh();
    expect(copies, 0);
    expect(consumed.status, ShareInboxStatus.consumed);
    final copy = await inbox.anotherCopy(consumed);
    expect(copy.id, isNot(consumed.id));
    expect(copy.fingerprint, consumed.fingerprint);
    expect(copy.operationId, isNull);
    expect(copies, 1);
  });

  test('same-ID another copy and duplicate record IDs are rejected', () async {
    respond((call) async => call.method == 'list'
      ? {'available': true, 'records': [record(state: 'consumed', duplicate: true)]}
      : record());
    final consumed = (await inbox.refresh()).records.single;
    await expectLater(inbox.anotherCopy(consumed), throwsFormatException);
    respond((_) async => {'available': true, 'records': [record(), record()]});
    await expectLater(inbox.refresh(), throwsFormatException);
  });

  test('outgoing sharing works independently of incoming availability and never reports saved', () async {
    final methods = <String>[];
    respond((call) async {
      methods.add(call.method);
      if (call.method == 'list') return {'available': false, 'records': <Object?>[]};
      return {'status': 'shared'};
    });
    expect((await inbox.refresh()).available, isFalse);
    final status = await inbox.shareExport(operationId: operation,
      scope: DocumentTransferScope.notebook, path: '/owned/export/notebook.zip',
      suggestedName: 'notebook.zip');
    expect(status, ShareExportStatus.shared);
    expect(methods, ['list', 'shareExport']);
    respond((_) async => {'status': 'saved'});
    expect(await inbox.shareExport(operationId: operation,
      scope: DocumentTransferScope.notebook, path: '/owned/export/notebook.zip',
      suggestedName: 'notebook.zip'), ShareExportStatus.failed);
  });

  test('outgoing quota refusal explains cleanup and preserves Save As as a separate action', () async {
    final methods = <String>[];
    respond((call) async {
      methods.add(call.method);
      throw PlatformException(code: 'share_quota', message: '/private/provider/name');
    });
    expect(await inbox.shareExport(operationId: operation,
      scope: DocumentTransferScope.notebook, path: '/owned/export/notebook.zip',
      suggestedName: 'notebook.zip'), ShareExportStatus.failed);
    expect(inbox.value.error, allOf(contains('share_quota'), contains('Clean up'),
      contains('Save As'), isNot(contains('/private/'))));
    expect(methods, ['shareExport']);
  });

  test('native error codes survive while private exception details never surface', () async {
    respond((_) async => throw PlatformException(code: 'inbox_quota',
      message: '/private/provider/secret-name', details: {'uri': 'content://private'}));
    await expectLater(inbox.cleanupExports(), throwsA(isA<StateError>().having(
      (error) => error.message.toString(), 'redacted code', allOf(
        contains('inbox_quota'), isNot(contains('secret-name')), isNot(contains('content://'))))));
  });

  test('a disappearing plugin cannot clear an already retained importing claim', () async {
    respond((_) async => {'available': true, 'records': [record(state: 'importing')]});
    await inbox.refresh();
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(inbox.refresh(), throwsStateError);
    expect(inbox.value.initialized, isFalse);
    expect(inbox.value.records.single.operationId, operation);
  });

  test('cleanup and consume require null native acknowledgement, not truthy guesses', () async {
    respond((call) async => call.method == 'list'
      ? {'available': true, 'records': [record(state: 'importing')]}
      : true);
    final claim = (await inbox.refresh()).records.single;
    await expectLater(inbox.consume(claim, 'cohort'), throwsStateError);
    await expectLater(inbox.cleanupExports(), throwsStateError);
  });

  test('unavailable plugin does not fabricate pending receipts', () async {
    final state = await inbox.refresh();
    expect(state.initialized, isTrue);
    expect(state.available, isFalse);
    expect(state.records, isEmpty);
  });

  testWidgets('receipt history remains fully reachable at the 10000-record limit', (tester) async {
    tester.view.physicalSize = const Size(400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = NotebookLibrary();
    addTearDown(() async { await library.shutdown(); library.dispose(); });
    final records = List.generate(10000, (i) => ShareInboxRecord(
      id: (i + 1).toRadixString(16).padLeft(32, '0'), fingerprint: '0' * 64,
      status: ShareInboxStatus.consumed, bytes: 1, files: const [],
      payloadAvailable: false, duplicateAvailable: false,
      operationId: (i + 1).toRadixString(16).padLeft(32, '0'),
      cohortId: '11111111-1111-4111-8111-${i.toString().padLeft(12, '0')}',
      target: CohortTarget(notebookId: '00000000-0000-4000-8000-000000000001',
        parentId: '00000000-0000-4000-8000-000000000002',
        notebookRelative: 'nb-fixture', folderName: 'Receipt $i'),
    ));
    library.value = NotebookLibraryState(inboxReady: true, stale: false,
      shareState: ShareInboxState(available: true, initialized: true, records: records));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ShareInboxPanel(library: library, showOperationErrors: false)))));
    await tester.pumpAndSettle();
    expect(find.text('Destination: Receipt 0'), findsOneWidget);
    final list = find.byType(ListView);
    final scroll = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)));
    for (var i = 0; i < 3; i++) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.text('Destination: Receipt 9999'), findsOneWidget);
    expect(tester.getRect(find.text('Destination: Receipt 9999')).overlaps(const Rect.fromLTWH(0, 0, 400, 720)), isTrue);
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Destination: Receipt 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
