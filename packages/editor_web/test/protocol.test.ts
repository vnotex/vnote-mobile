// SPDX-License-Identifier: LGPL-3.0-only
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EditorState, Text } from '@codemirror/state';
import { history, historyField, isolateHistory, undo, redo, undoDepth } from '@codemirror/commands';
import {
  applyChanges, assertCredits, decodeHostMessage, encodeMessage, insertionTransaction, LIMITS, ProtocolError, trimHistory, prepareHistoryPrune,
  preferredLineEnding, RequestCache, stringSource, utf8Length, validBoundary,
  validateChanges, validateHostMessage, validateSelection, validateSession, validateSource,
} from '../src/protocol';

const generation = '0123456789abcdef0123456789abcdef';
const documentId = 'bookA:nodeA';
const baseVersion = 'a'.repeat(64);
const envelope = (type: string, extra: Record<string, unknown> = {}) => ({
  v: 1, type, documentId, generation, revision: 0, requestId: 'host-1', ...extra,
});
const load = (text: string) => envelope('load', {
  text, language: 'markdown', baseVersion, lineEndingPolicy: 'preserve', reason: 'open', selection: { anchor: 0, head: 0 },
});

test('exact source survives edits with BOM, mixed separators, combining marks, emoji and RTL', () => {
  const original = '\ufeff# 标题\r\nCafe\u0301\n日本語\rאב😀';
  assert.equal(validateHostMessage(load(original)).type, 'load');
  const position = original.indexOf('日本');
  const edited = applyChanges(original, [{ from: position, to: position + 3, insert: '中文' }]);
  assert.equal(edited, '\ufeff# 标题\r\nCafe\u0301\n中文\rאב😀');
  assert.equal(applyChanges(edited, [{ from: position, to: position + 2, insert: '日本語' }]), original);
  assert.equal(utf8Length(original), Buffer.byteLength(original, 'utf8'));
});

test('all malformed committed surrogate forms are rejected before producing replacement source', () => {
  const original = 'keep 😀\r\ntext';
  for (const text of ['\ud800', '\udfff', 'a\ud800z', '\udfff\ud800']) {
    assert.throws(() => validateSource(text), ProtocolError);
    assert.throws(() => validateHostMessage(load(text)), ProtocolError);
    assert.throws(() => applyChanges(original, [{ from: 0, to: 0, insert: text }]), ProtocolError);
  }
  assert.equal(utf8Length('\ud800', false), 3);
});

test('edit and selection boundaries cannot bisect surrogate pairs or CRLF', () => {
  const original = 'a😀\r\nb';
  const source = stringSource(original);
  for (const at of [2, 4]) {
    assert.equal(validBoundary(source, at), false);
    assert.throws(() => applyChanges(original, [{ from: at, to: at, insert: 'x' }]), ProtocolError);
    assert.throws(() => applyChanges(original, [{ from: 0, to: at, insert: '' }]), ProtocolError);
    assert.throws(() => validateSelection(source, { anchor: at, head: 0 }), ProtocolError);
  }
  assert.equal(applyChanges(original, [{ from: 1, to: 3, insert: '🦊' }, { from: 3, to: 5, insert: '\n' }]), 'a🦊\nb');
  assert.equal(applyChanges(original, [{ from: 0, to: 1, insert: '\r' }], { anchor: 1, head: 1 }), '\r😀\r\nb');
  assert.throws(() => applyChanges('a\nb', [{ from: 0, to: 1, insert: '\r' }], { anchor: 1, head: 1 }), ProtocolError);
});

test('ranges are atomic, sorted and nonoverlapping, with finite integer coordinates', () => {
  const original = 'abcdef';
  const invalid = [
    [{ from: 3, to: 5, insert: '' }, { from: 2, to: 3, insert: '' }],
    [{ from: 1, to: 4, insert: '' }, { from: 3, to: 5, insert: '' }],
    [{ from: -1, to: 0, insert: '' }], [{ from: 0.5, to: 1, insert: '' }],
    [{ from: 4, to: 3, insert: '' }], [{ from: 0, to: 7, insert: '' }],
    [{ from: NaN, to: 0, insert: '' }], [{ from: 0, to: Infinity, insert: '' }],
    [{ from: 0, to: 0, insert: 1 }], [{ from: 0, to: 0, insert: '', extra: 1 }],
  ];
  for (const changes of invalid) assert.throws(() => applyChanges(original, changes as never));
  assert.equal(applyChanges(original, [{ from: 1, to: 2, insert: 'B' }, { from: 4, to: 5, insert: 'E' }]), 'aBcdEf');
});

test('document unit and UTF-8 limits both apply at the exact boundary', () => {
  const ascii = 'a'.repeat(LIMITS.documentUnits);
  assert.equal(validateSource(ascii), LIMITS.documentBytes);
  assert.throws(() => validateSource(ascii + 'a'), ProtocolError);
  assert.throws(() => applyChanges(ascii, [{ from: 0, to: 0, insert: 'a' }]), ProtocolError);
  const multi = '中'.repeat(Math.floor(LIMITS.documentBytes / 3));
  assert.equal(validateSource(multi + 'a'), LIMITS.documentBytes);
  assert.throws(() => validateSource(multi + '中'), ProtocolError);
  assert.equal(applyChanges(ascii, [{ from: 0, to: 3, insert: '中' }]).length, ascii.length - 2);
});

test('batch insertion and range ceilings reject the whole mutation', () => {
  assert.equal(applyChanges('', [{ from: 0, to: 0, insert: 'a'.repeat(LIMITS.insertedUnits) }]).length, LIMITS.insertedUnits);
  assert.throws(() => applyChanges('', [{ from: 0, to: 0, insert: 'a'.repeat(LIMITS.insertedUnits + 1) }]), ProtocolError);
  const ranges = Array.from({ length: LIMITS.ranges }, (_, i) => ({ from: i * 2, to: i * 2 + 1, insert: 'b' }));
  const source = 'a'.repeat(LIMITS.ranges * 2 + 2);
  assert.equal(applyChanges(source, ranges), 'ba'.repeat(LIMITS.ranges) + 'aa');
  assert.throws(() => applyChanges(source, [...ranges, { from: LIMITS.ranges * 2, to: LIMITS.ranges * 2 + 1, insert: 'b' }]), ProtocolError);
});

test('incremental byte accounting matches actual valid mutation output', () => {
  const original = '\ufeff甲😀\r\nCafe\u0301';
  const changes = [{ from: 1, to: 4, insert: '日本🦊' }, { from: 6, to: 7, insert: 'e\u0301' }];
  const result = applyChanges(original, changes);
  const metrics = validateChanges(stringSource(original), validateSource(original), changes);
  assert.equal(metrics.units, result.length);
  assert.equal(metrics.bytes, Buffer.byteLength(result));
  assert.equal(metrics.retainedBytes, 2 * (3 + '日本🦊'.length + 1 + 'e\u0301'.length));
});

test('strict envelopes reject malformed shapes, unsupported durability and unsafe counters', () => {
  for (const value of [null, [], 1, 'text', { ...load('ok'), v: 2 }, { ...load('ok'), revision: -1 },
    { ...load('ok'), generation: 'old' }, { ...load('ok'), documentId: 'notebook/path' },
    { ...load('ok'), revision: Number.MAX_SAFE_INTEGER + 1 }, { ...load('ok'), unexpected: true },
    { ...load('ok'), selection: { anchor: 0, head: 0, ranges: [] } },
    { ...load('ok'), requestId: 'host-0' }, { ...load('ok'), requestId: 'editor-1' },
    envelope('ack', { stage: 'saved', throughRevision: 0 }),
    envelope('ack', { stage: 'draftDurable', throughRevision: 0 }),
    envelope('ack', { stage: 'rejected', throughRevision: 0 }),
    envelope('close', { mode: 'request', disposition: 'save' }),
    { ...load('ok'), documentId: '' }, { ...load('ok'), documentId: 'x'.repeat(257) },
    { ...load('ok'), language: undefined }, { ...load('ok'), language: null },
    { ...load('ok'), language: 'html' }, { ...load('ok'), language: 'text\n' },
    { ...load('ok'), baseVersion: 'old-mtime' },
    { ...load('ok'), baseVersion: baseVersion + '\n' },
    { ...load('ok'), documentId: documentId + '\n' },
    { ...load('ok'), generation: generation + '\n' },
    envelope('save', { mode: 'request' }),
    envelope('command', { command: 'executeScript' }),
  ]) assert.throws(() => validateHostMessage(value));
  assert.throws(() => decodeHostMessage('{broken json'));
});

test('encoded limits include JSON escaping and multibyte data', () => {
  const content = '\u0000'.repeat(1400);
  assert.throws(() => encodeMessage(envelope('theme', { theme: content }), LIMITS.controlBytes), ProtocolError);
  assert.throws(() => encodeMessage('中'.repeat(3000), LIMITS.controlBytes), ProtocolError);
  const exact = 'a'.repeat(LIMITS.controlBytes - 2);
  assert.equal(utf8Length(encodeMessage(exact, LIMITS.controlBytes)), LIMITS.controlBytes);
  assert.throws(() => encodeMessage(exact + 'a', LIMITS.controlBytes), ProtocolError);
  assert.throws(() => decodeHostMessage(' '.repeat(LIMITS.fullMessageBytes + 1)), ProtocolError);
});

test('session checks reject unknown generation, future controls and stale exact-revision data', () => {
  const control = validateHostMessage(envelope('theme', { theme: 'dark', revision: 2 }));
  validateSession(control, documentId, generation, 3);
  assert.throws(() => validateSession(control, documentId, 'f'.repeat(32), 3), ProtocolError);
  assert.throws(() => validateSession(control, documentId, generation, 1), ProtocolError);
  assert.throws(() => validateSession(control, documentId, generation, 3, true), ProtocolError);
  validateSession(control, documentId, generation, 2, true);
});

test('stable document binding is independent of generation and snapshot revision is a lower bound', () => {
  const snapshot = validateHostMessage(envelope('save', { mode: 'snapshotRequest', revision: 2 }));
  validateSession(snapshot, documentId, generation, 3);
  assert.throws(() => validateSession(snapshot, 'other:node', generation, 3), ProtocolError);
  assert.throws(() => validateSession(snapshot, documentId, generation, 1), ProtocolError);
  const written = validateHostMessage(envelope('close', { mode: 'request', disposition: 'written', revision: 2 }));
  assert.throws(() => validateSession(written, documentId, generation, 3, true), ProtocolError);
});

test('receipt releases large transfer payloads while repeated snapshots retain bounded replay', () => {
  const cache = new RequestCache();
  const initial = validateHostMessage(load('x'.repeat(10000)));
  cache.begin(initial, encodeMessage(initial));
  cache.complete(initial, 'ready');
  cache.release('load', initial.requestId);
  assert.equal(cache.begin(initial, encodeMessage(initial))?.fingerprint, null);
  assert.equal(cache.begin(initial, encodeMessage(initial))?.response, null);
  for (let i = 2; i <= 100; i++) {
    const request = validateHostMessage(envelope('save', { mode: 'snapshotRequest', requestId: `host-${i}` }));
    const fingerprint = encodeMessage(request);
    assert.equal(cache.begin(request, fingerprint), undefined);
    cache.complete(request, 'large snapshot');
    assert.equal(cache.begin(request, fingerprint)?.response, 'large snapshot');
    cache.release('save', request.requestId);
    assert.equal(cache.begin(request, fingerprint)?.response, null);
    assert.throws(() => cache.begin(request, fingerprint + ' '), ProtocolError);
  }
});

test('exact request replay is bounded; changed and evicted requests cannot be reapplied', () => {
  const cache = new RequestCache();
  const first = validateHostMessage(envelope('theme', { theme: 'dark' }));
  const fingerprint = encodeMessage(first);
  assert.equal(cache.begin(first, fingerprint), undefined);
  cache.complete(first, 'response');
  assert.equal(cache.begin(first, fingerprint)?.response, 'response');
  assert.throws(() => cache.begin(first, fingerprint + ' '), ProtocolError);
  for (let i = 2; i <= LIMITS.replayEntries + 1; i++) {
    const next = validateHostMessage(envelope('theme', { theme: 'light', requestId: `host-${i}` }));
    cache.begin(next, encodeMessage(next));
  }
  assert.throws(() => cache.begin(first, fingerprint), ProtocolError);
  const changedType = validateHostMessage(envelope('command', { command: 'undo', requestId: `host-${LIMITS.replayEntries + 1}` }));
  assert.throws(() => cache.begin(changedType, encodeMessage(changedType)), ProtocolError);
});

test('outstanding batch and encoded-byte credits fail independently before acceptance', () => {
  assertCredits(LIMITS.outstandingBatches, LIMITS.outstandingBytes);
  assert.throws(() => assertCredits(LIMITS.outstandingBatches + 1, 1), ProtocolError);
  assert.throws(() => assertCredits(1, LIMITS.outstandingBytes + 1), ProtocolError);
});

test('pruning old history keeps recent undo/redo and allows continued editing', () => {
  let state = EditorState.create({ doc: '', extensions: history({ minDepth: LIMITS.historyGroups }) });
  for (let i = 0; i < 211; i++) state = state.update({ changes: { from: state.doc.length, insert: 'x' },
    annotations: isolateHistory.of('full') }).state;
  const serialized = state.toJSON({ history: historyField });
  const bounded = trimHistory(serialized.history);
  assert.equal(bounded.pruned, true);
  serialized.history = bounded.history;
  state = EditorState.fromJSON(serialized, { extensions: history() }, { history: historyField });
  assert.equal(undoDepth(state), 200);
  const dispatch = (transaction) => { state = transaction.state; };
  for (let i = 0; i < 200; i++) assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'x'.repeat(11));
  assert.equal(undo({ state, dispatch }), false);
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'x'.repeat(12));
  state = state.update({ changes: { from: state.doc.length, insert: 'continued' } }).state;
  assert.equal(state.doc.toString(), 'x'.repeat(12) + 'continued');
});

test('history byte pruning preserves newest complete deletion events', () => {
  let state = EditorState.create({ doc: 'abcdefgh'.repeat(10), extensions: history() });
  for (let i = 0; i < 10; i++) state = state.update({ changes: { from: 0, to: 8 },
    annotations: isolateHistory.of('full') }).state;
  const serialized = state.toJSON({ history: historyField });
  const bounded = trimHistory(serialized.history, 200, 64);
  assert.equal(bounded.bytes, 64);
  serialized.history = bounded.history;
  state = EditorState.fromJSON(serialized, { extensions: history() }, { history: historyField });
  const dispatch = (transaction) => { state = transaction.state; };
  for (let i = 0; i < 4; i++) assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'abcdefgh'.repeat(4));
  assert.equal(undo({ state, dispatch }), false);
});

test('CRLF history pruning preserves an end selection and executable undo/redo', () => {
  const extensions = [history({ minDepth: LIMITS.historyGroups }), EditorState.lineSeparator.of('\n')];
  let state = EditorState.create({ doc: 'base\r\n', extensions });
  for (let i = 0; i < 201; i++) {
    const end = state.doc.length;
    state = state.update({ changes: { from: end, insert: 'x' }, selection: { anchor: end + 1 },
      annotations: isolateHistory.of('full') }).state;
  }
  const bounded = prepareHistoryPrune(state);
  assert.equal(bounded.pruned, true);
  state = EditorState.create({ doc: state.doc, selection: state.selection,
    extensions: [...extensions, historyField.init(() => bounded.value)] });
  assert.equal(state.selection.main.head, 'base\r\n'.length + 201);
  const dispatch = (transaction) => { state = transaction.state; };
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'base\r\n' + 'x'.repeat(200));
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'base\r\n' + 'x'.repeat(201));
});

test('selection request and set variants are closed and insertion source is bounded', () => {
  assert.equal(validateHostMessage(envelope('selection', { mode: 'request' })).type, 'selection');
  assert.equal(validateHostMessage(envelope('selection', { anchor: 2, head: 1 })).type, 'selection');
  const insert = envelope('insert', { text: '![甲](assets/a%20b.png)', anchor: 2, head: 1 });
  assert.equal(validateHostMessage(insert).type, 'insert');
  for (const invalid of [
    envelope('selection', { mode: 'request', anchor: 0, head: 0 }),
    envelope('selection', { mode: 'current', anchor: 0, head: 0 }),
    envelope('selection', { mode: 'set', anchor: 0, head: 0 }),
    envelope('selection', { mode: undefined, anchor: 0, head: 0 }),
    envelope('selection', { anchor: 0 }),
    { ...insert, text: '\ud800' }, { ...insert, text: '\udfff' },
    { ...insert, text: 'x'.repeat(LIMITS.insertedUnits + 1) },
    { ...insert, text: '中'.repeat(3000) },
    { ...insert, text: '\u0000'.repeat(1400) },
    { ...insert, anchor: -1 }, { ...insert, head: 0.5 },
    { ...insert, execute: true }, { ...insert, text: undefined },
    { ...insert, requestId: 'editor-1' },
  ]) assert.throws(() => validateHostMessage(invalid), ProtocolError);
});

test('live insertion transaction retains literal source and is one isolated undo group', () => {
  let state = EditorState.create({ doc: Text.of(['base\r', '']),
    selection: { anchor: 6 }, extensions: [history(), EditorState.lineSeparator.of('\n')] });
  state = state.update({ changes: { from: 6, insert: 'typed' }, selection: { anchor: 11 },
    userEvent: 'input.type' }).state;
  const before = state.doc.toString();
  const literal = '![日本語](assets/a%20b.png)\r\n</script>${notJavaScript}😀';
  const request = validateHostMessage(envelope('insert', { text: literal, anchor: 11, head: 11 }));
  assert.equal(request.type, 'insert');
  if (request.type !== 'insert') throw new Error('Insertion request expected.');
  const transaction = insertionTransaction(state, utf8Length(before), request);
  assert.equal(transaction.annotation(isolateHistory), 'full');
  state = transaction.state;
  const inserted = state.doc.toString();
  assert.equal(inserted, before + literal);
  assert.equal(state.selection.main.head, inserted.length);
  state = state.update({ changes: { from: state.doc.length, insert: 'after' },
    userEvent: 'input.type' }).state;
  assert.equal(undoDepth(state), 3);
  const dispatch = (transaction) => { state = transaction.state; };
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), inserted);
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), before);
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'base\r\n');
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), inserted);
});

test('insertion binds the directed selection, revision and generation without moving the cursor', () => {
  const state = EditorState.create({ doc: 'a😀\r\nb', selection: { anchor: 5, head: 1 },
    extensions: [history(), EditorState.lineSeparator.of('\n')] });
  const request = validateHostMessage(envelope('insert', { text: '中', anchor: 5, head: 1, revision: 3 }));
  if (request.type !== 'insert') throw new Error('Insertion request expected.');
  validateSession(request, documentId, generation, 3, true);
  const next = insertionTransaction(state, utf8Length(state.doc.toString()), request).state;
  assert.equal(next.doc.toString(), 'a中b');
  assert.equal(next.selection.main.head, 2);
  for (const changed of [{ anchor: 1, head: 5 }, { anchor: 0, head: 0 }, { anchor: 2, head: 2 }]) {
    assert.throws(() => insertionTransaction(state, 9, { ...request, ...changed }), ProtocolError);
  }
  assert.throws(() => validateSession(request, documentId, generation, 4, true), ProtocolError);
  assert.throws(() => validateSession(request, documentId, 'f'.repeat(32), 3, true), ProtocolError);
  assert.equal(state.doc.toString(), 'a😀\r\nb');
  assert.equal(undoDepth(state), 0);
});

test('insertion refuses source boundaries, resulting CRLF cursor and full-document growth atomically', () => {
  const insertion = (state: EditorState, text: string) => {
    const request = validateHostMessage(envelope('insert', { text,
      anchor: state.selection.main.anchor, head: state.selection.main.head }));
    if (request.type !== 'insert') throw new Error('Insertion request expected.');
    return insertionTransaction(state, utf8Length(state.doc.toString()), request);
  };
  for (const at of [2, 4]) {
    const state = EditorState.create({ doc: Text.of(['a😀\r', 'b']), selection: { anchor: at } });
    assert.throws(() => insertion(state, 'x'), ProtocolError);
    assert.equal(state.doc.toString(), 'a😀\r\nb');
  }
  const pair = EditorState.create({ doc: Text.of(['', '']), selection: { anchor: 0 } });
  assert.throws(() => insertion(pair, '\r'), ProtocolError);
  assert.throws(() => insertion(pair, ''), ProtocolError);
  const full = EditorState.create({ doc: 'a'.repeat(LIMITS.documentUnits), extensions: history() });
  assert.throws(() => insertion(full, 'x'), ProtocolError);
  assert.equal(full.doc.length, LIMITS.documentUnits);
  assert.equal(undoDepth(full), 0);
});

test('queued insertion replay is inert until receipt and never becomes a second edit', () => {
  const cache = new RequestCache();
  const request = validateHostMessage(envelope('insert', { text: '[file](assets/file)', anchor: 0, head: 0 }));
  const wire = encodeMessage(request);
  assert.equal(cache.begin(request, wire), undefined);
  // While composition owns the cursor the queued request has no response yet.
  assert.equal(cache.begin(request, wire)?.response, null);
  const ack = encodeMessage(envelope('ack', { revision: 1, throughRevision: 1, stage: 'received' }));
  cache.complete(request, ack);
  assert.equal(cache.begin(request, wire)?.response, ack);
  assert.throws(() => cache.begin(request, wire + ' '), ProtocolError);
  for (let i = 2; i <= LIMITS.replayEntries + 1; i++) {
    const selection = validateHostMessage(envelope('selection', { requestId: `host-${i}`, mode: 'request' }));
    cache.begin(selection, encodeMessage(selection));
  }
  assert.throws(() => cache.begin(request, wire), ProtocolError);
});

test('new line policy counts exact separators, including chunk edges and first-occurrence ties', () => {

  assert.equal(preferredLineEnding(stringSource('plain')), '\n');
  assert.equal(preferredLineEnding(stringSource('a\r\nb\nc\r\nd')), '\r\n');
  assert.equal(preferredLineEnding(stringSource('a\rb\nc')), '\r');
  assert.equal(preferredLineEnding(stringSource('a\nb\rc')), '\n');
  assert.equal(preferredLineEnding(stringSource('a'.repeat(4095) + '\r\nb')), '\r\n');
});
