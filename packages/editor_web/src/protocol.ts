// SPDX-License-Identifier: LGPL-3.0-only
// Offsets are exact source UTF-16 units. This module has no DOM or storage access.
import { EditorState, Text, type Transaction } from '@codemirror/state';
import { history, historyField, isolateHistory } from '@codemirror/commands';
export const LIMITS = Object.freeze({
  documentUnits: 4 * 1024 * 1024,
  documentBytes: 4 * 1024 * 1024,
  fullMessageBytes: 32 * 1024 * 1024,
  editBytes: 512 * 1024,
  controlBytes: 8 * 1024,
  ranges: 256,
  insertedUnits: 65536,
  outstandingBatches: 8,
  outstandingBytes: 2 * 1024 * 1024,
  pendingControls: 32,
  replayEntries: 64,
  historyGroups: 200,
  historyBytes: 16 * 1024 * 1024,
});

export class ProtocolError extends Error {}
export function requireThat(condition: unknown, message: string): asserts condition {
  if (!condition) throw new ProtocolError(message);
}
export function integer(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}
export function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}
function keys(value: Record<string, unknown>, allowed: readonly string[]): void {
  requireThat(Object.keys(value).every(key => allowed.includes(key)), 'Unexpected message field.');
}

// Counting avoids allocating a UTF-8 copy. Provisional IME uses replacement-width
// accounting, but committed source always rejects unpaired surrogate code units.
export function utf8Length(text: string, strict = true): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) bytes++;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) { bytes += 4; i++; }
      else { requireThat(!strict, 'Unpaired UTF-16 surrogate.'); bytes += 3; }
    } else {
      requireThat(!strict || c < 0xdc00 || c > 0xdfff, 'Unpaired UTF-16 surrogate.');
      bytes += 3;
    }
  }
  return bytes;
}
export function validateSource(text: string): number {
  requireThat(text.length <= LIMITS.documentUnits, 'Document exceeds UTF-16 limit.');
  const bytes = utf8Length(text);
  requireThat(bytes <= LIMITS.documentBytes, 'Document exceeds UTF-8 limit.');
  return bytes;
}
export interface Source {
  readonly length: number;
  sliceString(from: number, to: number): string;
}
export function stringSource(text: string): Source {
  return { length: text.length, sliceString: (from, to) => text.slice(from, to) };
}
export function validBoundary(source: Source, at: number): boolean {
  if (!integer(at) || at > source.length) return false;
  if (at === 0 || at === source.length) return true;
  const pair = source.sliceString(at - 1, at + 1);
  const a = pair.charCodeAt(0), b = pair.charCodeAt(1);
  return !(a === 13 && b === 10)
    && !(a >= 0xd800 && a <= 0xdbff && b >= 0xdc00 && b <= 0xdfff);
}
export interface Selection { anchor: number; head: number }
export function selectionShape(value: unknown): asserts value is Selection {
  requireThat(object(value), 'Selection must be an object.');
  keys(value, ['anchor', 'head']);
  requireThat(integer(value.anchor) && integer(value.head), 'Invalid selection offsets.');
}
export function validateSelection(source: Source, selection: Selection): void {
  requireThat(validBoundary(source, selection.anchor) && validBoundary(source, selection.head),
    'Selection splits a source pair or is out of range.');
}
export interface Change { from: number; to: number; insert: string }
export interface ChangeMetrics { units: number; bytes: number; retainedBytes: number }
export function validateChanges(
  source: Source, sourceBytes: number, changes: readonly Change[], provisional = false,
): ChangeMetrics {
  requireThat(changes.length > 0 && changes.length <= LIMITS.ranges, 'Edit range count exceeds limit.');
  let end = -1, inserted = 0, units = source.length, bytes = sourceBytes, retainedBytes = 0;
  for (const change of changes) {
    requireThat(object(change), 'Invalid change.');
    keys(change as unknown as Record<string, unknown>, ['from', 'to', 'insert']);
    requireThat(integer(change.from) && integer(change.to) && change.from <= change.to
      && change.to <= source.length && change.from >= end, 'Unsorted, overlapping, or invalid edit range.');
    requireThat(typeof change.insert === 'string', 'Inserted source must be a string.');
    if (!provisional) requireThat(validBoundary(source, change.from) && validBoundary(source, change.to),
      'Edit splits a surrogate or CRLF pair.');
    inserted += change.insert.length;
    requireThat(inserted <= LIMITS.insertedUnits, 'Edit exceeds insertion limit; paste a smaller portion.');
    const removed = source.sliceString(change.from, change.to);
    units += change.insert.length - (change.to - change.from);
    bytes += utf8Length(change.insert, !provisional) - utf8Length(removed, !provisional);
    // A provisional range may cut a base surrogate pair. Reserve the difference
    // between pair encoding and replacement-width accounting until finalization.
    if (provisional) bytes += 2;
    retainedBytes += 2 * (change.insert.length + change.to - change.from);
    end = change.to;
  }
  requireThat(units <= LIMITS.documentUnits && bytes <= LIMITS.documentBytes,
    'Edit exceeds document limit; paste a smaller portion or import a file.');
  return { units, bytes, retainedBytes };
}
export function applyChanges(text: string, changes: readonly Change[], selection?: Selection): string {
  validateChanges(stringSource(text), validateSource(text), changes);
  const pieces: string[] = [];
  let at = 0;
  for (const change of changes) { pieces.push(text.slice(at, change.from), change.insert); at = change.to; }
  pieces.push(text.slice(at));
  const result = pieces.join('');
  if (selection) validateSelection(stringSource(result), selection);
  return result;
}

export interface Envelope {
  v: 1;
  type: string;
  documentId: string;
  generation: string;
  revision: number;
  requestId: string;
}
export type HostMessage = Envelope & (
  | { type: 'load'; text: string; language: 'markdown' | 'text'; baseVersion: string; lineEndingPolicy: 'preserve'; reason: 'open'; selection: Selection }
  | { type: 'ack'; stage: 'received' | 'rejected'; throughRevision: number; error?: string }
  | { type: 'selection'; mode: 'request' }
  | { type: 'selection'; anchor: number; head: number; mode?: never }
  | { type: 'insert'; text: string; anchor: number; head: number }
  | { type: 'command'; command: 'undo' | 'redo' }
  | { type: 'theme'; theme: 'light' | 'dark' }
  | { type: 'save'; mode: 'snapshotRequest'; reason?: 'manual' | 'close' }
  | { type: 'close'; mode: 'request'; disposition: 'discard' | 'written' }
);
const HEADER = ['v', 'type', 'documentId', 'generation', 'revision', 'requestId'];
export function encodeMessage(message: unknown, maximum = LIMITS.fullMessageBytes): string {
  const encoded = JSON.stringify(message);
  requireThat(typeof encoded === 'string' && encoded.length <= maximum && utf8Length(encoded) <= maximum,
    'Message exceeds encoded byte limit.');
  return encoded;
}
export function decodeHostMessage(raw: string): HostMessage {
  requireThat(raw.length <= LIMITS.fullMessageBytes && utf8Length(raw) <= LIMITS.fullMessageBytes,
    'Message exceeds encoded byte limit.');
  return validateHostMessage(JSON.parse(raw));
}
export function validateHostMessage(value: unknown): HostMessage {
  requireThat(object(value), 'Message must be an object.');
  requireThat(value.v === 1 && typeof value.documentId === 'string'
    && value.documentId.length > 0 && value.documentId.length <= 256 && !/[^A-Za-z0-9._:-]/.test(value.documentId)
    && typeof value.type === 'string' && typeof value.generation === 'string'
    && value.generation.length === 32 && /^[0-9a-f]{32}$/.test(value.generation) && integer(value.revision)
    && typeof value.requestId === 'string' && /^(host|editor)-[1-9][0-9]{0,15}$/.test(value.requestId)
    && integer(Number(value.requestId.slice(value.requestId.indexOf('-') + 1))), 'Invalid protocol envelope.');
  requireThat(value.type === 'ack' || value.requestId.startsWith('host-'), 'Wrong request ID direction.');
  encodeMessage(value, value.type === 'load' ? LIMITS.fullMessageBytes : LIMITS.controlBytes);
  switch (value.type) {
    case 'load':
      keys(value, [...HEADER, 'text', 'language', 'baseVersion', 'lineEndingPolicy', 'reason', 'selection']);
      requireThat(value.revision === 0 && typeof value.text === 'string' && typeof value.baseVersion === 'string' && value.baseVersion.length === 64 && /^[0-9a-f]{64}$/.test(value.baseVersion)
        && (value.language === 'markdown' || value.language === 'text')
        && value.lineEndingPolicy === 'preserve' && value.reason === 'open', 'Invalid load policy.');
      selectionShape(value.selection);
      validateSource(value.text);
      validateSelection(stringSource(value.text), value.selection);
      break;
    case 'ack':
      keys(value, [...HEADER, 'stage', 'throughRevision', 'error']);
      requireThat((value.stage === 'received' || value.stage === 'rejected') && integer(value.throughRevision)
        && (value.error === undefined || (typeof value.error === 'string' && value.error.length <= 1024))
        && (value.stage !== 'rejected' || typeof value.error === 'string'), 'Unsupported acknowledgement.');
      break;
    case 'selection':
      if ('mode' in value) {
        keys(value, [...HEADER, 'mode']);
        requireThat(value.mode === 'request', 'Invalid selection request mode.');
      } else {
        keys(value, [...HEADER, 'anchor', 'head']);
        requireThat(integer(value.anchor) && integer(value.head), 'Invalid selection offsets.');
      }
      break;
    case 'insert':
      keys(value, [...HEADER, 'text', 'anchor', 'head']);
      requireThat(typeof value.text === 'string' && value.text.length <= LIMITS.insertedUnits,
        'Invalid insertion source or size.');
      utf8Length(value.text);
      requireThat(integer(value.anchor) && integer(value.head), 'Invalid insertion selection.');
      break;
    case 'command':
      keys(value, [...HEADER, 'command']);
      requireThat(value.command === 'undo' || value.command === 'redo', 'Unknown command.');
      break;
    case 'theme':
      keys(value, [...HEADER, 'theme']);
      requireThat(value.theme === 'light' || value.theme === 'dark', 'Unknown theme.');
      break;
    case 'save':
      keys(value, [...HEADER, 'mode', 'reason']);
      requireThat(value.reason === undefined || ['manual', 'close'].includes(String(value.reason)), 'Invalid snapshot reason.');
      requireThat(value.mode === 'snapshotRequest', 'Unsupported snapshot mode.');
      break;
    case 'close':
      keys(value, [...HEADER, 'mode', 'disposition']);
      requireThat(value.mode === 'request' && (value.disposition === 'discard' || value.disposition === 'written'), 'Invalid close barrier.');
      break;
    default: throw new ProtocolError('Unknown message type.');
  }
  return value as unknown as HostMessage;
}
export function validateSession(message: Envelope, documentId: string, generation: string, revision: number, exact = false): void {
  requireThat(message.documentId === documentId && message.generation === generation, 'Stale or unknown session.');
  requireThat(exact ? message.revision === revision : message.revision <= revision,
    exact ? 'Message does not match current revision.' : 'Message refers to a future revision.');
}
// The live editor and history regressions use this same exact-source transaction.
// Transport credits are checked separately by the ordinary edit preflight.
export function insertionTransaction(
  state: EditorState, sourceBytes: number, message: Extract<HostMessage, { type: 'insert' }>,
): Transaction {
  const current = state.selection.main;
  requireThat(message.anchor === current.anchor && message.head === current.head,
    'Selection changed before insertion; choose Insert link again at the intended cursor.');
  validateSelection(state.doc, message);
  const from = Math.min(message.anchor, message.head), to = Math.max(message.anchor, message.head);
  requireThat(from !== to || message.text.length !== 0, 'Insertion must change source.');
  validateChanges(state.doc, sourceBytes, [{ from, to, insert: message.text }]);
  const position = from + message.text.length;
  const transaction = state.update({
    changes: { from, to, insert: Text.of(message.text.split('\n')) },
    selection: { anchor: position, head: position },
    annotations: isolateHistory.of('full'), userEvent: 'input.insert', filter: false,
  });
  validateSelection(transaction.newDoc, { anchor: position, head: position });
  return transaction;
}

export function assertCredits(count: number, bytes: number): void {
  requireThat(count <= LIMITS.outstandingBatches && bytes <= LIMITS.outstandingBytes,
    'Waiting for the host to receive edits. Text is still only in memory.');
}

interface ReplayEntry { fingerprint: string | null; response: string | null }
// Old requests cannot become new operations when the bounded replay window expires.
export class RequestCache {
  private readonly entries = new Map<string, ReplayEntry>();
  private highestHostRequest = 0;
  begin(message: HostMessage, fingerprint: string): ReplayEntry | undefined {
    const key = `${message.type}:${message.requestId}`;
    const old = this.entries.get(key);
    if (old) {
      requireThat(old.fingerprint === null || old.fingerprint === fingerprint, 'Request ID was reused with different content.');
      return old;
    }
    if (message.type !== 'ack') {
      const number = Number(message.requestId.slice(5));
      requireThat(number > this.highestHostRequest, 'Request is outside the replay window; preserve the session.');
      this.highestHostRequest = number;
    }
    this.entries.set(key, { fingerprint, response: null });
    if (this.entries.size > LIMITS.replayEntries) this.entries.delete(this.entries.keys().next().value!);
    return undefined;
  }
  // Receipt retires full snapshot responses and the initial load source. Retain
  // a bounded tombstone so an old transfer cannot install or capture text again.
  release(type: 'load' | 'save', requestId: string): void {
    const entry = this.entries.get(`${type}:${requestId}`);
    if (entry) {
      entry.response = null;
      if (type === 'load') entry.fingerprint = null;
    }
  }
  complete(message: HostMessage, response: string): void {
    const entry = this.entries.get(`${message.type}:${message.requestId}`);
    if (entry) entry.response = response;
  }
}

// CodeMirror's public history serialization allows pruning complete oldest events.
// This adapter is covered by real history serialize/restore/undo regression tests.
export interface SerializedHistory { done: unknown[]; undone: unknown[] }
export function trimHistory(input: SerializedHistory, maxGroups = LIMITS.historyGroups, maxBytes = LIMITS.historyBytes) {
  const textBytes = (value: unknown): number => {
    if (typeof value === 'string') return value.length * 2;
    if (Array.isArray(value)) return value.reduce<number>((sum, item) => sum + textBytes(item), 0);
    if (object(value)) return Object.values(value).reduce<number>((sum, item) => sum + textBytes(item), 0);
    return 0;
  };
  const doneWeights = input.done.map(textBytes), undoneWeights = input.undone.map(textBytes);
  let doneStart = 0, undoneStart = 0;
  let bytes = [...doneWeights, ...undoneWeights].reduce((sum, size) => sum + size, 0);
  let groups = input.done.length + input.undone.length;
  while (groups > maxGroups || bytes > maxBytes) {
    // Keep the closest undo step when possible; the start of each branch is oldest.
    if (input.done.length - doneStart > 1 || undoneStart === input.undone.length) {
      bytes -= doneWeights[doneStart++]!;
    } else {
      bytes -= undoneWeights[undoneStart++]!;
    }
    groups--;
  }
  return { history: { done: input.done.slice(doneStart), undone: input.undone.slice(undoneStart) },
    bytes, pruned: doneStart + undoneStart > 0 };
}

export function prepareHistoryPrune(state: EditorState) {
  const serialized = state.toJSON({ history: historyField });
  const bounded = trimHistory(serialized.history as SerializedHistory);
  if (!bounded.pruned) return { ...bounded, value: state.field(historyField) };
  serialized.history = bounded.history;
  // Default parsing would collapse CRLF, invalidating end-of-document selection.
  const restored = EditorState.fromJSON(serialized,
    { extensions: [history(), EditorState.lineSeparator.of('\n')] },
    { history: historyField });
  return { ...bounded, value: restored.field(historyField) };
}

export function preferredLineEnding(source: Source): string {
  const counts = [0, 0, 0], first = [Infinity, Infinity, Infinity];
  let pendingCR = -1;
  const add = (kind: number, at: number) => { counts[kind] = counts[kind]! + 1; first[kind] = Math.min(first[kind]!, at); };
  for (let offset = 0; offset < source.length; offset += 4096) {
    const chunk = source.sliceString(offset, Math.min(source.length, offset + 4096));
    for (let i = 0; i < chunk.length; i++) {
      const c = chunk.charCodeAt(i), at = offset + i;
      if (pendingCR >= 0) {
        if (c === 10) { add(1, pendingCR); pendingCR = -1; continue; }
        add(2, pendingCR); pendingCR = -1;
      }
      if (c === 13) pendingCR = at;
      else if (c === 10) add(0, at);
    }
  }
  if (pendingCR >= 0) add(2, pendingCR);
  let winner = 0;
  for (let i = 1; i < 3; i++) if (counts[i]! > counts[winner]!
    || (counts[i] === counts[winner] && first[i]! < first[winner]!)) winner = i;
  return ['\n', '\r\n', '\r'][winner]!;
}
