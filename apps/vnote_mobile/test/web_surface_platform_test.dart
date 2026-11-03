// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnote_mobile/services/web_surface_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'vnote.test/web-surface';
  const channel = MethodChannel(name);
  const codec = StandardMethodCodec();
  const surface = '11111111111111111111111111111111';
  const other = '22222222222222222222222222222222';
  const render = '33333333333333333333333333333333';
  const handle = '44444444444444444444444444444444';
  late WebSurfacePlatform platform;
  late List<MethodCall> calls;

  Future<void> event(Map<String, Object?> data) async {
    final delivered = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      name, codec.encodeMethodCall(MethodCall('event', data)), (_) => delivered.complete(),
    );
    await delivered.future;
  }

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    platform = WebSurfacePlatform(channel: channel);
  });
  tearDown(() async {
    await platform.shutdown();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('retired, foreign and malformed navigation cannot reach an owned surface', () async {
    final accepted = <SurfaceEvent>[];
    platform.listen(surface, accepted.add);
    final valid = <String, Object?>{
      'type': 'navigation', 'surfaceId': surface, 'renderId': render,
      'handle': handle, 'hasGesture': true,
    };
    await event({...valid, 'surfaceId': other});
    await event({...valid, 'renderId': '../unsafe'});
    await event({...valid, 'extraCommand': 'delete'});
    await event({...valid, 'hasGesture': 'true'});
    expect(accepted, isEmpty);
    await event(valid);
    expect(accepted.single.kind, SurfaceEventKind.navigation);
    expect(accepted.single.handle, handle);
    platform.unlisten(surface);
    await event(valid);
    expect(accepted, hasLength(1));
  });

  test('a renderer completion cannot install another generation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'render') return {'status': 'ready', 'renderId': other};
      return null;
    });
    await expectLater(platform.render(surfaceId: surface, previewId: other, renderId: render,
      preferences: const SurfacePreferences(dark: false)), throwsStateError);
  });

  test('unsafe external URLs never acquire a native launch', () async {
    for (final url in ['javascript:alert(1)', 'file:///private/note', 'data:text/html,x',
      'https://user:password@example.invalid/', 'https://example.invalid/%0aheader']) {
      await expectLater(Future.sync(() => platform.openExternal(Uri.parse(url))), throwsArgumentError, reason: url);
    }
    expect(calls, isEmpty);
  });

  test('close and shutdown wait for native reader retirement', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'close') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return null;
    });
    platform.listen(surface, (_) {});
    var closed = false;
    final closing = platform.close(surface).then((_) => closed = true);
    await entered.future;
    expect(closed, isFalse);
    var stopped = false;
    final stopping = platform.shutdown().then((_) => stopped = true);
    expect(stopped, isFalse);
    release.complete();
    await Future.wait([closing, stopping]);
    expect(closed && stopped, isTrue);
  });
}
