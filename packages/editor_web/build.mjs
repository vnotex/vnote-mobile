// SPDX-License-Identifier: LGPL-3.0-only
import { build, version as esbuildVersion } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFile, readdir, mkdir, rename, rm, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const packageDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(packageDir, '../..');
const args = process.argv.slice(2);
if (args.length > 1 || (args.length && !['--check', '--test'].includes(args[0]))) {
  throw new Error('Usage: node build.mjs [--check|--test]');
}
const pins = JSON.parse(await readFile(join(root, 'toolchains.json'), 'utf8'));
if (process.versions.node !== pins.node) throw new Error(`Node ${pins.node} is required.`);
const packageJson = JSON.parse(await readFile(join(packageDir, 'package.json'), 'utf8'));
if (esbuildVersion !== packageJson.devDependencies.esbuild) throw new Error('Installed esbuild differs from the exact package pin.');

if (args[0] === '--test') {
  // Compile the real pure module and its behavioral tests, then use Node's runner.
  // A temporary directory is removed even when compilation or a test fails.
  const temporary = await mkdtemp(join(tmpdir(), 'vnote-editor-test-'));
  try {
    const target = join(temporary, 'protocol.test.mjs');
    const compiled = await build({ absWorkingDir: packageDir, entryPoints: ['test/protocol.test.ts'],
      bundle: true, platform: 'node', target: 'node24', format: 'esm', write: false,
      outfile: 'protocol.test.mjs', sourcemap: false, legalComments: 'none' });
    await writeFile(target, compiled.outputFiles[0].contents);
    const result = spawnSync(process.execPath, ['--test', target], { stdio: 'inherit' });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
  } finally { await rm(temporary, { recursive: true, force: true }); }
} else {
  await buildAssets(args[0] === '--check');
}

function portable(path) { return path.split(sep).join('/'); }
function sha256(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
async function dependencyFor(input) {
  let current = dirname(resolve(packageDir, input));
  const nodeModules = join(packageDir, 'node_modules') + sep;
  if (!current.startsWith(nodeModules)) throw new Error(`Unexpected bundled dependency input: ${input}`);
  while (current.startsWith(nodeModules)) {
    try {
      const metadata = JSON.parse(await readFile(join(current, 'package.json'), 'utf8'));
      if (metadata.name && metadata.version) return { directory: current, metadata };
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    current = dirname(current);
  }
  throw new Error(`Cannot identify bundled dependency: ${input}`);
}
async function runtimeNotices(metafile) {
  const bundled = new Set();
  for (const output of Object.values(metafile.outputs)) {
    for (const [input, contribution] of Object.entries(output.inputs)) {
      if (contribution.bytesInOutput > 0 && input.includes('node_modules/')) bundled.add(input);
    }
  }
  if (!bundled.size) throw new Error('No bundled runtime dependency metadata was found.');
  const packages = new Map();
  for (const input of [...bundled].sort()) {
    const dependency = await dependencyFor(input);
    packages.set(`${dependency.metadata.name}@${dependency.metadata.version}`, dependency);
  }
  const notices = [
    'VNote Mobile editor validation\nApplication source: GNU LGPL version 3 only.\n'
      + 'See the accompanying legal/COPYING.LESSER and legal/COPYING.\n'
      + 'The following bundled runtime dependencies retain their own licenses.\n',
  ];
  for (const [name, { directory, metadata }] of [...packages].sort(([a], [b]) => a.localeCompare(b, 'en'))) {
    if (Object.hasOwn(packageJson.devDependencies, metadata.name)) throw new Error(`Development dependency was bundled: ${name}`);
    if (metadata.license !== 'MIT') throw new Error(`Review the runtime license before bundling ${name}: ${metadata.license}`);
    const files = (await readdir(directory)).filter(file => /^licen[sc]e(?:\.(?:txt|md))?$/i.test(file)).sort();
    if (!files.length) throw new Error(`Missing license text for bundled runtime dependency ${name}`);
    const texts = [];
    for (const file of files) {
      const text = await readFile(join(directory, file), 'utf8');
      if (!text.includes('Permission is hereby granted') || !text.includes('THE SOFTWARE IS PROVIDED')) {
        throw new Error(`Incomplete MIT license text for ${name}`);
      }
      texts.push(text);
    }
    notices.push(`\n===== ${name} (MIT) =====\n${texts.join('\n')}\n`);
  }
  return notices.join('');
}
async function buildAssets(check) {
  const result = await build({
    absWorkingDir: packageDir, entryPoints: ['src/editor.ts'], bundle: true,
    platform: 'browser', target: 'es2022', format: 'iife', write: false,
    outfile: 'editor.js', minify: true, charset: 'utf8', sourcemap: false,
    legalComments: 'none', metafile: true,
    banner: { js: '/* VNote Mobile editor: LGPL-3.0-only. Bundled dependency licenses: NOTICE.txt. */' },
  });
  if (result.outputFiles.length !== 1) throw new Error('Expected one offline JavaScript bundle.');
  const outputs = new Map([
    ['apps/vnote_mobile/assets/editor/index.html', await readFile(join(packageDir, 'src/index.html'))],
    ['apps/vnote_mobile/assets/editor/editor.css', await readFile(join(packageDir, 'src/editor.css'))],
    ['apps/vnote_mobile/assets/editor/editor.js', Buffer.from(result.outputFiles[0].contents)],
    ['apps/vnote_mobile/assets/editor/NOTICE.txt', Buffer.from(await runtimeNotices(result.metafile))],
    ['apps/vnote_mobile/assets/legal/COPYING', await readFile(join(root, 'COPYING'))],
    ['apps/vnote_mobile/assets/legal/COPYING.LESSER', await readFile(join(root, 'COPYING.LESSER'))],
  ]);
  const sourcePaths = [
    '.node-version', 'toolchains.json', 'pubspec.yaml', 'pubspec.lock', 'COPYING', 'COPYING.LESSER',
    'apps/vnote_mobile/pubspec.yaml',
    'packages/editor_web/package.json', 'packages/editor_web/package-lock.json',
    'packages/editor_web/tsconfig.json', 'packages/editor_web/build.mjs',
    'packages/editor_web/src/protocol.ts', 'packages/editor_web/src/editor.ts',
    'packages/editor_web/src/index.html', 'packages/editor_web/src/editor.css',
    'packages/editor_web/test/protocol.test.ts',
  ].sort();
  const sources = {};
  for (const path of sourcePaths) sources[path] = sha256(await readFile(join(root, path)));
  // The manifest does not hash itself. Every emitted payload and every build input
  // above is hashed; no timestamps, host paths, or nondeterministic identifiers.
  const manifest = {
    version: 1, node: pins.node, npm: pins.npm, esbuild: esbuildVersion,
    sources,
    outputs: Object.fromEntries([...outputs].sort(([a], [b]) => a.localeCompare(b, 'en'))
      .map(([path, bytes]) => [path, sha256(bytes)])),
  };
  outputs.set('apps/vnote_mobile/assets/editor/manifest.json', Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  const privatePath = portable(root);
  for (const [path, bytes] of outputs) {
    if (bytes.includes(Buffer.from(privatePath)) || bytes.includes(Buffer.from(root))) {
      throw new Error(`Private build path leaked into ${path}`);
    }
  }
  if (check) {
    const stale = [];
    for (const [path, expected] of outputs) {
      try { if (!(await readFile(join(root, path))).equals(expected)) stale.push(path); }
      catch (error) { if (error.code === 'ENOENT') stale.push(path); else throw error; }
    }
    if (stale.length) throw new Error(`Missing or stale generated assets; run npm run build:\n${stale.join('\n')}`);
    console.log('Editor assets and exact license texts match deterministic build inputs.');
    return;
  }
  for (const [path, bytes] of outputs) {
    const destination = join(root, path);
    const fromRoot = relative(root, destination);
    if (isAbsolute(fromRoot) || fromRoot.startsWith('..')) throw new Error('Output escaped the repository.');
    await mkdir(dirname(destination), { recursive: true });
    const temporary = `${destination}.tmp-${process.pid}`;
    try { await writeFile(temporary, bytes); await rename(temporary, destination); }
    finally { await rm(temporary, { force: true }); }
  }
  console.log('Built offline editor assets, dependency notices, exact legal texts, and input/output hash manifest.');
}
