// SPDX-License-Identifier: LGPL-3.0-only
import 'package:flutter/services.dart';

enum DocumentExportStatus { saved, cancelled, failed, unavailable }

class DocumentExportResult {
  const DocumentExportResult({
    required this.status,
    required this.externalMayBeIncomplete,
  });

  final DocumentExportStatus status;
  final bool externalMayBeIncomplete;
}

abstract interface class DocumentExportPlatform {
  Future<void> prepareStorage();
  Future<DocumentExportResult> save({
    required String operationId,
    required String path,
    required String suggestedName,
  });
  Future<void> cancel(String operationId);
}

/// The save future, not the cancellation acknowledgement, releases the source.
class MethodChannelDocumentExportPlatform implements DocumentExportPlatform {
  const MethodChannelDocumentExportPlatform({
    this._channel = const MethodChannel('vnote.mobile/document_export'),
  });

  final MethodChannel _channel;
  static final _id = RegExp(r'^[0-9a-f]{32}$');
  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$');

  static bool _validId(String value) =>
      value.length == 32 && _id.hasMatch(value);

  @override
  Future<void> prepareStorage() async {
    try {
      final result = await _channel.invokeMethod<Object?>('prepareStorage');
      if (result != null) throw const FormatException();
    } catch (_) {
      // Do not surface platform exception details containing private locations.
      throw StateError('Private storage backup protection is unavailable.');
    }
  }

  @override
  Future<DocumentExportResult> save({
    required String operationId,
    required String path,
    required String suggestedName,
  }) async {
    if (!_validId(operationId) ||
        path.isEmpty ||
        path.length > 16384 ||
        path.contains('\u0000') ||
        suggestedName.length > 100 ||
        suggestedName.contains('..') ||
        _name.firstMatch(suggestedName)?.end != suggestedName.length) {
      return const DocumentExportResult(
        status: DocumentExportStatus.failed,
        externalMayBeIncomplete: false,
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('saveExport', {
        'operationId': operationId,
        'path': path,
        'suggestedName': suggestedName,
      });
      if (raw is! Map ||
          raw.length != 2 ||
          raw['status'] is! String ||
          raw['externalMayBeIncomplete'] is! bool) {
        throw const FormatException();
      }
      final status = switch (raw['status']) {
        'saved' => DocumentExportStatus.saved,
        'cancelled' => DocumentExportStatus.cancelled,
        'failed' => DocumentExportStatus.failed,
        'unavailable' => DocumentExportStatus.unavailable,
        _ => throw const FormatException(),
      };
      final incomplete = raw['externalMayBeIncomplete'] as bool;
      if (status == DocumentExportStatus.saved && incomplete) {
        throw const FormatException();
      }
      return DocumentExportResult(
        status: status,
        externalMayBeIncomplete: incomplete,
      );
    } on MissingPluginException {
      return const DocumentExportResult(
        status: DocumentExportStatus.unavailable,
        externalMayBeIncomplete: false,
      );
    } catch (_) {
      // A transport/decoding failure cannot establish the external outcome.
      return const DocumentExportResult(
        status: DocumentExportStatus.failed,
        externalMayBeIncomplete: true,
      );
    }
  }

  @override
  Future<void> cancel(String operationId) async {
    if (!_validId(operationId)) {
      throw StateError('Document export cancellation is unavailable.');
    }
    try {
      final result = await _channel.invokeMethod<Object?>('cancelExport', {
        'operationId': operationId,
      });
      if (result != null) throw const FormatException();
    } catch (_) {
      throw StateError('Document export cancellation is unavailable.');
    }
  }
}
