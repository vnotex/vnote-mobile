// SPDX-License-Identifier: LGPL-3.0-only
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pins = JSON.parse(readFileSync(join(root, 'toolchains.json'), 'utf8'));
const mode = process.argv[2] ?? 'verify';
if (!['verify', 'assets', 'check', 'android', 'ios', 'run'].includes(mode)) {
  throw new Error('Usage: node scripts/verify.mjs [verify|assets|check|android|ios|run]');
}
if (process.version !== `v${pins.node}`) {
  throw new Error(`Node ${pins.node} required; found ${process.version}`);
}
const win = process.platform === 'win32';
const env = {
  ...process.env,
  FLUTTER_SUPPRESS_ANALYTICS: 'true',
};
const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') ?? 'PATH';
env[pathKey] = `${dirname(process.execPath)}${delimiter}${env[pathKey] ?? ''}`;
const localFlutter = join(root, '.tools', 'flutter', 'bin', win ? 'flutter.bat' : 'flutter');
const flutter = process.env.FLUTTER ?? (existsSync(localFlutter) ? localFlutter : 'flutter');
const localDart = join(root, '.tools', 'flutter', 'bin', win ? 'dart.bat' : 'dart');
const dart = process.env.DART ?? (existsSync(localDart) ? localDart : 'dart');
const bridge = join(root, 'packages', 'vxcore_bridge');
const npm = win ? join(dirname(process.execPath), 'npm.cmd') : 'npm';
const editor = join(root, 'packages', 'editor_web');
const app = join(root, 'apps', 'vnote_mobile');

function run(command, args, cwd = root, capture = false) {
  console.log(`> ${command} ${args.join(' ')}`);
  // PowerShell literal arguments avoid cmd.exe argument concatenation/expansion.
  // Native executables use direct process arguments on every platform.
  const batch = win && (command === flutter || command === dart || command.endsWith('.cmd'));
  const literal = value => "'" + value.replaceAll("'", "''") + "'";
  const invocation = batch
    ? ['-NoProfile', '-Command', `& ${[command, ...args].map(literal).join(' ')}; exit $LASTEXITCODE`]
    : args;
  const result = spawnSync(batch ? 'pwsh' : command, invocation, {
    cwd, env, shell: false, encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal})`);
  return result.stdout?.trim() ?? '';
}

if (run(npm, ['--version'], root, true) !== pins.npm) {
  throw new Error(`npm ${pins.npm} required`);
}
if (mode === 'check') {
  run(process.execPath, ['build.mjs', '--check'], editor);
} else {
  run(npm, ['ci', '--registry=https://registry.npmjs.org', '--no-audit', '--no-fund'], editor);
  run(npm, ['run', 'build'], editor);
  run(npm, ['run', 'check'], editor);
  if (mode !== 'assets') {
    const versionOutput = run(flutter, ['--version', '--machine'], root, true);
    const version = JSON.parse(versionOutput.slice(versionOutput.indexOf('{')));
    if (version.frameworkRevision !== pins.flutter.revision ||
        version.dartSdkVersion !== pins.flutter.dart) {
      throw new Error(`Flutter ${pins.flutter.version} at ${pins.flutter.revision} required`);
    }
    const core = run('git', ['-C', 'third_party/vxcore', 'rev-parse', 'HEAD'], root, true);
    if (core !== pins.core.revision) throw new Error('vxcore revision differs from toolchains.json');
    run(flutter, ['pub', 'get', '--enforce-lockfile']);
    if (mode === 'verify') {
      run(npm, ['run', 'typecheck'], editor);
      run(npm, ['test'], editor);
      run(dart, ['run', 'scripts/generate_bindings.dart', '--check']);
      run(dart, ['analyze'], bridge);
      run(dart, ['test'], bridge);
      run(flutter, ['analyze', '--no-pub'], app);
      run(flutter, ['test', '--no-pub'], app);
    } else if (mode === 'android') {
      run(flutter, ['build', 'apk', '--debug', '--no-pub', '--target-platform', 'android-arm64,android-x64'], app);
    } else if (mode === 'ios') {
      if (process.platform !== 'darwin') throw new Error('iOS requires macOS and pinned Xcode');
      const xcode = run('xcodebuild', ['-version'], root, true);
      if (!xcode.startsWith(`Xcode ${pins.ios.xcode}\n`)) {
        throw new Error(`Select Xcode ${pins.ios.xcode} before packaging`);
      }
      run(flutter, ['build', 'ios', '--no-codesign', '--no-pub'], app);
      run(flutter, ['build', 'ios', '--simulator', '--debug', '--no-pub'], app);
    } else {
      run(flutter, ['run', '--no-pub'], app);
    }
  }
}
