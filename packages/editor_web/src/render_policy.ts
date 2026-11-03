// SPDX-License-Identifier: LGPL-3.0-only
import createDOMPurify from 'dompurify';
import * as css from 'css-tree';

export const limits = Object.freeze({ source: 4 * 1024 * 1024, tokens: 100000, depth: 64,
  output: 16 * 1024 * 1024, nodes: 100000, attribute: 8192, math: 200, mathSource: 8192,
  mathOutput: 256 * 1024, diagrams: 20, diagramSource: 32768, diagramOutput: 1024 * 1024,
  vertices: 200, edges: 500, images: 200, pixels: 16000000, resident: 64 * 1024 * 1024 });
export type ErrorCategory = 'input-limit' | 'markdown-limit' | 'math-limit' | 'diagram-limit'
  | 'output-limit' | 'unsupported-output' | 'invalid-request' | 'render-failed';
export class PolicyError extends Error {
  constructor(readonly category: ErrorCategory) { super(category); }
}
export function fail(category: ErrorCategory): never { throw new PolicyError(category); }
export function utf8Size(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c < 0x80) bytes++;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < value.length
      && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}
export const opaqueId = /^[a-f0-9]{32}$/;
export interface Preferences { dark: boolean; highContrast: boolean; fontScale: number; reducedMotion: boolean }
export function preferences(value: unknown): Preferences {
  if (!closed(value, ['dark', 'highContrast', 'fontScale', 'reducedMotion'])
    || typeof value.dark !== 'boolean' || typeof value.highContrast !== 'boolean'
    || typeof value.reducedMotion !== 'boolean' || typeof value.fontScale !== 'number'
    || !Number.isFinite(value.fontScale) || value.fontScale < .75 || value.fontScale > 3) fail('invalid-request');
  return value as unknown as Preferences;
}
export function closed(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]!);
}
export function localBase(value: unknown, renderId: string, route: 'media' | 'nav'): value is string {
  return typeof value === 'string' && [
    `https://preview.vnote.invalid/g/${renderId}/${route}/`,
    `vnote-preview://preview.vnote.invalid/g/${renderId}/${route}/`,
  ].includes(value);
}

// Desktop HeadingSlugger at f8026adb: generated duplicate suffixes also reserve IDs.
export class HeadingSlugger {
  private readonly occurrences = new Map<string, number>();
  slug(text: string): string {
    const base = text.replace(/^[0-9]{1,3}(?:\.[0-9]+)*[.)]? /u, '').toLowerCase()
      .replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, '').replace(/ /g, '-');
    let result = base;
    let occurrence = this.occurrences.get(base);
    if (occurrence !== undefined) {
      do { result = `${base}-${occurrence++}`; } while (this.occurrences.has(result));
      this.occurrences.set(base, occurrence);
    }
    this.occurrences.set(result, 1);
    return result;
  }
}
export const headingId = (slug: string): string => `vnote-h-${slug}`;

const properties = new Set(('color background-color opacity fill fill-opacity fill-rule stroke stroke-width stroke-opacity '
  + 'stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit '
  + 'font-family font-size font-weight font-style font-variant line-height letter-spacing text-anchor '
  + 'text-align text-decoration text-transform dominant-baseline alignment-baseline baseline-shift '
  + 'vertical-align white-space word-spacing word-break overflow overflow-wrap display visibility '
  + 'position top right bottom left width height min-width max-width min-height max-height '
  + 'margin margin-left margin-right margin-top margin-bottom padding padding-left padding-right padding-top padding-bottom '
  + 'border border-width border-style border-color border-top-width border-right-width border-bottom-width border-left-width '
  + 'border-top-style border-right-style border-bottom-style border-left-style border-top-color border-right-color border-bottom-color border-left-color '
  + 'border-radius border-spacing box-sizing transform transform-origin vector-effect paint-order cursor filter').split(' '));
const keywords = new Set(('none auto normal bold bolder lighter italic oblique small-caps inherit initial unset '
  + 'block inline inline-block table table-row table-cell flex hidden visible scroll clip nowrap pre pre-wrap pre-line '
  + 'absolute relative static baseline sub super top bottom middle text-top text-bottom '
  + 'solid dashed dotted double round square butt bevel miter start end left right center justify '
  + 'alphabetic central hanging mathematical ideographic text-before-edge text-after-edge '
  + 'currentcolor transparent black white red green blue gray grey yellow orange purple pink brown '
  + 'serif sans-serif monospace system-ui KaTeX_Main KaTeX_Math '
  + 'border-box content-box non-scaling-stroke stroke fill markers pointer default '
  + 'underline overline line-through capitalize uppercase lowercase break-word evenodd nonzero').toLowerCase().split(' '));
const functions = new Set(['rgb', 'rgba', 'hsl', 'hsla', 'translate', 'translatex', 'translatey', 'scale', 'scalex', 'scaley', 'rotate', 'matrix']);
const units = new Set(['px', 'em', 'ex', 'rem', 'pt', 'pc', 'mm', 'cm', 'in', 'deg']);
function validateDeclaration(declaration: css.Declaration): string {
  const property = declaration.property.toLowerCase();
  if (!properties.has(property) || declaration.value.type !== 'Value') fail('unsupported-output');
  if (!css.lexer.matchProperty(property, declaration.value).matched) fail('unsupported-output');
  let count = 0;
  css.walk(declaration.value, node => {
    if (++count > 256) fail('unsupported-output');
    switch (node.type) {
      case 'Value': break;
      case 'Identifier': if (!keywords.has(node.name.toLowerCase())) fail('unsupported-output'); break;
      case 'Hash': if (!/^(?:[\da-f]{3,4}|[\da-f]{6}|[\da-f]{8})$/i.test(node.value)) fail('unsupported-output'); break;
      case 'Number': if (!Number.isFinite(+node.value) || Math.abs(+node.value) > 100000) fail('unsupported-output'); break;
      case 'Percentage': if (!Number.isFinite(+node.value) || Math.abs(+node.value) > 1000) fail('unsupported-output'); break;
      case 'Dimension': if (!units.has(node.unit.toLowerCase()) || !Number.isFinite(+node.value)
        || Math.abs(+node.value) > (['em', 'ex', 'rem'].includes(node.unit.toLowerCase()) ? 1000 : 100000)) fail('unsupported-output'); break;
      case 'Function': if (!functions.has(node.name.toLowerCase())) fail('unsupported-output'); break;
      case 'Operator': if (![',', '/', '+', '-'].includes(node.value)) fail('unsupported-output'); break;
      case 'String': if (property !== 'font-family' || !/^(?:system-ui|sans-serif|serif|monospace|KaTeX_(?:Main|Math))$/i.test(node.value)) fail('unsupported-output'); break;
      default: fail('unsupported-output');
    }
  });
  if (property === 'position' && !/^(?:absolute|relative|static)$/.test(css.generate(declaration.value))) fail('unsupported-output');
  if (property === 'filter' && css.generate(declaration.value) !== 'none') fail('unsupported-output');
  return `${property}:${css.generate(declaration.value)}${declaration.important ? '!important' : ''}`;
}
export function safeStyle(value: string): string {
  if (utf8Size(value) > limits.attribute) fail('output-limit');
  let ast: css.CssNode;
  try { ast = css.parse(value, { context: 'declarationList', positions: false, onParseError: () => fail('unsupported-output') }); }
  catch { fail('unsupported-output'); }
  if (ast.type !== 'DeclarationList') fail('unsupported-output');
  const output: string[] = [];
  ast.children.forEach(node => { if (node.type !== 'Declaration') fail('unsupported-output'); output.push(validateDeclaration(node)); });
  return output.join(';');
}

// Materialize only applicable generated rules into attributes. No stylesheet, URL,
// at-rule or note-authored CSS survives. Dead animation keyframes cannot execute
// because neither animation declarations nor note-controlled classes are admitted.
export function materializeDiagramStyles(svg: Element): void {
  const elements = [svg, ...Array.from(svg.querySelectorAll('*'))];
  const values = new Map<Element, Map<string, { score: number; value: string }>>();
  for (const element of elements) values.set(element, new Map());
  let order = 0;
  for (const style of Array.from(svg.querySelectorAll('style'))) {
    if (utf8Size(style.textContent ?? '') > limits.diagramOutput) fail('diagram-limit');
    let ast: css.CssNode;
    try { ast = css.parse(style.textContent ?? '', { positions: false, onParseError: () => fail('unsupported-output') }); }
    catch { fail('unsupported-output'); }
    if (ast.type !== 'StyleSheet') fail('unsupported-output');
    ast.children.forEach(rule => {
      if (rule.type === 'Atrule' && /^(?:-webkit-)?keyframes$/.test(rule.name)) return;
      if (rule.type !== 'Rule' || rule.prelude.type !== 'SelectorList') fail('unsupported-output');
      rule.prelude.children.forEach(selector => {
        if (selector.type !== 'Selector') fail('unsupported-output');
        let specificity = 0;
        let supported = true;
        css.walk(selector, node => {
          switch (node.type) {
            case 'Selector': break;
            case 'IdSelector': specificity += 100; break;
            case 'ClassSelector': specificity += 10; break;
            case 'TypeSelector': if (node.name !== '*') specificity++; break;
            case 'Combinator': if (![' ', '>', '+', '~'].includes(node.name)) supported = false; break;
            case 'PseudoClassSelector': if (node.name !== 'root') supported = false; else specificity += 10; break;
            case 'AttributeSelector':
              if (!['id', 'data-look'].includes(node.name.name) || !['=', '$='].includes(node.matcher ?? '') || node.flags) supported = false;
              specificity += 10; break;
            case 'Identifier': if (!/^[a-z0-9_-]+$/i.test(node.name)) supported = false; break;
            case 'String': if (!/^[a-z0-9_-]+$/i.test(node.value)) supported = false; break;
            default: supported = false;
          }
        });
        if (!supported) fail('unsupported-output');
        const text = css.generate(selector).replace(/:root\b/g, `#${svg.id}`);
        let matches: Element[];
        try { matches = elements.filter(element => element.matches(text)); } catch { fail('unsupported-output'); }
        if (!matches.length) return;
        rule.block.children.forEach(declaration => {
          if (declaration.type !== 'Declaration') fail('unsupported-output');
          const value = validateDeclaration(declaration);
          const score = (declaration.important ? 1e12 : 0) + specificity * 1e6 + order++;
          for (const target of matches) {
            const map = values.get(target)!;
            if ((map.get(declaration.property)?.score ?? -1) <= score) map.set(declaration.property, { score, value });
          }
        });
      });
    });
    style.remove();
  }
  for (const element of elements) {
    if (element.localName === 'style') continue;
    const applied = Array.from(values.get(element)!.values(), entry => entry.value);
    const inline = element.getAttribute('style');
    if (inline) applied.push(safeStyle(inline));
    if (applied.length) element.setAttribute('style', safeStyle(applied.join(';')));
  }
}

const htmlTags = 'p br hr h1 h2 h3 h4 h5 h6 blockquote pre code em strong s del ul ol li table thead tbody tr th td a img span div sup sub'.split(' ');
const svgTags = 'svg g path rect circle ellipse line polyline polygon text tspan defs marker title desc clipPath'.split(' ');
const mathTags = 'math semantics annotation mrow mi mn mo mtext mspace mfrac msqrt mroot mstyle merror mpadded mphantom mfenced menclose msub msup msubsup munder mover munderover mmultiscripts mprescripts none mtable mtr mtd'.split(' ');
const allowedAttributes = ('id class title alt role aria-label aria-hidden aria-describedby aria-labelledby aria-checked '
  + 'href data-media data-anchor width height style start align colspan rowspan '
  + 'xmlns viewBox preserveAspectRatio d x y x1 y1 x2 y2 dx dy cx cy r rx ry points transform '
  + 'fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin '
  + 'marker-start marker-mid marker-end markerWidth markerHeight markerUnits refX refY orient clip-path '
  + 'text-anchor dominant-baseline font-size font-family font-weight textLength lengthAdjust '
  + 'display displaystyle scriptlevel mathvariant mathsize mathcolor mathbackground encoding '
  + 'fence separator stretchy symmetric maxsize minsize largeop movablelimits accent accentunder '
  + 'lspace rspace linethickness columnalign rowalign columnspacing rowspacing columnlines rowlines equalrows equalcolumns frame framespacing').split(' ');
const svgNumeric = new Set('width height x y x1 y1 x2 y2 dx dy cx cy r rx ry refx refy markerwidth markerheight stroke-width stroke-opacity fill-opacity textlength'.split(' '));
const svgPaint = new Set(['fill', 'stroke']);
export interface OutputPolicy { renderId: string; mediaBase: string; navBase: string; media: ReadonlySet<string>; navigation: ReadonlySet<string> }

export function enforceDomBounds(root: Node): void {
  const stack: Array<{ node: Node; depth: number }> = [{ node: root, depth: 0 }];
  let count = 0;
  while (stack.length) {
    const { node, depth } = stack.pop()!;
    if (++count > limits.nodes || depth > limits.depth) fail('output-limit');
    if (node.nodeType === 1) {
      for (const attribute of Array.from((node as Element).attributes)) if (utf8Size(attribute.value) > limits.attribute) fail('output-limit');
    }
    for (let child = node.lastChild; child; child = child.previousSibling) stack.push({ node: child, depth: depth + 1 });
  }
}

export function prefixDiagramIds(svg: Element, prefix: string): void {
  const ids = new Map<string, string>();
  for (const element of [svg, ...Array.from(svg.querySelectorAll('[id]'))]) {
    const id = element.id;
    if (!id) continue;
    if (ids.has(id)) fail('unsupported-output');
    ids.set(id, `${prefix}${ids.size}`);
  }
  for (const element of [svg, ...Array.from(svg.querySelectorAll('*'))]) {
    if (element.id) element.id = ids.get(element.id)!;
    for (const attribute of Array.from(element.attributes)) {
      if (['aria-labelledby', 'aria-describedby'].includes(attribute.name)) {
        const references = attribute.value.split(/\s+/).map(id => ids.get(id));
        if (references.some(id => !id)) fail('unsupported-output');
        element.setAttribute(attribute.name, references.join(' '));
      } else if (['marker-start', 'marker-mid', 'marker-end', 'clip-path'].includes(attribute.name)) {
        const match = /^url\(#([^\s)]+)\)$/.exec(attribute.value);
        if (!match || !ids.has(match[1]!)) fail('unsupported-output');
        element.setAttribute(attribute.name, `url(#${ids.get(match[1]!)!})`);
      } else if (['href', 'xlink:href'].includes(attribute.name)) {
        // SVG use/image/a are not in the output subset.
        fail('unsupported-output');
      }
    }
  }
}

export function sanitizeFinal(document: Document, markup: string, policy: OutputPolicy): string {
  if (utf8Size(markup) > limits.output) fail('output-limit');
  const purifier = createDOMPurify(document.defaultView!);
  const idPrefix = `vnote-g-${policy.renderId}-`;
  purifier.addHook('uponSanitizeAttribute', (node, data) => {
    const name = data.attrName.toLowerCase();
    const value = data.attrValue;
    if (utf8Size(value) > limits.attribute) fail('output-limit');
    if (name === 'style') { data.attrValue = safeStyle(value); return; }
    if (name === 'id') {
      data.keepAttr = value.startsWith('vnote-h-') && /^h[1-6]$/i.test(node.nodeName)
        || value.startsWith(idPrefix) && /^vnote-g-[a-f0-9]{32}-\d+-\d+$/.test(value);
    } else if (name === 'href') {
      data.keepAttr = node.nodeName.toLowerCase() === 'a' && (value.startsWith('#vnote-h-')
        || value.startsWith(policy.navBase) && policy.navigation.has(value.slice(policy.navBase.length)));
      if (data.keepAttr) data.forceKeepAttr = true; // Exact opaque custom-scheme URL already validated.
    } else if (name === 'data-media') {
      data.keepAttr = node.nodeName.toLowerCase() === 'img' && value.startsWith(policy.mediaBase)
        && policy.media.has(value.slice(policy.mediaBase.length));
      if (data.keepAttr) data.forceKeepAttr = true; // Sealed local media URL, including the WK scheme.
    } else if (name.startsWith('data-') && name !== 'data-anchor') data.keepAttr = false;
    else if (name === 'xmlns') data.keepAttr = ['http://www.w3.org/2000/svg', 'http://www.w3.org/1998/Math/MathML'].includes(value);
    else if (['marker-start', 'marker-mid', 'marker-end', 'clip-path'].includes(name)) {
      data.keepAttr = new RegExp(`^url\\(#${idPrefix}\\d+-\\d+\\)$`).test(value);
    } else if (svgNumeric.has(name)) {
      data.keepAttr = /^(?:-?\d+(?:\.\d+)?(?:px|em|ex|%)?)(?:[ ,]+-?\d+(?:\.\d+)?(?:px|em|ex|%)?)*$/.test(value)
        && value.split(/[ ,]+/).every(part => Math.abs(Number.parseFloat(part)) < 1000000);
    } else if (svgPaint.has(name)) {
      data.keepAttr = /^(?:none|currentColor|transparent|[a-z]+|#[\da-f]{3,8}|rgba?\([\d.,% ]+\))$/i.test(value);
    } else if (name === 'transform') {
      data.keepAttr = /^(?:(?:translate|scale|rotate|matrix|skewX|skewY)\([\d.eE+\-, ]+\)\s*)+$/.test(value);
    } else if (name === 'viewbox' || name === 'points') data.keepAttr = /^[\d.eE+\-, ]+$/.test(value);
    else if (name === 'd') data.keepAttr = /^[MmZzLlHhVvCcSsQqTtAa\d.eE+\-, \t\r\n]+$/.test(value);
    else if (name === 'name' || name.startsWith('on') || name === 'src') data.keepAttr = false;
  });
  const fragment = purifier.sanitize(markup, { ALLOWED_TAGS: ['#text', ...htmlTags, ...svgTags, ...mathTags],
    ALLOWED_ATTR: allowedAttributes, ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false,
    FORBID_TAGS: ['style', 'script', 'foreignObject', 'image', 'use', 'animate', 'set', 'form', 'input', 'iframe', 'object'],
    FORBID_ATTR: ['name', 'src', 'srcset', 'form', 'formaction', 'target', 'download', 'xlink:href'],
    KEEP_CONTENT: false, SANITIZE_DOM: true, RETURN_DOM_FRAGMENT: true });
  enforceDomBounds(fragment);
  const emittedIds = new Set<string>();
  for (const element of fragment.querySelectorAll('[id]')) {
    if (emittedIds.has(element.id)) fail('unsupported-output');
    emittedIds.add(element.id);
  }
  for (const svg of fragment.querySelectorAll('svg')) {
    const subtree = [svg, ...Array.from(svg.querySelectorAll('*'))].filter(element => element.closest('svg') === svg);
    const localIds = new Set(subtree.map(element => element.id).filter(Boolean));
    for (const element of subtree) for (const name of ['marker-start', 'marker-mid', 'marker-end', 'clip-path', 'aria-labelledby', 'aria-describedby']) {
      const value = element.getAttribute(name);
      if (!value) continue;
      const targets = name.startsWith('aria-') ? value.split(/\s+/) : [value.slice(5, -1)];
      if (targets.some(target => !localIds.has(target))) fail('unsupported-output');
    }
  }
  const holder = document.createElement('div');
  holder.append(fragment);
  const output = holder.innerHTML;
  if (utf8Size(output) > limits.output) fail('output-limit');
  return output;
}
