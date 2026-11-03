// SPDX-License-Identifier: LGPL-3.0-only
import { ChangeSet, Compartment, EditorSelection, EditorState, Text, Transaction } from '@codemirror/state';
import { EditorView, keymap, lineNumbers } from '@codemirror/view';
import { defaultKeymap, history, historyField, historyKeymap, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { defaultHighlightStyle, syntaxHighlighting } from '@codemirror/language';
import {
  assertCredits, assertDurableCredits, encodeMessage, insertionTransaction, LIMITS, preferredLineEnding, prepareHistoryPrune, ProtocolError,
  RequestCache, requireThat, utf8Length, validBoundary, validateChanges, validateHostMessage,
  validateSelection, validateSession, validateSource,
  type Change, type Envelope, type HostMessage, type Selection,
} from './protocol';
import { formattingTransaction } from './formatting';

declare global {
  interface Window {
    VNoteEditor?: { postMessage(message: string): void };
    vnoteEditor: Readonly<{ receive(message: unknown): void }>;
  }
}
const status = document.getElementById('status')!;
const retry = document.getElementById('retry') as HTMLButtonElement;
const refusal = document.getElementById('refusal')!;
const candidate = document.getElementById('candidate') as HTMLTextAreaElement;
const theme = new Compartment();
const nonce = new Compartment();
const scriptNonce = document.querySelector<HTMLMetaElement>('meta[name="vnote-csp-nonce"]')?.content
  ?? (document.currentScript as HTMLScriptElement | null)?.nonce ?? '';
const writable = new Compartment();
const cache = new RequestCache();
const undoHistory = new Compartment();
let retainedHistoryBytes = 0;
let lineEnding = '\n';
let generation: string | null = null;
let documentId: string | null = null;
let revision = 0, receivedRevision = 0, durableRevision = 0, savedRevision: number | null = null, documentBytes = 0, nextRequest = 1;
let readyRequest = '', ready = false, closed = false, frozen = false, quiesced = false;
let snapshot: { requestId: string; revision: number } | null = null;
let resyncSource: Text | null = null;
let sourceOperationId: string | undefined;
let activitySequence = 0, lastActivity = '';
let editorLanguage: 'markdown' | 'text' = 'text';
let batchTimer: ReturnType<typeof setTimeout> | undefined;
let selectionTimer: ReturnType<typeof setTimeout> | undefined;
let transportTimer: ReturnType<typeof setTimeout> | undefined;
let compositionTimer: ReturnType<typeof setTimeout> | undefined;
let suppressSelection = false;
interface Pending {
  base: Text;
  baseBytes: number;
  changes: ChangeSet;
  requestId: string;
  reservedBytes: number;
  operationId?: string;
}
interface InFlight { revision: number; bytes: number; encoded: string }
interface Composition {
  base: EditorState;
  baseBytes: number;
  changes: ChangeSet;
  failed: string | null;
  reserved: boolean;
}
let pending: Pending | null = null;
let composing: Composition | null = null;
const inFlight = new Map<string, InFlight>();
const undurable = new Map<string, { revision: number; bytes: number }>();
const controls: HostMessage[] = [];

function show(message: string, error = false): void {
  status.textContent = message;
  status.dataset.error = String(error);
}
function errorText(error: unknown): string {
  return (error instanceof Error ? error.message : 'Editor protocol operation refused.').slice(0, 1024);
}
function memoryStatus(): void {
  if (closed) show('Editor closed after the requested barrier.');
  else if (frozen) show('Transport rejected an edit. Text is retained here; copy it before discarding.', true);
  else if (quiesced) show('Editing paused while the host retains the final source.');
  else if (composing) show('Composition is provisional. Finish composing before Write.');
  else if (pending || inFlight.size) show('Input pending receipt. Text remains in this editor.');
  else if (undurable.size) show(`Received revision ${receivedRevision}; waiting for durable draft storage.`);
  else if (savedRevision === revision) show(`Saved locally at revision ${revision}.`);
  else show(`Draft durable through revision ${durableRevision}. Notebook write status is shown above.`);
}
function header(type: string, requestId: string, at = revision): Envelope {
  requireThat(generation !== null && documentId !== null, 'Waiting for a host session.');
  return { v: 2, type, documentId, generation, revision: at, requestId };
}
function requestId(): string {
  requireThat(Number.isSafeInteger(nextRequest + 1), 'Request counter exhausted; preserve this session.');
  return `editor-${nextRequest++}`;
}
function post(encoded: string): void {
  requireThat(window.VNoteEditor && typeof window.VNoteEditor.postMessage === 'function',
    'Native host channel is unavailable. Text is retained; do not reload.');
  window.VNoteEditor.postMessage(encoded);
}
function reply(message: HostMessage, body: Record<string, unknown>): void {
  const encoded = encodeMessage({ ...header(String(body.type), message.requestId), ...body });
  cache.complete(message, encoded);
  post(encoded);
}
function reject(message: HostMessage, error: unknown): void {
  const text = errorText(error);
  show(text, true);
  if (message.type !== 'ack') {
    try { reply(message, { type: 'ack', stage: 'rejected', throughRevision: revision, error: text }); }
    catch (failure) { show(errorText(failure), true); }
  }
}
function sendActivity(): void {
  if (!ready || closed) return;
  const state = `${revision}:${pending !== null}:${composing !== null}`;
  if (state === lastActivity) return;
  try {
    post(encodeMessage({ ...header('activity', requestId()), sequence: ++activitySequence,
      pending: pending !== null, composing: composing !== null }, LIMITS.controlBytes));
    lastActivity = state;
  } catch (error) { show(errorText(error), true); }
}
function reserveCredits(bytes: number): void {
  assertCredits(inFlight.size + 1, outstandingBytes() + bytes);
  let retained = 0;
  for (const entry of undurable.values()) retained += entry.bytes;
  assertDurableCredits(undurable.size + 1, retained + bytes);
}
function outstandingBytes(): number {
  let total = 0;
  for (const entry of inFlight.values()) total += entry.bytes;
  return total;
}
function changesOf(changes: ChangeSet): Change[] {
  const result: Change[] = [];
  changes.iterChanges((from, to, _fromB, _toB, inserted) => {
    requireThat(result.length < LIMITS.ranges, 'Edit range count exceeds limit.');
    result.push({ from, to, insert: inserted.toString() });
  });
  return result;
}
function selectionOf(state: EditorState): Selection {
  return { anchor: state.selection.main.anchor, head: state.selection.main.head };
}
function editEnvelope(batch: Pending, selection: Selection): Record<string, unknown> {
  return { ...header('edit', batch.requestId, revision + 1), baseRevision: revision,
    changes: changesOf(batch.changes), selection, ...(batch.operationId ? { operationId: batch.operationId } : {}) };
}
function preflight(transaction: Transaction): { batch: Pending | null; bytes: number; retained: number } {
  requireThat(ready && !closed && !frozen && !quiesced, 'Editing is unavailable; existing text is retained.');
  requireThat(Number.isSafeInteger(revision + 1), 'Revision exhausted; preserve this session.');
  const metrics = validateChanges(transaction.startState.doc, documentBytes, changesOf(transaction.changes));
  validateSelection(transaction.newDoc, selectionOf(transaction.state));
  const prepare = (): Pending | null => {
    requireThat(Number.isSafeInteger(revision + 1), 'Revision exhausted; preserve this session.');
    const changes = pending ? pending.changes.compose(transaction.changes) : transaction.changes;
    if (changes.empty) return null;
    const batch: Pending = {
      base: pending?.base ?? transaction.startState.doc,
      baseBytes: pending?.baseBytes ?? documentBytes,
      changes,
      requestId: pending?.requestId ?? 'editor-9007199254740991',
      reservedBytes: 0,
      ...(sourceOperationId ? { operationId: sourceOperationId } : {}),
    };
    validateChanges(batch.base, batch.baseBytes, changesOf(changes));
    // Reserve maximum selection offsets so a later cursor move cannot overflow a batch.
    batch.reservedBytes = utf8Length(encodeMessage(editEnvelope(batch,
      { anchor: LIMITS.documentUnits, head: LIMITS.documentUnits }), LIMITS.editBytes));
    reserveCredits(batch.reservedBytes);
    return batch;
  };
  let batch: Pending | null;
  try { batch = prepare(); } catch (error) {
    if (!pending) throw error;
    // The individual mutation already passed validation. End the earlier batch
    // at its boundary rather than rejecting merely because composition grew.
    flush();
    batch = prepare();
  }
  return { batch, bytes: metrics.bytes, retained: metrics.retainedBytes };
}
function scheduleBatch(): void {
  if (batchTimer === undefined && pending) batchTimer = setTimeout(() => {
    batchTimer = undefined;
    try { flush(); } catch (error) { show(errorText(error), true); }
  }, 50);
}
function armTransportTimeout(): void {
  clearTimeout(transportTimer);
  transportTimer = undefined;
  retry.hidden = inFlight.size === 0;
  if (inFlight.size) transportTimer = setTimeout(() => {
    transportTimer = undefined;
    show('The host has not received edits for five seconds. Retry sending or copy text before discarding. Receipt is not a disk write.', true);
    retry.hidden = false;
  }, 5000);
}
function flush(): void {
  if (composing || !pending) return;
  requireThat(!frozen, 'Rejected edits remain in memory; do not overwrite this session.');
  const batch = pending;
  batch.requestId = requestId();
  const encoded = encodeMessage(editEnvelope(batch, selectionOf(view.state)), LIMITS.editBytes);
  const bytes = utf8Length(encoded);
  reserveCredits(bytes);
  clearTimeout(batchTimer);
  batchTimer = undefined;
  // Retain the exact wire message before calling the external channel, which may fail.
  pending = null;
  revision++;
  inFlight.set(batch.requestId, { revision, bytes, encoded });
  undurable.set(batch.requestId, { revision, bytes });
  armTransportTimeout();
  memoryStatus();
  post(encoded);
  sendActivity();
}
function scheduleSelection(): void {
  if (suppressSelection || composing || !ready || closed || selectionTimer !== undefined) return;
  selectionTimer = setTimeout(() => {
    selectionTimer = undefined;
    if (composing || closed || frozen) return;
    try {
      flush();
      post(encodeMessage({ ...header('selection', requestId()), ...selectionOf(view.state) }, LIMITS.controlBytes));
    } catch (error) { show(errorText(error), true); }
  }, 50);
}

function applyTransaction(transaction: Transaction): boolean {
  if (!transaction.docChanged) {
    view.update([transaction]);
    if (transaction.selection) scheduleSelection();
    return true;
  }
  if (composing) {
    try {
      requireThat(composing.reserved && !composing.failed, composing.failed ?? 'No composition credit is available.');
      const changes = composing.changes.compose(transaction.changes);
      if (!changes.empty) {
        validateChanges(composing.base.doc, composing.baseBytes, changesOf(changes), true);
              // The full edit slot is reserved before compositionstart. Lone surrogates
        // may exist only in this provisional state, never in a sent batch.
        const encoded = encodeMessage({ ...header('edit', 'editor-9007199254740991', revision + 1),
          baseRevision: revision, changes: changesOf(changes),
          selection: { anchor: LIMITS.documentUnits, head: LIMITS.documentUnits } }, LIMITS.editBytes);
        reserveCredits(utf8Length(encoded));
      }
      composing.changes = changes;
      view.update([transaction]);
    } catch (error) {
      composing.failed = errorText(error);
      show(`${composing.failed} Finish composing to retain the previous document.`, true);
    }
    return composing.failed === null;
  }
  try {
    const accepted = preflight(transaction);
    retainedHistoryBytes += accepted.retained;
    pending = accepted.batch;
    documentBytes = accepted.bytes;
    view.update([transaction]);
    pruneHistory();
    scheduleBatch();
    scheduleSelection();
    memoryStatus();
    sendActivity();
    return true;
  } catch (error) {
    // No view.update: document, selection, and history stay at the prior state.
    show(errorText(error), true);
    return false;
  }
}
function pruneHistory(): void {
  if (retainedHistoryBytes < LIMITS.historyBytes && undoDepth(view.state) + redoDepth(view.state) <= LIMITS.historyGroups) return;
  // Use only supported serialization/initialization APIs, and only at a budget
  // boundary. Reconfiguration retains source, selection, theme and session.
  const bounded = prepareHistoryPrune(view.state);
  retainedHistoryBytes = bounded.bytes;
  if (!bounded.pruned) return;
  view.update([view.state.update({ effects: undoHistory.reconfigure([]) })]);
  view.update([view.state.update({ effects: undoHistory.reconfigure([
    history({ minDepth: LIMITS.historyGroups }), historyField.init(() => bounded.value),
  ]) })]);
  document.getElementById('history-notice')!.hidden = false;
}
function startComposition(): void {
  if (composing) return;
  let failure: string | null = null;
  try {
    requireThat(ready && !closed && !frozen && !quiesced, 'Editing is unavailable.');
    flush();
    reserveCredits(LIMITS.editBytes);
  } catch (error) { failure = errorText(error); }
  composing = { base: view.state, baseBytes: documentBytes,
    changes: ChangeSet.empty(view.state.doc.length), failed: failure, reserved: failure === null };
  compositionTimer = setTimeout(() => {
    show('Finish the active composition before snapshot or close. Text is provisional and has not been written.', true);
  }, 5000);
  if (failure) show(failure, true); else memoryStatus();
  sendActivity();
}
function finishComposition(): void {
  // Run after CM's compositionend observer and final DOM transaction have settled.
  setTimeout(() => {
    if (!composing) return;
    if (view.composing) { finishComposition(); return; }
    const provisional = composing;
    const finalSelection = selectionOf(view.state);
    const provisionalText = view.state.doc;
    let failure = provisional.failed;
    try {
      if (failure) throw new ProtocolError(failure);
      if (!provisional.changes.empty) {
        validateChanges(provisional.base.doc, provisional.baseBytes, changesOf(provisional.changes));
        validateSelection(view.state.doc, finalSelection);
      }
    } catch (error) { failure = errorText(error); }
    composing = null;
    clearTimeout(compositionTimer);
    compositionTimer = undefined;
    // Restore the persistent pre-composition state (including history), then enter
    // exactly one ordinary validated transaction. Previously accepted text remains.
    view.setState(provisional.base);
    if (!failure && !provisional.changes.empty) {
      const applied = applyTransaction(provisional.base.update({ changes: provisional.changes, selection: finalSelection,
        userEvent: 'input.type.compose' }));
      if (!applied) failure = 'The final composition could not be accepted.';
    }
    if (failure) {
      candidate.value = provisionalText.toString();
      refusal.hidden = false;
      show(`${failure} Composition was refused; the previous document is retained.`, true);
    }
    else { try { flush(); } catch (error) { show(errorText(error), true); } }
    sendActivity();
    while (controls.length) {
      const message = controls.shift()!;
      try { handle(message); } catch (error) { reject(message, error); }
    }
  }, 20);
}
function editorTheme(dark: boolean, highContrast = false, fontScale = 1, reducedMotion = false) {
  const foreground = highContrast ? (dark ? '#ffffff' : '#000000') : (dark ? '#e5eaf1' : '#17212b');
  const background = highContrast ? (dark ? '#000000' : '#ffffff') : (dark ? '#171b22' : '#fafafa');
  return EditorView.theme({
    '&': { backgroundColor: background, color: foreground, fontSize: `${16 * fontScale}px` },
    '.cm-content': { caretColor: foreground },
    '.cm-cursor': { borderLeftColor: foreground, ...(reducedMotion ? { animation: 'none' } : {}) },
    '.cm-gutters': { backgroundColor: background, color: foreground },
    ...(highContrast ? { '.cm-selectionBackground': { backgroundColor: dark ? '#555555 !important' : '#b0b0b0 !important' } } : {}),
    ...(reducedMotion ? { '*': { animation: 'none !important', transition: 'none !important', scrollBehavior: 'auto' } } : {}),
  }, { dark });
}
function deletePairedLineBreak(editor: EditorView, backward: boolean): boolean {
  const selection = editor.state.selection.main;
  if (editor.state.readOnly || !selection.empty) return false;
  const from = backward ? selection.head - 2 : selection.head;
  if (from < 0 || from + 2 > editor.state.doc.length
    || editor.state.doc.sliceString(from, from + 2) !== '\r\n') return false;
  editor.dispatch({ changes: { from, to: from + 2, insert: '' }, selection: { anchor: from },
    userEvent: backward ? 'delete.backward' : 'delete.forward' });
  return true;
}
function createState(source: string, selection: Selection, language: 'markdown' | 'text'): EditorState {
  return EditorState.create({
    doc: Text.of(source.split('\n')), selection,
    extensions: [
      EditorState.lineSeparator.of('\n'),
      EditorState.allowMultipleSelections.of(false),
      nonce.of(EditorView.cspNonce.of(scriptNonce)),
      writable.of([EditorState.readOnly.of(true), EditorView.editable.of(false)]), theme.of(editorTheme(false)),
      undoHistory.of(history({ minDepth: LIMITS.historyGroups })),
      language === 'markdown' ? markdown({ addKeymap: false }) : [],
      syntaxHighlighting(defaultHighlightStyle), lineNumbers(), EditorView.lineWrapping,
      EditorView.contentAttributes.of({ 'aria-label': language === 'markdown' ? 'Markdown source editor' : 'Plain text source editor',
        'aria-describedby': 'status', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off' }),
      EditorState.transactionExtender.of(transaction => !transaction.docChanged || composing
        ? { annotations: Transaction.addToHistory.of(false) } : null),
      EditorState.transactionFilter.of(transaction => {
        if (composing) return transaction;
        const selection = transaction.newSelection.main;
        const snap = (at: number, forward: boolean) => validBoundary(transaction.newDoc, at) ? at : at + (forward ? 1 : -1);
        const anchor = snap(selection.anchor, selection.anchor >= transaction.startState.selection.main.anchor);
        const head = snap(selection.head, selection.head >= transaction.startState.selection.main.head);
        if (anchor === selection.anchor && head === selection.head) return transaction;
        return [transaction, { selection: EditorSelection.single(anchor, head), sequential: true }];
      }),
      keymap.of([
        { key: 'Enter', run: editor => {
          if (editor.state.readOnly) return false;
          editor.dispatch({ ...editor.state.replaceSelection(lineEnding), userEvent: 'input' });
          return true;
        } },
        { key: 'Backspace', run: editor => deletePairedLineBreak(editor, true) },
        { key: 'Delete', run: editor => deletePairedLineBreak(editor, false) },
        ...historyKeymap, ...defaultKeymap,
      ]),
      EditorView.domEventHandlers({
        compositionstart: () => { startComposition(); return false; },
        compositionend: () => { finishComposition(); return false; },
        paste: (event, editor) => {
          const text = event.clipboardData?.getData('text/plain');
          if (text === undefined) return false;
          // Browser paste normalization is bypassed; clipboard source stays exact.
          event.preventDefault();
          editor.dispatch({ ...editor.state.replaceSelection(Text.of(text.split('\n'))), userEvent: 'input.paste' });
          return true;
        },
        drop: event => { event.preventDefault(); show('Drop is unavailable; paste exact plain text instead.', true); return true; },
      }),
    ],
  });
}
const view = new EditorView({ parent: document.getElementById('editor')!,
  state: createState('', { anchor: 0, head: 0 }, 'text'),
  dispatchTransactions: transactions => { for (const transaction of transactions) applyTransaction(transaction); },
});

function receiveAck(message: Extract<HostMessage, { type: 'ack' }>): void {
  requireThat(message.throughRevision <= revision, 'Acknowledgement refers to a future revision.');
  if (message.stage === 'rejected') {
    requireThat(inFlight.has(message.requestId) || message.requestId === readyRequest
      || message.requestId === snapshot?.requestId, 'Rejected acknowledgement has no matching request.');
    frozen = true;
    show(`Host rejected editor data: ${message.error}`, true);
    return;
  }
  if (message.stage === 'draftDurable' || message.stage === 'saved') {
    requireThat(message.revision === message.throughRevision, 'Durability capture mismatch.');
    if (message.stage === 'draftDurable') {
      requireThat(message.throughRevision <= receivedRevision, 'Draft durability exceeds received source.');
      if (message.throughRevision < durableRevision) return;
      durableRevision = message.throughRevision;
      for (const [id, entry] of undurable) if (entry.revision <= durableRevision) undurable.delete(id);
    } else {
      requireThat(message.throughRevision <= durableRevision, 'Saved receipt exceeds durable source.');
      if (savedRevision === null || message.throughRevision > savedRevision) savedRevision = message.throughRevision;
    }
    memoryStatus();
    return;
  }
  if (message.requestId === readyRequest) {
    requireThat(message.revision === 0 && message.throughRevision === 0, 'Invalid ready acknowledgement.');
    if (ready) return;
    ready = true;
    cache.release('load', readyRequest);
    view.dispatch({ effects: writable.reconfigure([EditorState.readOnly.of(false), EditorView.editable.of(true)]) });
    memoryStatus();
    sendActivity();
    return;
  }
  if (message.requestId === snapshot?.requestId) {
    requireThat(message.throughRevision === snapshot.revision && message.revision === snapshot.revision, 'Snapshot acknowledgement revision mismatch.');
    cache.release('resync', snapshot.requestId);
    snapshot = null;
    return;
  }
  const entry = inFlight.get(message.requestId);
  if (!entry && message.throughRevision <= receivedRevision) return;
  requireThat(entry && message.throughRevision === entry.revision && message.revision === entry.revision,
    'Acknowledgement does not match an outstanding edit.');
  receivedRevision = message.throughRevision;
  for (const [id, outstanding] of inFlight) if (outstanding.revision <= receivedRevision) inFlight.delete(id);
  armTransportTimeout();
  memoryStatus();
}
function handle(message: HostMessage): void {
  if (message.type === 'load') {
    requireThat(generation === null, 'A load cannot replace existing text. Explicitly discard the session first.');
    requireThat(window.VNoteEditor && typeof window.VNoteEditor.postMessage === 'function', 'Waiting for the native host channel.');
    const state = createState(message.text, message.selection, message.language);
    const title = message.language === 'markdown' ? 'Markdown source' : 'Plain text source';
    document.getElementById('source-title')!.textContent = title;
    document.getElementById('editor')!.setAttribute('aria-label', `${title} editor`);
    documentBytes = validateSource(message.text);
    lineEnding = preferredLineEnding(state.doc);
    editorLanguage = message.language;
    documentId = message.documentId;
    generation = message.generation;
    readyRequest = message.requestId;
    view.setState(state);
    show('Source loaded in memory. Waiting for host acknowledgement before editing.');
    reply(message, { type: 'ready', textLength: state.doc.length });
    return;
  }
  requireThat(generation !== null && documentId !== null, 'Load a host session before sending controls.');
  validateSession(message, documentId!, generation, revision);
  if (message.type === 'ack') { receiveAck(message); return; }
  requireThat(ready && !closed, 'Editor session is not writable.');
  if (message.type === 'close' && message.mode === 'abort') {
    for (let i = controls.length - 1; i >= 0; i--) {
      const queued = controls[i]!;
      if (queued.type === 'close' && queued.mode === 'quiesce') {
        controls.splice(i, 1);
        reject(queued, new ProtocolError('Close was aborted; text is retained.'));
      }
    }
    quiesced = false;
    view.dispatch({ effects: writable.reconfigure([EditorState.readOnly.of(false), EditorView.editable.of(true)]) });
    reply(message, { type: 'close', mode: 'aborted' });
    memoryStatus();
    return;
  }
  if (composing) {
    requireThat(controls.length < LIMITS.pendingControls, 'Too many controls waiting for composition.');
    controls.push(message);
    return;
  }
  switch (message.type) {
    case 'selection':
      requireThat(!frozen, 'Rejected text cannot supply an insertion selection.');
      clearTimeout(selectionTimer);
      selectionTimer = undefined;
      flush();
      if (message.mode === 'request') {
        // Flush precedes the correlated cursor barrier, including after IME.
        // No document snapshot or delayed coalesced selection is needed.
        reply(message, { type: 'selection', mode: 'current', ...selectionOf(view.state) });
        break;
      }
      validateSession(message, documentId!, generation, revision, true);
      validateSelection(view.state.doc, message);
      suppressSelection = true;
      try { view.dispatch({ selection: { anchor: message.anchor, head: message.head } }); }
      finally { suppressSelection = false; }
      break;
    case 'insert':
    case 'format': {
      requireThat(!frozen && !quiesced, 'Retained text cannot accept a source operation.');
      requireThat(message.type !== 'format' || editorLanguage === 'markdown', 'Formatting is available only for Markdown source.');
      flush();
      validateSession(message, documentId!, generation, revision, true);
      const transaction = message.type === 'insert'
        ? insertionTransaction(view.state, documentBytes, message)
        : formattingTransaction(view.state, documentBytes, message, lineEnding);
      sourceOperationId = message.requestId;
      try { requireThat(applyTransaction(transaction), 'Source operation was refused; the previous text is retained.'); }
      finally { sourceOperationId = undefined; }
      // The ordinary validated batch carries the one shared operation correlation.
      flush();
      reply(message, { type: 'ack', stage: 'received', throughRevision: revision, changed: transaction.docChanged });
      break;
    }
    case 'command':
      requireThat(!frozen && !quiesced, 'Text is retained; commands are paused.');
      if (message.command === 'undo') undo(view); else redo(view);
      break;
    case 'preferences':
      document.documentElement.dataset.theme = message.dark ? 'dark' : 'light';
      document.documentElement.dataset.contrast = message.highContrast ? 'high' : 'normal';
      document.documentElement.dataset.motion = message.reducedMotion ? 'reduced' : 'normal';
      document.documentElement.style.fontSize = `${16 * message.fontScale}px`;
      view.dispatch({ effects: theme.reconfigure(editorTheme(message.dark, message.highContrast, message.fontScale, message.reducedMotion)) });
      break;
    case 'flush':
      requireThat(!frozen && refusal.hidden, 'Resolve retained or provisional source before writing.');
      flush();
      reply(message, { type: 'flush', mode: 'ready', ...selectionOf(view.state) });
      break;
    case 'resync':
      if (message.mode === 'resume') {
        validateSession(message, documentId!, generation, revision, true);
        requireThat(resyncSource === view.state.doc && !pending && !composing && refusal.hidden,
          'Resync source changed; preserve both candidates.');
        frozen = false;
        resyncSource = null;
        receivedRevision = revision;
        inFlight.clear();
        armTransportTimeout();
        reply(message, { type: 'resync', mode: 'resumed' });
        sendActivity();
        memoryStatus();
        break;
      }
      requireThat(snapshot === null && resyncSource === null, 'A resync candidate is already retained.');
      if (!frozen) flush();
      frozen = true;
      // Replaying is bounded by the independent unreceived credit ceiling.
      for (const entry of inFlight.values()) post(entry.encoded);
      resyncSource = view.state.doc;
      snapshot = { requestId: message.requestId, revision };
      reply(message, { type: 'resync', mode: 'candidate', text: resyncSource.toString(), ...selectionOf(view.state) });
      break;
    case 'close':
      if (message.mode === 'quiesce') {
        requireThat(!frozen && refusal.hidden, 'Resolve retained or provisional source before closing.');
        flush();
        quiesced = true;
        view.dispatch({ effects: writable.reconfigure([EditorState.readOnly.of(true), EditorView.editable.of(false)]) });
        reply(message, { type: 'close', mode: 'quiesced', ...selectionOf(view.state) });
      } else if (message.mode === 'complete') {
        requireThat(quiesced && !pending && !composing, 'Close requires a quiesced source.');
        validateSession(message, documentId!, generation, revision, true);
        requireThat(message.disposition === 'discard' || durableRevision >= revision, 'Final source is not draft durable.');
        closed = true;
        clearTimeout(transportTimer);
        clearTimeout(selectionTimer);
        transportTimer = selectionTimer = undefined;
        retry.hidden = true;
        reply(message, { type: 'close', mode: 'closed' });
      }
      memoryStatus();
      break;
  }
}
function receive(input: unknown): void {
  let message: HostMessage;
  try {
    message = validateHostMessage(input);
    if (generation !== null) requireThat(message.documentId === documentId && message.generation === generation,
      'Stale or unknown session.');
    const previous = cache.begin(message, encodeMessage(message));
    if (previous) { if (previous.response !== null) post(previous.response); return; }
  } catch (error) { show(errorText(error), true); return; }
  try { handle(message); } catch (error) { reject(message, error); }
}
retry.addEventListener('click', () => {
  try { for (const entry of inFlight.values()) post(entry.encoded); armTransportTimeout(); }
  catch (error) { show(errorText(error), true); }
});
document.getElementById('dismiss')!.addEventListener('click', () => { candidate.value = ''; refusal.hidden = true; });
window.vnoteEditor = Object.freeze({ receive });
