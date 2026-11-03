// SPDX-License-Identifier: LGPL-3.0-only
import { EditorState, Text, type Transaction } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import {
  LIMITS, requireThat, validateChanges, validateFormat, validateSelection,
  type Change, type FormatAction, type Selection, type Source,
} from './protocol';

export interface FormatRequest extends Selection {
  action: FormatAction;
  level?: number;
  destination?: string;
}

// Read bounded chunks, never a copy of the selection or a whole long line.
function longestRun(source: Source, from: number, to: number, character: string): number {
  let longest = 0, current = 0;
  for (let at = from; at < to; at += 4096) {
    const chunk = source.sliceString(at, Math.min(to, at + 4096));
    for (const value of chunk) {
      current = value === character ? current + 1 : 0;
      longest = Math.max(longest, current);
    }
  }
  return longest;
}
function lineStart(source: Source, at: number): number {
  while (at > 0) {
    const from = Math.max(0, at - 4096), chunk = source.sliceString(from, at);
    for (let i = chunk.length - 1; i >= 0; i--) {
      if (chunk[i] === '\n' || chunk[i] === '\r') return from + i + 1;
    }
    at = from;
  }
  return 0;
}
function nextLine(source: Source, at: number): number | null {
  for (; at < source.length; at += 4096) {
    const chunk = source.sliceString(at, Math.min(source.length, at + 4096));
    for (let i = 0; i < chunk.length; i++) {
      if (chunk[i] === '\n') return at + i + 1;
      if (chunk[i] === '\r') return at + i + (source.sliceString(at + i + 1, at + i + 2) === '\n' ? 2 : 1);
    }
  }
  return null;
}

export function formattingTransaction(
  state: EditorState, sourceBytes: number, request: FormatRequest, newline: string,
): Transaction {
  validateFormat(request);
  requireThat(['\n', '\r\n', '\r'].includes(newline), 'Invalid preferred line ending.');
  const selected = state.selection.main;
  requireThat(request.anchor === selected.anchor && request.head === selected.head,
    'Selection changed before formatting; choose the action again.');
  validateSelection(state.doc, request);
  const from = selected.from, to = selected.to;
  const changes: Change[] = [];
  let selection: Selection | undefined;
  const wrap = (open: string, close: string): void => {
    if (from === to) changes.push({ from, to, insert: open + close });
    else changes.push({ from, to: from, insert: open }, { from: to, to, insert: close });
    const left = from + open.length, right = to + open.length;
    selection = selected.anchor <= selected.head ? { anchor: left, head: right } : { anchor: right, head: left };
  };
  switch (request.action) {
    case 'bold': wrap('**', '**'); break;
    case 'italic': wrap('*', '*'); break;
    case 'code': {
      const width = longestRun(state.doc, from, to, '`') + 1;
      requireThat(width * 2 + 2 <= LIMITS.insertedUnits, 'Code delimiter exceeds insertion limits.');
      const marker = '`'.repeat(width);
      // CommonMark strips one padding space; protect edge backticks/spaces.
      const first = state.doc.sliceString(from, Math.min(to, from + 1));
      const last = state.doc.sliceString(Math.max(from, to - 1), to);
      const padding = from !== to && (first === '`' || last === '`' || first === ' ' || last === ' ') ? ' ' : '';
      wrap(marker + padding, padding + marker);
      break;
    }
    case 'fence': {
      const width = Math.max(3, longestRun(state.doc, from, to, '`') + 1);
      requireThat(width * 2 + newline.length * 4 <= LIMITS.insertedUnits, 'Fence delimiter exceeds insertion limits.');
      const marker = '`'.repeat(width);
      const prefix = from > 0 && !/[\r\n]/.test(state.doc.sliceString(from - 1, from)) ? newline : '';
      const suffix = to < state.doc.length && !/[\r\n]/.test(state.doc.sliceString(to, to + 1)) ? newline : '';
      const end = to > from && /[\r\n]/.test(state.doc.sliceString(to - 1, to)) ? '' : newline;
      wrap(prefix + marker + newline, end + marker + suffix);
      break;
    }
    case 'link': {
      // Angle destinations preserve literal parentheses without source rewrites.
      const destination = request.destination!.replace(/\\/g, '\\\\');
      wrap('[', `](<${destination}>)`);
      break;
    }
    default: {
      const rows: { from: number; old: string; replacement: string }[] = [];
      let at: number | null = lineStart(state.doc, from), ordinal = 1;
      const last = to > from && lineStart(state.doc, to) === to ? to - 1 : to;
      while (at !== null && at <= last) {
        requireThat(rows.length < LIMITS.ranges, 'Formatting exceeds the selected-line limit.');
        const prefix = state.doc.sliceString(at, Math.min(state.doc.length, at + 64));
        let old = '', replacement = '';
        switch (request.action) {
          case 'heading': old = /^#{1,6}[ \t]+/.exec(prefix)?.[0] ?? ''; replacement = '#'.repeat(request.level!) + ' '; break;
          case 'quote': old = /^>[ \t]?/.exec(prefix)?.[0] ?? ''; replacement = '> '; break;
          case 'bullet': old = /^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/.exec(prefix)?.[0] ?? ''; replacement = '- '; break;
          case 'ordered': old = /^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/.exec(prefix)?.[0] ?? ''; replacement = `${ordinal++}. `; break;
          case 'task': old = /^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/.exec(prefix)?.[0] ?? ''; replacement = '- [ ] '; break;
        }
        // Never silently consume a partial prefix at the bounded lookahead edge.
        requireThat(old.length < 64, 'Formatting prefix exceeds its bounded lookahead.');
        rows.push({ from: at, old, replacement });
        at = nextLine(state.doc, at);
      }
      const remove = rows.every(row => row.old === row.replacement);
      for (const row of rows) {
        const insert = remove ? '' : row.replacement;
        if (row.old !== insert) changes.push({ from: row.from, to: row.from + row.old.length, insert });
      }
      break;
    }
  }
  if (changes.length === 0) return state.update({ annotations: isolateHistory.of('full') });
  validateChanges(state.doc, sourceBytes, changes);
  const changeSet = state.changes(changes.map(change => ({ ...change, insert: Text.of(change.insert.split('\n')) })));
  if (!selection) selection = {
    anchor: changeSet.mapPos(selected.anchor, 1), head: changeSet.mapPos(selected.head, 1),
  };
  const transaction = state.update({ changes: changeSet, selection,
    annotations: isolateHistory.of('full'), userEvent: 'input.format', filter: false });
  validateSelection(transaction.newDoc, selection);
  return transaction;
}
