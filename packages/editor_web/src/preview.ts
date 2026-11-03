// SPDX-License-Identifier: LGPL-3.0-only
// No Markdown/math/diagram imports and no command channel in the visible viewer.
import type { Preferences } from './render_policy';

const maximumResident = 64 * 1024 * 1024;
const maximumOutput = 16 * 1024 * 1024;
const root = document.getElementById('preview')!;
const renderId = root.dataset.renderId ?? '';
const validGeneration = /^[a-f0-9]{32}$/.test(renderId);
const mediaPattern = new RegExp(`^(?:https://preview\\.vnote\\.invalid|vnote-preview://preview\\.vnote\\.invalid)/g/${renderId}/media/([a-f0-9]{32})$`);
interface ResidentImage { element: HTMLImageElement; handle: string; url: string; bytes: number; near: boolean; resident: boolean; loading: boolean; failed: boolean }
const images: ResidentImage[] = [];
const waiting = new Set<ResidentImage>();
const residentHandles = new Map<string, number>();
let residentBytes = 0;
let loading = 0;
let disposed = false;
let installPhase: 'empty' | 'receiving' | 'installed' | 'failed' = 'empty';
let expectedUnits = 0;
let expectedBytes = 0;
let receivedUnits = 0;
let chunks: string[] = [];

function utf8Size(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit < 0x80) bytes++;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < value.length
      && value.charCodeAt(index + 1) >= 0xdc00 && value.charCodeAt(index + 1) <= 0xdfff) { bytes += 4; index++; }
    else bytes += 3;
  }
  return bytes;
}
function refuseInstall(): false { installPhase = 'failed'; chunks = []; receivedUnits = 0; return false; }
function begin(value: unknown): boolean {
  if (disposed || installPhase !== 'empty' || !validGeneration || !value || typeof value !== 'object'
    || Array.isArray(value) || Object.keys(value).length !== 4 || !('version' in value) || value.version !== 1
    || !('renderId' in value) || value.renderId !== renderId || !('outputUnits' in value) || !('outputBytes' in value)
    || typeof value.outputUnits !== 'number' || typeof value.outputBytes !== 'number'
    || !Number.isSafeInteger(value.outputUnits) || !Number.isSafeInteger(value.outputBytes)
    || value.outputUnits < 0 || value.outputBytes < value.outputUnits || value.outputBytes > maximumOutput) return refuseInstall();
  expectedUnits = value.outputUnits; expectedBytes = value.outputBytes;
  installPhase = 'receiving'; return true;
}
function append(offset: number, chunk: string): boolean {
  if (disposed || installPhase !== 'receiving' || offset !== receivedUnits || typeof chunk !== 'string'
    || chunk.length < 1 || chunk.length > 32768 || receivedUnits + chunk.length > expectedUnits) return refuseInstall();
  chunks.push(chunk); receivedUnits += chunk.length; return true;
}
function finish(): boolean {
  if (disposed || installPhase !== 'receiving' || receivedUnits !== expectedUnits) return refuseInstall();
  const markup = chunks.join(''); chunks = [];
  if (utf8Size(markup) !== expectedBytes) return refuseInstall();
  const template = document.createElement('template');
  template.innerHTML = markup;
  // This is installation of the isolated renderer's already-final-sanitized
  // fragment, not a second renderer. Recheck resource ceilings before attachment.
  const stack: Array<{ node: Node; depth: number }> = [{ node: template.content, depth: 0 }];
  let nodes = 0;
  while (stack.length) {
    const { node, depth } = stack.pop()!;
    if (++nodes > 100000 || depth > 64) return refuseInstall();
    if (node.nodeType === 1) {
      const element = node as Element;
      for (const attribute of element.attributes) if (utf8Size(attribute.value) > 8192) return refuseInstall();
    }
    for (let child = node.lastChild; child; child = child.previousSibling) stack.push({ node: child, depth: depth + 1 });
  }
  root.replaceChildren(template.content);
  installPhase = 'installed'; collectImages(); return true;
}

function release(image: ResidentImage): void {
  if (!image.resident) return;
  // Retire the src before removing its handle from native-polled residency.
  image.element.removeAttribute('src');
  image.resident = false; residentBytes -= image.bytes;
  const references = residentHandles.get(image.handle)! - 1;
  if (references) residentHandles.set(image.handle, references); else residentHandles.delete(image.handle);
  if (image.loading) {
    image.loading = false; loading--;
    if (!disposed) {
      // An aborted decoder's late event must not settle a later admission.
      const previous = image.element;
      image.element = previous.cloneNode(false) as HTMLImageElement;
      previous.replaceWith(image.element);
      observer.unobserve(previous); byElement.delete(previous);
      byElement.set(image.element, image); bindImage(image);
      image.near = false; observer.observe(image.element);
    }
  }
}
function pump(): void {
  if (disposed) return;
  for (const image of waiting) {
    if (loading >= 4) break;
    if (residentBytes + image.bytes > maximumResident) continue;
    waiting.delete(image);
    image.resident = true; image.loading = true;
    residentBytes += image.bytes; loading++;
    residentHandles.set(image.handle, (residentHandles.get(image.handle) ?? 0) + 1);
    image.element.src = image.url;
  }
}
function bindImage(image: ResidentImage): void {
  const element = image.element;
  element.decoding = 'async';
  const complete = (failed: boolean): void => {
    if (image.element !== element || !image.resident || !image.loading) return;
    image.loading = false; loading--;
    if (failed) {
      image.failed = true; release(image);
      element.classList.add('unavailable');
      element.setAttribute('aria-label', 'Image unavailable');
    }
    pump();
  };
  element.addEventListener('load', () => complete(false));
  element.addEventListener('error', () => complete(true));
}
function collectImages(): void {
  for (const element of root.querySelectorAll<HTMLImageElement>('img[data-media]')) {
    const url = element.dataset.media ?? '';
    const match = mediaPattern.exec(url);
    const width = Number(element.getAttribute('width')); const height = Number(element.getAttribute('height'));
    if (!match || !Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 || width * height > 16000000) continue;
    const image: ResidentImage = { element, handle: match[1]!, url, bytes: width * height * 4,
      near: false, resident: false, loading: false, failed: false };
    bindImage(image);
    images.push(image);
    byElement.set(element, image); observer.observe(element);
  }
}
const byElement = new Map<Element, ResidentImage>();
const observer = new IntersectionObserver(entries => {
  for (const entry of entries) {
    const image = byElement.get(entry.target);
    if (!image) continue;
    image.near = entry.isIntersecting;
    if (!image.near) { waiting.delete(image); release(image); }
    else if (!image.resident && !image.failed) waiting.add(image);
  }
  pump();
}, { rootMargin: '256px' });

function preferences(value: Preferences): void {
  if (!value || Object.keys(value).length !== 4 || typeof value.dark !== 'boolean'
    || typeof value.highContrast !== 'boolean' || typeof value.reducedMotion !== 'boolean'
    || !Number.isFinite(value.fontScale) || value.fontScale < .75 || value.fontScale > 3) return;
  document.documentElement.dataset.theme = value.dark ? 'dark' : 'light';
  document.documentElement.dataset.contrast = value.highContrast ? 'high' : 'normal';
  document.documentElement.dataset.motion = value.reducedMotion ? 'reduced' : 'normal';
  document.documentElement.style.fontSize = `${16 * value.fontScale}px`;
  for (const svg of root.querySelectorAll<SVGSVGElement>('.diagram > svg')) {
    const viewBox = (svg.getAttribute('viewBox') ?? '').trim().split(/[ ,]+/).map(Number);
    const width = viewBox.length === 4 ? viewBox[2] : Number(svg.getAttribute('width'));
    if (width && Number.isFinite(width) && width > 0 && width <= 100000) {
      svg.style.width = `${width * value.fontScale}px`;
      svg.style.maxWidth = value.fontScale > 1 ? 'none' : '100%';
      svg.style.height = 'auto';
    }
  }
}
function fragment(slug: string): void {
  if (typeof slug !== 'string' || slug.length > 8192 || /[\u0000-\u001f\u007f]/.test(slug)) return;
  const heading = document.getElementById(`vnote-h-${slug}`);
  if (heading && root.contains(heading) && /^H[1-6]$/.test(heading.tagName)) {
    heading.scrollIntoView({ block: 'start', behavior: 'auto' });
    heading.setAttribute('tabindex', '-1'); heading.focus({ preventScroll: true });
  }
}
root.addEventListener('click', event => {
  const target = event.target instanceof Element ? event.target.closest('a') : null;
  const href = target?.getAttribute('href');
  if (href?.startsWith('#vnote-h-')) { event.preventDefault(); fragment(href.slice('#vnote-h-'.length)); }
});
window.addEventListener('pagehide', () => {
  disposed = true; chunks = []; observer.disconnect(); for (const image of images) release(image);
}, { once: true });
Object.defineProperty(window, 'vnotePreview', { configurable: false, writable: false,
  value: Object.freeze({ begin, append, finish, preferences, fragment,
    status: () => ({ version: 1, renderId, images: [...residentHandles.keys()] }) }) });
