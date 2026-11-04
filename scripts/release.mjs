// SPDX-License-Identifier: LGPL-3.0-only
import { spawnSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readFile, writeFile, mkdir, cp, rm, readdir, stat } from 'node:fs/promises';
import { delimiter, dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { sha256, zipEntries } from './dependency_notices.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = join(root, 'apps/vnote_mobile');
const pins = JSON.parse(await readFile(join(root, 'toolchains.json'), 'utf8'));
const [platform, mode, option, ...extra] = process.argv.slice(2);
const owner = mode === 'owner-release';
const win = process.platform === 'win32';
const env = { ...process.env, FLUTTER_SUPPRESS_ANALYTICS: 'true', VNOTE_PACKAGE_MODE: mode };
// Only this script's explicit Release configuration may inject owner settings.
delete env.XCODE_XCCONFIG_FILE;
const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') ?? 'PATH';
env[pathKey] = `${dirname(process.execPath)}${delimiter}${env[pathKey] ?? ''}`;
const localFlutter = join(root, '.tools/flutter/bin', win ? 'flutter.bat' : 'flutter');
const flutter = env.FLUTTER ?? (existsSync(localFlutter) ? localFlutter : 'flutter');
const android = join(app, 'android');
const gradle = join(android, win ? 'gradlew.bat' : 'gradlew');
const generatedOwnerFiles = [];
const installedProfiles = [];

function required(name) {
  const value = env[name];
  if (!value?.trim()) throw Error(`Missing protected owner input: ${name}. Owner IDs/signing are not available; use unsigned-validation only for package validation.`);
  return value;
}
function identifier(name, group = false) {
  const value = required(name);
  if (!/^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*){2,}$/.test(value)
      || /(^|\.)(example|test|localhost|invalid)(\.|$)/i.test(value)
      || (group && !value.startsWith('group.'))) throw Error(`Invalid/development owner identifier: ${name}`);
  return value;
}
async function requiredFile(name) {
  const path = resolve(required(name));
  if (!(await stat(path).catch(() => null))?.isFile()) throw Error(`Protected input file is unavailable: ${name}`);
  return path;
}
function run(command, args, { cwd = root, capture = false, input, overrides = {}, quiet = false } = {}) {
  // Never echo command arguments: paths, identities, or owner configuration can
  // be private. Protected-tool diagnostics are captured and not echoed either.
  const batch = win && /\.(?:bat|cmd)$/i.test(command);
  const literal = value => `'${value.replaceAll("'", "''")}'`;
  const argv = batch ? ['-NoProfile', '-Command', `& ${[command, ...args].map(literal).join(' ')}; exit $LASTEXITCODE`] : args;
  const result = spawnSync(batch ? 'pwsh' : command, argv, { cwd, env: { ...env, ...overrides }, shell: false,
    encoding: 'utf8', input, maxBuffer: 64 * 1024 * 1024,
    stdio: capture || quiet || input !== undefined ? ['pipe', 'pipe', 'pipe'] : 'inherit' });
  if (result.error || result.status !== 0) throw Error(`Packaging tool failed: ${basename(command)} (${result.status ?? 'unavailable'}). No release result was certified.`);
  return result.stdout?.trim() ?? '';
}
async function androidOwnerGate() {
  const id = identifier('VNOTE_ANDROID_APPLICATION_ID');
  if (!/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*){2,}$/.test(id)) throw Error('Owner Android ID is not a valid application ID');
  const keystore = await requiredFile('VNOTE_ANDROID_KEYSTORE');
  const alias = required('VNOTE_ANDROID_KEY_ALIAS');
  required('VNOTE_ANDROID_STORE_PASSWORD'); required('VNOTE_ANDROID_KEY_PASSWORD');
  const expected = required('VNOTE_ANDROID_CERT_SHA256').replaceAll(':', '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(expected) || /^androiddebugkey$/i.test(alias) || /^debug\.keystore$/i.test(basename(keystore))) throw Error('Development signing keys are forbidden for owner release');
  const pem = run('keytool', ['-exportcert', '-rfc', '-keystore', keystore, '-alias', alias, '-storepass:env', 'VNOTE_ANDROID_STORE_PASSWORD'], { capture: true });
  const cert = new X509Certificate(pem);
  if (/Android Debug/i.test(cert.subject) || cert.fingerprint256.replaceAll(':', '').toLowerCase() !== expected
      || Date.parse(cert.validTo) <= Date.now()) throw Error('Owner Android signing certificate is invalid or does not match the protected pin');
  return { id, certificateSha256: expected };
}
function decodePlist(bytes) {
  // Standard-library parsing, not regex interpretation of signing entitlements.
  return JSON.parse(run('python3', ['-c', 'import sys,plistlib,json,datetime,base64; print(json.dumps(plistlib.loads(sys.stdin.buffer.read()), default=lambda v: base64.b64encode(v).decode() if isinstance(v,bytes) else v.isoformat()))'], { capture: true, input: bytes }));
}
async function iosOwnerGate() {
  const id = identifier('VNOTE_IOS_BUNDLE_ID'), extension = identifier('VNOTE_IOS_EXTENSION_ID');
  const group = identifier('VNOTE_IOS_APP_GROUP', true), team = required('VNOTE_IOS_TEAM_ID');
  if (!extension.startsWith(`${id}.`) || extension === id || !/^[A-Z0-9]{10}$/.test(team)) throw Error('iOS app/extension/team owner relationship is invalid');
  const identity = required('VNOTE_IOS_SIGNING_IDENTITY_SHA1').replaceAll(':', '').toUpperCase();
  if (!/^[A-F0-9]{40}$/.test(identity)) throw Error('Pin an installed distribution signing identity by SHA-1');
  const method = required('VNOTE_IOS_EXPORT_METHOD');
  if (!['app-store-connect', 'release-testing', 'enterprise'].includes(method)) throw Error('Select an explicit distribution export method (never development/upload)');
  const profilePaths = [await requiredFile('VNOTE_IOS_APP_PROFILE'), await requiredFile('VNOTE_IOS_EXTENSION_PROFILE')];
  if (process.platform !== 'darwin') throw Error('Owner iOS signing requires macOS, pinned Xcode, installed distribution private key and matching profiles');
  const identities = run('security', ['find-identity', '-v', '-p', 'codesigning'], { capture: true });
  if (!identities.includes(identity)) throw Error('Protected iOS distribution private key is not available in the signing keychain');
  const profiles = [];
  for (let i = 0; i < profilePaths.length; i++) {
    const profile = decodePlist(run('security', ['cms', '-D', '-i', profilePaths[i]], { capture: true }));
    const entitlements = profile.Entitlements ?? {}, bundleId = i ? extension : id;
    if (!/^[A-Fa-f0-9-]{36}$/.test(profile.UUID ?? '') || !profile.TeamIdentifier?.includes(team)
        || entitlements['com.apple.developer.team-identifier'] !== team
        || entitlements['application-identifier'] !== `${team}.${bundleId}`
        || entitlements['get-task-allow'] !== false
        || !entitlements['com.apple.security.application-groups']?.includes(group)
        || Date.parse(profile.ExpirationDate) <= Date.now()
        || !profile.DeveloperCertificates?.some(value => new X509Certificate(Buffer.from(value, 'base64')).fingerprint.replaceAll(':', '').toUpperCase() === identity)) {
      throw Error('Protected iOS profile does not authorize the exact distribution certificate, app/team/group, or has expired');
    }
    if (method === 'app-store-connect' && (profile.ProvisionedDevices || profile.ProvisionsAllDevices)
        || method === 'release-testing' && !profile.ProvisionedDevices?.length
        || method === 'enterprise' && profile.ProvisionsAllDevices !== true) throw Error('iOS profile distribution type does not match export method');
    profiles.push({ path: profilePaths[i], uuid: profile.UUID });
  }
  return { id, extension, group, team, identity, method, profiles };
}
function plist(value) {
  const escape = text => String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  function encode(item) {
    if (typeof item === 'boolean') return item ? '<true/>' : '<false/>';
    if (Array.isArray(item)) return `<array>${item.map(encode).join('')}</array>`;
    if (typeof item === 'object') return `<dict>${Object.entries(item).map(([key, val]) => `<key>${escape(key)}</key>${encode(val)}`).join('')}</dict>`;
    return `<string>${escape(item)}</string>`;
  }
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">${encode(value)}</plist>\n`;
}
async function ownerXcodeConfig(ownerInfo, work) {
  const config = join(app, 'ios/Flutter/Owner.xcconfig');
  const appEntitlements = join(app, 'ios/Flutter/Owner-App.entitlements');
  const extensionEntitlements = join(app, 'ios/Flutter/Owner-Extension.entitlements');
  for (const path of [config, appEntitlements, extensionEntitlements]) {
    if (existsSync(path)) throw Error('An existing owner-generated Xcode file must be preserved; remove it explicitly before packaging');
    generatedOwnerFiles.push(path);
  }
  const values = { VNOTE_APP_BUNDLE_ID: ownerInfo.id, VNOTE_EXTENSION_BUNDLE_ID: ownerInfo.extension,
    VNOTE_APP_GROUP: ownerInfo.group, DEVELOPMENT_TEAM: ownerInfo.team, CODE_SIGN_STYLE: 'Manual',
    CODE_SIGN_IDENTITY: ownerInfo.identity, VNOTE_APP_PROFILE: ownerInfo.profiles[0].uuid,
    VNOTE_EXTENSION_PROFILE: ownerInfo.profiles[1].uuid,
    VNOTE_APP_ENTITLEMENTS: appEntitlements, VNOTE_EXTENSION_ENTITLEMENTS: extensionEntitlements };
  for (const value of Object.values(values)) if (/[\r\n$"#]/.test(value)) throw Error('Unsafe owner build-setting value');
  await writeFile(config, Object.entries(values).map(([key, value]) => `${key} = ${value}`).join('\n') + '\n', { mode: 0o600, flag: 'wx' });
  for (const [path, id] of [[appEntitlements, ownerInfo.id], [extensionEntitlements, ownerInfo.extension]]) {
    await writeFile(path, plist({ 'application-identifier': `${ownerInfo.team}.${id}`, 'com.apple.developer.team-identifier': ownerInfo.team,
      'com.apple.security.application-groups': [ownerInfo.group], 'get-task-allow': false }), { mode: 0o600, flag: 'wx' });
  }
  const home = required('HOME');
  const installed = join(home, 'Library/Developer/Xcode/UserData/Provisioning Profiles');
  await mkdir(installed, { recursive: true });
  for (const profile of ownerInfo.profiles) {
    const destination = join(installed, `${profile.uuid}.mobileprovision`);
    if (existsSync(destination)) {
      if (sha256(await readFile(destination)) !== sha256(await readFile(profile.path))) throw Error('An installed profile with this UUID differs; it was not overwritten');
    } else { await cp(profile.path, destination, { errorOnExist: true, force: false }); installedProfiles.push(destination); }
  }
  const exportOptions = join(work, 'ExportOptions.plist');
  await writeFile(exportOptions, plist({ method: ownerInfo.method, destination: 'export', teamID: ownerInfo.team,
    signingStyle: 'manual', signingCertificate: ownerInfo.identity, manageAppVersionAndBuildNumber: false,
    provisioningProfiles: { [ownerInfo.id]: ownerInfo.profiles[0].uuid, [ownerInfo.extension]: ownerInfo.profiles[1].uuid } }), { mode: 0o600 });
  return { config, exportOptions };
}
function elf16k(bytes, name) {
  if (bytes.length < 64 || bytes.toString('hex', 0, 4) !== '7f454c46' || bytes[4] !== 2 || bytes[5] !== 1) throw Error(`Unexpected ELF architecture: ${name}`);
  const offset = Number(bytes.readBigUInt64LE(32)), stride = bytes.readUInt16LE(54), count = bytes.readUInt16LE(56);
  if (stride < 56 || offset + stride * count > bytes.length) throw Error(`Invalid ELF program headers: ${name}`);
  let loads = 0;
  for (let i = 0; i < count; i++) {
    const at = offset + i * stride;
    if (bytes.readUInt32LE(at) !== 1) continue;
    loads++;
    const alignment = bytes.readBigUInt64LE(at + 48), fileOffset = bytes.readBigUInt64LE(at + 8), virtual = bytes.readBigUInt64LE(at + 16);
    if (alignment < 16384n || (alignment & (alignment - 1n)) !== 0n || fileOffset % 16384n !== virtual % 16384n) throw Error(`ELF PT_LOAD is not 16 KiB compatible: ${name}`);
  }
  if (!loads) throw Error(`ELF has no loadable segments: ${name}`);
}
function protobufFields(bytes) {
  const fields = new Map(); let at = 0;
  const integer = () => { let value = 0, shift = 0; while (at < bytes.length && shift < 49) { const byte = bytes[at++]; value += (byte & 127) * 2 ** shift; if (!(byte & 128)) return value; shift += 7; } throw Error('Invalid protobuf integer'); };
  while (at < bytes.length) {
    const key = integer(), number = Math.floor(key / 8), wire = key % 8;
    let value;
    if (wire === 0) value = integer();
    else if (wire === 2) { const size = integer(); if (at + size > bytes.length) throw Error('Truncated protobuf'); value = bytes.subarray(at, at += size); }
    else if (wire === 1 || wire === 5) { at += wire === 1 ? 8 : 4; if (at > bytes.length) throw Error('Truncated protobuf'); continue; }
    else throw Error('Unsupported protobuf field');
    if (!fields.has(number)) fields.set(number, []); fields.get(number).push(value);
  }
  return fields;
}
async function validateAndroidArtifact(path, bundle, ownerInfo) {
  const bytes = await readFile(path), entries = zipEntries(bytes);
  for (const requiredName of bundle ? ['BundleConfig.pb', 'base/manifest/AndroidManifest.xml', 'base/resources.pb', 'base/dex/classes.dex'] : ['AndroidManifest.xml', 'resources.arsc', 'classes.dex']) {
    if (!entries.has(requiredName)) throw Error(`Missing packaged Android structure: ${requiredName}`);
  }
  const asset = bundle ? 'base/assets/flutter_assets/assets/legal/DEPENDENCIES.txt' : 'assets/flutter_assets/assets/legal/DEPENDENCIES.txt';
  if (!entries.has(asset) || sha256(entries.get(asset).read()) !== sha256(await readFile(join(app, 'assets/legal/DEPENDENCIES.txt')))) throw Error('Packaged dependency notices differ from audited input');
  const abis = new Map();
  for (const [name, entry] of entries) {
    if (/(?:^|\/)(?:Owner\.xcconfig|Owner-.*\.entitlements|.*\.(?:keystore|jks|p12|mobileprovision))$/i.test(name)) throw Error('Private signing input entered an Android package');
    const match = /^(?:base\/)?lib\/([^/]+)\/([^/]+\.so)$/.exec(name);
    if (!match) continue;
    if (!['arm64-v8a', 'x86_64'].includes(match[1])) throw Error('Unexpected packaged Android ABI');
    elf16k(entry.read(), name);
    if (!bundle && (entry.method !== 0 || entry.offset % 16384 !== 0)) throw Error(`Native APK member is not uncompressed and 16 KiB ZIP aligned: ${name}`);
    if (!abis.has(match[1])) abis.set(match[1], new Set()); abis.get(match[1]).add(match[2]);
  }
  for (const abi of ['arm64-v8a', 'x86_64']) for (const library of ['libflutter.so', 'libapp.so', 'libvnote_host.so']) if (!abis.get(abi)?.has(library)) throw Error(`Missing packaged native runtime: ${abi}/${library}`);
  if (bundle) {
    const rootElement = protobufFields(entries.get('base/manifest/AndroidManifest.xml').read()).get(1)?.[0];
    if (!rootElement) throw Error('AAB manifest has no root element');
    const element = protobufFields(rootElement);
    const attributes = (element.get(4) ?? []).map(value => protobufFields(value));
    const packageAttribute = attributes.find(value => value.get(2)?.[0].toString('utf8') === 'package');
    if (element.get(3)?.[0].toString('utf8') !== 'manifest'
        || packageAttribute?.get(3)?.[0].toString('utf8') !== (owner ? ownerInfo.id : 'com.example.vnote_mobile')) throw Error('AAB manifest identity differs from selected package mode');
    // BundleConfig.optimizations(2).uncompress_native_libraries(2).alignment(2).
    // Source: google/bundletool 1.18.2 src/main/proto/config.proto.
    const optimizations = protobufFields(entries.get('BundleConfig.pb').read()).get(2)?.[0];
    const native = optimizations && protobufFields(optimizations).get(2)?.[0];
    const fields = native && protobufFields(native);
    if (fields?.get(1)?.[0] !== 1 || ![2, 3].includes(fields?.get(2)?.[0])) throw Error('AAB does not request uncompressed native libraries with at least 16 KiB split alignment');
    if (owner) {
      run('jarsigner', ['-verify', '-strict', '-keystore', required('VNOTE_ANDROID_KEYSTORE'), '-storepass:env', 'VNOTE_ANDROID_STORE_PASSWORD', path], { quiet: true });
      const certificate = new X509Certificate(run('keytool', ['-printcert', '-rfc', '-jarfile', path], { capture: true }));
      if (certificate.fingerprint256.replaceAll(':', '').toLowerCase() !== ownerInfo.certificateSha256) throw Error('AAB signer differs from protected owner certificate');
    } else if ([...entries.keys()].some(name => /^META-INF\/.*\.(RSA|DSA|EC)$/i.test(name))) throw Error('Unsigned validation AAB unexpectedly contains a signature');
  } else {
    const sdk = required('ANDROID_HOME');
    const directories = (await readdir(join(sdk, 'build-tools'))).filter(name => /^\d+\.\d+\.\d+$/.test(name)).sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
    if (!directories.length) throw Error('Android SDK build-tools are unavailable');
    const tools = join(sdk, 'build-tools', directories[0]);
    run(join(tools, win ? 'zipalign.exe' : 'zipalign'), ['-c', '-P', '16', '-v', '4', path], { quiet: true });
    const badging = run(join(tools, win ? 'aapt2.exe' : 'aapt2'), ['dump', 'badging', path], { capture: true });
    if (!badging.includes(`package: name='${owner ? ownerInfo.id : 'com.example.vnote_mobile'}'`)) throw Error('Packaged APK identity differs from selected package mode');
    if (owner) {
      const verified = run(join(tools, win ? 'apksigner.bat' : 'apksigner'), ['verify', '--verbose', '--print-certs', path], { capture: true });
      if (!verified.toLowerCase().includes(ownerInfo.certificateSha256)) throw Error('APK signer differs from protected owner certificate');
    } else {
      // APK Signing Block sits immediately before the central directory.
      if (bytes.includes(Buffer.from('APK Sig Block 42')) || [...entries.keys()].some(name => /^META-INF\/.*\.(RSA|DSA|EC)$/i.test(name))) throw Error('Unsigned validation APK unexpectedly contains a signature');
    }
  }
  return { name: basename(path), sha256: sha256(bytes), bytes: bytes.length, elfAndZipAlignment: '16KiB', signed: owner };
}
async function validateIosApp(path, ownerInfo) {
  const info = decodePlist(await readFile(join(path, 'Info.plist')));
  const extensionPath = join(path, 'PlugIns/ShareExtension.appex');
  const extensionInfo = decodePlist(await readFile(join(extensionPath, 'Info.plist')));
  if (info.CFBundleIdentifier !== (owner ? ownerInfo.id : 'com.example.vnoteMobile')
      || extensionInfo.CFBundleIdentifier !== (owner ? ownerInfo.extension : 'com.example.vnoteMobile.ShareExtension')) throw Error('iOS packaged app/extension identities differ from selected mode');
  const legalAsset = join(path, 'Frameworks/App.framework/flutter_assets/assets/legal/DEPENDENCIES.txt');
  if (sha256(await readFile(legalAsset)) !== sha256(await readFile(join(app, 'assets/legal/DEPENDENCIES.txt')))) throw Error('Packaged iOS dependency notices differ from audited input');
  if (owner) {
    for (const [target, id] of [[path, ownerInfo.id], [extensionPath, ownerInfo.extension]]) {
      run('codesign', ['--verify', '--deep', '--strict', target], { quiet: true });
      // codesign writes entitlement XML to stdout for the explicit '-' output.
      const entitlements = decodePlist(run('codesign', ['-d', '--entitlements', ':-', target], { capture: true }));
      if (entitlements['application-identifier'] !== `${ownerInfo.team}.${id}` || entitlements['get-task-allow'] === true
          || !entitlements['com.apple.security.application-groups']?.includes(ownerInfo.group)) throw Error('Signed iOS entitlements differ from authorized owner inputs');
    }
  } else if (existsSync(join(path, '_CodeSignature')) || existsSync(join(extensionPath, '_CodeSignature')) || info.VNoteAppGroup || extensionInfo.VNoteAppGroup) {
    throw Error('Unsigned validation app unexpectedly carries signing or an App Group');
  }
}
async function packageRelease(ownerInfo) {
  if (process.versions.node !== pins.node) throw Error(`Node ${pins.node} required`);
  if (platform === 'ios') {
    if (process.platform !== 'darwin') throw Error('Unsigned iOS app/archive validation requires macOS and pinned Xcode; it cannot run on this host');
    const xcode = run('xcodebuild', ['-version'], { capture: true });
    if (!xcode.startsWith(`Xcode ${pins.ios.xcode}\n`) || !xcode.includes(pins.ios.xcodeBuild)) throw Error('Pinned Xcode version/build is required');
  }
  const flutterVersion = run(flutter, ['--version', '--machine'], { capture: true });
  const version = JSON.parse(flutterVersion.slice(flutterVersion.indexOf('{')));
  if (version.frameworkRevision !== pins.flutter.revision || version.dartSdkVersion !== pins.flutter.dart) throw Error('Pinned Flutter/Dart SDK is required');
  if (run('git', ['-C', 'third_party/vxcore', 'rev-parse', 'HEAD'], { capture: true }) !== pins.core.revision) throw Error('Native source pin differs from toolchains.json');
  env.ANDROID_HOME ??= env.ANDROID_SDK_ROOT;
  if (!env.ANDROID_HOME) throw Error('ANDROID_HOME is required for actual Maven/native dependency inventory (including iOS validation)');
  const commandLineRoot = join(env.ANDROID_HOME, 'cmdline-tools');
  const commandLineVersions = await readdir(commandLineRoot).catch(() => []);
  if (!commandLineVersions.some(version => existsSync(join(commandLineRoot, version, 'bin', win ? 'apkanalyzer.bat' : 'apkanalyzer')))) {
    throw Error('Android SDK command-line tools/apkanalyzer are required for Flutter bundle validation. Install cmdline-tools;19.0 after accepting the Android SDK terms; no build has started.');
  }
  run(process.execPath, ['scripts/verify.mjs', 'assets']);
  run(flutter, ['pub', 'get', '--enforce-lockfile']);
  // Bootstrap never installs or clears the development application. It compiles
  // the exact native source/license inventory before the final notice-bearing packages.
  run(flutter, ['build', 'apk', '--debug', '--no-pub', '--target-platform', 'android-arm64,android-x64'], { cwd: app, overrides: { VNOTE_PACKAGE_MODE: 'unsigned-validation' } });
  run(gradle, [':app:dependencyNoticeInputs', '-Ptarget-platform=android-arm64,android-x64', '--dependency-verification=strict', '--no-daemon'], { cwd: android, overrides: { VNOTE_PACKAGE_MODE: 'unsigned-validation' } });
  const nativeArgs = ['--native', '.tools/host-android-arm64-28', '--native', '.tools/host-android-x64-28'];
  if (platform === 'ios') {
    run(flutter, ['build', 'ios', '--release', '--no-codesign', '--no-pub'], { cwd: app, overrides: { VNOTE_PACKAGE_MODE: 'unsigned-validation' } });
    nativeArgs.push('--native', '.tools/host-ios-arm64-iphoneos');
  }
  run(process.execPath, ['scripts/dependency_notices.mjs', ...nativeArgs]);
  const work = join(root, '.tools/release', `work-${platform}-${process.pid}`);
  if (existsSync(work)) throw Error('Packaging work directory already exists');
  await mkdir(work, { recursive: true });
  const artifacts = [];
  if (platform === 'android') {
    run(flutter, ['build', 'apk', '--release', '--no-pub', '--target-platform', 'android-arm64,android-x64'], { cwd: app, quiet: owner });
    run(flutter, ['build', 'appbundle', '--release', '--no-pub', '--target-platform', 'android-arm64,android-x64'], { cwd: app, quiet: owner });
    const apkDirectory = join(app, 'build/app/outputs/flutter-apk');
    const apks = (await readdir(apkDirectory)).filter(name => /^app-release(?:-unsigned)?\.apk$/.test(name));
    if (!apks.length) throw Error('Final release APK was not produced');
    // Flutter normally uses app-release.apk for both modes; do not select a
    // stale signed/unsigned alternative without proving its notices and signer.
    const apk = join(apkDirectory, apks.includes('app-release.apk') ? 'app-release.apk' : apks[0]);
    const aab = join(app, 'build/app/outputs/bundle/release/app-release.aab');
    for (const [path, bundle] of [[apk, false], [aab, true]]) {
      const destination = join(work, `${mode}.${bundle ? 'aab' : 'apk'}`);
      await cp(path, destination);
      artifacts.push(await validateAndroidArtifact(destination, bundle, ownerInfo));
    }
  } else {
    const signing = owner ? await ownerXcodeConfig(ownerInfo, work) : null;
    const common = ['-workspace', 'Runner.xcworkspace', '-scheme', 'Runner', '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS'];
    const settings = owner ? ['-xcconfig', signing.config, 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES']
      : ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'VNOTE_APP_GROUP=', 'VNOTE_APP_ENTITLEMENTS=', 'VNOTE_EXTENSION_ENTITLEMENTS='];
    run('xcodebuild', [...common, ...settings, '-derivedDataPath', join(work, 'DerivedData'), 'build'], { cwd: join(app, 'ios'), quiet: owner });
    const builtApp = join(work, 'DerivedData/Build/Products/Release-iphoneos/Runner.app');
    await validateIosApp(builtApp, ownerInfo);
    await cp(builtApp, join(work, `${mode}.app`), { recursive: true });
    const archive = join(work, `${mode}.xcarchive`);
    run('xcodebuild', [...common, ...settings, '-archivePath', archive, 'archive'], { cwd: join(app, 'ios'), quiet: owner });
    await validateIosApp(join(archive, 'Products/Applications/Runner.app'), ownerInfo);
    artifacts.push({ name: `${mode}.app`, signed: owner }, { name: `${mode}.xcarchive`, signed: owner });
    if (owner) {
      const destination = join(work, 'export');
      run('xcodebuild', ['-exportArchive', '-archivePath', archive, '-exportPath', destination, '-exportOptionsPlist', signing.exportOptions], { quiet: true });
      const ipas = (await readdir(destination)).filter(name => name.endsWith('.ipa'));
      if (ipas.length !== 1) throw Error('Owner archive export did not produce exactly one IPA');
      const ipaPath = join(destination, ipas[0]);
      zipEntries(await readFile(ipaPath));
      const extracted = join(work, 'export-inspection');
      run('ditto', ['-x', '-k', ipaPath, extracted], { quiet: true });
      const apps = (await readdir(join(extracted, 'Payload'))).filter(name => name.endsWith('.app'));
      if (apps.length !== 1) throw Error('Exported IPA must contain exactly one application');
      await validateIosApp(join(extracted, 'Payload', apps[0]), ownerInfo);
      await rm(extracted, { recursive: true });
      artifacts.push({ name: `export/${ipas[0]}`, sha256: sha256(await readFile(join(destination, ipas[0]))), signed: true });
    }
    await rm(join(work, 'DerivedData'), { recursive: true, force: true });
    await rm(join(work, 'ExportOptions.plist'), { force: true });
  }
  for (const name of ['dependency-inventory.json', 'sbom.cdx.json']) await cp(join(root, '.tools/notices', name), join(work, name));
  await cp(join(app, 'assets/legal/DEPENDENCIES.txt'), join(work, 'DEPENDENCIES.txt'));
  const result = { schema: 1, platform, mode, signed: owner, publication: 'none',
    warning: owner ? 'Locally packaged only; external legal/store/device gates remain.' : 'Unsigned package validation only. Not an installable/distributable owner release.', artifacts };
  await writeFile(join(work, 'package-result.json'), JSON.stringify(result, null, 2) + '\n');
  const destination = join(root, '.tools/release', platform, mode);
  if (existsSync(destination)) throw Error('A previous certified package output exists; preserve or remove it explicitly before replacing it');
  await mkdir(dirname(destination), { recursive: true });
  const { rename } = await import('node:fs/promises');
  await rename(work, destination);
  console.log(`${owner ? 'OWNER-SIGNED LOCAL PACKAGE' : 'UNSIGNED PACKAGE VALIDATION'}: .tools/release/${platform}/${mode}/package-result.json. No publication or upload performed.`);
}
try {
  if (!['android', 'ios'].includes(platform) || !['unsigned-validation', 'owner-release'].includes(mode) || extra.length || option && option !== '--gate-only') throw Error('Usage: node scripts/release.mjs android|ios unsigned-validation|owner-release [--gate-only]');
  // Missing-owner failure happens before dependency resolution or any artifact.
  const ownerInfo = owner ? await (platform === 'android' ? androidOwnerGate() : iosOwnerGate()) : null;
  if (option === '--gate-only') console.log(owner ? 'Owner identity/signing prerequisite gate passed; no artifacts built.' : 'Explicit unsigned-validation mode selected; no owner-release claim.');
  else await packageRelease(ownerInfo);
} catch (error) {
  console.error(`Release gate: ${error.message}`);
  process.exitCode = 1;
} finally {
  for (const path of generatedOwnerFiles) await rm(path, { force: true });
  for (const path of installedProfiles) await rm(path, { force: true });
}
