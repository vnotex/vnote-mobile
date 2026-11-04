// SPDX-License-Identifier: LGPL-3.0-only
import { createHash } from 'node:crypto';
import { readFile, readdir, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inflateRawSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const portable = path => path.split(sep).join('/');

// Read only selected ZIP members. Never extract paths supplied by an archive.
// This also inspects the exact packaged native libraries in release.mjs.
export function zipEntries(bytes) {
  let end = bytes.length - 22;
  while (end >= Math.max(0, bytes.length - 65557) && bytes.readUInt32LE(end) !== 0x06054b50) end--;
  if (end < 0 || bytes.readUInt32LE(end) !== 0x06054b50 || end + 22 + bytes.readUInt16LE(end + 20) !== bytes.length) throw Error('Invalid ZIP directory');
  const count = bytes.readUInt16LE(end + 10), start = bytes.readUInt32LE(end + 16);
  if (bytes.readUInt16LE(end + 4) || bytes.readUInt16LE(end + 6) || count === 65535 || start === 0xffffffff) throw Error('Unsupported split/ZIP64 artifact');
  const result = new Map();
  let at = start;
  for (let i = 0; i < count; i++) {
    if (at + 46 > end || bytes.readUInt32LE(at) !== 0x02014b50) throw Error('Invalid ZIP member');
    const flags = bytes.readUInt16LE(at + 8), method = bytes.readUInt16LE(at + 10);
    const compressed = bytes.readUInt32LE(at + 20), size = bytes.readUInt32LE(at + 24);
    const length = bytes.readUInt16LE(at + 28), extra = bytes.readUInt16LE(at + 30), comment = bytes.readUInt16LE(at + 32);
    const local = bytes.readUInt32LE(at + 42), name = bytes.toString('utf8', at + 46, at + 46 + length);
    if (flags & 1 || ![0, 8].includes(method) || size > 512 * 1024 * 1024 || !name || name.startsWith('/') || name.includes('\\') || name.split('/').includes('..') || result.has(name)) throw Error('Unsafe or unsupported ZIP member');
    if (local + 30 > start || bytes.readUInt32LE(local) !== 0x04034b50) throw Error('Invalid ZIP local header');
    const offset = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28);
    if (offset + compressed > start) throw Error('Truncated ZIP data');
    result.set(name, { name, size, method, offset, read() {
      const data = bytes.subarray(offset, offset + compressed);
      const value = method === 0 ? data : inflateRawSync(data, { maxOutputLength: size || 1 });
      if (value.length !== size) throw Error('ZIP member size mismatch');
      return value;
    } });
    at += 46 + length + extra + comment;
  }
  if (at !== start + bytes.readUInt32LE(end + 12)) throw Error('ZIP directory size mismatch');
  return result;
}

const grants = [
  ['Apache-2.0', [/Apache License/i, /Version 2\.0, January 2004/i, /END OF TERMS AND CONDITIONS/i]],
  ['MIT', [/Permission is hereby granted/i, /THE SOFTWARE IS PROVIDED/i]],
  ['BSD-3-Clause', [/Redistribution and use in source and binary forms/i, /Neither the name|names of its contributors/i, /THIS SOFTWARE IS PROVIDED/i]],
  ['BSD-2-Clause', [/Redistribution and use in source and binary forms/i, /THIS SOFTWARE IS PROVIDED/i]],
  ['ISC', [/Permission to use, copy, modify, and\/or distribute/i, /THE SOFTWARE IS PROVIDED/i]],
  ['curl', [/COPYRIGHT AND PERMISSION NOTICE/i, /Permission to use, copy, modify, and distribute this software for any/i, /THE SOFTWARE IS PROVIDED/i]],
  ['SQLite-public-domain', [/author disclaims copyright/i, /May you do good and not evil/]],
  ['LGPL-3.0-only', [/GNU LESSER GENERAL PUBLIC LICENSE/, /Version 3, 29 June 2007/]],
  ['GPL-2.0-with-linking-exception', [/GNU GENERAL PUBLIC LICENSE/, /linking exception|link.*independent modules/i]],
  ['Unlicense', [/free and unencumbered software released into the public domain/i, /THE SOFTWARE IS PROVIDED/i]],
];
function identify(text, component) {
  const found = grants.filter(([, markers]) => markers.every(marker => marker.test(text))).map(([name]) => name);
  if (!found.length) throw Error(`Missing or unrecognized complete license grant: ${component}`);
  return [...new Set(found)].filter(name => name !== 'BSD-2-Clause' || !found.includes('BSD-3-Clause'));
}
async function evidence(path, name = portable(relative(root, path))) {
  const bytes = await readFile(path);
  if (!bytes.length || bytes.length > 16 * 1024 * 1024) throw Error(`Empty or oversized license evidence: ${name}`);
  return { name, sha256: sha256(bytes), text: bytes.toString('utf8') };
}
async function licenseFiles(directory) {
  const files = await readdir(directory, { withFileTypes: true });
  return files.filter(file => file.isFile() && /^(?:licen[sc]e|copying|notice)(?:[._-].*)?$/i.test(file.name)).map(file => file.name).sort();
}
function lockPackages(text) {
  const result = new Map();
  for (const match of text.matchAll(/^  ([\w]+):\r?\n([\s\S]*?)(?=^  [\w]+:|^sdks:|$(?![\s\S]))/gm)) {
    const field = name => new RegExp(`^    ${name}: ["']?([^"'\\r\\n]+)`, 'm').exec(match[2])?.[1];
    result.set(match[1], { version: field('version'), source: field('source'),
      sha256: /^      sha256: ["']?([a-f0-9]{64})/m.exec(match[2])?.[1],
      url: /^      url: ["']?([^"'\r\n]+)/m.exec(match[2])?.[1] });
  }
  if (!result.size) throw Error('Dart lockfile could not be read');
  return result;
}
async function dartInventory(pins) {
  const configPath = join(root, '.dart_tool/package_config.json');
  const config = await json(configPath), graph = await json(join(root, '.dart_tool/package_graph.json'));
  const locked = lockPackages(await readFile(join(root, 'pubspec.lock'), 'utf8'));
  const packages = new Map(graph.packages.map(value => [value.name, value]));
  const runtime = new Set();
  function visit(name) {
    if (runtime.has(name)) return;
    const value = packages.get(name);
    if (!value) throw Error(`Missing resolved Dart package: ${name}`);
    runtime.add(name);
    for (const next of value.dependencies ?? []) visit(next);
  }
  visit('vnote_mobile');
  const results = [];
  for (const name of [...runtime].sort()) {
    if (['vnote_mobile', 'vxcore_bridge'].includes(name)) continue;
    const entry = config.packages.find(value => value.name === name), lock = locked.get(name);
    if (!entry || !lock || packages.get(name).version !== lock.version) throw Error(`Dart lock/config mismatch: ${name}`);
    const directory = fileURLToPath(new URL(entry.rootUri, pathToFileURL(configPath)));
    let files = await licenseFiles(directory);
    let base = directory;
    if (!files.length && lock.source === 'sdk' && name.startsWith('flutter')) {
      base = resolve(directory, '../..'); files = await licenseFiles(base);
    }
    const texts = await Promise.all(files.map(file => evidence(join(base, file), `${name}/${file}`)));
    // archive's upstream distribution omits some bundled-library notices; the
    // existing audited app license supplement is already used by Flutter.
    if (name === 'archive' && lock.version === '4.6.0') texts.push(await evidence(join(root, 'apps/vnote_mobile/licenses/archive-4.6.0.txt')));
    if (!texts.length) throw Error(`Missing Dart runtime license: ${name}`);
    const licenses = identify(texts.map(value => value.text).join('\n'), name);
    if (lock.source !== 'sdk' && (lock.source !== 'hosted' || !lock.sha256 || lock.url !== 'https://pub.dev')) throw Error(`Unpinned Dart runtime source: ${name}`);
    results.push({ ecosystem: 'pub', name, version: lock.version, licenses,
      source: lock.source === 'sdk' ? `https://github.com/flutter/flutter/tree/${pins.flutter.revision}` : `https://pub.dev/packages/${name}/versions/${lock.version}`,
      integrity: lock.sha256 ?? pins.flutter.revision, evidence: texts });
  }
  const flutterPackage = config.packages.find(value => value.name === 'flutter');
  if (!flutterPackage) throw Error('Flutter SDK package is unresolved');
  const flutterRoot = resolve(fileURLToPath(new URL(flutterPackage.rootUri, pathToFileURL(configPath))), '../..');
  const engineRevision = (await readFile(join(flutterRoot, 'bin/internal/engine.version'), 'utf8')).trim();
  if (!/^[a-f0-9]{40}$/.test(engineRevision)) throw Error('Invalid pinned Flutter engine revision');
  const sky = config.packages.find(value => value.name === 'sky_engine');
  if (!sky) throw Error('Flutter engine aggregate license package is unresolved');
  const skyRoot = fileURLToPath(new URL(sky.rootUri, pathToFileURL(configPath)));
  const engineEvidence = await evidence(join(skyRoot, 'LICENSE'), 'Flutter-engine/LICENSE');
  identify(engineEvidence.text, 'Flutter engine');
  return { components: results, engineRevision, engineEvidence, frameworkRevision: pins.flutter.revision };
}
function xmlValue(xml, tag) {
  return new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${tag}>`).exec(xml)?.[1]?.trim()
    .replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
}
async function mavenInventory(path, dart) {
  const input = await json(path);
  if (input.schema !== 1 || input.configuration !== 'releaseRuntimeClasspath' || !input.components?.length) throw Error('Actual release Maven resolution is required');
  const lockText = await readFile(join(root, 'apps/vnote_mobile/android/app/gradle.lockfile'), 'utf8');
  const lockedRuntime = lockText.split(/\r?\n/).filter(line => !line.startsWith('#') && line.split('=')[1]?.split(',').includes('releaseRuntimeClasspath'))
    .map(line => line.split('=')[0]).filter(value => value !== 'empty').sort();
  const resolvedRuntime = input.components.map(value => value.coordinate).sort();
  if (JSON.stringify(lockedRuntime) !== JSON.stringify(resolvedRuntime)) throw Error('Resolved Maven runtime graph differs from its reviewed dependency lock');
  const verification = await readFile(join(root, 'apps/vnote_mobile/android/gradle/verification-metadata.xml'), 'utf8');
  if (!verification.includes('<verify-metadata>true</verify-metadata>')) throw Error('Gradle verification must include metadata');
  const verified = new Map();
  for (const match of verification.matchAll(/<component group="([^"]+)" name="([^"]+)" version="([^"]+)">([\s\S]*?)<\/component>/g)) {
    const files = new Map();
    for (const artifact of match[4].matchAll(/<artifact name="([^"]+)">([\s\S]*?)<\/artifact>/g)) {
      files.set(artifact[1], new Set([...artifact[2].matchAll(/<(?:sha256|also-trust) value="([a-f0-9]{64})"/g)].map(value => value[1])));
    }
    verified.set(`${match[1]}:${match[2]}:${match[3]}`, files);
  }
  const verifyHash = (coordinate, name, hash) => {
    if (!verified.get(coordinate)?.get(name)?.has(hash)) throw Error(`Missing exact Gradle verification evidence: ${coordinate}/${name}`);
  };
  const apache = await evidence(join(root, 'packages/editor_web/node_modules/notice-chevrotain/LICENSE.txt'), 'Apache-2.0 actual pinned npm license body');
  if (apache.sha256 !== 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30') throw Error('Audited Apache license body changed');
  const pomCache = new Map();
  async function pom(coordinate, seen = new Set()) {
    if (seen.has(coordinate)) throw Error('Maven parent cycle');
    if (pomCache.has(coordinate)) return pomCache.get(coordinate);
    seen.add(coordinate);
    const location = input.poms[coordinate];
    if (!location) throw Error(`Missing resolved POM: ${coordinate}`);
    const bytes = await readFile(location), text = bytes.toString('utf8');
    verifyHash(coordinate, location.split(/[\\/]/).at(-1), sha256(bytes));
    if (/<!DOCTYPE|<!ENTITY/i.test(text)) throw Error('Unsafe POM metadata');
    const parent = xmlValue(text, 'parent');
    const inherited = parent ? await pom(['groupId', 'artifactId', 'version'].map(tag => xmlValue(parent, tag)).join(':'), seen) : null;
    const value = { hash: sha256(bytes), licenses: xmlValue(text, 'licenses') ?? inherited?.licenses,
      source: xmlValue(xmlValue(text, 'scm') ?? '', 'url') ?? inherited?.source ?? xmlValue(text, 'url') };
    pomCache.set(coordinate, value); return value;
  }
  const results = [];
  for (const item of [...input.components].sort((a, b) => a.coordinate.localeCompare(b.coordinate, 'en'))) {
    const [group, name, version, extra] = item.coordinate.split(':');
    if (extra || !group || !name || !version || !lockText.split(/\r?\n/).some(line => line.startsWith(`${item.coordinate}=`) && line.split('=')[1].split(',').includes('releaseRuntimeClasspath'))) throw Error(`Unlocked Maven runtime component: ${item.coordinate}`);
    const metadata = await pom(item.coordinate), texts = [], artifacts = [];
    for (const artifact of item.artifacts) {
      const bytes = await readFile(artifact.path), hash = sha256(bytes);
      if (hash !== artifact.sha256) throw Error(`Resolved Maven artifact changed: ${item.coordinate}/${artifact.name}`);
      verifyHash(item.coordinate, artifact.name, hash);
      artifacts.push({ name: artifact.name, sha256: hash });
      const members = zipEntries(bytes);
      for (const [member, entry] of members) {
        if (/(?:^|\/)(?:licen[sc]e|notice|copying)(?:[._-][^/]*)?$/i.test(member) && entry.size < 16 * 1024 * 1024) {
          const body = entry.read(); texts.push({ name: `${artifact.name}!/${member}`, sha256: sha256(body), text: body.toString('utf8') });
        }
        if (member === 'classes.jar') {
          for (const [nestedName, nested] of zipEntries(entry.read())) if (/(?:^|\/)(?:licen[sc]e|notice|copying)(?:[._-][^/]*)?$/i.test(nestedName)) {
            const body = nested.read(); texts.push({ name: `${artifact.name}!/classes.jar!/${nestedName}`, sha256: sha256(body), text: body.toString('utf8') });
          }
        }
      }
    }
    // Flutter publishes POMs without license declarations. Match the exact SDK
    // engine revision and known artifact family, then retain its real full notice.
    const flutter = group === 'io.flutter' && /^(flutter_embedding_release|arm64_v8a_release|x86_64_release)$/.test(name) && version === `1.0.0-${dart.engineRevision}`;
    if (flutter) texts.push(dart.engineEvidence);
    const declared = metadata.licenses ?? '';
    if (!flutter && !declared) throw Error(`Maven runtime license declaration is missing: ${item.coordinate}`);
    if (/https?:\/\/(?:www\.)?apache\.org\/licenses\/LICENSE-2\.0(?:\.txt)?/.test(declared)) texts.push(apache);
    if (!texts.length) throw Error(`Maven runtime license body is missing: ${item.coordinate}`);
    const licenses = identify(texts.map(value => value.text).join('\n'), item.coordinate);
    if (!flutter) {
      const declarations = [...declared.matchAll(/<license>([\s\S]*?)<\/license>/g)];
      if (!declarations.length) throw Error(`Missing Maven license declarations: ${item.coordinate}`);
      for (const [, declaration] of declarations) {
        const name = xmlValue(declaration, 'name') ?? '', url = xmlValue(declaration, 'url') ?? '';
        const kind = /apache\.org\/licenses\/LICENSE-2\.0|Apache.*2\.0/i.test(`${name} ${url}`) ? 'Apache-2.0'
          : /\bMIT\b|opensource\.org\/licenses\/MIT/i.test(`${name} ${url}`) ? 'MIT'
          : /\bBSD\b/i.test(`${name} ${url}`) ? 'BSD'
          : /\bISC\b/i.test(`${name} ${url}`) ? 'ISC' : null;
        if (!kind || !licenses.some(value => value === kind || kind === 'BSD' && value.startsWith('BSD-'))) {
          throw Error(`Unsupported or unproved Maven runtime license: ${item.coordinate}`);
        }
      }
    }
    if (!flutter && (!metadata.source || metadata.source.includes('${') || !/^https?:\/\//.test(metadata.source))) throw Error(`Maven source provenance is missing: ${item.coordinate}`);
    results.push({ ecosystem: 'maven', name: `${group}:${name}`, version, licenses,
      source: flutter ? `https://github.com/flutter/flutter/tree/${dart.frameworkRevision}/engine/src/flutter` : metadata.source,
      pomSha256: metadata.hash, artifacts, evidence: texts });
  }
  return results;
}
async function nativeInventory(paths, pins) {
  if (!paths.length) throw Error('Provide --native <configured mobile CMake build directory> for actual built-source notices');
  const results = new Map(), declarations = await readFile(join(root, 'third_party/vxcore/third_party/CMakeLists.txt'), 'utf8');
  const sourcePins = { core: pins.core, openssl: pins.openssl, utf8proc: pins.utf8proc,
    cmakeSha256: sha256(declarations), fetched: [...declarations.matchAll(/URL (https:\/\/[^\s]+)\s+URL_HASH SHA256=([a-f0-9]{64})/g)].map(match => ({ url: match[1], sha256: match[2] })),
    sodium: /GIT_REPOSITORY (https:\/\/[^\s]+)\s+GIT_TAG ([a-f0-9]{40})/.exec(declarations)?.slice(1),
    sodiumCoreRevision: /official libsodium at ([a-f0-9]{40})/.exec(declarations)?.[1] };
  if (sourcePins.fetched.length !== 2 || !sourcePins.sodium || !sourcePins.sodiumCoreRevision) throw Error('Native source pins changed; audit the updated source graph');
  const revision = directory => {
    const result = spawnSync('git', ['-C', directory, 'rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
    if (result.status !== 0 || !/^[a-f0-9]{40}$/.test(result.stdout.trim())) throw Error('Native source revision is unavailable');
    return result.stdout.trim();
  };
  if (revision('third_party/vxcore') !== pins.core.revision) throw Error('Native core source differs from the reviewed pin');
  sourcePins.cmarkRevision = revision('third_party/vxcore/third_party/cmark');
  sourcePins.libgit2Revision = revision('third_party/vxcore/third_party/libgit2');
  sourcePins.vendoredSha256 = {};
  for (const file of ['sqlite/sqlite3.c', 'nlohmann/json.hpp', 'BS_thread_pool/BS_thread_pool.hpp']) {
    sourcePins.vendoredSha256[file] = sha256(await readFile(join(root, 'third_party/vxcore/third_party', file)));
  }
  function nativeVersion(label) {
    if (label === 'vxcore (MIT)') return pins.core.revision;
    if (label.startsWith('VNote cmark')) return sourcePins.cmarkRevision;
    if (label.startsWith('libgit2 ')) return sourcePins.libgit2Revision;
    if (label === 'libsodium CMake adapter') return sourcePins.sodium[1];
    if (label === 'libsodium') return sourcePins.sodiumCoreRevision;
    if (label === 'pugixml') return /pugixml-(\d+\.\d+)\.tar/.exec(sourcePins.fetched.find(value => value.url.includes('pugixml')).url)[1];
    if (label === 'libcurl') return /curl-(\d+\.\d+\.\d+)\.tar/.exec(sourcePins.fetched.find(value => value.url.includes('/curl/')).url)[1];
    if (label.startsWith('utf8proc ')) return pins.utf8proc.version;
    if (label.startsWith('OpenSSL ')) return pins.openssl.version;
    if (label.startsWith('Android NDK ')) return pins.android.ndk;
    if (label.startsWith('nlohmann/json 3.11.3 ')) return '3.11.3';
    if (label.startsWith('BS::thread_pool 5.1.0 ')) return '5.1.0';
    if (label.startsWith('SQLite 3.47.2 ')) return '3.47.2';
    throw Error(`Unknown native runtime component: ${label}`);
  }
  for (const path of paths) {
    const input = await json(join(resolve(root, path), 'native-dependencies.json'));
    if (input.schema !== 1 || !['Android', 'iOS'].includes(input.system) || !input.notices?.length) throw Error('Configured mobile native source inventory required');
    if (input.producerSha256 !== sha256(await readFile(join(root, 'packages/vxcore_bridge/native/CMakeLists.txt')))
        || input.declarationsSha256 !== sourcePins.cmakeSha256) throw Error('Native dependency inventory is stale; configure the actual mobile target');
    for (const notice of input.notices) {
      const body = await evidence(notice.path, notice.label);
      if (body.sha256 !== notice.sha256) throw Error(`Native notice drift: ${notice.label}`);
      const key = `${notice.label}:${body.sha256}`;
      if (!results.has(key)) results.set(key, { ecosystem: 'native', name: notice.label, version: nativeVersion(notice.label),
        licenses: identify(body.text, notice.label), source: sourcePins, evidence: [body], platforms: [] });
      const value = results.get(key), platform = `${input.system}/${input.architecture}`;
      if (!value.platforms.includes(platform)) value.platforms.push(platform);
    }
  }
  return [...results.values()].sort((a, b) => a.name.localeCompare(b.name, 'en'));
}
async function publish(path, bytes, check) {
  if (check) {
    let actual; try { actual = await readFile(path); } catch { throw Error(`Missing generated notice artifact: ${portable(relative(root, path))}`); }
    if (!actual.equals(bytes)) throw Error(`Stale generated notice artifact: ${portable(relative(root, path))}`);
    return;
  }
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}`;
  try { await writeFile(temporary, bytes); await rename(temporary, path); } finally { await rm(temporary, { force: true }); }
}
async function main() {
  const args = process.argv.slice(2), native = [];
  let check = false, maven = join(root, '.tools/notices/android-runtime.json');
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--check') check = true;
    else if (args[i] === '--native' && args[i + 1]) native.push(args[++i]);
    else if (args[i] === '--maven' && args[i + 1]) maven = resolve(root, args[++i]);
    else throw Error('Usage: dependency_notices.mjs [--check] --native <CMake build directory> [--native <other ABI>] [--maven <resolved input.json>]');
  }
  const pins = await json(join(root, 'toolchains.json'));
  if (process.versions.node !== pins.node) throw Error(`Node ${pins.node} required`);
  const npm = await json(join(root, '.tools/notices/npm-runtime.json'));
  if (npm.schema !== 1 || npm.lockSha256 !== sha256(await readFile(join(root, 'packages/editor_web/package-lock.json')))) throw Error('npm notices differ from the current lock; run the editor build');
  if (npm.producerSha256 !== sha256(await readFile(join(root, 'packages/editor_web/build.mjs')))) throw Error('npm notice producer changed; run the editor build');
  for (const notice of npm.notices) {
    if (!['editor', 'preview'].includes(notice.name)
        || sha256(Buffer.from(notice.text)) !== sha256(await readFile(join(root, `apps/vnote_mobile/assets/${notice.name}/NOTICE.txt`)))) throw Error('npm notice artifact differs from audited evidence');
  }
  const dart = await dartInventory(pins);
  const components = [...dart.components, ...npm.components, ...await nativeInventory(native, pins), ...await mavenInventory(maven, dart)]
    .sort((a, b) => `${a.ecosystem}:${a.name}@${a.version}`.localeCompare(`${b.ecosystem}:${b.name}@${b.version}`, 'en'));
  for (const component of components) for (const body of component.evidence) if (sha256(Buffer.from(body.text)) !== body.sha256) throw Error(`License evidence changed: ${component.name}`);
  const inputs = {};
  for (const path of ['pubspec.lock', 'packages/editor_web/package-lock.json', 'toolchains.json',
    'packages/editor_web/build.mjs', 'packages/vxcore_bridge/native/CMakeLists.txt', 'scripts/dependency_notices.mjs',
    'apps/vnote_mobile/android/app/build.gradle.kts', 'apps/vnote_mobile/android/app/gradle.lockfile',
    'apps/vnote_mobile/android/gradle/verification-metadata.xml']) inputs[path] = sha256(await readFile(join(root, path)));
  const inventory = { schema: 1, inputs, components };
  const applicationVersion = /^version:\s*([^\s]+)$/m.exec(await readFile(join(root, 'apps/vnote_mobile/pubspec.yaml'), 'utf8'))?.[1];
  if (!applicationVersion) throw Error('Application version is missing');
  const sbom = { bomFormat: 'CycloneDX', specVersion: '1.6', version: 1,
    metadata: { component: { type: 'application', name: 'VNote Mobile', version: applicationVersion } },
    components: components.map(value => ({ type: 'library', name: value.name, version: value.version,
      'bom-ref': `${value.ecosystem}:${value.name}:${value.version}:${value.evidence[0].sha256}`,
      ...(value.ecosystem === 'npm' ? { purl: `pkg:npm/${value.name.replace('@', '%40')}@${value.version}` } : {}),
      licenses: (value.licenses ?? [value.license]).filter(Boolean).map(name => ({ license: { name } })),
      hashes: value.artifacts?.map(artifact => ({ alg: 'SHA-256', content: artifact.sha256 })) ?? [],
      properties: value.evidence.map(body => ({ name: `vnote:license-evidence:${body.name}`, value: body.sha256 })) })) };
  const notices = ['VNote Mobile — dependency licenses and corresponding-source notices\n\n'
    + 'Application: GNU LGPL version 3 only. Full application terms accompany this file in COPYING.LESSER and COPYING.\n'
    + 'This inventory is evidence, not legal or store clearance. See docs/dependency-notices.md and docs/mobile-release.md in the corresponding source.\n'
    + 'Retain the complete corresponding source, modifications, toolchain pins, build scripts, and material needed to rebuild/relink the LGPL application with modified components.\n'];
  const seenBodies = new Set();
  for (const value of components) {
    notices.push(`\n===== ${value.ecosystem}: ${value.name}@${value.version} =====\nSource: ${typeof value.source === 'string' ? value.source : JSON.stringify(value.source)}\n`);
    for (const body of value.evidence) {
      notices.push(`Evidence: ${body.name}; SHA-256 ${body.sha256}\n`);
      if (seenBodies.has(body.sha256)) notices.push(`Complete text appears earlier under the same SHA-256.\n`);
      else { notices.push(`${body.text}\n`); seenBodies.add(body.sha256); }
    }
  }
  // Includes fonts and audited embedded/transformed JS not exposed as packages.
  for (const value of npm.notices) notices.push(`\n===== Complete ${value.name} embedded runtime/font notices =====\n${value.text}\n`);
  const outputs = new Map([
    ['apps/vnote_mobile/assets/legal/DEPENDENCIES.txt', Buffer.from(notices.join(''))],
    ['.tools/notices/dependency-inventory.json', Buffer.from(JSON.stringify(inventory, null, 2) + '\n')],
    ['.tools/notices/sbom.cdx.json', Buffer.from(JSON.stringify(sbom, null, 2) + '\n')],
  ]);
  for (const [path, bytes] of outputs) {
    if (bytes.includes(Buffer.from(root)) || bytes.includes(Buffer.from(portable(root)))) throw Error('Private build path entered dependency outputs');
    await publish(join(root, path), bytes, check);
  }
  console.log(check ? 'Dependency inventory and real license bodies match locked inputs.' : 'Generated DEPENDENCIES.txt, dependency-inventory.json and sbom.cdx.json; no legal/store clearance asserted.');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch (error) { console.error(`Dependency notice gate: ${error.message}`); process.exitCode = 1; }
}
