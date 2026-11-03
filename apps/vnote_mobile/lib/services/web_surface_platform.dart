// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

@immutable
class SurfacePreferences {
  const SurfacePreferences({
    required this.dark,
    this.highContrast = false,
    this.fontScale = 1,
    this.reducedMotion = false,
  });

  final bool dark;
  final bool highContrast;
  final double fontScale;
  final bool reducedMotion;

  Map<String, Object> toJson() {
    if (!fontScale.isFinite || fontScale < 0.75 || fontScale > 3) {
      throw ArgumentError('Unsupported surface text scale.');
    }
    return {
      'dark': dark,
      'highContrast': highContrast,
      'fontScale': fontScale,
      'reducedMotion': reducedMotion,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is SurfacePreferences &&
      dark == other.dark &&
      highContrast == other.highContrast &&
      fontScale == other.fontScale &&
      reducedMotion == other.reducedMotion;

  @override
  int get hashCode => Object.hash(dark, highContrast, fontScale, reducedMotion);
}

@immutable
class EditorSurfaceBinding {
  const EditorSurfaceBinding({
    required this.surfaceId,
    required this.entryUrl,
    required this.nonce,
  });
  final String surfaceId;
  final String entryUrl;
  final String nonce;
}

enum SurfaceEventKind { navigation, failure, editorLost }

@immutable
class SurfaceEvent {
  const SurfaceEvent({
    required this.kind,
    required this.surfaceId,
    this.renderId,
    this.handle,
    this.hasGesture = false,
    this.category,
  });
  final SurfaceEventKind kind;
  final String surfaceId;
  final String? renderId;
  final String? handle;
  final bool hasGesture;
  final String? category;
}

@immutable
class SurfaceRenderResult {
  const SurfaceRenderResult({required this.renderId, required this.ready});
  final String renderId;
  final bool ready;
}

/// One injected router per Flutter engine, never a preview JavaScript channel.
/// Native render/cancel/close futures, not UI disposal, own renderer/read leases.
class WebSurfacePlatform {
  WebSurfacePlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vnote.mobile/web_surface') {
    _channel.setMethodCallHandler(_event);
  }

  static const previewViewType = 'vnote.mobile/preview';
  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');
  static const _failureCategories = {
    'renderer_unavailable',
    'renderer_timeout',
    'renderer_failed',
    'output_invalid',
    'view_lost',
    'offline_policy_unavailable',
  };
  final MethodChannel _channel;
  final _listeners = <String, void Function(SurfaceEvent)>{};
  final _owned = <String, bool>{};
  final _retiring = <String, Future<void>>{};
  Future<void>? _shutdown;
  bool _stopping = false;
  bool _disposed = false;

  static String newSurfaceId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      growable: false,
    ).join();
  }

  static bool _validId(Object? value) =>
      value is String && value.length == 32 && _idPattern.hasMatch(value);

  static void _id(String value) {
    if (!_validId(value)) throw ArgumentError('Invalid surface identity.');
  }

  void listen(String surfaceId, void Function(SurfaceEvent) listener) {
    _id(surfaceId);
    if (_disposed || _listeners.containsKey(surfaceId)) {
      throw StateError('Surface listener is already owned or retired.');
    }
    _listeners[surfaceId] = listener;
    _owned.putIfAbsent(surfaceId, () => false);
  }

  void unlisten(String surfaceId) => _listeners.remove(surfaceId);

  Future<void> _event(MethodCall call) async {
    if (_disposed || call.method != 'event') return;
    final data = call.arguments;
    if (data is! Map || !_validId(data['surfaceId'])) return;
    final listener = _listeners[data['surfaceId']];
    if (listener == null) return;
    final SurfaceEvent event;
    switch (data['type']) {
      case 'navigation':
        if (data.length != 5 ||
            !_validId(data['renderId']) ||
            !_validId(data['handle']) ||
            data['hasGesture'] is! bool) {
          return;
        }
        event = SurfaceEvent(
          kind: SurfaceEventKind.navigation,
          surfaceId: data['surfaceId'] as String,
          renderId: data['renderId'] as String,
          handle: data['handle'] as String,
          hasGesture: data['hasGesture'] as bool,
        );
      case 'failure':
        if (data.length != 4 ||
            !_validId(data['renderId']) ||
            !_failureCategories.contains(data['category'])) {
          return;
        }
        event = SurfaceEvent(
          kind: SurfaceEventKind.failure,
          surfaceId: data['surfaceId'] as String,
          renderId: data['renderId'] as String,
          category: data['category'] as String,
        );
      case 'editorLost':
        if (data.length != 2) return;
        event = SurfaceEvent(
          kind: SurfaceEventKind.editorLost,
          surfaceId: data['surfaceId'] as String,
        );
      default:
        return;
    }
    listener(event);
  }

  Future<Object?> _invoke(String method, Map<String, Object?> arguments) async {
    if (_disposed) throw StateError('Native surface router is retired.');
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw StateError('The native web surface is unavailable on this platform.');
    } on PlatformException catch (error) {
      final message = switch (error.code) {
        'renderer_timeout' => 'Preview exceeded its rendering time limit.',
        'cancelled' || 'superseded' => 'Preview rendering was cancelled.',
        'output_invalid' => 'Preview output did not pass its safety checks.',
        'offline_policy_unavailable' => 'This WebView cannot prove the required offline security policy. Source and drafts remain available for recovery or export.',
        _ => 'The native web surface could not complete its operation.',
      };
      throw StateError(message);
    }
  }

  Future<void> _void(String method, Map<String, Object?> arguments) async {
    if (await _invoke(method, arguments) != null) {
      throw StateError('The native surface returned a malformed completion.');
    }
  }

  Future<EditorSurfaceBinding> configureEditor(
    String surfaceId,
    WebViewController controller,
  ) async {
    _id(surfaceId);
    if (_stopping) throw StateError('Native surfaces are retiring.');
    _owned[surfaceId] = true;
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // Retain the plugin's security-specialized native Chrome client. These
      // public callbacks deny capabilities before any document is loaded.
      await platform.setOnPlatformPermissionRequest((request) => unawaited(request.deny()));
      await platform.setOnShowFileSelector((_) async => const <String>[]);
      await platform.setGeolocationEnabled(false);
      await platform.setOnConsoleMessage((_) {}); // Consume, never log source.
      await platform.setOnJavaScriptAlertDialog((_) async {}); // No modal UI.
      await platform.setOnJavaScriptConfirmDialog((_) async => false);
      await platform.setOnJavaScriptTextInputDialog((_) async => '');
    }
    final identifier = switch (platform) {
      AndroidWebViewController() => platform.webViewIdentifier,
      WebKitWebViewController() => platform.webViewIdentifier,
      _ => throw StateError('A supported native WebView is required.'),
    };
    final data = await _invoke('configureEditor', {
      'surfaceId': surfaceId,
      'webViewIdentifier': identifier,
    });
    if (data is! Map ||
        data.length != 2 ||
        data['entryUrl'] != 'https://editor.vnote.invalid/' ||
        !_validId(data['nonce'])) {
      throw StateError('The native editor binding is malformed.');
    }
    return EditorSurfaceBinding(
      surfaceId: surfaceId,
      entryUrl: data['entryUrl'] as String,
      nonce: data['nonce'] as String,
    );
  }

  Future<void> loadEditor(EditorSurfaceBinding binding) =>
      _void('loadEditor', {'surfaceId': binding.surfaceId});

  Future<void> disposeEditor(String surfaceId) {
    _id(surfaceId);
    unlisten(surfaceId);
    return _retire(surfaceId, editor: true);
  }

  Future<SurfaceRenderResult> render({
    required String surfaceId,
    required String previewId,
    required String renderId,
    required SurfacePreferences preferences,
  }) async {
    _id(surfaceId);
    _id(previewId);
    _id(renderId);
    if (_stopping) throw StateError('Native surfaces are retiring.');
    final data = await _invoke('render', {
      'surfaceId': surfaceId,
      'previewId': previewId,
      'renderId': renderId,
      'preferences': preferences.toJson(),
    });
    if (data is! Map ||
        data.length != 2 ||
        data['renderId'] != renderId ||
        (data['status'] != 'ready' && data['status'] != 'superseded')) {
      throw StateError('The renderer completion does not match its generation.');
    }
    return SurfaceRenderResult(
      renderId: renderId,
      ready: data['status'] == 'ready',
    );
  }

  Future<void> show({
    required String surfaceId,
    required String previewId,
    required String renderId,
  }) {
    _id(surfaceId);
    _id(previewId);
    _id(renderId);
    return _void('show', {
      'surfaceId': surfaceId,
      'previewId': previewId,
      'renderId': renderId,
    });
  }

  Future<void> preferences(String surfaceId, SurfacePreferences preferences) {
    _id(surfaceId);
    return _void('preferences', {
      'surfaceId': surfaceId,
      'preferences': preferences.toJson(),
    });
  }

  Future<void> fragment(String surfaceId, String renderId, String fragment) {
    _id(surfaceId); _id(renderId);
    if (fragment.length > 8192 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(fragment)) {
      throw ArgumentError('Invalid heading fragment.');
    }
    return _void('fragment', {'surfaceId': surfaceId, 'renderId': renderId, 'fragment': fragment});
  }

  Future<void> cancel(String surfaceId, String renderId) {
    _id(surfaceId);
    _id(renderId);
    return _void('cancel', {'surfaceId': surfaceId, 'renderId': renderId});
  }

  Future<void> close(String surfaceId) {
    _id(surfaceId);
    unlisten(surfaceId);
    return _retire(surfaceId, editor: false);
  }

  Future<void> openExternal(Uri uri) {
    final String decoded;
    try { decoded = Uri.decodeFull(uri.toString()); }
    on FormatException { throw ArgumentError('External link is not permitted.'); }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(decoded) ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.toString().length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(uri.toString())) {
      throw ArgumentError('External link is not permitted.');
    }
    return _void('openExternal', {'url': uri.toString()});
  }

  Future<void> _retire(String surfaceId, {required bool editor}) {
    final pending = _retiring[surfaceId];
    if (pending != null) return pending;
    late final Future<void> retiring;
    retiring = _void(editor ? 'disposeEditor' : 'close', {'surfaceId': surfaceId})
        .then<void>((_) { _owned.remove(surfaceId); })
        .whenComplete(() { _retiring.remove(surfaceId); });
    _retiring[surfaceId] = retiring;
    return retiring;
  }

  Future<void> shutdown() => _shutdown ??= _shutdownOwned();
  Future<void> _shutdownOwned() async {
    _stopping = true;
    final owned = Map<String, bool>.of(_owned);
    _listeners.clear();
    await Future.wait(owned.entries.map((entry) => _retire(entry.key, editor: entry.value)));
    await Future.wait(List<Future<void>>.of(_retiring.values));
    dispose();
  }

  /// Call only after every owned editor/preview has completed retirement.
  void dispose() {
    if (_disposed) return;
    if (_listeners.isNotEmpty) {
      throw StateError('Retire native surfaces before disposing their router.');
    }
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
