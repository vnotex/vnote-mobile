// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:vxcore_bridge/vxcore_bridge.dart';

@Native<Int32 Function()>(symbol: 'vxm_host_test_enable_sync_fixture',
  assetId: 'package:vxcore_bridge/src/generated/vxcore_host_bindings.dart')
external int enableSyncFixtureForTesting();

/// The root verifier launches each integration suite in a fresh desktop process
/// under vxcore/tests/run_webdav_test.py. No tests change process trust stores.
final class SyncFixture {
  SyncFixture._(this.root, this._client);
  final Directory root;
  final HttpClient _client;
  static bool _enabled = false;
  static int _counter = 0;
  static bool get available => !Platform.isAndroid && !Platform.isIOS &&
      Platform.environment['VXCORE_WEBDAV_TEST_URL']?.startsWith('https://') == true;
  static String _environment(String key) {
    final value = Platform.environment[key];
    if (value == null || value.isEmpty) throw StateError('Required HTTPS fixture input is absent: $key');
    return value;
  }
  static void enableNativeFixtureMode() {
    if (!available) throw StateError('Real HTTPS fixture requires a fresh desktop integration process');
    if (_enabled) return;
    final code = enableSyncFixtureForTesting();
    if (code != 0) throw CoreException(code, 'Fixture mode must precede every native context');
    _enabled = true;
  }
  static Future<SyncFixture> create({bool resetRemote = true}) async {
    enableNativeFixtureMode();
    final root = await Directory(_environment('VXCORE_WEBDAV_TEST_CLIENT_ROOT')).createTemp('bridge-sync-');
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(_environment('VXCORE_WEBDAV_TEST_CA_FILE'));
    final fixture = SyncFixture._(root, HttpClient(context: trust)..connectionTimeout = const Duration(seconds: 15));
    if (resetRemote) await fixture.control({'action': 'reset'});
    return fixture;
  }
  String get endpoint => _environment('VXCORE_WEBDAV_TEST_URL');
  String get username => _environment('VXCORE_WEBDAV_TEST_USERNAME');
  String get password => _environment('VXCORE_WEBDAV_TEST_PASSWORD');
  String get caFile => _environment('VXCORE_WEBDAV_TEST_CA_FILE');
  CoreSyncCredentials get credentials => CoreSyncCredentials(username: username, password: password);
  CoreSyncConfiguration get configuration => CoreSyncConfiguration(endpoint: endpoint, autoSyncEnabled: false);
  String path(String relative) => '${root.path}/$relative';
  String operationId() => '76543210-0000-4000-8000-${(++_counter).toRadixString(16).padLeft(12, '0')}';
  String importId() => (++_counter).toRadixString(16).padLeft(32, '0');
  Future<Map<String, Object?>> control(Map<String, Object?> command) async {
    final request = await _client.postUrl(Uri.parse(_environment('VXCORE_WEBDAV_TEST_CONTROL_URL')));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${_environment('VXCORE_WEBDAV_TEST_CONTROL_TOKEN')}');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(command));
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (out, chunk) {
      if (out.length + chunk.length > 4 * 1024 * 1024) throw StateError('Fixture response exceeds its bound');
      return out..addAll(chunk);
    });
    if (response.statusCode != 200) throw StateError('Fixture control failed (details redacted)');
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> || value['ok'] != true) throw StateError('Malformed fixture response');
    return Map<String, Object?>.from(value);
  }
  Future<void> put(String path, String content) async {
    await control({'action': 'put', 'path': path, 'text': content, 'parents': true});
  }
  Future<String?> remoteText(String path) async {
    final result = await control({'action': 'inspect', 'path': path, 'content': true});
    if (result['exists'] == false) return null;
    return utf8.decode(base64Decode(result['content_base64']! as String));
  }
  Future<CoreNotebook> createCatalog({String name = 'Sync fixture', String directory = 'book'}) =>
      CoreNotebook.createCatalog(appDataPath: path('$directory-app'), localDataPath: path('$directory-local'),
        notebookPath: path(directory), notebookName: name);
  Future<void> dispose() async {
    try { await control({'action': 'clear_faults'}); }
    finally { _client.close(force: true); if (await root.exists()) await root.delete(recursive: true); }
  }
}
