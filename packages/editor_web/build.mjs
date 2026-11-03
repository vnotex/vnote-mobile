// SPDX-License-Identifier: LGPL-3.0-only
import { build, version as esbuildVersion } from 'esbuild';
import * as css from 'css-tree';
import { createHash } from 'node:crypto';
import { readFile, readdir, mkdir, rename, rm, mkdtemp, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
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
const lock = JSON.parse(await readFile(join(packageDir, 'package-lock.json'), 'utf8'));
if (esbuildVersion !== packageJson.devDependencies.esbuild) throw new Error('Installed esbuild differs from the exact package pin.');

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
async function embeddedDependency(name, version) {
  // Upstream Mermaid core/parser modules contain explicit embedded package/version
  // provenance comments. Exact notice-only dev aliases retain those licenses even
  // when npm does not expose the embedded packages as runtime dependencies.
  if (!Object.entries(packageJson.devDependencies).some(([alias, pin]) => alias.startsWith('notice-') && pin === `npm:${name}@${version}`)) {
    throw new Error(`Unaudited embedded runtime dependency ${name}@${version}`);
  }
  for (const [path, metadata] of Object.entries(lock.packages)) {
    if (!path || metadata.version !== version) continue;
    const effectiveName = metadata.name ?? path.slice(path.lastIndexOf('node_modules/') + 13);
    if (effectiveName !== name) continue;
    const directory = join(packageDir, path);
    const installed = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
    if (installed.name === name && installed.version === version) return { directory, metadata: installed };
  }
  throw new Error(`Missing exact embedded runtime notice dependency ${name}@${version}`);
}
const licenseMarkers = new Map([
  ['MIT', [/Permission is hereby granted/i, /THE SOFTWARE IS PROVIDED/i]],
  ['ISC', [/Permission to use, copy, modify, and\/or distribute/i, /THE SOFTWARE IS PROVIDED/i]],
  ['BSD-2-Clause', [/Redistribution and use in source and binary forms/i, /THIS(?: SOFTWARE)? IS PROVIDED/i]],
  ['BSD-3-Clause', [/Redistribution and use in source and binary forms/i, /Neither the name|names of its contributors/i, /THIS SOFTWARE IS PROVIDED/i]],
  ['Apache-2.0', [/Apache License/i, /Version 2\.0, January 2004/i, /END OF TERMS AND CONDITIONS/i]],
  ['CC0-1.0', [/CC0 1\.0 Universal/i, /No Copyright|Waiver/i]],
  ['Unlicense', [/free and unencumbered software released into the public domain/i, /THE SOFTWARE IS PROVIDED/i]],
]);
async function runtimeNotices(metafile) {
  const bundled = new Set();
  for (const output of Object.values(metafile.outputs)) for (const [input, contribution] of Object.entries(output.inputs)) {
    if (contribution.bytesInOutput > 0 && input.includes('node_modules/')) bundled.add(input);
  }
  if (!bundled.size) throw new Error('No bundled runtime dependency metadata was found.');
  const packages = new Map();
  let babelHelpers = false;
  const reactAdaptations = new Set();
  for (const input of [...bundled].sort()) {
    const dependency = await dependencyFor(input);
    const key = `${dependency.metadata.name}@${dependency.metadata.version}`;
    if (Object.hasOwn(packageJson.devDependencies, dependency.metadata.name) || /(?:^|\/)node_modules\/notice-/.test(input)) {
      throw new Error(`Development or audit-only dependency bundled directly: ${key}`);
    }
    packages.set(key, dependency);
    const source = await readFile(resolve(packageDir, input), 'utf8');
    if (source.includes('regenerator-runtime -- Copyright (c) 2014-present, Facebook, Inc.')) {
      if (key !== 'dompurify@3.4.17' || sha256(Buffer.from(source)) !== '60c5d5ccbb466de3de3ba863461a92bf134f8c156cef7992da43e0f659bc5cbd') {
        throw new Error('Unreviewed embedded Babel helper provenance.');
      }
      babelHelpers = true;
    }
    if (source.includes("hyphenate and escape adapted from Facebook's React under Apache 2 license")) {
      const audited = new Map([
        ['katex@0.19.1', '5f0c3749f8b28ce1a63b68de34d3950bb4aa1a9e0130865e4b09ecc9a250c8b7'],
        ['katex@0.16.47', '09a78a9812d1e7d3ace85033512e6a450127b9554ef281b4b6567408694c6e36'],
      ]);
      if (audited.get(key) !== sha256(Buffer.from(source))) throw new Error('Unreviewed React adaptation provenance.');
      reactAdaptations.add(key);
    }
    const provenance = /^\/\/ .*node_modules\/\.pnpm\/([^/]+)\/node_modules\/((?:@[^/]+\/)?[^/]+)\//gm;
    for (const match of source.matchAll(provenance)) {
      const version = match[1].slice(match[1].lastIndexOf('@') + 1).split('_')[0];
      // Peer suffixes can contain @; recover the package's own exact version.
      const own = new RegExp(`^${match[2].replace('/', '+').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}@([^_]+)`).exec(match[1]);
      const exactVersion = own?.[1] ?? version;
      const embedded = await embeddedDependency(match[2], exactVersion);
      packages.set(`${match[2]}@${exactVersion}`, embedded);
    }
  }
  const notices = ['VNote Mobile source editor and isolated preview\nApplication source: GNU LGPL version 3 only.\n'
    + 'See accompanying legal/COPYING.LESSER and legal/COPYING.\n'
    + 'Bundled runtime dependencies and fonts retain the following licenses.\n'];
  for (const [name, { directory, metadata }] of [...packages].sort(([a], [b]) => a.localeCompare(b, 'en'))) {
    let license = metadata.license;
    if (name.startsWith('dompurify@') && license === '(MPL-2.0 OR Apache-2.0)') license = 'Apache-2.0';
    const files = (await readdir(directory)).filter(file => /^(?:licen[sc]e(?:[-.][\w.-]+)?|copying(?:\.\w+)?|notice(?:\.\w+)?)$/i.test(file)
      && !(metadata.name === 'dompurify' && /MPL/i.test(file))).sort();
    const texts = await Promise.all(files.map(file => readFile(join(directory, file), 'utf8')));
    // This pinned package publishes its complete MIT grant only in README.md.
    if (!texts.length && name === 'fastdom@1.0.12' && license === 'MIT') {
      const section = /^## License\r?\n([\s\S]+)$/m.exec(await readFile(join(directory, 'README.md'), 'utf8'));
      if (section) texts.push(section[1].trim());
    }
    if (!texts.length) throw new Error(`Missing license text for bundled runtime dependency ${name}`);
    // khroma 2.1.0 omits package metadata, but ships this audited exact MIT text.
    if (!license && name === 'khroma@2.1.0' && files.length === 1
      && sha256(Buffer.from(texts[0])) === '66b333b0f66759a0b710459e03f7029abe17f4358114a128d2c972e642961b49') license = 'MIT';
    const markers = licenseMarkers.get(license);
    const combined = texts.join('\n');
    if (!markers || markers.some(marker => !marker.test(combined))) throw new Error(`Unsupported or incomplete runtime license for ${name}: ${license}`);
    notices.push(`\n===== ${name} (${license}) =====\n${combined}\n`);
  }
  if (babelHelpers) {
    if (sha256(Buffer.from(babelHelperLicense)) !== '4be9d87b56a306293223b490c0d0b245e9e94f39884147bf051a6c7b825aeb30') throw new Error('Embedded helper license text drift.');
    notices.push('\n===== Babel/regenerator helpers embedded in DOMPurify 3.4.17 (MIT) =====\n' + babelHelperLicense);
  }
  if (reactAdaptations.size) {
    const apache = await readFile(join(packageDir, 'node_modules/notice-chevrotain/LICENSE.txt'));
    if (sha256(apache) !== 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30') throw new Error('Apache license text drift.');
    notices.push(`\n===== React utility adaptations in ${[...reactAdaptations].sort().join(', ')} (Apache-2.0) =====\n`
      + "hyphenate and escape adapted from Facebook's React under Apache 2 license.\n"
      + 'These utilities were modified by upstream KaTeX; this attribution is retained from its source.\n' + apache.toString('utf8'));
  }
  return notices.join('');
}

// Exact helper license from the URL identified by the shipped DOMPurify notice:
// https://raw.githubusercontent.com/babel/babel/a0690e39ea63cdcc3d9282ece739e6677c83ad6e/packages/babel-helpers/LICENSE
const babelHelperLicense = `MIT License

Copyright (c) 2014-present Sebastian McKenzie and other contributors
Copyright (c) 2014-present, Facebook, Inc. (ONLY ./src/helpers/regenerator* files)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
`;

// Native iOS floor is Safari 15.0. Upstream Mermaid 11 uses these built-ins;
// syntax targeting alone cannot supply them. Only missing built-ins are defined.
// structuredClone covers the real graph data types, preserves cycles, and refuses
// unsupported transferable/host/function/symbol values rather than JSON-coercing.
const browserCompatibility = `(()=>{
if(!Object.hasOwn)Object.defineProperty(Object,'hasOwn',{configurable:true,writable:true,value:(o,k)=>{if(o==null)throw new TypeError();return Object.prototype.hasOwnProperty.call(o,k)}});
if(!Array.prototype.at)Object.defineProperty(Array.prototype,'at',{configurable:true,writable:true,value:function(i){if(this==null)throw new TypeError();const n=Math.min(Math.max(Math.trunc(Number(this.length))||0,0),Number.MAX_SAFE_INTEGER);i=Math.trunc(Number(i)||0);const k=i<0?n+i:i;return k<0||k>=n?undefined:this[k]}});
if(!globalThis.structuredClone)Object.defineProperty(globalThis,'structuredClone',{configurable:true,writable:true,value:(value,options)=>{
const bad=()=>{throw new DOMException('Unsupported clone value','DataCloneError')};if(options?.transfer?.length)bad();const seen=new Map();
const copy=v=>{if(typeof v==='function'||typeof v==='symbol')return bad();if(v===null||typeof v!=='object')return v;if(seen.has(v))return seen.get(v);let out;
if(v instanceof Date)out=new Date(v.getTime());else if(v instanceof RegExp)out=new RegExp(v.source,v.flags);else if(v instanceof ArrayBuffer)out=v.slice(0);else if(ArrayBuffer.isView(v)){const b=copy(v.buffer);out=v instanceof DataView?new DataView(b,v.byteOffset,v.byteLength):new v.constructor(b,v.byteOffset,v.length)}
else if(v instanceof Map){out=new Map();seen.set(v,out);for(const [k,x]of v)out.set(copy(k),copy(x));return out}else if(v instanceof Set){out=new Set();seen.set(v,out);for(const x of v)out.add(copy(x));return out}
else{if(!Array.isArray(v)&&Object.prototype.toString.call(v)!=='[object Object]')return bad();out=Array.isArray(v)?new Array(v.length):{};seen.set(v,out);for(const k of Object.keys(v))Object.defineProperty(out,k,{value:copy(v[k]),enumerable:true,writable:true,configurable:true});return out}seen.set(v,out);return out};return copy(value)}});
})();`;

// Exact authoritative English OFL 1.1 terms. Per-font copyright and Reserved Font
// Name statements are extracted from the pinned package's font name tables below.
// Source: https://openfontlicense.org/documents/OFL.txt
const ofl = `SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
`;
function fontLicense(bytes) {
  const tables = bytes.readUInt16BE(4);
  const notices = new Set();
  for (let index = 0; index < tables; index++) {
    const record = 12 + index * 16;
    if (bytes.toString('ascii', record, record + 4) !== 'name') continue;
    const start = bytes.readUInt32BE(record + 8);
    const count = bytes.readUInt16BE(start + 2);
    const strings = start + bytes.readUInt16BE(start + 4);
    for (let name = 0; name < count; name++) {
      const at = start + 6 + name * 12;
      const platform = bytes.readUInt16BE(at), id = bytes.readUInt16BE(at + 6);
      if (![0, 13, 14].includes(id)) continue;
      const length = bytes.readUInt16BE(at + 8), offset = bytes.readUInt16BE(at + 10);
      const raw = bytes.subarray(strings + offset, strings + offset + length);
      const text = platform === 0 || platform === 3 ? new TextDecoder('utf-16be', { fatal: true }).decode(raw) : raw.toString('latin1');
      notices.add(text);
    }
  }
  const text = [...notices].sort().join('\n\n');
  if (!text.includes('Copyright') || !text.includes('Reserved Font Name KaTeX_')
    || !text.includes('SIL Open Font License, Version 1.1.')) throw new Error('Unsupported or missing KaTeX font license.');
  return text;
}
async function previewStylesAndFonts(outputs) {
  const directory = join(packageDir, 'node_modules/katex/dist');
  const files = (await readdir(join(directory, 'fonts'))).filter(file => file.endsWith('.woff2')).sort();
  if (!files.length || files.some(file => !/^KaTeX_[A-Za-z0-9]+-[A-Za-z]+\.woff2$/.test(file))) throw new Error('Unreviewed font set.');
  const fonts = [], notices = [];
  for (const file of files) {
    const bytes = await readFile(join(directory, 'fonts', file));
    if (bytes.toString('ascii', 0, 4) !== 'wOF2') throw new Error('Invalid packaged font.');
    const path = `apps/vnote_mobile/assets/preview/fonts/${file}`;
    outputs.set(path, bytes); fonts.push({ path, mime: 'font/woff2', sha256: sha256(bytes), bytes: bytes.length });
    const license = fontLicense(await readFile(join(directory, 'fonts', file.replace(/\.woff2$/, '.ttf'))));
    notices.push(`\n===== ${file} (OFL-1.1, unmodified) =====\n${license}\n`);
  }
  const ast = css.parse(await readFile(join(directory, 'katex.css'), 'utf8'), { positions: false });
  css.walk(ast, { visit: 'Declaration', enter(node) {
    if (node.property !== 'src') return;
    const urls = [];
    css.walk(node.value, item => { if (item.type === 'Url' && item.value.endsWith('.woff2')) urls.push(item.value); });
    if (urls.length !== 1 || !urls[0].startsWith('fonts/') || !files.includes(urls[0].slice(6))) throw new Error('Unmanifested font URL.');
    node.value = css.parse(`url("/${urls[0]}") format("woff2")`, { context: 'value' });
  } });
  css.walk(ast, node => {
    if (node.type === 'Atrule' && node.name.toLowerCase() === 'import') throw new Error('Unexpected CSS import.');
    if (node.type === 'Url' && !files.some(file => node.value === `/fonts/${file}`)) throw new Error('Unexpected bundled CSS URL.');
  });
  return { fonts, notice: notices.join('') + '\n' + ofl,
    css: Buffer.from((await readFile(join(packageDir, 'src/preview.css'), 'utf8')) + '\n' + css.generate(ast) + '\n') };
}
async function bundle(name) {
  const result = await build({ absWorkingDir: packageDir, entryPoints: [`src/${name}.ts`], bundle: true,
    platform: 'browser', target: ['es2020', 'safari15'], format: 'iife', write: false,
    outfile: `${name}.js`, minify: true, charset: 'utf8', sourcemap: false,
    legalComments: 'none', metafile: true,
    banner: { js: `/* VNote Mobile: LGPL-3.0-only. Bundled dependency licenses: NOTICE.txt. */\n${name === 'preview' ? '' : browserCompatibility}` } });
  if (result.outputFiles.length !== 1) throw new Error('Expected one self-contained offline JavaScript bundle per context.');
  const bytes = Buffer.from(result.outputFiles[0].contents);
  if (/<\/script/i.test(bytes.toString('utf8'))) throw new Error('Unsafe closing-script delimiter in trusted inline bundle.');
  for (const input of Object.keys(result.metafile.inputs)) {
    if (name === 'editor' && /(?:render_policy|render|preview)\.ts$|node_modules\/(?:mermaid|katex|dompurify|markdown-it|css-tree)\//.test(input)) throw new Error('Preview code entered the privileged editor.');
    if (name === 'preview' && /node_modules\//.test(input)) throw new Error('Heavy runtime dependency entered the lightweight viewer.');
  }
  return { bytes, metafile: result.metafile };
}
async function buildAssets(check) {
  const outputs = new Map();
  const editor = await bundle('editor'), renderer = await bundle('render'), viewer = await bundle('preview');
  for (const [name, directory] of [['index.html', 'editor'], ['editor.css', 'editor'], ['render.html', 'preview'], ['preview.html', 'preview']]) {
    outputs.set(`apps/vnote_mobile/assets/${directory}/${name}`, await readFile(join(packageDir, 'src', name)));
  }
  outputs.set('apps/vnote_mobile/assets/editor/editor.js', editor.bytes);
  outputs.set('apps/vnote_mobile/assets/preview/render.js', renderer.bytes);
  outputs.set('apps/vnote_mobile/assets/preview/preview.js', viewer.bytes);
  const styles = await previewStylesAndFonts(outputs);
  if (/<\/style/i.test(styles.css.toString('utf8'))) throw new Error('Unsafe closing-style delimiter in trusted inline CSS.');
  const editorCss = outputs.get('apps/vnote_mobile/assets/editor/editor.css');
  if (/<\/style/i.test(editorCss.toString('utf8'))) throw new Error('Unsafe closing-style delimiter in editor CSS.');
  outputs.set('apps/vnote_mobile/assets/preview/preview.css', styles.css);
  outputs.set('apps/vnote_mobile/assets/editor/NOTICE.txt', Buffer.from(await runtimeNotices(editor.metafile)));
  outputs.set('apps/vnote_mobile/assets/preview/NOTICE.txt', Buffer.from(await runtimeNotices(renderer.metafile) + styles.notice));
  for (const name of ['COPYING', 'COPYING.LESSER']) outputs.set(`apps/vnote_mobile/assets/legal/${name}`, await readFile(join(root, name)));
  const sourcePaths = [
    '.node-version', 'toolchains.json', 'pubspec.yaml', 'pubspec.lock', 'COPYING', 'COPYING.LESSER',
    'apps/vnote_mobile/pubspec.yaml', 'packages/editor_web/package.json', 'packages/editor_web/package-lock.json',
    'packages/editor_web/tsconfig.json', 'packages/editor_web/build.mjs',
    ...['protocol.ts', 'editor.ts', 'formatting.ts', 'render.ts', 'render_policy.ts', 'preview.ts', 'index.html', 'editor.css', 'render.html', 'preview.html', 'preview.css'].map(name => `packages/editor_web/src/${name}`),
    ...['protocol.test.ts', 'formatting.test.ts', 'render.test.ts', 'render_policy.test.ts', 'fixtures/preview_cases.json'].map(name => `packages/editor_web/test/${name}`),
  ].sort();
  const sources = {};
  for (const path of sourcePaths) sources[path] = sha256(await readFile(join(root, path)));
  for (const directory of ['editor', 'preview']) {
    const prefix = `apps/vnote_mobile/assets/${directory}/`;
    const manifest = { version: 2, node: pins.node, npm: pins.npm, esbuild: esbuildVersion, sources,
      outputs: Object.fromEntries([...outputs].filter(([path]) => path.startsWith(prefix) || path.startsWith('apps/vnote_mobile/assets/legal/'))
        .sort(([a], [b]) => a.localeCompare(b, 'en')).map(([path, bytes]) => [path, sha256(bytes)])),
      ...(directory === 'preview' ? { fonts: styles.fonts } : {}) };
    outputs.set(`${prefix}manifest.json`, Buffer.from(JSON.stringify(manifest, null, 2) + '\n'));
  }
  for (const [path, bytes] of outputs) {
    if (bytes.includes(Buffer.from(portable(root))) || bytes.includes(Buffer.from(root))) throw new Error(`Private build path leaked into ${path}`);
  }
  if (check) {
    const stale = [];
    for (const [path, expected] of outputs) {
      try { if (!(await readFile(join(root, path))).equals(expected)) stale.push(path); }
      catch (error) { if (error.code === 'ENOENT') stale.push(path); else throw error; }
    }
    if (stale.length) throw new Error(`Missing or stale generated assets; run npm run build:\n${stale.join('\n')}`);
    console.log('Isolated editor/renderer/viewer assets, runtime/font notices and manifests match deterministic inputs.');
    return;
  }
  for (const [path, bytes] of outputs) {
    const destination = join(root, path), fromRoot = relative(root, destination);
    if (isAbsolute(fromRoot) || fromRoot.startsWith('..')) throw new Error('Output escaped the repository.');
    await mkdir(dirname(destination), { recursive: true });
    const temporary = `${destination}.tmp-${process.pid}`;
    try { await writeFile(temporary, bytes); await rename(temporary, destination); }
    finally { await rm(temporary, { force: true }); }
  }
  console.log('Built isolated offline bundles, exact runtime/font notices, and deterministic hash manifests.');
}
async function runTests() {
  // Keep the temporary ESM entrypoints under node_modules so external real jsdom
  // and Mermaid dependencies resolve normally; never bundle jsdom's Node internals.
  const temporary = await mkdtemp(join(packageDir, 'node_modules/.vnote-editor-test-'));
  try {
    const bootstrap = join(temporary, 'dom-bootstrap.mjs');
    await writeFile(bootstrap, "import { JSDOM } from 'jsdom'; const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://render.vnote.invalid/' }); Object.assign(globalThis, { window: dom.window, document: dom.window.document });\n");
    const names = ['protocol', 'formatting', 'render', 'render_policy'];
    const compiled = await build({ absWorkingDir: packageDir, entryPoints: names.map(name => `test/${name}.test.ts`),
      bundle: true, packages: 'external', platform: 'node', target: 'node24', format: 'esm', write: false,
      outdir: temporary, outExtension: { '.js': '.mjs' }, sourcemap: false, legalComments: 'none' });
    for (const file of compiled.outputFiles) await writeFile(file.path, file.contents);
    const result = spawnSync(process.execPath, ['--import', pathToFileURL(bootstrap).href, '--test', '--test-concurrency=1', ...names.map(name => join(temporary, `${name}.test.mjs`))], { stdio: 'inherit' });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
  } finally { await rm(temporary, { recursive: true, force: true }); }
}
if (args[0] === '--test') await runTests();
else await buildAssets(args[0] === '--check');
