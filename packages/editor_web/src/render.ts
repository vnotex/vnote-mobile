// SPDX-License-Identifier: LGPL-3.0-only
import MarkdownIt from 'markdown-it';
import type Token from 'markdown-it/lib/token.mjs';
import katex from 'katex';
import mermaid from 'mermaid';
import { closed, escapeHtml, fail, headingId, HeadingSlugger, limits, localBase, materializeDiagramStyles,
  opaqueId, PolicyError, preferences, prefixDiagramIds, sanitizeFinal, enforceDomBounds, utf8Size,
  type ErrorCategory, type OutputPolicy, type Preferences } from './render_policy';

interface ImageMapping { source: string; handle: string; width: number; height: number }
interface NavigationMapping { source: string; handle: string }
interface RenderRequest { version: 1; renderId: string; source: string; mediaBase: string; navBase: string;
  images: ImageMapping[]; navigation: NavigationMapping[]; preferences: Preferences }
type Phase = 'idle' | 'prepared' | 'running' | 'ready' | 'complete' | 'error';
export interface RenderStatus { version: 1; renderId: string; phase: Phase; jobs: number; nextJob: number;
  activeKind: 'math' | 'diagram' | null; outputUnits: number; outputBytes: number; error: ErrorCategory | null }
interface Job { kind: 'math' | 'diagram'; source: string; display: boolean; output: string }

function request(value: unknown): RenderRequest {
  if (!closed(value, ['version', 'renderId', 'source', 'mediaBase', 'navBase', 'images', 'navigation', 'preferences'])
    || value.version !== 1 || typeof value.renderId !== 'string' || !opaqueId.test(value.renderId)
    || typeof value.source !== 'string' || !localBase(value.mediaBase, value.renderId, 'media')
    || !localBase(value.navBase, value.renderId, 'nav') || !Array.isArray(value.images) || !Array.isArray(value.navigation)) fail('invalid-request');
  if (value.source.length > limits.source || utf8Size(value.source) > limits.source) fail('input-limit');
  if (value.images.length > limits.images || value.navigation.length > limits.tokens) fail('input-limit');
  preferences(value.preferences);
  for (const [entries, image] of [[value.images, true], [value.navigation, false]] as const) {
    const sources = new Set<string>();
    const handles = new Set<string>();
    for (const item of entries) {
      if (!closed(item, image ? ['source', 'handle', 'width', 'height'] : ['source', 'handle'])
        || typeof item.source !== 'string' || !item.source.length || utf8Size(item.source) > limits.attribute
        || typeof item.handle !== 'string' || !opaqueId.test(item.handle)
        || sources.has(item.source) || handles.has(item.handle)) fail('invalid-request');
      if (image && (typeof item.width !== 'number' || typeof item.height !== 'number'
        || !Number.isSafeInteger(item.width) || !Number.isSafeInteger(item.height)
        || item.width <= 0 || item.height <= 0 || item.width * item.height > limits.pixels)) fail('invalid-request');
      sources.add(item.source); handles.add(item.handle);
    }
  }
  return value as unknown as RenderRequest;
}
function lookup<T>(map: ReadonlyMap<string, T>, destination: string): T | undefined {
  const exact = map.get(destination);
  if (exact) return exact;
  // markdown-it normalizes Unicode/space URI bytes. Native cmark supplies decoded
  // CommonMark destinations; this never performs path resolution or decoding twice.
  try { return map.get(decodeURI(destination)); } catch { return undefined; }
}
function unsupported(source: string, category: 'math' | 'diagram'): string {
  return `<span class="unsupported" role="note"><span class="unsupported-label">Unsupported ${category}</span><code>${escapeHtml(source)}</code></span>`;
}
function anchorText(tokens: readonly Token[]): string {
  let result = '';
  for (const token of tokens) {
    if (token.type === 'text' || token.type === 'code_inline' || token.type === 'math_inline') result += token.content;
    else if (token.type === 'softbreak' || token.type === 'hardbreak') result += ' ';
    else if (token.type === 'image') result += token.children ? anchorText(token.children) : token.content;
    else if (token.children) result += anchorText(token.children);
  }
  return result;
}
export function checkTokenBounds(tokens: readonly Token[]): void {
  const stack = [...tokens];
  let count = 0;
  while (stack.length) {
    const token = stack.pop()!;
    if (++count > limits.tokens || token.level > limits.depth) fail('markdown-limit');
    if (token.children) for (const child of token.children) stack.push(child);
  }
}

export function diagramKind(source: string): 'flowchart' | 'sequence' | null {
  if (utf8Size(source) > limits.diagramSource) fail('diagram-limit');
  // No directives/frontmatter/configuration, author CSS/classes, HTML/Markdown
  // labels, callbacks, external resources, icons, or embedded math sub-renderers.
  if (/^\s*---/m.test(source) || /%%\{|:::|@\{|`|\$\$|<\/?[a-z!]|&(?:lt|gt|#)/i.test(source)
    || /(?:^|[\r\n;])\s*(?:click|callback|classDef|class|style|linkStyle|link|links|properties|details)\b/i.test(source)
    || /\b(?:https?|file|data|javascript|vbscript):/i.test(source)) return null;
  const first = source.replace(/^\s*%%[^\r\n]*(?:\r?\n|$)/gm, '').trimStart();
  if (/^(?:flowchart|graph)\s+(?:TB|TD|BT|RL|LR)(?:\s|;|$)/.test(first)) return 'flowchart';
  if (/^sequenceDiagram(?:\s|;|$)/.test(first)) return 'sequence';
  return null;
}
export function checkDiagramDatabase(kind: 'flowchart' | 'sequence', database: unknown): void {
  const db = database as { getVertices?: () => Map<string, unknown>; getEdges?: () => unknown[];
    getActors?: () => Map<string, unknown>; getMessages?: () => unknown[]; getSubGraphs?: () => unknown[] };
  const vertices = kind === 'flowchart' ? db.getVertices?.() : db.getActors?.();
  const edges = kind === 'flowchart' ? db.getEdges?.() : db.getMessages?.();
  if (!(vertices instanceof Map) || !Array.isArray(edges)) fail('unsupported-output');
  const subgraphs = kind === 'flowchart' ? db.getSubGraphs?.() : [];
  if (!Array.isArray(subgraphs)) fail('unsupported-output');
  if (vertices.size + subgraphs.length > limits.vertices || edges.length > limits.edges) fail('diagram-limit');
  for (const value of [...vertices.values(), ...edges, ...subgraphs]) {
    if (!value || typeof value !== 'object') fail('unsupported-output');
    const record = value as Record<string, unknown>;
    if (record.haveCallback || record.link || record.linkTarget || record.icon || record.img
      || record.animate || record.animation || record.labelType === 'markdown'
      || ['classes', 'styles', 'style'].some(key => Array.isArray(record[key]) && record[key].length > 0)
      || ['links', 'properties'].some(key => record[key] && typeof record[key] === 'object' && Object.keys(record[key]).length > 0)) fail('unsupported-output');
  }
}

export class RenderController {
  private state: RenderStatus = this.emptyStatus();
  private current: RenderRequest | null = null;
  private markdown: MarkdownIt | null = null;
  private tokens: Token[] = [];
  private jobs: Job[] = [];
  private output = '';
  private jobBytes = 0;
  private generation = 0;
  constructor(private readonly document: Document) {}
  private emptyStatus(): RenderStatus {
    return { version: 1, renderId: '', phase: 'idle', jobs: 0, nextJob: 0, activeKind: null,
      outputUnits: 0, outputBytes: 0, error: null };
  }
  status = (): RenderStatus => ({ ...this.state });
  cancel = (): void => {
    this.generation++;
    this.current = null; this.markdown = null; this.tokens = []; this.jobs = [];
    this.output = ''; this.jobBytes = 0; this.state = this.emptyStatus();
  };
  private reject(error: unknown): RenderStatus {
    this.generation++;
    this.current = null; this.markdown = null; this.tokens = []; this.jobs = []; this.jobBytes = 0;
    this.state.phase = 'error'; this.state.activeKind = null;
    this.state.error = error instanceof PolicyError ? error.category : 'render-failed';
    this.output = ''; this.state.outputBytes = 0; this.state.outputUnits = 0;
    return this.status();
  }
  prepare = (value: unknown): RenderStatus => {
    this.cancel();
    try {
      this.current = request(value);
      this.state.renderId = this.current.renderId;
      this.markdown = this.parser(this.current);
      this.tokens = this.markdown.parse(this.current.source, {});
      checkTokenBounds(this.tokens);
      this.state.jobs = this.jobs.length;
      this.state.phase = this.jobs.length ? 'prepared' : 'ready';
      return this.status();
    } catch (error) { return this.reject(error); }
  };
  private addJob(kind: Job['kind'], source: string, display: boolean): number {
    const count = this.jobs.reduce((sum, job) => sum + Number(job.kind === kind), 0);
    const maximum = kind === 'math' ? limits.math : limits.diagrams;
    const sourceMaximum = kind === 'math' ? limits.mathSource : limits.diagramSource;
    if (count >= maximum || utf8Size(source) > sourceMaximum) fail(kind === 'math' ? 'math-limit' : 'diagram-limit');
    const index = this.jobs.length;
    this.jobs.push({ kind, source, display, output: '' });
    return index;
  }
  private parser(input: RenderRequest): MarkdownIt {
    const options = { html: false, linkify: false, typographer: false, maxNesting: limits.depth };
    const md = new MarkdownIt(options);
    const images = new Map(input.images.map(image => [image.source, image]));
    const navigation = new Map(input.navigation.map(nav => [nav.source, nav]));
    const slugger = new HeadingSlugger();
    // Footnotes are deliberately literal. Intercept definitions BEFORE ordinary
    // reference rules so continuation headings never reserve invisible anchors.
    md.block.ruler.before('reference', 'unsupported_footnote', (state, start, end, silent) => {
      const beginning = state.bMarks[start]! + state.tShift[start]!;
      if (!/^\[\^[^\]\r\n]+\]:/.test(state.src.slice(beginning, state.eMarks[start]))) return false;
      if (silent) return true;
      let next = start + 1;
      while (next < end) {
        if (state.isEmpty(next)) {
          if (next + 1 < end && state.sCount[next + 1]! >= 4) { next++; continue; }
          break;
        }
        if (state.sCount[next]! < 4) break;
        next++;
      }
      const token = state.push('unsupported_footnote', 'pre', 0);
      token.content = state.src.slice(state.bMarks[start], next < state.bMarks.length ? state.bMarks[next] : state.src.length);
      token.map = [start, next]; state.line = next;
      return true;
    });
    md.renderer.rules.unsupported_footnote = (tokens, index) => `<pre class="unsupported-footnote"><code>${escapeHtml(tokens[index]!.content)}</code></pre>\n`;
    md.block.ruler.before('fence', 'math_block', (state, start, end, silent) => {
      const begin = state.bMarks[start]! + state.tShift[start]!;
      const first = state.src.slice(begin, state.eMarks[start]);
      const opening = first.startsWith('$$') ? '$$' : first.startsWith('\\[') ? '\\[' : null;
      if (!opening) return false;
      const closing = opening === '$$' ? '$$' : '\\]';
      let content = first.slice(2);
      let next = start + 1;
      if (content.trimEnd().endsWith(closing)) content = content.trimEnd().slice(0, -2);
      else {
        let found = false;
        for (; next < end; next++) {
          const line = state.src.slice(state.bMarks[next], state.eMarks[next]);
          if (line.trimEnd().endsWith(closing)) { content += '\n' + line.trimEnd().slice(0, -2); next++; found = true; break; }
          content += '\n' + line;
          if (content.length > limits.mathSource) fail('math-limit');
        }
        if (!found) return false;
      }
      if (silent) return true;
      const token = state.push('math_block', 'div', 0);
      token.content = content; token.meta = this.addJob('math', content, true);
      token.map = [start, next]; state.line = next; return true;
    });
    md.inline.ruler.before('escape', 'math_inline', (state, silent) => {
      const start = state.pos;
      const opening = state.src.startsWith('\\(', start) ? '\\(' : state.src[start] === '$' && state.src[start + 1] !== '$' ? '$' : null;
      if (!opening) return false;
      const closing = opening === '$' ? '$' : '\\)';
      if (opening === '$' && /\s/.test(state.src[start + 1] ?? '')) return false;
      let end = start + opening.length;
      while (end < state.posMax) {
        if (state.src.startsWith(closing, end)) {
          let slashes = 0;
          for (let at = end - 1; at > start && state.src[at] === '\\'; at--) slashes++;
          if (slashes % 2 === 0) break;
        }
        if (end - start > limits.mathSource) fail('math-limit');
        if (state.src[end] === '\n') return false;
        end++;
      }
      if (end >= state.posMax || end === start + opening.length || opening === '$' && /\s/.test(state.src[end - 1]!)) return false;
      if (!silent) {
        const token = state.push('math_inline', 'span', 0);
        token.content = state.src.slice(start + opening.length, end);
        token.meta = this.addJob('math', token.content, false);
      }
      state.pos = end + closing.length; return true;
    });
    const mathOutput = (tokens: Token[], index: number): string => this.jobs[tokens[index]!.meta as number]!.output;
    md.renderer.rules.math_inline = mathOutput; md.renderer.rules.math_block = mathOutput;
    const fence = md.renderer.rules.fence!;
    md.core.ruler.after('inline', 'bounded_jobs_and_tasks', state => {
      checkTokenBounds(state.tokens);
      for (let index = 0; index < state.tokens.length; index++) {
        const token = state.tokens[index]!;
        if (token.type === 'fence' && token.info.trim().toLowerCase() === 'mermaid') token.meta = this.addJob('diagram', token.content, true);
        if (token.type === 'inline' && state.tokens[index - 1]?.type === 'paragraph_open'
          && state.tokens[index - 2]?.type === 'list_item_open' && token.children?.[0]?.type === 'text') {
          const child = token.children[0]; const match = /^\[([ xX])\] /.exec(child.content);
          if (match) {
            child.content = child.content.slice(match[0].length);
            const marker = new state.Token('task_marker', 'span', 0);
            marker.content = match[1]!.toLowerCase(); token.children.unshift(marker);
          }
        }
      }
    });
    md.renderer.rules.task_marker = (tokens, index) => `<span class="task-marker" role="checkbox" aria-checked="${tokens[index]!.content === 'x'}" aria-label="${tokens[index]!.content === 'x' ? 'Completed task' : 'Incomplete task'}">[${tokens[index]!.content}]</span> `;
    md.renderer.rules.fence = (tokens, index, options, env, self) => tokens[index]!.info.trim().toLowerCase() === 'mermaid'
      ? `<div class="diagram">${this.jobs[tokens[index]!.meta as number]!.output}</div>\n` : fence(tokens, index, options, env, self);
    md.renderer.rules.heading_open = (tokens, index, options, _env, self) => {
      const token = tokens[index]!;
      // Called only at the actual emission point; no source-offset prepass.
      const slug = slugger.slug(anchorText(tokens[index + 1]?.children ?? []));
      token.attrSet('id', headingId(slug)); token.attrSet('data-anchor', slug);
      return self.renderToken(tokens, index, options);
    };
    md.renderer.rules.image = (tokens, index) => {
      const token = tokens[index]!; const mapping = lookup(images, token.attrGet('src') ?? '');
      const alt = escapeHtml(anchorText(token.children ?? []));
      if (!mapping) return `<span class="unsupported-image" role="note">[Image unavailable: ${alt}]</span>`;
      return `<img data-media="${input.mediaBase}${mapping.handle}" width="${mapping.width}" height="${mapping.height}" alt="${alt}">`;
    };
    md.renderer.rules.link_open = (tokens, index) => {
      const destination = tokens[index]!.attrGet('href') ?? '';
      let url: string | null = null;
      if (destination.startsWith('#')) {
        try { const slug = decodeURIComponent(destination.slice(1)); if (!/[\u0000-\u001f\u007f]/.test(slug)) url = `#${headingId(slug)}`; } catch { /* Literal unsupported destination. */ }
      } else {
        const mapping = lookup(navigation, destination); if (mapping) url = input.navBase + mapping.handle;
      }
      return url ? `<a href="${escapeHtml(url)}">` : '<a class="unsupported-link" role="note" aria-label="Unsupported link">';
    };
    return md;
  }
  runJob = async (index: number): Promise<void> => {
    if (!this.current || this.state.phase !== 'prepared' || index !== this.state.nextJob || !Number.isInteger(index)) {
      this.reject(new PolicyError('invalid-request')); return;
    }
    const generation = this.generation;
    const job = this.jobs[index]!;
    this.state.phase = 'running'; this.state.activeKind = job.kind;
    try {
      let output: string;
      if (job.kind === 'math') {
        if (/\\(?:url|href|includegraphics|html\w*|class|style|cssId|require|def|gdef|edef|xdef|let|futurelet|global|newcommand|renewcommand|providecommand|message|errmessage|show|csname|endcsname|catcode)\b/.test(job.source)) output = unsupported(job.source, 'math');
        else {
          try { output = katex.renderToString(job.source, { displayMode: job.display, output: 'htmlAndMathml',
            trust: false, strict: 'error', throwOnError: true, maxExpand: 1000, maxSize: 20,
            globalGroup: false, macros: Object.create(null) }); }
          catch { output = unsupported(job.source, 'math'); }
        }
      } else output = await this.diagram(job, index);
      if (generation !== this.generation) return;
      const bytes = utf8Size(output);
      if (bytes > (job.kind === 'math' ? limits.mathOutput : limits.diagramOutput)) fail(job.kind === 'math' ? 'math-limit' : 'diagram-limit');
      this.jobBytes += bytes;
      if (this.jobBytes > limits.output) fail('output-limit');
      job.output = output; this.state.nextJob++;
      this.state.activeKind = null;
      this.state.phase = this.state.nextJob === this.jobs.length ? 'ready' : 'prepared';
    } catch (error) { if (generation === this.generation) this.reject(error); }
  };
  private async diagram(job: Job, index: number): Promise<string> {
    const kind = diagramKind(job.source);
    if (!kind) return unsupported(job.source, 'diagram');
    const input = this.current!;
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      logLevel: 'fatal', htmlLabels: false, theme: 'neutral', look: 'classic',
      fontFamily: 'system-ui, sans-serif', deterministicIds: true, deterministicIDSeed: `${input.renderId}-${index}`,
      maxTextSize: limits.diagramSource, maxEdges: limits.edges, layout: 'dagre',
      flowchart: { defaultRenderer: 'dagre-wrapper', htmlLabels: false, useMaxWidth: false },
      sequence: { useMaxWidth: false, actorFontFamily: 'system-ui, sans-serif', noteFontFamily: 'system-ui, sans-serif',
        messageFontFamily: 'system-ui, sans-serif' }, arrowMarkerAbsolute: false });
    let diagram;
    try { diagram = await mermaid.mermaidAPI.getDiagramFromText(job.source); }
    catch (error) {
      // Mermaid 11.17.2 aborts expansion at its real DB edge ceiling. The
      // library message is inspected only for classification, never returned.
      if (error instanceof Error && error.message.startsWith('Edge limit exceeded.')) fail('diagram-limit');
      return unsupported(job.source, 'diagram');
    }
    if (kind === 'flowchart' && !['flowchart', 'flowchart-v2'].includes(diagram.type)
      || kind === 'sequence' && diagram.type !== 'sequence') return unsupported(job.source, 'diagram');
    checkDiagramDatabase(kind, diagram.db);
    const container = this.document.createElement('div');
    this.document.body.append(container);
    try {
      let svg: string;
      try { svg = (await mermaid.render(`diagram-${input.renderId}-${index}`, job.source, container)).svg; }
      catch { return unsupported(job.source, 'diagram'); }
      if (utf8Size(svg) > limits.diagramOutput) fail('diagram-limit');
      const holder = this.document.createElement('template'); holder.innerHTML = svg;
      // Symbols/use are outside the SVG subset. Mermaid eagerly emits unused
      // actor symbols; discard inert definitions before retained-output quotas.
      for (const symbol of holder.content.querySelectorAll('defs > symbol')) symbol.remove();
      enforceDomBounds(holder.content);
      const root = holder.content.firstElementChild;
      if (!root || root.localName !== 'svg' || holder.content.children.length !== 1) fail('unsupported-output');
      materializeDiagramStyles(root);
      prefixDiagramIds(root, `vnote-g-${input.renderId}-${index}-`);
      return root.outerHTML;
    } finally { container.remove(); }
  }
  finish = (): RenderStatus => {
    if (!this.current || !this.markdown || this.state.phase !== 'ready') return this.reject(new PolicyError('invalid-request'));
    try {
      const policy: OutputPolicy = { renderId: this.current.renderId, mediaBase: this.current.mediaBase, navBase: this.current.navBase,
        media: new Set(this.current.images.map(image => image.handle)), navigation: new Set(this.current.navigation.map(nav => nav.handle)) };
      const markup = this.markdown.renderer.render(this.tokens, this.markdown.options, {});
      this.output = sanitizeFinal(this.document, markup, policy);
      this.state.outputUnits = this.output.length; this.state.outputBytes = utf8Size(this.output);
      this.state.phase = 'complete';
      // Retain only final bounded output, not source plus all intermediate trees.
      this.current = null; this.markdown = null; this.tokens = []; this.jobs = [];
      return this.status();
    } catch (error) { return this.reject(error); }
  };
  readOutput = (offset: number, units: number): string => {
    if (this.state.phase !== 'complete' || !Number.isSafeInteger(offset) || offset < 0 || offset > this.output.length
      || !Number.isSafeInteger(units) || units < 1 || units > 32768) return '';
    const first = this.output.charCodeAt(offset), previous = this.output.charCodeAt(offset - 1);
    if (first >= 0xdc00 && first <= 0xdfff && previous >= 0xd800 && previous <= 0xdbff) return '';
    let end = Math.min(offset + units, this.output.length);
    const last = this.output.charCodeAt(end - 1), next = this.output.charCodeAt(end);
    // Native value conversion may replace an isolated surrogate before a caller
    // can join it. Return complete scalars and advance by the actual chunk length.
    if (last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end--;
    return this.output.slice(offset, end);
  };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  const controller = new RenderController(document);
  Object.defineProperty(window, 'vnoteRender', { configurable: false, writable: false,
    value: Object.freeze({ prepare: controller.prepare, runJob: controller.runJob, finish: controller.finish,
      status: controller.status, readOutput: controller.readOutput, cancel: controller.cancel }) });
}
