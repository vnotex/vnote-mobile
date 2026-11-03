// SPDX-License-Identifier: LGPL-3.0-only
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import fixtures from './fixtures/preview_cases.json';
import { HeadingSlugger, limits, safeStyle, sanitizeFinal, prefixDiagramIds,
  materializeDiagramStyles, enforceDomBounds, utf8Size } from '../src/render_policy';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
const document = dom.window.document;
const renderId = 'a'.repeat(32);
const handle = 'b'.repeat(32);
const policy = { renderId, mediaBase: `https://preview.vnote.invalid/g/${renderId}/media/`,
  navBase: `https://preview.vnote.invalid/g/${renderId}/nav/`, media: new Set([handle]), navigation: new Set([handle]) };
function output(markup: string) {
  const holder = document.createElement('div'); holder.innerHTML = sanitizeFinal(document, markup, policy); return holder;
}

for (const markup of fixtures.hostileMarkup) test('DOMPurify final pass removes active and clobbering content', () => {
  const holder = output(markup);
  assert.equal(holder.querySelector('script,style,form,input,iframe,object,foreignObject,animate,set,use,image'), null);
  for (const element of holder.querySelectorAll('*')) {
    for (const attribute of element.attributes) assert.doesNotMatch(attribute.name, /^(?:on|src|name|xlink)/);
    assert.notEqual(element.id, 'preview'); assert.notEqual(element.id, 'vnoteRender');
  }
  assert.doesNotMatch(holder.innerHTML, /href="(?:javascript|file|data|https:\/\/example)/);
});

for (const declaration of fixtures.hostileCss) test('positive CSS AST grammar rejects authority and unsupported styles', () => {
  assert.throws(() => safeStyle(declaration), /unsupported-output/);
});

test('generated positioning, safe colors and SVG paint survive positive CSS validation', () => {
  const source = 'height:1.04em;vertical-align:-0.2em;margin-right:0.2778em;color:#123abc;stroke-width:1.5px;fill:rgb(10,20,30)';
  const safe = safeStyle(source);
  assert.match(safe, /height:1.04em/); assert.match(safe, /vertical-align:-0.2em/);
  assert.equal(safeStyle(safe), safe);
});

test('raw unknown functions, dimensions and parser recovery cannot sneak through', () => {
  for (const value of ['width:calc(1px + 1em)', 'width:999999999px', 'height:NaN', 'color:rgb(from red r g b)',
    'color:red; garbage', 'color:/**/var(--x)', 'color:red!important;background-image:url(x)', 'content:"private"']) {
    assert.throws(() => safeStyle(value));
  }
});

test('generated diagram stylesheet is materialized and discarded before the final pass', () => {
  const holder = document.createElement('div');
  holder.innerHTML = '<svg id="diagram" xmlns="http://www.w3.org/2000/svg"><style>#diagram{font-family:system-ui,sans-serif;font-size:16px}#diagram .node{fill:#fff;stroke:#123}#diagram .edge-animation-fast{animation:dash 2s linear infinite}@keyframes dash{to{stroke-dashoffset:0}}</style><g class="node"><rect width="10" height="20"></rect></g></svg>';
  const svg = holder.firstElementChild!;
  materializeDiagramStyles(svg);
  assert.equal(svg.querySelector('style'), null);
  assert.match(svg.querySelector('g')!.getAttribute('style')!, /fill:#fff/);
  prefixDiagramIds(svg, `vnote-g-${renderId}-0-`);
  const sanitized = output(svg.outerHTML);
  assert.ok(sanitized.querySelector('svg g rect'));
  assert.equal(sanitized.querySelector('style'), null);
});

test('fractional SVG layout survives while oversized coordinates remain inert', () => {
  const holder = output('<svg><rect x="-48.2343750001" width="96.4687500002" height="51" y="1000000"></rect></svg>');
  const rect = holder.querySelector('rect')!;
  assert.equal(Number(rect.getAttribute('x')), -48.2343750001);
  assert.equal(Number(rect.getAttribute('width')), 96.4687500002);
  assert.equal(Number(rect.getAttribute('height')), 51);
  assert.equal(rect.getAttribute('y'), null);
});

test('an applicable generated animation or URL rule fails rather than weakening policy', () => {
  for (const rule of ['animation:dash 1s linear infinite', 'fill:url(https://example.org)']) {
    const holder = document.createElement('div'); holder.innerHTML = `<svg id="diagram"><style>#diagram .node{${rule}}</style><g class="node"></g></svg>`;
    assert.throws(() => materializeDiagramStyles(holder.firstElementChild!));
  }
});

test('diagram references bind only within their own prefixed subtree', () => {
  const holder = document.createElement('div'); holder.innerHTML = '<svg id="diagram"><defs><marker id="arrow"></marker></defs><path d="M0 0 L10 10" marker-end="url(#arrow)"></path></svg>';
  prefixDiagramIds(holder.firstElementChild!, `vnote-g-${renderId}-7-`);
  const sanitized = output(holder.innerHTML);
  const marker = sanitized.querySelector('marker')!;
  assert.equal(sanitized.querySelector('path')!.getAttribute('marker-end'), `url(#${marker.id})`);
  assert.match(marker.id, new RegExp(`^vnote-g-${renderId}-7-`));
  holder.innerHTML = '<svg id="diagram"><path marker-end="url(#foreign)"></path></svg>';
  assert.throws(() => prefixDiagramIds(holder.firstElementChild!, `vnote-g-${renderId}-8-`), /unsupported-output/);
});

test('stale, malformed and unsealed handles remain inert', () => {
  const stale = 'c'.repeat(32);
  const holder = output(`<img data-media="${policy.mediaBase}${stale}" src="${policy.mediaBase}${handle}"><a href="${policy.navBase}${stale}">stale</a><a href="${policy.navBase}${handle}">current</a><img data-media="${policy.mediaBase}${handle}">`);
  assert.equal(holder.querySelectorAll('img[data-media]').length, 1);
  assert.equal(holder.querySelectorAll('a[href]').length, 1);
  assert.equal(holder.querySelector('[src]'), null);
});

test('desktop slugs reserve generated collisions, preserve combining marks and strip only section prefixes', () => {
  const slugger = new HeadingSlugger();
  assert.deepEqual(['a', 'a', 'a-1', 'a', 'a-2'].map(text => slugger.slug(text)), ['a', 'a-1', 'a-1-1', 'a-2', 'a-2-1']);
  assert.equal(slugger.slug('1.2) CafÉ 日本語'), 'café-日本語');
  assert.equal(slugger.slug('2026 Title'), '2026-title');
  assert.equal(slugger.slug('Cafe\u0301'), 'cafe\u0301');
});

test('DOM node, depth and per-attribute ceilings precede installation', () => {
  const holder = document.createElement('div');
  holder.innerHTML = '<span>'.repeat(65) + 'x' + '</span>'.repeat(65);
  assert.throws(() => enforceDomBounds(holder), /output-limit/);
  holder.innerHTML = '<br>'.repeat(limits.nodes);
  assert.throws(() => enforceDomBounds(holder), /output-limit/);
  assert.throws(() => sanitizeFinal(document, `<p title="${'x'.repeat(limits.attribute + 1)}">x</p>`, policy), /output-limit/);
  assert.throws(() => sanitizeFinal(document, 'x'.repeat(limits.output + 1), policy), /output-limit/);
});

test('UTF8 quotas count multibyte and surrogate pairs, not UTF16 units', () => {
  for (const text of ['ASCII', '日本語', 'Cafe\u0301', '\ud83d\ude00', '\ud800']) assert.equal(utf8Size(text), Buffer.byteLength(text));
});

test('final sanitizer also rejects cross-diagram references and duplicate emitted IDs', () => {
  const first = `vnote-g-${renderId}-0-0`, second = `vnote-g-${renderId}-1-0`;
  assert.throws(() => output(`<svg id="${first}"><path marker-end="url(#${second})"></path></svg><svg id="${second}"></svg>`), /unsupported-output/);
  assert.throws(() => output('<h1 id="vnote-h-a">a</h1><h1 id="vnote-h-a">a</h1>'), /unsupported-output/);
});
