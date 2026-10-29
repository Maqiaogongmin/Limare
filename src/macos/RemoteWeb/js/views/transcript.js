import { h } from '../dom.js';
import { renderMessage, disclosure } from './message.js';
import { t } from '../i18n.js';

const UNSUCCESSFUL = new Set(['failed', 'timedOut', 'cancelled', 'denied', 'interrupted']);

/// The Mac transcript's grouping (TranscriptTurnGrouping in MessageListView.swift): a turn is the
/// messages between two user messages. Its earlier steps fold under one disclosure once it ends
/// in a finished answer (complete, no tool calls, some text), while the run works on it (all but
/// the current step) and before a message the user sent while it worked; otherwise every message
/// shows. `frozen` ({ key, count }) keeps the last running turn's fold where it was while the
/// reader is away from the bottom; a finished turn folds anyway. Folded calls that did not
/// succeed are counted on the fold's title.
export function groupTranscript(messages, { runActive = false, frozen = null } = {}) {
  const entries = [];
  let turn = [];
  const flush = (isLast, endsAtSteer) => {
    if (!turn.length) return;
    const final = turn[turn.length - 1];
    const finished = final.state === 'complete' && !final.toolCalls.length && final.content.trim() !== '';
    let rowIndex = turn.length - 1;
    let folded = false;
    let hidesReasoning = false;
    if (!finished && frozen && frozen.key === turn[0].id) {
      rowIndex = Math.min(frozen.count, turn.length - 1);
      folded = rowIndex > 0;
    } else if (finished) {
      folded = turn.length > 1 || !!final.reasoning;
      hidesReasoning = folded;
    } else if (turn.length > 1 && ((isLast && runActive) || endsAtSteer)) {
      folded = true;
    }
    if (!folded) rowIndex = 0;
    const history = turn.slice(0, rowIndex);
    entries.push({
      kind: 'turn',
      key: turn[0].id,
      messages: turn,
      folded,
      rowIndex,
      hidesReasoning,
      unsuccessful: history.flatMap((m) => m.toolCalls).filter((t) => UNSUCCESSFUL.has(t.state)).length,
    });
    turn = [];
  };
  for (const message of messages) {
    if (message.role === 'user') {
      flush(false, !!message.sentWhileWorking);
      entries.push({ kind: 'user', key: message.id, messages: [message], folded: false });
    } else {
      turn.push(message);
    }
  }
  flush(true, false);
  return entries;
}

/// The last turn's current fold, to keep while the reader is away from the bottom.
export function currentFold(entries) {
  const last = entries[entries.length - 1];
  return last && last.kind === 'turn' ? { key: last.key, count: last.folded ? last.rowIndex : 0 } : null;
}

/// One entry as an element named by `data-entry`. A folded turn builds its history only when
/// it is opened; `ui.openHistory` keeps the ones the reader opened across re-renders, by the
/// turn's first message, so a fold stays open from its first step to the answer. The turn's
/// files show on the row after the fold, not inside it (the Mac's `TurnDeliverables`).
export function renderEntry(entry, ui) {
  if (entry.kind === 'user') {
    const element = renderMessage(entry.messages[0], ui);
    element.dataset.entry = entry.key;
    return element;
  }
  const element = h('div', { class: 'turn', dataset: { entry: entry.key, folded: String(entry.folded) } });
  if (!entry.folded) {
    for (const message of entry.messages) element.append(renderMessage(message, ui));
    return element;
  }
  const history = entry.messages.slice(0, entry.rowIndex);
  const row = entry.messages[entry.rowIndex];
  const rest = entry.messages.slice(entry.rowIndex + 1);
  const title = h('summary', {}, t('Execution (%lld)', history.length),
    entry.unsuccessful ? h('span', { class: 'warn' }, t(' · %lld unsuccessful', entry.unsuccessful)) : null);
  element.append(
    disclosure({ class: 'history' }, title, ui.openHistory, entry.key,
      () => h('div', { class: 'history-body' },
        entry.hidesReasoning && row.reasoning ? renderReasoning(row, ui) : null,
        history.map((message) => renderMessage(message, ui, { files: [] })))),
    renderMessage(row, ui, { hidesReasoning: entry.hidesReasoning, files: turnFiles(entry.messages) }),
    ...rest.map((message) => renderMessage(message, ui, { files: [] })));
  return element;
}

/// The files a turn's messages delivered, first appearance first.
function turnFiles(messages) {
  const seen = new Set();
  return messages.flatMap((m) => m.files).filter((f) => !seen.has(f.id) && seen.add(f.id));
}

function renderReasoning(message, ui) {
  return disclosure({ class: 'reasoning' }, h('summary', {}, t('Thought process')), ui.openReasoning, message.id,
    () => h('div', { class: 'reasoning-text' }, message.reasoning));
}

/// The message ids an entry holds.
export function entryIDs(entry) {
  return entry.messages.map((m) => m.id);
}

function tokens(count) {
  if (count < 1000) return String(count);
  const [value, unit] = count < 1e6 ? [count / 1e3, 'K'] : [count / 1e6, 'M'];
  return `${value.toFixed(1).replace(/\.0$/, '')}${unit}`;
}

/// A finished Compact command, as the Mac shows it: one quiet line.
export function finishedCompactionLine(finished) {
  const saved = Math.max(0, finished.tokensBefore - finished.tokensAfter);
  return h('div', { class: 'compaction', title: t('The model now reads a summary of the conversation up to here (about %@ → %@ tokens). The transcript is unchanged.', tokens(finished.tokensBefore), tokens(finished.tokensAfter)) },
    t('Conversation compacted · %@ tokens saved', tokens(saved)));
}

/// The Compact command running or just failed, at the end of the transcript.
export function currentCompactionLine(current) {
  if (current.state === 'failed') {
    return h('div', { class: 'compaction failed' }, t('Compact failed: %@', current.message || ''));
  }
  const label = h('span', {});
  const since = current.since ? new Date(current.since).getTime() : Date.now();
  const tick = () => { label.textContent = t('Compacting conversation… %llds', Math.max(0, Math.round((Date.now() - since) / 1000))); };
  tick();
  const line = h('div', { class: 'compaction running' }, h('span', { class: 'spinner' }), label);
  const timer = setInterval(() => { if (line.isConnected) tick(); else clearInterval(timer); }, 1000);
  return line;
}
