// SPDX-License-Identifier: LGPL-3.0-only
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EditorState, Text, type Transaction } from '@codemirror/state';
import { history, isolateHistory, undo, redo, undoDepth } from '@codemirror/commands';
import { formattingTransaction, type FormatRequest } from '../src/formatting';
import { LIMITS, preferredLineEnding, ProtocolError, utf8Length, validateHostMessage } from '../src/protocol';

function stateFor(source: string, anchor = 0, head = source.length): EditorState {
  return EditorState.create({ doc: Text.of(source.split('\n')), selection: { anchor, head },
    extensions: [history(), EditorState.lineSeparator.of('\n')] });
}
function format(state: EditorState, action: FormatRequest['action'], fields: Partial<FormatRequest> = {}): Transaction {
  return formattingTransaction(state, utf8Length(state.doc.toString()), {
    action, anchor: state.selection.main.anchor, head: state.selection.main.head, ...fields,
  }, preferredLineEnding(state.doc));
}

test('inline actions preserve directed selection and every outside source unit', () => {
  const source = '\ufeffoutside\r\n日本語😀\rend';
  const from = source.indexOf('日本'), to = source.indexOf('\rend');
  for (const [action, opening, closing] of [
    ['bold', '**', '**'], ['italic', '*', '*'], ['code', '`', '`'],
    ['link', '[', '](<notes/a(b).md#heading>)'],
  ] as const) {
    const state = stateFor(source, to, from);
    const transaction = format(state, action, action === 'link' ? { destination: 'notes/a(b).md#heading' } : {});
    assert.equal(transaction.newDoc.toString(), source.slice(0, from) + opening + source.slice(from, to) + closing + source.slice(to));
    assert.equal(transaction.newSelection.main.anchor, to + opening.length);
    assert.equal(transaction.newSelection.main.head, from + opening.length);
  }
});

test('formatting is one isolated undo group, distinct from prior typing', () => {
  let state = stateFor('a', 1, 1);
  state = state.update({ changes: { from: 1, insert: 'typed' }, selection: { anchor: 1, head: 6 }, userEvent: 'input.type' }).state;
  const transaction = format(state, 'bold');
  assert.equal(transaction.annotation(isolateHistory), 'full');
  state = transaction.state;
  assert.equal(undoDepth(state), 2);
  const dispatch = (transaction: Transaction) => { state = transaction.state; };
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'atyped');
  assert.equal(state.selection.main.anchor, 1);
  assert.equal(state.selection.main.head, 6);
  assert.equal(undo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'a');
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(redo({ state, dispatch }), true);
  assert.equal(state.doc.toString(), 'a**typed**');
});

test('empty inline selections place the caret between delimiters', () => {
  const transaction = format(stateFor('ab', 1, 1), 'bold');
  assert.equal(transaction.newDoc.toString(), 'a****b');
  assert.equal(transaction.newSelection.main.anchor, 3);
  assert.equal(transaction.newSelection.main.head, 3);
});

test('inline and fenced code exceed embedded delimiter runs and preserve CRLF', () => {
  const inline = format(stateFor('`x``'), 'code');
  assert.equal(inline.newDoc.toString(), '``` `x`` ```');
  const source = 'before\r\n```code\r\nmore\r\nafter';
  const from = source.indexOf('```'), to = source.indexOf('after');
  const fenced = format(stateFor(source, from, to), 'fence');
  assert.equal(fenced.newDoc.toString(), 'before\r\n````\r\n```code\r\nmore\r\n````\r\nafter');
  assert.equal(fenced.newSelection.main.anchor, from + 6);
  assert.throws(() => format(stateFor('`'.repeat(LIMITS.insertedUnits)), 'fence'), ProtocolError);
});

test('line actions only change selected line prefixes across mixed newline styles', () => {
  const source = 'untouched\r\none\ntwo\rthree\r\nlast';
  const from = source.indexOf('one'), to = source.indexOf('last');
  for (const [action, prefix] of [['heading', '### '], ['quote', '> '], ['bullet', '- '], ['task', '- [ ] ']] as const) {
    const transaction = format(stateFor(source, from, to), action, action === 'heading' ? { level: 3 } : {});
    assert.equal(transaction.newDoc.toString(), `untouched\r\n${prefix}one\n${prefix}two\r${prefix}three\r\nlast`);
    const reverted = format(transaction.state, action, action === 'heading' ? { level: 3 } : {});
    assert.equal(reverted.newDoc.toString(), source);
  }
  assert.equal(format(stateFor(source, from, to), 'ordered').newDoc.toString(), 'untouched\r\n1. one\n2. two\r3. three\r\nlast');
});

test('heading and list conversion replaces prefixes without serializing source', () => {
  assert.equal(format(stateFor('## old\n# next'), 'heading', { level: 4 }).newDoc.toString(), '#### old\n#### next');
  assert.equal(format(stateFor('- [x] done\n42. more'), 'bullet').newDoc.toString(), '- done\n- more');
  assert.equal(format(stateFor('1. a\n2. b'), 'ordered').newDoc.toString(), 'a\nb');
});

test('oversized selected lines and invalid boundaries fail atomically', () => {
  const state = stateFor('line\n'.repeat(257));
  assert.throws(() => format(state, 'quote'), ProtocolError);
  assert.equal(state.doc.toString(), 'line\n'.repeat(257));
  assert.equal(undoDepth(state), 0);
  const paired = stateFor('a😀\r\nb', 1, 3);
  assert.throws(() => format(paired, 'bold', { anchor: 2 }), ProtocolError);
  assert.throws(() => format(stateFor('a😀\r\nb', 4, 4), 'bold'), ProtocolError);
  assert.throws(() => format(paired, 'heading', { level: 7 }), ProtocolError);
});

test('large inline selections use paired insertions, not copied replacements', () => {
  const source = 'x'.repeat(1024 * 1024);
  const transaction = format(stateFor(source), 'bold');
  const changes: { from: number; to: number; inserted: number }[] = [];
  transaction.changes.iterChanges((from, to, _a, _b, inserted) => changes.push({ from, to, inserted: inserted.length }));
  assert.deepEqual(changes, [{ from: 0, to: 0, inserted: 2 }, { from: source.length, to: source.length, inserted: 2 }]);
  assert.equal(transaction.newDoc.length, source.length + 4);
});

test('format controls require explicit closed action parameters', () => {
  const envelope = { v: 2, type: 'format', documentId: 'book:note', generation: 'a'.repeat(32), revision: 3,
    requestId: 'host-4', anchor: 1, head: 3 };
  assert.equal(validateHostMessage({ ...envelope, action: 'link', destination: 'note.md#anchor' }).type, 'format');
  for (const fields of [{ action: 'heading', level: 0 }, { action: 'bold', destination: 'extra' },
    { action: 'link', destination: 'x\ny' }, { action: 'execute' }, { action: 'link' }]) {
    assert.throws(() => validateHostMessage({ ...envelope, ...fields }), ProtocolError);
  }
});
