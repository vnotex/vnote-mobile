// SPDX-License-Identifier: LGPL-3.0-only
import 'core_notebook.dart' show CoreException;
import 'generated/vxcore_host_bindings.dart' as native;

/// Snapshot work borrows the current NOTE owner; it never writes note content.
abstract interface class PreviewCore {
  Future<CorePreviewSnapshot> preparePreview({
    required String previewsRoot,
    required String previewId,
    required String renderId,
    required String token,
    required int revision,
    required String source,
  });
  void cancelPreview();
}

/// Trusted host metadata. Neither [previewsRoot] nor [token] may enter renderer
/// data. The source token is attached by the caller, not a native owner counter.
final class CorePreviewSnapshot {
  const CorePreviewSnapshot({
    required this.previewsRoot,
    required this.previewId,
    required this.renderId,
    required this.token,
    required this.sourceRevision,
    required this.sourceHash,
    required this.manifestHash,
    required this.imageCount,
    required this.fileCount,
    required this.navigationCount,
    required this.encodedBytes,
  });

  factory CorePreviewSnapshot.fromJson(
    Map<String, Object?> value, {
    required String previewsRoot,
    required String token,
  }) {
    _keys(value, const {
      'version', 'previewId', 'renderId', 'sourceRevision', 'sourceHash',
      'manifestHash', 'imageCount', 'fileCount', 'navigationCount', 'encodedBytes',
    });
    if (value['version'] != 1 || previewsRoot.isEmpty || !_hex(token, 32)) {
      _malformed();
    }
    final images = _number(value['imageCount'], maximum: 200);
    final files = _number(value['fileCount'], maximum: 200);
    return CorePreviewSnapshot(
      previewsRoot: previewsRoot,
      previewId: _identifier(value['previewId'], 32),
      renderId: _identifier(value['renderId'], 32),
      token: token,
      sourceRevision: _number(value['sourceRevision']),
      sourceHash: _identifier(value['sourceHash'], 64),
      manifestHash: _identifier(value['manifestHash'], 64),
      imageCount: images,
      fileCount: files,
      navigationCount: _number(value['navigationCount'], maximum: 100000),
      encodedBytes: _number(value['encodedBytes'], maximum: 64 * 1024 * 1024),
    );
  }

  final String previewsRoot;
  final String previewId;
  final String renderId;
  final String token;
  final int sourceRevision;
  final String sourceHash;
  final String manifestHash;
  final int imageCount;
  final int fileCount;
  final int navigationCount;
  final int encodedBytes;

  Map<String, Object?> command(String operation) => {
    'op': operation,
    'previewRoot': previewsRoot,
    'previewId': previewId,
    'renderId': renderId,
  };
}

enum CorePreviewNavigationKind { note, external, export }

/// A native-resolved intent, never permission to navigate without confirmation.
final class CorePreviewNavigation {
  const CorePreviewNavigation._({
    required this.source,
    required this.handle,
    required this.kind,
    this.notebookId,
    this.nodeId,
    this.fragment,
    this.url,
    this.origin,
    this.insecure = false,
    this.fileHandle,
  });

  factory CorePreviewNavigation.fromJson(Map<String, Object?> value) {
    final kind = switch (value['kind']) {
      'note' => CorePreviewNavigationKind.note,
      'external' => CorePreviewNavigationKind.external,
      'export' => CorePreviewNavigationKind.export,
      _ => _malformed(),
    };
    _keys(value, {
      'source', 'handle', 'kind',
      ...switch (kind) {
        CorePreviewNavigationKind.note => {'notebookId', 'nodeId', 'fragment'},
        CorePreviewNavigationKind.external => {'url', 'origin', 'insecure'},
        CorePreviewNavigationKind.export => {'fileHandle'},
      },
    });
    final source = _text(value['source']);
    final handle = _identifier(value['handle'], 32);
    if (kind == CorePreviewNavigationKind.external) {
      final url = _text(value['url']);
      final uri = Uri.tryParse(url);
      if (uri == null || !{'https', 'http'}.contains(uri.scheme) ||
          uri.host.isEmpty || uri.userInfo.isNotEmpty ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(url) ||
          value['insecure'] is! bool || value['insecure'] != (uri.scheme == 'http')) {
        _malformed();
      }
      final origin = _text(value['origin']);
      final parsedOrigin = Uri.tryParse(origin);
      if (parsedOrigin == null || parsedOrigin.scheme != uri.scheme ||
          parsedOrigin.host != uri.host || parsedOrigin.port != uri.port ||
          parsedOrigin.userInfo.isNotEmpty || parsedOrigin.path.isNotEmpty ||
          parsedOrigin.hasQuery || parsedOrigin.hasFragment ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(origin)) _malformed();
      return CorePreviewNavigation._(
        source: source, handle: handle, kind: kind, url: url,
        origin: origin, insecure: value['insecure']! as bool,
      );
    }
    return CorePreviewNavigation._(
      source: source, handle: handle, kind: kind,
      notebookId: kind == CorePreviewNavigationKind.note ? _text(value['notebookId']) : null,
      nodeId: kind == CorePreviewNavigationKind.note ? _text(value['nodeId']) : null,
      fragment: kind == CorePreviewNavigationKind.note ? _text(value['fragment'], empty: true) : null,
      fileHandle: kind == CorePreviewNavigationKind.export ? _identifier(value['fileHandle'], 32) : null,
    );
  }

  final String source;
  final String handle;
  final CorePreviewNavigationKind kind;
  final String? notebookId;
  final String? nodeId;
  final String? fragment;
  final String? url;
  final String? origin;
  final bool insecure;
  final String? fileHandle;
}

Never _malformed() => throw const CoreException(
  native.VxCoreError.VXCORE_ERR_JSON_PARSE, 'Malformed native preview result',
);

void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains)) _malformed();
}

bool _hex(Object? value, int length) => value is String &&
    value.length == length && RegExp(r'^[0-9a-f]+$').hasMatch(value);

String _identifier(Object? value, int length) {
  if (!_hex(value, length)) _malformed();
  return value! as String;
}

String _text(Object? value, {bool empty = false}) {
  if (value is! String || (!empty && value.isEmpty) || value.length > 16384 ||
      value.contains('\u0000')) _malformed();
  return value;
}

int _number(Object? value, {int maximum = 9007199254740991}) {
  if (value is! int || value < 0 || value > maximum) _malformed();
  return value;
}
