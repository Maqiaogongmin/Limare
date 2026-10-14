import { h } from '../dom.js';
import { renderMessage, disclosure } from './message.js';

/// The Mac transcript's grouping (TranscriptTurnGrouping in MessageListView.swift): a turn is the
/// messages between two user messages. Once its last message is a finished answer (complete, no
/// tool calls, some text), the work before it folds under one disclosure and the answer shows
/// alone; until then every message shows, as it streams.
export function groupTranscript(messages) {
  const entries = [];
  let turn = [];
  const flush = () => {
    if (!turn.length) return;
    const final = turn[turn.length - 1];
    const finished = final.state === 'complete' && !final.toolCalls.length && final.content.trim() !== '';
    const history = turn.slice(0, -1);
    entries.push({
      kind: 'turn',
      key: turn[0].id,
      messages: turn,
      folded: finished && (history.length > 0 || !!final.reasoning),
    });
    turn = [];
  };
  for (const message of messages) {
    if (message.role === 'user') {
      flush();
      entries.push({ kind: 'user', key: message.id, messages: [message], folded: false });
    } else {
      turn.push(message);
    }
  }
  flush();
  return entries;
}

/// One entry as an element named by `data-entry`. A folded turn builds its history only when
/// it is opened; `ui.openHistory` keeps the ones the reader opened across re-renders. Its files
/// show on its answer, not inside the folded history (the Mac's `TurnDeliverables`).
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
  const final = entry.messages[entry.messages.length - 1];
  const history = entry.messages.slice(0, -1);
  element.append(
    disclosure({ class: 'history' }, h('summary', {}, `执行过程 · ${history.length} 条记录`), ui.openHistory, final.id,
      () => h('div', { class: 'history-body' },
        final.reasoning ? renderReasoning(final, ui) : null,
        history.map((message) => renderMessage(message, ui, { files: [] })))),
    renderMessage(final, ui, { hidesReasoning: true, files: turnFiles(entry.messages) }));
  return element;
}

/// The files a turn's messages delivered, first appearance first.
function turnFiles(messages) {
  const seen = new Set();
  return messages.flatMap((m) => m.files).filter((f) => !seen.has(f.id) && seen.add(f.id));
}

function renderReasoning(message, ui) {
  return disclosure({ class: 'reasoning' }, h('summary', {}, '思考过程'), ui.openReasoning, message.id,
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
  return h('div', { class: 'compaction', title: `模型此后读取到这里为止的摘要（约 ${tokens(finished.tokensBefore)} → ${tokens(finished.tokensAfter)} tokens），对话记录不变。` },
    `对话已压缩 · 节省 ${tokens(saved)} tokens`);
}

/// The Compact command running or just failed, at the end of the transcript.
export function currentCompactionLine(current) {
  if (current.state === 'failed') {
    return h('div', { class: 'compaction failed' }, `压缩失败：${current.message || ''}`);
  }
  const label = h('span', {});
  const since = current.since ? new Date(current.since).getTime() : Date.now();
  const tick = () => { label.textContent = `正在压缩对话… ${Math.max(0, Math.round((Date.now() - since) / 1000))}s`; };
  tick();
  const line = h('div', { class: 'compaction running' }, h('span', { class: 'spinner' }), label);
  const timer = setInterval(() => { if (line.isConnected) tick(); else clearInterval(timer); }, 1000);
  return line;
}
