// SPDX-License-Identifier: LGPL-3.0-only
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import fixtures from './fixtures/preview_cases.json';
import type Token from 'markdown-it/lib/token.mjs';

const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://render.vnote.invalid/' });
Object.assign(globalThis, { window: dom.window, document: dom.window.document });
const { RenderController, checkDiagramDatabase, diagramKind } = await import('../src/render');
const { limits } = await import('../src/render_policy');
const { default: mermaid } = await import('mermaid');
const renderId = 'a'.repeat(32);
const handle = 'b'.repeat(32);
const second = 'c'.repeat(32);
const prefs = { dark: false, highContrast: false, fontScale: 1, reducedMotion: true };
const input = (source: string, extra = {}) => ({ version: 1, renderId, source,
  mediaBase: `https://preview.vnote.invalid/g/${renderId}/media/`,
  navBase: `https://preview.vnote.invalid/g/${renderId}/nav/`, images: [], navigation: [], preferences: prefs, ...extra });
async function render(source: string, extra = {}) {
  const controller = new RenderController(dom.window.document);
  let status = controller.prepare(input(source, extra));
  assert.notEqual(status.phase, 'error', status.error ?? '');
  for (let index = 0; index < status.jobs; index++) {
    await controller.runJob(index); status = controller.status();
    assert.notEqual(status.phase, 'error', status.error ?? '');
  }
  assert.equal(controller.status().phase, 'ready');
  status = controller.finish();
  assert.equal(status.phase, 'complete', status.error ?? '');
  let output = '';
  for (let offset = 0; offset < status.outputUnits;) {
    const chunk = controller.readOutput(offset, 32768);
    assert.ok(chunk.length > 0 && chunk.length <= 32768);
    output += chunk; offset += chunk.length;
  }
  assert.equal(Buffer.byteLength(output), status.outputBytes);
  const holder = dom.window.document.createElement('div'); holder.innerHTML = output;
  return { controller, output, holder };
}

test('native UTF8 chunk transport preserves a Unicode scalar at its boundary', async () => {
  // The paragraph opener adds three units, placing the high surrogate at32767.
  const source = 'x'.repeat(32764) + '😀' + 'z'.repeat(32768);
  const { controller } = await render(source);
  const status = controller.status();
  const bytes: Buffer[] = [];
  for (let offset = 0; offset < status.outputUnits;) {
    const chunk = controller.readOutput(offset, 32768);
    assert.ok(chunk.length > 0 && chunk.length <= 32768);
    // Native value conversion encodes each fragment independently, not after join.
    bytes.push(Buffer.from(chunk, 'utf8'));
    offset += chunk.length;
  }
  const nativeOutput = Buffer.concat(bytes);
  assert.equal(nativeOutput.length, status.outputBytes);
  const holder = dom.window.document.createElement('div');
  holder.innerHTML = nativeOutput.toString('utf8');
  assert.equal(holder.querySelector('p')!.textContent, source);
  assert.equal(controller.readOutput(32768, 16), '');
});

for (const fixture of fixtures.markdown) test(fixture.name, async () => {
  const original = fixture.source;
  const { holder } = await render(original);
  assert.deepEqual(Array.from(holder.querySelectorAll('h1,h2,h3,h4,h5,h6'), heading => heading.getAttribute('data-anchor')), fixture.headings);
  if ('tags' in fixture) for (const tag of fixture.tags ?? []) assert.ok(holder.querySelector(tag), tag);
  if ('literal' in fixture) assert.ok(holder.textContent!.includes(fixture.literal!));
  assert.equal(holder.querySelector('script,form,input,iframe,foreignObject'), null);
});

test('anchors are assigned in actual emitted order, even after token relocation', () => {
  const controller = new RenderController(dom.window.document);
  controller.prepare(input('# a\n# a-1\n# a\n'));
  const state = controller as unknown as { tokens: Token[] };
  const blocks = [state.tokens.slice(0, 3), state.tokens.slice(3, 6), state.tokens.slice(6, 9)];
  state.tokens = [...blocks[2]!, ...blocks[0]!, ...blocks[1]!];
  assert.equal(controller.finish().phase, 'complete');
  const holder = dom.window.document.createElement('div'); holder.innerHTML = controller.readOutput(0, 32768);
  assert.deepEqual(Array.from(holder.querySelectorAll('h1'), node => node.id), ['vnote-h-a', 'vnote-h-a-1', 'vnote-h-a-1-1']);
});

test('native maps are the sole image and navigation authority', async () => {
  const { holder } = await render('[ok](other.md) [blocked](vx://home) ![ok](assets/a.png) ![blocked](https://example.org/a.png)', {
    images: [{ source: 'assets/a.png', handle, width: 400, height: 300 }],
    navigation: [{ source: 'other.md', handle: second }],
  });
  assert.equal(holder.querySelector('a[href]')!.getAttribute('href'), `https://preview.vnote.invalid/g/${renderId}/nav/${second}`);
  assert.equal(holder.querySelectorAll('a[href]').length, 1);
  assert.equal(holder.querySelectorAll('img').length, 1);
  assert.equal(holder.querySelector('img')!.getAttribute('src'), null);
  assert.equal(holder.querySelector('img')!.getAttribute('data-media'), `https://preview.vnote.invalid/g/${renderId}/media/${handle}`);
});

test('opaque custom-scheme mappings survive exact URI policy without network fallback', async () => {
  const { holder } = await render('[note](a.md) ![image](a.png)', {
    mediaBase: `vnote-preview://preview.vnote.invalid/g/${renderId}/media/`,
    navBase: `vnote-preview://preview.vnote.invalid/g/${renderId}/nav/`,
    images: [{ source: 'a.png', handle, width: 1, height: 1 }], navigation: [{ source: 'a.md', handle: second }],
  });
  assert.match(holder.querySelector('a')!.getAttribute('href')!, /^vnote-preview:/);
  assert.match(holder.querySelector('img')!.getAttribute('data-media')!, /^vnote-preview:/);
});

for (const expression of fixtures.math) test(`real KaTeX output: ${expression.source}`, async () => {
  const source = expression.display ? `$$\n${expression.source}\n$$` : `$${expression.source}$`;
  const { holder } = await render(source);
  assert.ok(holder.querySelector('.katex'));
  assert.ok(holder.querySelector('math'));
  assert.equal(holder.querySelector('.unsupported'), null);
  assert.equal(holder.querySelector('style,script'), null);
});

for (const source of fixtures.unsupportedMath) test('unsupported math is escaped source, not library diagnostics', async () => {
  const { holder, output } = await render(`$${source}$`);
  assert.ok(holder.querySelector('.unsupported'));
  assert.ok(holder.textContent!.includes(source));
  assert.doesNotMatch(output, /ParseError|stack trace|file:\/\/\/.*href=/);
  assert.equal(holder.querySelector('a,img,script,style'), null);
});

test('prepare enumerates jobs without running expensive math', async () => {
  const controller = new RenderController(dom.window.document);
  const status = controller.prepare(input('$x$\n\n$$y$$\n\n```mermaid\nflowchart LR\na-->b\n```'));
  assert.equal(status.jobs, 3); assert.equal(status.phase, 'prepared');
  assert.equal(status.nextJob, 0); assert.equal(status.outputUnits, 0);
  assert.equal(controller.readOutput(0, 32768), '');
  await controller.runJob(0);
  assert.equal(controller.status().nextJob, 1);
  assert.equal(controller.finish().error, 'invalid-request');
});

test('only the next enumerated job can execute, cancellation cannot publish stale output', async () => {
  const controller = new RenderController(dom.window.document);
  controller.prepare(input('$x$ $y$'));
  await controller.runJob(1);
  assert.equal(controller.status().error, 'invalid-request');
  controller.cancel();
  assert.equal(controller.status().phase, 'idle');
  assert.equal(controller.readOutput(0, 32768), '');
});

test('limits fail closed with fixed redacted status', () => {
  const controller = new RenderController(dom.window.document);
  for (const [source, category] of [
    ['x'.repeat(limits.source + 1), 'input-limit'],
    [Array.from({ length: 201 }, () => '$x$').join(' '), 'math-limit'],
    [`$${'x'.repeat(limits.mathSource + 1)}$`, 'math-limit'],
    [Array.from({ length: 21 }, () => '```mermaid\nflowchart LR\na-->b\n```').join('\n\n'), 'diagram-limit'],
  ] as const) {
    const status = controller.prepare(input(source));
    assert.equal(status.phase, 'error'); assert.equal(status.error, category);
    assert.ok(JSON.stringify(status).length < 512); assert.equal(status.outputBytes, 0);
  }
});

test('mapping generation, duplicate authority, malformed dimensions and unknown request keys are refused', () => {
  const controller = new RenderController(dom.window.document);
  const cases = [input('x', { mediaBase: 'https://example.org/' }), input('x', { privatePath: '/private' }),
    input('x', { images: [{ source: 'x', handle, width: 16000001, height: 1 }] }),
    input('x', { navigation: [{ source: 'x', handle }, { source: 'x', handle: second }] })];
  for (const value of cases) assert.equal(controller.prepare(value).error, 'invalid-request');
});

for (const fixture of fixtures.diagrams) test(`real ${fixture.kind} parser database supplies quota counts`, async () => {
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', htmlLabels: false, logLevel: 'fatal',
    flowchart: { defaultRenderer: 'dagre-wrapper', htmlLabels: false }, maxEdges: 500 });
  const diagram = await mermaid.mermaidAPI.getDiagramFromText(fixture.source);
  assert.equal(diagramKind(fixture.source), fixture.kind);
  checkDiagramDatabase(fixture.kind as 'flowchart' | 'sequence', diagram.db);
  const db = diagram.db as unknown as { getVertices: () => Map<string, unknown>; getEdges: () => unknown[];
    getActors: () => Map<string, unknown>; getMessages: () => unknown[] };
  assert.equal(fixture.kind === 'flowchart' ? db.getVertices().size : db.getActors().size, fixture.vertices);
  assert.equal(fixture.kind === 'flowchart' ? db.getEdges().length : db.getMessages().length, fixture.edges);
});

test('real parser expansion is bounded, not source-line counting', async () => {
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', htmlLabels: false, logLevel: 'fatal', maxEdges: 500 });
  const source = 'flowchart LR\n' + Array.from({ length: 201 }, (_, index) => `n${index}[node]`).join(';');
  const diagram = await mermaid.mermaidAPI.getDiagramFromText(source);
  assert.throws(() => checkDiagramDatabase('flowchart', diagram.db), /diagram-limit/);
});

test('expanded edge ceiling returns a fixed category before SVG layout', async () => {
  const left = Array.from({ length: 23 }, (_, index) => `a${index}`).join(' & ');
  const right = Array.from({ length: 23 }, (_, index) => `b${index}`).join(' & ');
  const controller = new RenderController(dom.window.document);
  assert.equal(controller.prepare(input(`\`\`\`mermaid\nflowchart LR\n${left} --> ${right}\n\`\`\``)).jobs, 1);
  await controller.runJob(0);
  assert.equal(controller.status().error, 'diagram-limit');
  assert.equal(controller.status().outputBytes, 0);
});

for (const source of fixtures.unsupportedDiagrams) test('unsupported diagram capabilities never reach Mermaid', () => {
  assert.equal(diagramKind(source), null);
});

for (const workload of fixtures.workloads) test(workload.name, async () => {
  const source = workload.repeat.repeat(workload.count);
  const { holder, controller } = await render(source);
  assert.ok(controller.status().outputBytes <= limits.output);
  assert.ok(holder.textContent!.startsWith(workload.repeat.replace(/\r\n/g, '\n')));
});

test('viewer enforces residency, retires stale decoder events and changes preferences without rendering', async () => {
  // jsdom has no layout engine. Drive only the viewport notification boundary;
  // images/attributes/events/preferences use the actual viewer and real DOM.
  let notify: (entries: Array<{ target: Element; isIntersecting: boolean }>) => void = () => { throw new Error('Observer not installed'); };
  const observed = new Set<Element>();
  const originalObserver = globalThis.IntersectionObserver;
  globalThis.IntersectionObserver = class {
    constructor(callback: typeof notify) { notify = callback; }
    observe(target: Element) { observed.add(target); }
    unobserve(target: Element) { observed.delete(target); }
    disconnect() { observed.clear(); }
  } as unknown as typeof IntersectionObserver;
  try {
    const handles = Array.from({ length: 5 }, (_, index) => String(index + 1).repeat(32));
    document.body.innerHTML = `<main id="preview" data-render-id="${renderId}"></main>`;
    const markup = handles.map(id => `<img width="2048" height="2048" alt="test" data-media="https://preview.vnote.invalid/g/${renderId}/media/${id}">`).join('') + '<div class="diagram"><svg viewBox="0 0 200 100"></svg></div><p>\ud83d\ude00</p>';
    await import('../src/preview');
    // The real viewer just installed its frozen in-process API on this jsdom window.
    const viewerWindow = dom.window as unknown as { vnotePreview: {
      begin(value: { version: number; renderId: string; outputUnits: number; outputBytes: number }): boolean;
      append(offset: number, chunk: string): boolean; finish(): boolean;
      status(): { images: string[] }; preferences(value: typeof prefs): void;
    } };
    const api = viewerWindow.vnotePreview;
    assert.equal(document.querySelectorAll('img').length, 0);
    assert.equal(api.begin({ version: 1, renderId, outputUnits: markup.length, outputBytes: Buffer.byteLength(markup) }), true);
    const split = markup.indexOf('\ud83d\ude00') + 1; // Split the surrogate pair across native chunks.
    assert.equal(api.append(0, markup.slice(0, split)), true);
    assert.equal(document.querySelectorAll('img').length, 0);
    assert.equal(api.append(split, markup.slice(split)), true);
    assert.equal(api.finish(), true);
    assert.equal(document.querySelector('p')!.textContent, '\ud83d\ude00');
    const initial = Array.from(document.querySelectorAll('img'));
    notify(initial.map(target => ({ target, isIntersecting: true })));
    assert.deepEqual(api.status().images, handles.slice(0, 4));
    assert.equal(initial[4]!.getAttribute('src'), null);
    initial[0]!.dispatchEvent(new dom.window.Event('load'));
    assert.equal(initial[4]!.getAttribute('src'), null); // Decoded residency, not merely concurrent reads.
    notify([{ target: initial[0]!, isIntersecting: false }]);
    assert.equal(initial[0]!.getAttribute('src'), null);
    assert.deepEqual(api.status().images, handles.slice(1));
    notify([{ target: initial[1]!, isIntersecting: false }]);
    const replacement = document.querySelectorAll('img')[1]!;
    assert.notEqual(replacement, initial[1]);
    notify([{ target: replacement, isIntersecting: true }]);
    initial[1]!.dispatchEvent(new dom.window.Event('error'));
    assert.ok(api.status().images.includes(handles[1]!));
    assert.equal(replacement.classList.contains('unavailable'), false);
    replacement.dispatchEvent(new dom.window.Event('error'));
    assert.equal(api.status().images.includes(handles[1]!), false);
    assert.equal(replacement.getAttribute('src'), null);
    const before = document.querySelector('svg')!.outerHTML;
    api.preferences({ dark: true, highContrast: true, fontScale: 2, reducedMotion: true });
    assert.equal(document.documentElement.dataset.theme, 'dark');
    assert.equal(document.documentElement.dataset.contrast, 'high');
    assert.equal(document.documentElement.style.fontSize, '32px');
    assert.equal(document.querySelector('svg')!.style.width, '400px');
    assert.equal(document.querySelector('svg')!.getAttribute('viewBox'), '0 0 200 100');
    assert.ok(before.includes('200 100'));
    assert.ok(Object.isFrozen(api));
    assert.deepEqual(Object.keys(api).sort(), ['append', 'begin', 'finish', 'fragment', 'preferences', 'status']);
    dom.window.dispatchEvent(new dom.window.Event('pagehide'));
    assert.deepEqual(api.status().images, []);
  } finally { globalThis.IntersectionObserver = originalObserver; }
});
