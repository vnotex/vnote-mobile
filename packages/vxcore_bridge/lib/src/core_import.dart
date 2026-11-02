// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'core_notebook.dart' show CoreException;
import 'generated/vxcore_host_bindings.dart' as native;

/// Synchronous filesystem transport for a worker isolate, never a UI callback.
///
/// This does not create, borrow, or transfer a core context. Catalog validation
/// remains on a dedicated catalog owner. Cancellation addresses may cross
/// isolates, but their owner must join every borrower before freeing the token.
abstract final class CoreImportStore {
  static const _maximumRequest = 16384;
  static const _maximumResponse = 8 * 1024 * 1024;
  static const _invalid = native.VxCoreError.VXCORE_ERR_INVALID_PARAM;

  /// Executes the closed native command set. ANY error may follow a publication
  /// rename: use `recover` with an uncancelled token, never infer rollback.
  static Map<String, Object?> run(
    Map<String, Object?> request, {
    int cancellationAddress = 0,
  }) {
    if (cancellationAddress < 0) {
      throw const CoreException(_invalid, 'Invalid import cancellation token');
    }
    final encoded = jsonEncode(request);
    if (encoded.length > _maximumRequest ||
        utf8.encode(encoded).length > _maximumRequest) {
      throw const CoreException(_invalid, 'Import command exceeds its limit');
    }
    return using((arena) {
      final output = arena<Pointer<Char>>();
      final code = native.vxm_import_run(
        encoded.toNativeUtf8(allocator: arena).cast(),
        Pointer<native.VxmImportCancel>.fromAddress(cancellationAddress),
        output,
      );
      final response = output.value;
      try {
        if (code != native.VxCoreError.VXCORE_OK) {
          throw CoreException(code, _message(code));
        }
        if (response == nullptr) _malformed();
        final bytes = response.cast<Uint8>();
        var size = 0;
        while (size <= _maximumResponse && bytes[size] != 0) {
          size++;
        }
        if (size > _maximumResponse) _malformed();
        final Object? value;
        try {
          value = jsonDecode(
            utf8.decode(bytes.asTypedList(size), allowMalformed: false),
          );
        } on FormatException {
          _malformed();
        }
        if (value is! Map<String, dynamic>) _malformed();
        return Map<String, Object?>.from(value);
      } finally {
        native.vxm_import_result_free(response);
      }
    });
  }

  /// Portable full case-folded NFC and NFD keys, preserving neither spelling
  /// nor identity. Callers must retain the original spelling independently.
  static ({String nfc, String nfd}) pathKeys(String input) {
    if (input.length > 1024 || input.contains('\u0000')) {
      throw const CoreException(_invalid, 'Invalid import path key input');
    }
    for (var i = 0; i < input.length; i++) {
      final unit = input.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i == input.length ||
            input.codeUnitAt(i) < 0xdc00 ||
            input.codeUnitAt(i) > 0xdfff) {
          throw const CoreException(_invalid, 'Invalid import path Unicode');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const CoreException(_invalid, 'Invalid import path Unicode');
      }
    }
    final encoded = utf8.encode(input);
    if (encoded.length > 1024) {
      throw const CoreException(_invalid, 'Import path key exceeds its limit');
    }
    return using((arena) {
      final source = arena<Uint8>(encoded.isEmpty ? 1 : encoded.length);
      source.asTypedList(encoded.length).setAll(0, encoded);
      final nfc = arena<Uint8>(16384);
      final nfd = arena<Uint8>(16384);
      final nfcSize = arena<Uint64>();
      final nfdSize = arena<Uint64>();
      final code = native.vxm_import_path_keys(
        source,
        encoded.length,
        nfc,
        16384,
        nfcSize,
        nfd,
        16384,
        nfdSize,
      );
      if (code != native.VxCoreError.VXCORE_OK) {
        throw CoreException(code, 'Import path Unicode is not supported');
      }
      if (nfcSize.value > 16384 || nfdSize.value > 16384) _malformed();
      return (
        nfc: utf8.decode(nfc.asTypedList(nfcSize.value)),
        nfd: utf8.decode(nfd.asTypedList(nfdSize.value)),
      );
    });
  }

  static int createCancellation() {
    final token = native.vxm_import_cancel_create();
    if (token == nullptr) {
      throw const CoreException(
        native.VxCoreError.VXCORE_ERR_OUT_OF_MEMORY,
        'Import cancellation storage is unavailable',
      );
    }
    return token.address;
  }

  static void requestCancellation(int address) {
    if (address <= 0) {
      throw const CoreException(_invalid, 'Invalid import cancellation token');
    }
    native.vxm_import_cancel_request(
      Pointer<native.VxmImportCancel>.fromAddress(address),
    );
  }

  static bool queryCancellation(int address) {
    if (address < 0) {
      throw const CoreException(_invalid, 'Invalid import cancellation token');
    }
    return native.vxm_import_cancel_query(
          Pointer<native.VxmImportCancel>.fromAddress(address),
        ) !=
        0;
  }

  /// Call only after all filesystem/decoder jobs using this address have joined.
  static void freeCancellation(int address) {
    if (address <= 0) {
      throw const CoreException(_invalid, 'Invalid import cancellation token');
    }
    native.vxm_import_cancel_free(
      Pointer<native.VxmImportCancel>.fromAddress(address),
    );
  }

  static Never _malformed() => throw const CoreException(
    native.VxCoreError.VXCORE_ERR_JSON_PARSE,
    'Malformed native import response',
  );

  static String _message(int code) => switch (code) {
    native.VxCoreError.VXCORE_ERR_CANCELLED =>
      'Import work was cancelled; recover its actual state before cleanup',
    native.VxCoreError.VXCORE_ERR_FILE_CHANGED_OUTSIDE => 'Import storage changed or its identity does not match; it remains quarantined',
    native.VxCoreError.VXCORE_ERR_UNSUPPORTED => 'Import refused an unsafe path, storage type, limit, or nonportable notebook',
    native.VxCoreError.VXCORE_ERR_JSON_PARSE =>
      'Import metadata or its durable records are malformed',
    native.VxCoreError.VXCORE_ERR_IO =>
      'Import storage operation failed; recover its actual publication state',
    _ => 'Import operation failed; the retained data remains quarantined',
  };
}
