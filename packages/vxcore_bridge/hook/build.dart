// SPDX-License-Identifier: LGPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<String> run(String command, List<String> args, String cwd) async {
  final process = await Process.start(command, args, workingDirectory: cwd);
  final out = StringBuffer();
  final stdoutDone = process.stdout.transform(utf8.decoder).listen((text) {
    out.write(text);
    stdout.write(text);
  }).asFuture<void>();
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write)
      .asFuture<void>();
  final code = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  if (code != 0)
    throw ProcessException(command, args, 'Native build failed', code);
  return out.toString().trim();
}

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final root = Directory.fromUri(input.packageRoot.resolve('../../'));
    final pinsFile = File('${root.path}/toolchains.json');
    final pins =
        jsonDecode(await pinsFile.readAsString()) as Map<String, dynamic>;
    final config = input.config.code;
    final os = switch (config.targetOS) {
      OS.android => 'android',
      OS.iOS => 'ios',
      OS.windows => 'windows',
      OS.macOS => 'macos',
      OS.linux => 'linux',
      _ => throw UnsupportedError(
        'Unsupported vxcore host platform: ${config.targetOS}',
      ),
    };
    final arch = switch (config.targetArchitecture) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'x64',
      _ => throw UnsupportedError('vxcore host requires arm64 or x64'),
    };
    if (os == 'windows' && arch != 'x64') {
      throw UnsupportedError('The verified Windows host toolchain is x64');
    }
    final cmake = Platform.environment['CMAKE'] ?? 'cmake';
    final cmakeVersion = await run(cmake, ['--version'], root.path);
    if (!cmakeVersion.startsWith('cmake version ${pins['cmake']}')) {
      throw StateError(
        'CMake ${pins['cmake']} required; set CMAKE to that executable',
      );
    }
    final sdk = os == 'ios'
        ? config.iOS.targetSdk == IOSSdk.iPhoneOS
              ? 'iphoneos'
              : 'iphonesimulator'
        : '';
    final api = os == 'android' ? config.android.targetNdkApi : 0;
    if (os == 'android' && api < (pins['android']['minSdk'] as int)) {
      throw StateError(
        'Application minSdk must be at least ${pins['android']['minSdk']}',
      );
    }
    final key = os == 'windows'
        ? 'windows'
        : '$os-$arch-${sdk.isEmpty ? api : sdk}';
    // CMake tracks source dependencies incrementally. The cache is segregated by
    // target; no host binary is ever a mobile fallback.
    final nativeBuild = Directory('${root.path}/.tools/host-$key');
    await nativeBuild.create(recursive: true);
    final dependenciesResult = File(
      '${nativeBuild.path}/dependency-inputs.json',
    );
    final localNode = File(
      '${root.path}/.tools/node-v${pins['node']}-win-x64/node.exe',
    );
    final node =
        Platform.environment['NODE'] ??
        (Platform.isWindows && await localNode.exists()
            ? localNode.path
            : 'node');
    final dependencyArgs = <String>[
      '${root.path}/scripts/native_deps.mjs',
      '--os',
      os,
      '--arch',
      arch,
      '--result',
      dependenciesResult.path,
    ];
    Directory? ndk;
    if (os == 'android') {
      final compiler = config.cCompiler?.compiler;
      if (compiler == null)
        throw StateError('Flutter did not supply its Android NDK compiler');
      ndk = Directory.fromUri(compiler.resolve('../../../../../'));
      final toolchain = File('${ndk.path}/build/cmake/android.toolchain.cmake');
      if (!await toolchain.exists())
        throw StateError('Cannot identify the supplied Android NDK');
      dependencyArgs.addAll(['--ndk', ndk.path, '--api', '$api']);
      output.dependencies.add(File('${ndk.path}/source.properties').uri);
    } else if (os == 'ios') {
      dependencyArgs.addAll(['--sdk', sdk]);
    }
    await run(node, dependencyArgs, root.path);
    final prepared = jsonDecode(
      await dependenciesResult.readAsString(),
    ) as Map<String, dynamic>;
    final configure = <String>[
      '-S',
      Directory.fromUri(input.packageRoot.resolve('native/')).path,
      '-B',
      nativeBuild.path,
      '-DCMAKE_BUILD_TYPE=Release',
      '-DVXM_JSON_LICENSE=${prepared['jsonLicense']}',
    ];
    if (os == 'windows') {
      configure.addAll(['-G', 'Visual Studio 17 2022', '-A', 'x64']);
    } else {
      configure.addAll(['-G', 'Ninja']);
    }
    if (ndk != null) {
      configure.addAll([
        '-DCMAKE_TOOLCHAIN_FILE=${ndk.path}/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=${arch == 'arm64' ? 'arm64-v8a' : 'x86_64'}',
        '-DANDROID_PLATFORM=android-$api',
        '-DANDROID_STL=c++_static',
      ]);
    } else if (os == 'ios') {
      configure.addAll([
        '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_OSX_SYSROOT=$sdk',
        '-DCMAKE_OSX_ARCHITECTURES=${arch == 'x64' ? 'x86_64' : 'arm64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${pins['ios']['minimumOs']}',
      ]);
    } else if (os == 'macos') {
      configure.add(
        '-DCMAKE_OSX_ARCHITECTURES=${arch == 'x64' ? 'x86_64' : 'arm64'}',
      );
    }
    if (os == 'android' || os == 'ios') {
      final ssl = prepared['root'] as String;
      configure.addAll([
        '-DOPENSSL_ROOT_DIR=$ssl',
        '-DOPENSSL_INCLUDE_DIR=$ssl/include',
        '-DOPENSSL_SSL_LIBRARY=$ssl/lib/libssl.a',
        '-DOPENSSL_CRYPTO_LIBRARY=$ssl/lib/libcrypto.a',
        '-DOPENSSL_USE_STATIC_LIBS=TRUE',
        '-DVXM_OPENSSL_LICENSE=${prepared['license']}',
      ]);
    }
    await run(cmake, configure, root.path);
    await run(cmake, [
      '--build',
      nativeBuild.path,
      '--config',
      'Release',
      '--target',
      'vnote_host',
      '--parallel',
      '4',
    ], root.path);
    final filename = os == 'windows'
        ? 'vnote_host.dll'
        : (os == 'ios' || os == 'macos')
        ? 'libvnote_host.dylib'
        : 'libvnote_host.so';
    final library = File('${nativeBuild.path}/artifacts/$filename');
    if (!await library.exists())
      throw StateError('Native host artifact missing: $filename');
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/generated/vxcore_host_bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
    output.dependencies.addAll([
      pinsFile.uri,
      File('${root.path}/scripts/native_deps.mjs').uri,
      File.fromUri(input.packageRoot.resolve('pubspec.yaml')).uri,
    ]);
    for (final directory in [
      Directory.fromUri(input.packageRoot.resolve('native/')),
      Directory('${root.path}/third_party/vxcore'),
    ]) {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.c') ||
            name.endsWith('.cpp') ||
            name.endsWith('.mm') ||
            name.endsWith('.h') ||
            name.endsWith('.hpp') ||
            name.endsWith('.cmake') ||
            name.endsWith('.in') ||
            name.endsWith('.json') ||
            name == 'CMakeLists.txt' ||
            name.startsWith('LICENSE') ||
            name.startsWith('COPYING')) {
          output.dependencies.add(entity.uri);
        }
      }
    }
  });
}
