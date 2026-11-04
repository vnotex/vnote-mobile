// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cohort_import.dart';
import 'document_transfer_platform.dart';
import 'transfer_worker.dart';

enum ShareInboxStatus { ready, importing, consumed, discarded, failed }
enum ShareExportStatus { shared, cancelled, failed, unavailable }

String shareExportMessage(ShareExportStatus result) => switch (result) {
  ShareExportStatus.shared => 'Shared with the system. Recipient persistence is not guaranteed.',
  ShareExportStatus.cancelled => 'System sharing was cancelled. Private bytes are retained.',
  ShareExportStatus.failed => 'System sharing failed. Private bytes are retained.',
  ShareExportStatus.unavailable => 'System sharing is unavailable. Private bytes are retained.',
};

@immutable
class ShareInboxFile {
  const ShareInboxFile({required this.name, required this.mime,
    required this.bytes, required this.sha256});
  final String name;
  final String mime;
  final int bytes;
  final String sha256;
}

@immutable
class ShareInboxRecord {
  const ShareInboxRecord({required this.id, required this.fingerprint,
    required this.status, required this.bytes, required this.files,
    required this.payloadAvailable, required this.duplicateAvailable,
    this.operationId, this.target, this.cohortId});
  final String id;
  final String fingerprint;
  final ShareInboxStatus status;
  final int bytes;
  final List<ShareInboxFile> files;
  final bool payloadAvailable;
  final bool duplicateAvailable;
  final String? operationId;
  final CohortTarget? target;
  final String? cohortId;
  bool get settled => status == ShareInboxStatus.consumed ||
    status == ShareInboxStatus.discarded;
}

@immutable
class ShareInboxState {
  const ShareInboxState({this.available = false, this.initialized = false,
    this.records = const [], this.error, this.message});
  final bool available;
  final bool initialized;
  final List<ShareInboxRecord> records;
  final String? error;
  final String? message;
  int get pendingCount => records.where((item) => !item.settled).length;
}

/// Separate from document pickers: a chooser callback is never Save As success.
/// No reply grants filesystem authority; native validates every retained proof.
class ShareInbox extends ValueNotifier<ShareInboxState> {
  ShareInbox({this._channel = const MethodChannel('vnote.mobile/share_inbox')})
    : super(const ShareInboxState());
  final MethodChannel _channel;
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  static bool _validUnicode(String value) {
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
    return true;
  }
  static bool validName(String value) => value.isNotEmpty && value != '.' &&
    value != '..' && !value.endsWith('.') && !value.endsWith(' ') &&
    value.length <= 255 && _validUnicode(value) && utf8.encode(value).length <= 255 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f/\\:*?"<>|]').hasMatch(value) &&
    !RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$',
      caseSensitive: false).hasMatch(value.split('.').first);

  static Map<String, Object?> targetMap(CohortTarget target) => {
    'notebookId': target.notebookId, 'parentId': target.parentId,
    'notebookRelative': target.notebookRelative, 'folderName': target.folderName,
  };
  static bool _identity(Object? value) => value is String && value.isNotEmpty &&
    value.length <= 1024 && _validUnicode(value) && utf8.encode(value).length <= 1024 && !_control.hasMatch(value);
  static Map<Object?, Object?> _map(Object? raw, Set<String> required,
      [Set<String> optional = const {}]) {
    if (raw is! Map || !required.every(raw.containsKey) ||
        raw.keys.any((key) => key is! String || !required.contains(key) &&
          !optional.contains(key))) {
      throw const FormatException('Invalid inbox reply.');
    }
    return raw;
  }
  static int _number(Object? raw, int maximum) {
    if (raw is! int || raw < 0 || raw > maximum) {
      throw const FormatException('Invalid inbox count.');
    }
    return raw;
  }
  static CohortTarget _target(Object? raw) {
    final map = _map(raw, {'notebookId', 'parentId', 'notebookRelative', 'folderName'});
    if (!_identity(map['notebookId']) || !_identity(map['parentId']) ||
        map['notebookRelative'] is! String || !validName(map['notebookRelative'] as String) ||
        map['folderName'] is! String || !validName(map['folderName'] as String)) {
      throw const FormatException('Invalid inbox target.');
    }
    return CohortTarget(notebookId: map['notebookId'] as String,
      parentId: map['parentId'] as String, notebookRelative: map['notebookRelative'] as String,
      folderName: map['folderName'] as String);
  }
  static ShareInboxRecord _record(Object? raw) {
    final map = _map(raw, {'id', 'fingerprint', 'state', 'bytes', 'files',
      'payloadAvailable', 'duplicateAvailable'}, {'operationId', 'target', 'cohortId'});
    if (!validTransferId(map['id']) || map['fingerprint'] is! String ||
        !_hash.hasMatch(map['fingerprint'] as String) ||
        map['payloadAvailable'] is! bool || map['duplicateAvailable'] is! bool ||
        map['files'] is! List) {
      throw const FormatException('Invalid inbox record.');
    }
    final status = switch (map['state']) {
      'ready' => ShareInboxStatus.ready, 'importing' => ShareInboxStatus.importing,
      'consumed' => ShareInboxStatus.consumed, 'discarded' => ShareInboxStatus.discarded,
      'failed' => ShareInboxStatus.failed,
      _ => throw const FormatException('Invalid inbox state.'),
    };
    final operationId = map['operationId'];
    final target = map['target'];
    if ((operationId == null) != (target == null) ||
        operationId != null && !validTransferId(operationId) ||
        status == ShareInboxStatus.importing && operationId == null ||
        map['cohortId'] != null && !_identity(map['cohortId']) ||
        !const [ShareInboxStatus.consumed, ShareInboxStatus.discarded].contains(status) &&
          map['duplicateAvailable'] == true) {
      throw const FormatException('Invalid inbox claim.');
    }
    final rawFiles = map['files'] as List;
    if (rawFiles.length > 64) throw const FormatException('Too many inbox files.');
    final files = <ShareInboxFile>[];
    final names = <String>{};
    var fileBytes = 0;
    for (final rawFile in rawFiles) {
      final file = _map(rawFile, {'name', 'mime', 'bytes', 'sha256'});
      if (file['name'] is! String || !validName(file['name'] as String) ||
          !names.add((file['name'] as String).toLowerCase()) ||
          !_identity(file['mime']) || file['sha256'] is! String ||
          !_hash.hasMatch(file['sha256'] as String)) {
        throw const FormatException('Invalid inbox file.');
      }
      final bytes = _number(file['bytes'], 64 << 20);
      fileBytes += bytes;
      files.add(ShareInboxFile(name: file['name'] as String,
        mime: file['mime'] as String, bytes: bytes, sha256: file['sha256'] as String));
    }
    final bytes = _number(map['bytes'], 256 << 20);
    if (fileBytes > bytes) throw const FormatException('Invalid inbox byte count.');
    return ShareInboxRecord(id: map['id'] as String, fingerprint: map['fingerprint'] as String,
      status: status, bytes: bytes, files: List.unmodifiable(files),
      payloadAvailable: map['payloadAvailable'] as bool,
      duplicateAvailable: map['duplicateAvailable'] as bool,
      operationId: operationId as String?, target: target == null ? null : _target(target),
      cohortId: map['cohortId'] as String?);
  }

  Future<Object?> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      final code = RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(error.code)
        ? error.code : 'invalid_platform_error';
      if (code == 'share_quota') {
        throw StateError('Shared item error share_quota. Share storage is full. Clean up finished outgoing shares or settle inbox items and history. For a prepared notebook or resource export, use Save As instead.');
      }
      // Platform details/messages may contain provider paths; only stable codes
      // cross this privacy boundary, with an accurate retained-outcome warning.
      throw StateError('Shared item error $code. Retained bytes and uncertain outcomes remain protected.');
    }
  }

  Future<ShareInboxState> refresh() async {
    try {
      final raw = _map(await _call('list'), {'available', 'records'});
      if (raw['available'] is! bool || raw['records'] is! List ||
          (raw['records'] as List).length > 10000) {
        throw const FormatException();
      }
      final records = (raw['records'] as List).map(_record).toList(growable: false);
      final claims = records.map((item) => item.operationId).whereType<String>().toList(growable: false);
      if (records.map((item) => item.id).toSet().length != records.length ||
          claims.toSet().length != claims.length ||
          records.where((item) => !item.settled).length > 200 ||
          raw['available'] == false && (records.isNotEmpty || value.records.any((item) =>
            item.status == ShareInboxStatus.importing))) {
        throw const FormatException();
      }
      value = ShareInboxState(available: raw['available'] as bool,
        initialized: true, records: List.unmodifiable(records), message: value.message);
    } on MissingPluginException {
      if (value.available || value.records.isNotEmpty) {
        value = ShareInboxState(available: value.available, records: value.records,
          error: 'Shared items could not be reconciled. Notebook writers remain blocked.');
        throw StateError(value.error!);
      }
      value = const ShareInboxState(initialized: true);
    } catch (error) {
      value = ShareInboxState(available: value.available, records: value.records,
        error: error is StateError ? error.message.toString()
          : 'Shared items could not be reconciled. Notebook writers remain blocked.');
      rethrow;
    }
    return value;
  }

  void reportShare(ShareExportStatus result) {
    value = ShareInboxState(available: value.available, initialized: value.initialized,
      records: value.records, error: value.error,
      message: value.error ?? shareExportMessage(result));
  }

  Future<void> _void(String method, [Map<String, Object?>? arguments]) async {
    try {
      if (await _call(method, arguments) != null) {
        throw const FormatException();
      }
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('The shared item operation could not be completed. Retained bytes are unchanged.');
    }
  }
  Future<void> activate() => _void('activate');
  Future<ShareInboxRecord> claim(ShareInboxRecord record, {
      required String operationId, required CohortTarget target}) async {
    if (!validTransferId(operationId)) throw const FormatException('Invalid operation.');
    _target(targetMap(target));
    final claimed = _record(await _call('claim', {
      'id': record.id, 'operationId': operationId, 'target': targetMap(target),
    }));
    if (claimed.id != record.id || claimed.fingerprint != record.fingerprint ||
        claimed.status != ShareInboxStatus.importing || claimed.operationId != operationId ||
        !mapEquals(targetMap(claimed.target!), targetMap(target))) {
      throw const FormatException('Inbox claim did not match.');
    }
    return claimed;
  }
  Future<DocumentImportResult> stage(ShareInboxRecord record) async {
    if (record.status != ShareInboxStatus.importing || record.operationId == null) {
      throw StateError('Claim this shared item before copying it.');
    }
    final raw = _map(await _call('stage', {
      'id': record.id, 'operationId': record.operationId,
    }), {'status', 'sourceName', 'bytes', 'entries'});
    if (raw['status'] != 'captured' || !_identity(raw['sourceName'])) {
      throw const FormatException('Invalid retained capture.');
    }
    return DocumentImportResult(status: DocumentImportStatus.ready,
      sourceName: raw['sourceName'] as String, bytes: _number(raw['bytes'], 256 << 20),
      entries: _number(raw['entries'], 65));
  }
  Future<void> consume(ShareInboxRecord record, String cohortId) => _void('consume', {
    'id': record.id, 'operationId': record.operationId, 'cohortId': cohortId,
  });
  Future<void> discard(ShareInboxRecord record) => _void('discard', {'id': record.id});
  Future<void> dismissDuplicate(ShareInboxRecord record) =>
    _void('dismissDuplicate', {'id': record.id});
  Future<void> forgetHistory() => _void('forgetHistory');
  Future<void> cleanupExports() => _void('cleanupExports');
  Future<ShareInboxRecord> anotherCopy(ShareInboxRecord record) async {
    final copy = _record(await _call('anotherCopy', {'id': record.id}));
    if (copy.id == record.id || copy.fingerprint != record.fingerprint ||
        copy.status != ShareInboxStatus.ready || copy.operationId != null ||
        !copy.payloadAvailable) {
      throw const FormatException('Invalid explicit shared copy.');
    }
    return copy;
  }
  Future<ShareExportStatus> _share(String method, Map<String, Object?> arguments) async {
    value = ShareInboxState(available: value.available, initialized: value.initialized,
      records: value.records, message: value.message);
    try {
      final raw = _map(await _call(method, arguments), {'status'});
      return ShareExportStatus.values.byName(raw['status'] as String);
    } on MissingPluginException {
      return ShareExportStatus.unavailable;
    } catch (error) {
      if (error is StateError) {
        value = ShareInboxState(available: value.available, initialized: value.initialized,
          records: value.records, error: error.message.toString(), message: value.message);
      }
      return ShareExportStatus.failed;
    }
  }
  Future<ShareExportStatus> export(ShareInboxRecord record) => _share('export', {'id': record.id});
  Future<ShareExportStatus> shareExport({required String operationId,
      required DocumentTransferScope scope, required String path, required String suggestedName}) {
    if (!validTransferId(operationId) || scope == DocumentTransferScope.cohort ||
        path.isEmpty || path.length > 16384 || path.contains('\u0000') ||
        !validName(suggestedName)) {
      return Future.value(ShareExportStatus.failed);
    }
    return _share('shareExport', {'operationId': operationId, 'scope': scope.name,
      'path': path, 'suggestedName': suggestedName});
  }
}
