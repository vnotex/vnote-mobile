// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/preview_session.dart';
import 'package:vnote_mobile/services/web_surface_platform.dart';
import 'package:vxcore_bridge/vxcore_bridge.dart';

class _Native extends WebSurfacePlatform {
  final renders = <String, Completer<SurfaceRenderResult>>{};
  final shown = <String>[];
  final firstRender = Completer<void>();
  final secondRender = Completer<void>();
  final showEntered = Completer<void>();
  Completer<void>? showGate;
  Completer<void>? closeGate;
  int closeFailures = 0;
  int cancelFailures = 0;
  bool automatic = false;

  @override
  void listen(String id, void Function(SurfaceEvent) listener) {}
  @override
  void unlisten(String id) {}
  @override
  Future<SurfaceRenderResult> render({required String surfaceId, required String previewId,
      required String renderId, required SurfacePreferences preferences}) {
    final result = Completer<SurfaceRenderResult>();
    renders[renderId] = result;
    if (renders.length == 1) firstRender.complete();
    if (renders.length == 2) secondRender.complete();
    if (automatic) result.complete(SurfaceRenderResult(renderId: renderId, ready: true));
    return result.future;
  }
  @override
  Future<void> show({required String surfaceId, required String previewId, required String renderId}) async {
    if (!showEntered.isCompleted) showEntered.complete();
    await showGate?.future;
    shown.add(renderId);
  }
  @override
  Future<void> cancel(String surfaceId, String renderId) async {
    if (cancelFailures > 0) { cancelFailures--; throw StateError('Native reader retirement unproved'); }
    final pending = renders[renderId];
    if (pending != null && !pending.isCompleted) pending.complete(SurfaceRenderResult(renderId: renderId, ready: false));
  }
  @override
  Future<void> close(String surfaceId) async {
    if (closeFailures > 0) { closeFailures--; throw StateError('Native retirement failed'); }
    await closeGate?.future;
  }
  @override
  Future<void> preferences(String surfaceId, SurfacePreferences preferences) async {}
}

CorePreviewSnapshot _snapshot(PreviewCaptureRequest request, int revision, {String? previewId}) => CorePreviewSnapshot(
  previewsRoot: '/owned/previews', previewId: previewId ?? request.previewId,
  renderId: request.renderId, token: '11111111111111111111111111111111',
  sourceRevision: revision, sourceHash: 'a' * 64, manifestHash: 'b' * 64,
  imageCount: 0, fileCount: 0, navigationCount: 0, encodedBytes: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferences = SurfacePreferences(dark: false);

  test('one newest pending preview supersedes older work without stale installation', () async {
    final native = _Native();
    final revoked = <String>[];
    var captures = 0;
    late PreviewSession session;
    session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, ++captures),
      isCurrent: (_) => true, onPrepared: () => session.attachView(),
      onNavigate: (_, _) async {}, store: (request) async {
        revoked.add(request['renderId']! as String); return {'revoked': true, 'retained': false};
      });
    final first = session.request(preferences);
    await native.firstRender.future;
    final middle = session.request(const SurfacePreferences(dark: true));
    final latest = session.request(const SurfacePreferences(dark: false, fontScale: 2));
    expect(await middle, isFalse);
    final firstId = native.renders.keys.first;
    native.renders[firstId]!.complete(SurfaceRenderResult(renderId: firstId, ready: true));
    expect(await first, isFalse);
    await native.secondRender.future;
    final latestId = native.renders.keys.last;
    native.renders[latestId]!.complete(SurfaceRenderResult(renderId: latestId, ready: true));
    expect(await latest, isTrue);
    expect(captures, 2);
    expect(native.shown, [latestId]);
    expect(session.value.snapshot!.sourceRevision, 2);
    expect(revoked, [firstId]);
    await session.close(); session.dispose(); native.dispose();
  });

  test('capture cancellation cannot wait forever for an unmounted native view', () async {
    final native = _Native();
    final prepared = Completer<void>();
    final revoked = <String>[];
    final session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, 1), isCurrent: (_) => true,
      onPrepared: prepared.complete, onNavigate: (_, _) async {}, store: (request) async {
        revoked.add(request['renderId']! as String); return {'revoked': true, 'retained': false};
      });
    final rendering = session.request(preferences);
    await prepared.future;
    await session.cancel();
    expect(await rendering, isFalse);
    expect(native.renders, isEmpty);
    expect(revoked, hasLength(1));
    await session.close(); session.dispose(); native.dispose();
  });

  test('close joins both display retirement and late render completion before reclaiming', () async {
    final native = _Native()..automatic = true;
    native.showGate = Completer<void>();
    native.closeGate = Completer<void>();
    final revoked = <String>[];
    late PreviewSession session;
    session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, 1), isCurrent: (_) => true,
      onPrepared: () => session.attachView(), onNavigate: (_, _) async {}, store: (request) async {
        revoked.add(request['renderId']! as String); return {'revoked': true, 'retained': false};
      });
    final rendering = session.request(preferences);
    await native.showEntered.future;
    var closed = false;
    final closing = session.close().then((_) => closed = true);
    expect(revoked, isEmpty);
    native.closeGate!.complete();
    expect(closed, isFalse);
    expect(revoked, isEmpty);
    native.showGate!.complete();
    expect(await rendering, isFalse);
    await closing;
    expect(revoked, hasLength(1));
    expect(session.value.closed, isTrue);
    session.dispose(); native.dispose();
  });

  test('a foreign capture cannot authorize another snapshot revocation', () async {
    final native = _Native();
    final revoked = <String>[];
    final session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, 1, previewId: 'ffffffffffffffffffffffffffffffff'),
      isCurrent: (_) => true, onPrepared: () {}, onNavigate: (_, _) async {},
      store: (request) async { revoked.add(request['renderId']! as String); return {}; });
    expect(await session.request(preferences), isFalse);
    expect(session.value.error, isNotNull);
    expect(native.renders, isEmpty);
    expect(revoked, isEmpty);
    await session.close(); session.dispose(); native.dispose();
  });

  test('failed renderer retirement settles without revocation until a proved close retry', () async {
    final native = _Native()..cancelFailures = 1;
    final revoked = <String>[];
    late PreviewSession session;
    session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, 1), isCurrent: (_) => true,
      onPrepared: () => session.attachView(), onNavigate: (_, _) async {},
      store: (request) async { revoked.add(request['renderId']! as String); return {}; });
    final rendering = session.request(preferences);
    await native.firstRender.future;
    final id = native.renders.keys.single;
    native.renders[id]!.completeError(StateError('Renderer identity unavailable'));
    expect(await rendering, isFalse);
    expect(session.value.error, isNotNull);
    expect(revoked, isEmpty);
    await expectLater(session.request(preferences), throwsStateError);
    native.closeFailures = 1;
    await expectLater(session.close(), throwsStateError);
    expect(revoked, isEmpty);
    expect(session.value.closed, isFalse);
    await session.close();
    expect(revoked, [id]);
    expect(session.value.closed, isTrue);
    session.dispose(); native.dispose();
  });

  test('failed native close retains files and permits an explicit retirement retry', () async {
    final native = _Native()..automatic = true;
    final revoked = <String>[];
    late PreviewSession session;
    session = PreviewSession(platform: native,
      capture: (request) async => _snapshot(request, 1), isCurrent: (_) => true,
      onPrepared: () => session.attachView(), onNavigate: (_, _) async {}, store: (request) async {
        revoked.add(request['renderId']! as String); return {'revoked': true, 'retained': false};
      });
    expect(await session.request(preferences), isTrue);
    native.closeFailures = 1;
    await expectLater(session.close(), throwsStateError);
    expect(revoked, isEmpty);
    await session.close();
    expect(revoked, hasLength(1));
    session.dispose(); native.dispose();
  });
}
