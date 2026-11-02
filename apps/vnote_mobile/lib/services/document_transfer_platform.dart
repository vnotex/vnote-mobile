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

enum DocumentImportKind { zip, folder }

enum DocumentImportStatus { ready, cancelled, failed, unavailable }

class DocumentImportResult {
  const DocumentImportResult({
    required this.status,
    required this.sourceName,
    required this.bytes,
    required this.entries,
  });

  final DocumentImportStatus status;
  final String? sourceName;
  final int bytes;
  final int entries;
}

abstract interface class DocumentTransferPlatform {
  Future<void> prepareStorage();
  Future<DocumentExportResult> save({
    required String operationId,
    required String path,
    required String suggestedName,
  });
  Future<void> cancel(String operationId);
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentImportKind kind,
  });
  Future<void> cancelImport(String operationId);
}

/// Transfer futures, not cancellation acknowledgements, release IO leases.
class MethodChannelDocumentTransferPlatform
    implements DocumentTransferPlatform {
  const MethodChannelDocumentTransferPlatform({
    this._channel = const MethodChannel('vnote.mobile/document_transfer'),
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

  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentImportKind kind,
  }) async {
    const failed = DocumentImportResult(
      status: DocumentImportStatus.failed,
      sourceName: null,
      bytes: 0,
      entries: 0,
    );
    if (!_validId(operationId)) return failed;
    try {
      final raw = await _channel.invokeMethod<Object?>('pickImport', {
        'operationId': operationId,
        'kind': kind.name,
      });
      if (raw is! Map ||
          raw.length != 4 ||
          raw['bytes'] is! int ||
          raw['entries'] is! int) {
        throw const FormatException();
      }
      final status = switch (raw['status']) {
        'ready' => DocumentImportStatus.ready,
        'cancelled' => DocumentImportStatus.cancelled,
        'failed' => DocumentImportStatus.failed,
        'unavailable' => DocumentImportStatus.unavailable,
        _ => throw const FormatException(),
      };
      final name = raw['sourceName'];
      final bytes = raw['bytes'] as int;
      final entries = raw['entries'] as int;
      if (status == DocumentImportStatus.ready) {
        final maximum = kind == DocumentImportKind.zip ? 1 << 30 : 2 << 30;
        if (name is! String ||
            name.isEmpty ||
            name.length > 1024 ||
            name.contains('\u0000') ||
            bytes < 0 ||
            bytes > maximum ||
            entries < 0 ||
            entries > 100000 ||
            (kind == DocumentImportKind.zip && (bytes == 0 || entries != 1))) {
          throw const FormatException();
        }
      } else if (name != null || bytes != 0 || entries != 0) {
        throw const FormatException();
      }
      return DocumentImportResult(
        status: status,
        sourceName: name as String?,
        bytes: bytes,
        entries: entries,
      );
    } on MissingPluginException {
      return const DocumentImportResult(
        status: DocumentImportStatus.unavailable,
        sourceName: null,
        bytes: 0,
        entries: 0,
      );
    } catch (_) {
      return failed;
    }
  }

  @override
  Future<void> cancelImport(String operationId) async {
    if (!_validId(operationId)) {
      throw StateError('Document import cancellation is unavailable.');
    }
    try {
      final result = await _channel.invokeMethod<Object?>('cancelImport', {
        'operationId': operationId,
      });
      if (result != null) throw const FormatException();
    } catch (_) {
      throw StateError('Document import cancellation is unavailable.');
    }
  }
}
