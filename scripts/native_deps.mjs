// SPDX-License-Identifier: LGPL-3.0-only
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pins = JSON.parse(readFileSync(join(root, 'toolchains.json'), 'utf8'));
const args = process.argv.slice(2);
if (args.length % 2) throw new Error('Native dependency arguments must be --name value pairs.');
const options = Object.fromEntries(Array.from({ length: args.length / 2 }, (_, i) => [args[i * 2], args[i * 2 + 1]]));
for (const key of Object.keys(options)) {
  if (!['--os', '--arch', '--ndk', '--api', '--sdk', '--result'].includes(key)) throw new Error(`Unknown option ${key}`);
}
const os = options['--os'], arch = options['--arch'];
if (!['android', 'ios', 'windows', 'macos', 'linux'].includes(os) || !['arm64', 'x64'].includes(arch) || !options['--result']) {
  throw new Error('Usage: native_deps.mjs --os android|ios --arch arm64|x64 --result file [--ndk root --api 28 | --sdk iphoneos|iphonesimulator]');
}
if (process.versions.node !== pins.node) throw new Error(`Node ${pins.node} required.`);
const win = process.platform === 'win32';
const tar = win ? join(process.env.SystemRoot, 'System32', 'tar.exe') : 'tar';
if (os === 'ios' && process.platform !== 'darwin') throw new Error('iOS native dependencies require macOS/Xcode.');
const jsonLicense = join(root, '.tools', 'native-licenses', 'nlohmann-LICENSE.MIT');
if (!existsSync(jsonLicense) || createHash('sha256').update(await readFile(jsonLicense)).digest('hex') !== pins.jsonLicense.sha256) {
  const response = await fetch(pins.jsonLicense.url);
  if (!response.ok) throw new Error(`Native license download failed: ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(bytes).digest('hex') !== pins.jsonLicense.sha256) throw new Error('Native license SHA256 mismatch.');
  await mkdir(dirname(jsonLicense), { recursive: true });
  await writeFile(jsonLicense, bytes);
}
if (os !== 'android' && os !== 'ios') {
  const destination = resolve(options['--result']);
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, JSON.stringify({ jsonLicense }));
  process.exit(0);
}
const api = os === 'android' ? Number(options['--api']) : pins.ios.minimumOs;
if (os === 'android' && (!Number.isInteger(api) || api < pins.android.minSdk)) throw new Error(`Android API ${pins.android.minSdk} or newer required.`);
const sdk = os === 'ios' ? options['--sdk'] : '';
if (os === 'ios' && !['iphoneos', 'iphonesimulator'].includes(sdk)) throw new Error('Select the exact iOS SDK.');
if (sdk === 'iphoneos' && arch !== 'arm64') throw new Error('iPhoneOS requires arm64.');
const ndk = os === 'android' ? resolve(options['--ndk'] ?? '') : null;
if (ndk && !readFileSync(join(ndk, 'source.properties'), 'utf8').includes(`Pkg.Revision = ${pins.android.ndk}`)) {
  throw new Error(`NDK ${pins.android.ndk} required.`);
}
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const key = `${os}-${arch}-${sdk || api}`;
const directory = join(root, '.tools', 'native-deps', key);
const source = join(directory, `openssl-${pins.openssl.version}`);
const prefix = join(directory, 'installed');
const identity = {
  openssl: pins.openssl, os, arch, api, sdk, perlModules: win ? pins.perlModules : null,
  ndk: ndk ? pins.android.ndk : null,
  xcode: os === 'ios' ? pins.ios.xcode : null,
  builder: hash(await readFile(fileURLToPath(import.meta.url))),
};
const stamp = join(directory, 'complete.json');
const libraries = ['libssl.a', 'libcrypto.a'].map(name => join(prefix, 'lib', name));
const result = { root: prefix, source, license: join(source, 'LICENSE.txt'), jsonLicense };
if (existsSync(stamp) && readFileSync(stamp, 'utf8') === JSON.stringify(identity) &&
    libraries.every(existsSync) && existsSync(join(prefix, 'include', 'openssl', 'opensslv.h'))) {
  await publishResult();
  process.exit(0);
}
await mkdir(directory, { recursive: true });
const archive = join(root, '.tools', `openssl-${pins.openssl.version}.tar.gz`);
if (!existsSync(archive)) {
  const response = await fetch(pins.openssl.url);
  if (!response.ok) throw new Error(`OpenSSL download failed: ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (hash(bytes) !== pins.openssl.sha256) throw new Error('OpenSSL archive SHA256 mismatch.');
  const temporary = `${archive}.${process.pid}.tmp`;
  await writeFile(temporary, bytes);
  await rename(temporary, archive);
}
if (hash(await readFile(archive)) !== pins.openssl.sha256) throw new Error('Cached OpenSSL source hash mismatch.');
const env = { ...process.env };
const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') ?? 'PATH';
function run(command, values, cwd = directory, capture = false) {
  console.error(`> ${command} ${values.join(' ')}`);
  const completed = spawnSync(command, values, { cwd, env, encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit' });
  if (completed.error) throw completed.error;
  if (completed.status !== 0) throw new Error(`Native dependency command failed (${completed.status}): ${command}`);
  return completed.stdout?.trim() ?? '';
}
if (!existsSync(join(source, 'Configure'))) run(tar, ['-xf', archive, '-C', directory]);
let shell;
let make = process.env.MAKE ?? (win ? 'gmake' : 'make');
if (win) {
  const gitExec = run('git', ['--exec-path'], directory, true);
  const gitRoot = resolve(gitExec, '../../..');
  const unixBin = join(gitRoot, 'usr', 'bin');
  shell = join(unixBin, 'bash.exe');
  if (!existsSync(shell) || !existsSync(join(unixBin, 'perl.exe'))) {
    throw new Error('Git for Windows Unix Perl and Bash are required for OpenSSL.');
  }
  env[pathKey] = `${unixBin}${delimiter}${env[pathKey] ?? ''}`;
}
const quote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
const unixPath = path => win ? run(shell, ['--noprofile', '--norc', '-c', `cygpath -u ${quote(path)}`], directory, true) : path;
if (win) {
  // Git's Unix Perl omits build modules used by IPC::Cmd. Supply the real,
  // pinned pure-Perl distributions locally, without patching OpenSSL or Git.
  const perlRoot = join(root, '.tools', 'perl');
  const libraries = [];
  for (const dependency of pins.perlModules) {
    const moduleRoot = join(perlRoot, `${dependency.name}-${dependency.version}`);
    if (!existsSync(join(moduleRoot, 'lib', dependency.module))) {
      await mkdir(perlRoot, { recursive: true });
      const response = await fetch(dependency.url);
      if (!response.ok) throw new Error(`Perl module download failed: ${response.status}`);
      const bytes = Buffer.from(await response.arrayBuffer());
      if (hash(bytes) !== dependency.sha256) throw new Error('Perl module SHA256 mismatch.');
      const archive = join(perlRoot, `${dependency.name}.tar.gz`);
      await writeFile(archive, bytes);
      run(tar, ['-xf', archive, '-C', perlRoot]);
    }
    libraries.push(unixPath(join(moduleRoot, 'lib')));
  }
  env.PERL5LIB = libraries.join(':');
  env.MSYS2_ENV_CONV_EXCL = [env.MSYS2_ENV_CONV_EXCL, 'PERL5LIB'].filter(Boolean).join(';');
}
let target;
if (ndk) {
  const host = win ? 'windows-x86_64' : process.platform === 'darwin' ? 'darwin-x86_64' : 'linux-x86_64';
  const bin = join(ndk, 'toolchains', 'llvm', 'prebuilt', host, 'bin');
  env[pathKey] = `${bin}${delimiter}${env[pathKey] ?? ''}`;
  env.ANDROID_NDK_ROOT = unixPath(ndk);
  target = arch === 'arm64' ? 'android-arm64' : 'android-x86_64';
} else {
  const version = run('xcodebuild', ['-version'], directory, true);
  if (!version.startsWith(`Xcode ${pins.ios.xcode}\n`)) throw new Error(`Xcode ${pins.ios.xcode} required.`);
  target = sdk === 'iphoneos' ? 'ios64-xcrun' : `iossimulator-${arch === 'x64' ? 'x86_64' : 'arm64'}-xcrun`;
}
const configure = ['perl', 'Configure', target, 'no-shared', 'no-tests', 'no-apps', 'no-module',
  '--libdir=lib', `--prefix=${unixPath(prefix)}`,
  ...(ndk ? [`-D__ANDROID_API__=${api}`] : [`-mios-version-min=${api}`]),
];
function buildCommand(command) {
  if (win) return run(shell, ['--noprofile', '--norc', '-c', `exec ${command.map(quote).join(' ')}`], source);
  return run(command[0], command.slice(1), source);
}
buildCommand(configure);
buildCommand([make, '-j4', ...(win ? ['SHELL=sh.exe', 'PERL=perl'] : []), 'build_libs']);
buildCommand([make, ...(win ? ['SHELL=sh.exe', 'PERL=perl'] : []), 'install_dev']);
if (!libraries.every(existsSync)) throw new Error('OpenSSL build completed without both static target libraries.');
await writeFile(stamp, JSON.stringify(identity));
await publishResult();
async function publishResult() {
  const destination = resolve(options['--result']);
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, JSON.stringify(result));
  console.error(`Prepared OpenSSL ${pins.openssl.version} for ${key}.`);
}
