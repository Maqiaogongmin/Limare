import { h, clear } from '../dom.js';
import { renderMessage } from './message.js';
import { groupTranscript, currentFold, renderEntry, entryIDs, finishedCompactionLine, currentCompactionLine } from './transcript.js';
import { loadMarkdown, isMarkdownReady } from '../markdown.js';
import { runBadge } from './list.js';
import { Composer } from './composer.js';

function isActive(runState) {
  const status = runState && runState.run && runState.run.status;
  return status === 'running' || status === 'paused' || status === 'queued';
}

/// One conversation: messages, the run's controls and the composer (new conversations start
/// from the list page's composer). Everything shown comes from the store; the view keeps only
/// scroll position and open disclosures. The store holds the latest page of messages; older
/// pages are asked for when the reader scrolls near the top. Messages are drawn in the Mac's
/// entries (`groupTranscript`): a finished turn folds its work away and shows its answer.
export class ConversationView {
  constructor({ store, connection, conversationID }) {
    this.store = store;
    this.connection = connection;
    this.conversationID = conversationID;
    this.ui = { openTools: new Set(), openReasoning: new Set(), openHistory: new Set() };
    this.loadingEarlier = false;
    this.pendingMessages = new Map(); // upserts waiting for the next frame
    this.frozen = null; // the last turn's fold while the reader is away from the bottom
    this.wasActive = null;

    this.title = h('h1', {}, '');
    this.project = h('div', { class: 'topbar-project', hidden: true });
    this.badge = h('span');
    this.messages = h('div', { class: 'messages' }, h('div', { class: 'loading' }, '正在载入…'));
    this.runbar = h('div', { class: 'runbar', hidden: true });
    this.queuebar = h('div', { class: 'runbar queue', hidden: true });
    this.questionSlot = h('div', { class: 'question-slot' }); // filled by renderQuestion
    this.composer = new Composer({ store, connection, conversationID, isActive: () => isActive(this.store.open && this.store.open.runState) });
    this.earlier = h('button', { class: 'earlier', type: 'button', hidden: true, onclick: () => this.loadEarlier() }, '加载更早的消息');
    this.messages.addEventListener('scroll', () => { this.loadEarlierIfNearTop(); this.updateFreeze(); }, { passive: true });

    this.element = h('section', { class: 'conversation' },
      h('header', { class: 'topbar' },
        h('button', { class: 'back', 'aria-label': '返回', onclick: () => { location.hash = '#/'; } }, '‹'),
        h('div', { class: 'topbar-titles' }, this.title, this.project), this.badge),
      this.messages, this.runbar, this.queuebar, this.questionSlot, this.composer.element);
    this.updateSummary();
    this.updateRun();
    if (!isMarkdownReady()) {
      loadMarkdown().then(() => { if (this.store.open && this.element.isConnected) this.redrawAll(); });
    }
  }

  /// The transcript in the Mac's entries, folding the turn the run works on.
  group(messages = this.store.open.messages) {
    return groupTranscript(messages, { runActive: isActive(this.store.open && this.store.open.runState), frozen: this.frozen });
  }

  /// While the reader is away from the bottom the last turn's fold stays where it was, so what
  /// they read does not move into it; back at the bottom it folds as usual again.
  updateFreeze() {
    if (!this.store.open) return;
    const away = !this.nearBottom();
    if (away && !this.frozen) {
      this.frozen = currentFold(this.group());
    } else if (!away && this.frozen) {
      this.frozen = null;
      this.redrawLastTurn();
    }
  }

  redrawLastTurn() {
    if (!this.store.open) return;
    this.keepBottom(() => {
      const entries = this.group();
      const last = entries[entries.length - 1];
      if (last && last.kind === 'turn') this.entryElement(last.key)?.replaceWith(renderEntry(last, this.ui));
    });
  }

  /// Every entry again, keeping the reader's place (used once markdown-it has loaded).
  redrawAll() {
    const fromBottom = this.messages.scrollHeight - this.messages.scrollTop;
    for (const entry of this.group()) {
      this.entryElement(entry.key)?.replaceWith(renderEntry(entry, this.ui));
    }
    this.messages.scrollTop = this.messages.scrollHeight - fromBottom;
  }

  entryElement(key) {
    return this.messages.querySelector(`[data-entry="${CSS.escape(key)}"]`);
  }

  /// The Compact lines: each finished one after the entry holding its message (as the Mac
  /// places them), and the running or failed one at the end.
  placeCompactions() {
    for (const line of this.messages.querySelectorAll('.compaction')) line.remove();
    const compactions = this.store.open?.compactions;
    if (!compactions) return;
    for (const finished of compactions.finished) {
      const entry = this.messages.querySelector(`[data-id="${CSS.escape(finished.afterMessageID)}"]`)?.closest('[data-entry]');
      // A message in a folded turn's unopened history is not drawn; its turn's element names it.
      const owner = entry || this.entryHolding(finished.afterMessageID);
      if (!owner) continue;
      let after = owner;
      while (after.nextElementSibling?.classList.contains('compaction')) after = after.nextElementSibling;
      after.after(finishedCompactionLine(finished));
    }
    if (compactions.current) this.messages.append(currentCompactionLine(compactions.current));
  }

  entryHolding(messageID) {
    const entry = this.group().find((e) => entryIDs(e).includes(messageID));
    return entry ? this.entryElement(entry.key) : null;
  }

  onCompactions() {
    this.keepBottom(() => this.placeCompactions());
  }

  nearBottom() {
    const m = this.messages;
    return m.scrollHeight - m.scrollTop - m.clientHeight < 80;
  }

  keepBottom(update) {
    const stick = this.nearBottom();
    update();
    if (stick) this.messages.scrollTop = this.messages.scrollHeight;
  }

  // Store events -------------------------------------------------------------

  onSnapshot() {
    const open = this.store.open;
    this.pendingMessages.clear();
    this.loadingEarlier = false;
    this.frozen = null;
    clear(this.messages);
    this.earlier.hidden = !open.hasEarlier;
    this.earlier.textContent = '加载更早的消息';
    this.messages.append(this.earlier);
    if (!open.messages.length) this.messages.append(h('div', { class: 'empty' }, '还没有消息'));
    const fragment = document.createDocumentFragment();
    for (const entry of this.group(open.messages)) fragment.append(renderEntry(entry, this.ui));
    this.messages.append(fragment);
    this.placeCompactions();
    this.messages.scrollTop = this.messages.scrollHeight;
    this.updateSummary();
    this.updateRun();
    this.loadEarlierIfNearTop();
  }

  /// Older messages go above the ones on screen without moving what the reader is looking at.
  /// The page's last turn may continue the first one on screen; it then replaces that turn.
  onEarlier(messages) {
    this.loadingEarlier = false;
    const fromBottom = this.messages.scrollHeight - this.messages.scrollTop;
    const added = new Set(messages.map((m) => m.id));
    const entries = this.group().filter((e) => entryIDs(e).some((id) => added.has(id)));
    const last = entries[entries.length - 1];
    for (const id of last ? entryIDs(last) : []) if (!added.has(id)) this.entryElement(id)?.remove();
    const fragment = document.createDocumentFragment();
    for (const entry of entries) fragment.append(renderEntry(entry, this.ui));
    this.earlier.after(fragment);
    this.placeCompactions();
    this.earlier.hidden = !this.store.open.hasEarlier;
    this.earlier.textContent = '加载更早的消息';
    this.messages.scrollTop = this.messages.scrollHeight - fromBottom;
    this.loadEarlierIfNearTop(); // one page may not fill the screen
  }

  loadEarlierIfNearTop() {
    if (this.messages.scrollTop < 600) this.loadEarlier();
  }

  async loadEarlier() {
    const open = this.store.open;
    if (this.loadingEarlier || !open || !open.hasEarlier || !open.messages.length || !this.connection.isLive) return;
    this.loadingEarlier = true;
    this.earlier.textContent = '正在载入…';
    const result = await this.connection.request('conversation.loadEarlier', {
      conversationID: this.conversationID,
      beforeMessageID: open.messages[0].id,
    });
    if (!result.ok) {
      this.loadingEarlier = false;
      this.earlier.textContent = '加载更早的消息';
    }
  }

  /// Streaming sends whole messages up to ten times a second; each is drawn once per frame at most.
  onMessage(message) {
    const first = this.pendingMessages.size === 0;
    this.pendingMessages.set(message.id, message);
    if (first) requestAnimationFrame(() => this.drawPendingMessages());
  }

  /// Upserts change messages on screen or add them at the end (anything else arrives as a
  /// snapshot). A turn still at work is updated message by message; one that folds or unfolds
  /// is drawn again whole.
  drawPendingMessages() {
    const pending = this.pendingMessages;
    this.pendingMessages = new Map();
    if (!pending.size || !this.store.open) return;
    this.keepBottom(() => {
      for (const entry of this.group()) {
        const touched = entry.messages.filter((m) => pending.has(m.id));
        if (!touched.length) continue;
        const existing = this.entryElement(entry.key);
        if (!existing) {
          this.messages.querySelector('.empty')?.remove();
          const trailing = this.messages.querySelector('.compaction.running, .compaction.failed');
          const element = renderEntry(entry, this.ui);
          if (trailing) trailing.before(element); else this.messages.append(element);
        } else if (entry.kind === 'turn' && !entry.folded && existing.dataset.folded === 'false') {
          for (const message of touched) {
            const element = renderMessage(message, this.ui);
            const old = existing.querySelector(`[data-id="${CSS.escape(message.id)}"]`);
            if (old) old.replaceWith(element); else existing.append(element);
          }
        } else {
          existing.replaceWith(renderEntry(entry, this.ui));
        }
      }
    });
  }

  updateSummary() {
    const summary = this.store.summary(this.conversationID);
    if (!summary) return;
    this.title.textContent = summary.title || '新对话';
    // The project is fixed for an existing conversation; it is shown, not chosen (addendum D1).
    const project = summary.projectID ? this.store.project(summary.projectID) : null;
    this.project.hidden = !project;
    this.project.textContent = project ? project.name : '';
    const badge = runBadge(summary.run);
    this.badge.replaceChildren(...(badge ? [badge] : []));
  }

  updateRun() {
    const runState = this.store.open && this.store.open.conversation.id === this.conversationID ? this.store.open.runState : null;
    const active = isActive(runState);
    const run = runState && runState.run;
    // The run starting or ending changes how its turn folds.
    if (this.wasActive !== null && this.wasActive !== active) this.redrawLastTurn();
    this.wasActive = active;

    clear(this.runbar);
    this.runbar.hidden = !active;
    if (active) {
      const paused = run.status === 'paused';
      const label = paused ? '已暂停' : run.isPausing ? '将在安全点暂停…' : (run.statusText || '运行中');
      const pauseButton = paused || run.isPausing
        ? h('button', { class: 'small', onclick: () => this.command('run.resume') }, paused ? '继续' : '取消暂停')
        : h('button', { class: 'small', onclick: () => this.command('run.pause') }, '暂停');
      this.runbar.append(
        h('span', { class: 'status' }, runBadge(paused ? 'paused' : run.isPausing ? 'pausing' : 'running'), label),
        pauseButton,
        h('button', { class: 'small danger', onclick: () => this.command('run.stop') }, '停止'));
    }

    clear(this.queuebar);
    const queued = runState ? runState.queuedCount : 0;
    this.queuebar.hidden = queued === 0;
    if (queued > 0) {
      this.queuebar.append(h('span', { class: 'status' }, runState.queueHeld ? `${queued} 条排队（停止或出错后已暂停）` : `${queued} 条排队，当前运行结束后执行`));
      if (runState.queueHeld || !active) {
        this.queuebar.append(
          h('button', { class: 'small', onclick: () => this.command('queue.resume') }, runState.queueHeld ? '恢复队列' : '运行队列'),
          h('button', { class: 'small', onclick: () => this.command('queue.clear') }, '清空'));
      }
    }
    this.composer.render();
  }

  onConnection() {
    this.composer.render();
  }

  // Commands -----------------------------------------------------------------

  async command(type) {
    const result = await this.connection.request(type, { conversationID: this.conversationID });
    this.composer.showError(result.ok ? null : result.error);
  }
}
