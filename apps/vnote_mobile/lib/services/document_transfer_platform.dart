// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';

enum DocumentTransferScope { notebook, cohort, resource }

enum DocumentExportStatus { saved, cancelled, failed, unavailable }

class DocumentExportResult {
  const DocumentExportResult({
    required this.status,
    required this.externalMayBeIncomplete,
  });

  final DocumentExportStatus status;
  final bool externalMayBeIncomplete;
}

enum DocumentImportKind { zip, folder, file, image }

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
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  });
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  });
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  });
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  });
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

  static bool _validResourceName(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.endsWith('.') ||
        value.endsWith(' ') ||
        RegExp(r'[\x00-\x1f\x7f-\x9f/\\:*?"<>|]').hasMatch(value) ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$',
          caseSensitive: false,
        ).hasMatch(value.split('.').first)) {
      return false;
    }
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return false;
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return utf8.encode(value).length <= 255;
  }

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
    required DocumentTransferScope scope,
    required String path,
    required String suggestedName,
  }) async {
    if (!_validId(operationId) ||
        path.isEmpty ||
        path.length > 16384 ||
        path.contains('\u0000') ||
        scope == DocumentTransferScope.cohort ||
        (scope == DocumentTransferScope.resource
            ? !_validResourceName(suggestedName)
            : suggestedName.length > 100 ||
                  suggestedName.contains('..') ||
                  _name.firstMatch(suggestedName)?.end !=
                      suggestedName.length)) {
      return const DocumentExportResult(
        status: DocumentExportStatus.failed,
        externalMayBeIncomplete: false,
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('saveExport', {
        'operationId': operationId,
        'scope': scope.name,
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
  Future<void> cancel(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    if (!_validId(operationId)) {
      throw StateError('Document export cancellation is unavailable.');
    }
    try {
      final result = await _channel.invokeMethod<Object?>('cancelExport', {
        'operationId': operationId,
        'scope': scope.name,
      });
      if (result != null) throw const FormatException();
    } catch (_) {
      throw StateError('Document export cancellation is unavailable.');
    }
  }

  @override
  Future<DocumentImportResult> pickImport({
    required String operationId,
    required DocumentTransferScope scope,
    required DocumentImportKind kind,
  }) async {
    const failed = DocumentImportResult(
      status: DocumentImportStatus.failed,
      sourceName: null,
      bytes: 0,
      entries: 0,
    );
    if (!_validId(operationId) ||
        (scope == DocumentTransferScope.notebook &&
            kind != DocumentImportKind.zip &&
            kind != DocumentImportKind.folder) ||
        (scope == DocumentTransferScope.cohort &&
            kind == DocumentImportKind.image) ||
        (scope == DocumentTransferScope.resource &&
            kind != DocumentImportKind.file &&
            kind != DocumentImportKind.image)) {
      return failed;
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('pickImport', {
        'operationId': operationId,
        'scope': scope.name,
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
        final maximum = switch (kind) {
          DocumentImportKind.zip => 1 << 30,
          DocumentImportKind.folder => 2 << 30,
          DocumentImportKind.file || DocumentImportKind.image => 256 << 20,
        };
        if (name is! String ||
            name.isEmpty ||
            name.length > 1024 ||
            name.contains('\u0000') ||
            ((kind == DocumentImportKind.file ||
                    kind == DocumentImportKind.image) &&
                !_validResourceName(name)) ||
            bytes < 0 ||
            bytes > maximum ||
            entries < 0 ||
            entries > 100000 ||
            (kind != DocumentImportKind.folder && entries != 1) ||
            (kind == DocumentImportKind.zip && bytes == 0)) {
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
  Future<void> cancelImport(
    String operationId, {
    required DocumentTransferScope scope,
  }) async {
    if (!_validId(operationId)) {
      throw StateError('Document import cancellation is unavailable.');
    }
    try {
      final result = await _channel.invokeMethod<Object?>('cancelImport', {
        'operationId': operationId,
        'scope': scope.name,
      });
      if (result != null) throw const FormatException();
    } catch (_) {
      throw StateError('Document import cancellation is unavailable.');
    }
  }
}
