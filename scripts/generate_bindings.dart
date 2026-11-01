// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && (args.length != 1 || args.single != '--check')) {
    throw ArgumentError(
      'Usage: dart run scripts/generate_bindings.dart [--check]',
    );
  }
  final root = File.fromUri(Platform.script).parent.parent;
  final pins = jsonDecode(
    await File('${root.path}/toolchains.json').readAsString(),
  ) as Map<String, dynamic>;
  final bridge = Directory('${root.path}/packages/vxcore_bridge');
  final output = File(
    '${bridge.path}/lib/src/generated/vxcore_host_bindings.dart',
  );
  final temporary = Directory('${root.path}/.tools/ffigen');
  await temporary.create(recursive: true);
  final generated = File('${temporary.path}/vxcore_host_bindings.dart');
  var clang = Platform.environment['LIBCLANG_PATH'];
  if (clang == null) {
    final native = Directory('${root.path}/.tools/libclang/clang/native');
    if (!await native.exists()) {
      throw StateError(
        'Install libclang ${pins['libclang']} under .tools/libclang or set LIBCLANG_PATH to an LLVM root',
      );
    }
    final llvm = Directory('${temporary.path}/llvm');
    await llvm.create(recursive: true);
    final libraryDirectory = Link(
      '${llvm.path}/${Platform.isWindows ? 'bin' : 'lib'}',
    );
    if (!await libraryDirectory.exists())
      await libraryDirectory.create(native.path);
    clang = llvm.path;
  }
  var ndk = Platform.environment['ANDROID_NDK_ROOT'];
  if (ndk == null) {
    var sdk =
        Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];
    if (sdk == null) {
      final properties = File(
        '${root.path}/apps/vnote_mobile/android/local.properties',
      );
      if (await properties.exists()) {
        final match = RegExp(
          r'^sdk\.dir=(.*)$',
          multiLine: true,
        ).firstMatch(await properties.readAsString());
        sdk = match
            ?.group(1)
            ?.trim()
            .replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);
      }
    }
    if (sdk == null)
      throw StateError(
        'Set ANDROID_HOME to the SDK containing pinned NDK headers',
      );
    ndk = '$sdk/ndk/${pins['android']['ndk']}';
  }
  final properties = await File('$ndk/source.properties').readAsString();
  if (!properties.contains('Pkg.Revision = ${pins['android']['ndk']}')) {
    throw StateError(
      'Binding generation requires NDK ${pins['android']['ndk']}',
    );
  }
  final host = Platform.isWindows
      ? 'windows-x86_64'
      : Platform.isMacOS
      ? 'darwin-x86_64'
      : 'linux-x86_64';
  final prebuilt = '$ndk/toolchains/llvm/prebuilt/$host';
  final config = File('${temporary.path}/ffigen.yaml');
  var yaml = await File('${bridge.path}/ffigen.yaml').readAsString();
  yaml = yaml.replaceFirst(
    RegExp(r'^output:.*$', multiLine: true),
    'output: ${jsonEncode(generated.path)}',
  );
  yaml = yaml.replaceFirst(
    '    - native/vxcore_host.h',
    '    - ${jsonEncode('${bridge.path}/native/vxcore_host.h')}',
  );
  yaml = yaml.replaceAll(
    '    - native/vxcore_host.h',
    "    - '**/vxcore_host.h'",
  );
  yaml = yaml.replaceFirst(
    "  - '-I../../third_party/vxcore/include'",
    '  - ${jsonEncode('-I${root.path}/third_party/vxcore/include')}',
  );
  yaml = yaml.replaceFirst(
    'compiler-opts:\n',
    'compiler-opts:\n'
        '  - ${jsonEncode('--target=x86_64-linux-android${pins['android']['minSdk']}')}\n'
        '  - ${jsonEncode('--sysroot=$prebuilt/sysroot')}\n'
        '  - ${jsonEncode('-resource-dir=$prebuilt/lib/clang/19')}\n',
  );
  yaml += '\nllvm-path:\n  - ${jsonEncode(clang)}\n';
  await config.writeAsString(yaml);
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'ffigen',
    '--config',
    config.path,
  ], workingDirectory: bridge.path);
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .listen(stdout.write)
      .asFuture<void>();
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write)
      .asFuture<void>();
  final status = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  if (status != 0) throw StateError('ffigen failed ($status)');
  final bytes = await generated.readAsBytes();
  if (args.isNotEmpty) {
    final actual = await output.readAsBytes();
    if (actual.length != bytes.length)
      throw StateError('Generated FFI bindings are stale');
    for (var i = 0; i < bytes.length; i++) {
      if (actual[i] != bytes[i])
        throw StateError('Generated FFI bindings are stale');
    }
    print('Generated FFI bindings match the public C headers.');
  } else {
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes);
    print('Generated ${output.path}');
  }
  await temporary.delete(recursive: true);
}
