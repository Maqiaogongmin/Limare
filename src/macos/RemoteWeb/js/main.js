import { Connection } from './connection.js';
import { Store } from './store.js';
import { ListView } from './views/list.js';
import { ConversationView } from './views/conversation.js';
import { Composer } from './views/composer.js';
import { renderApprovals } from './views/approval.js';
import { renderQuestion } from './views/question.js';
import { renderBanner } from './views/banner.js';
import { loadMarkdown } from './markdown.js';
import { refreshPicker, closePicker } from './picker.js';
import { closeViewer } from './views/files.js';
import { closeConversationActions } from './views/conversation-actions.js';

const PROTOCOL_VERSION = 12;
window.limareStarted = true; // every module loaded; boot.js stands down

const app = document.getElementById('app');
const banner = document.getElementById('banner');
const approvalLayer = document.getElementById('approval-layer');
const connection = new Connection();
const store = new Store();
let view = null; // the ConversationView on screen, if any
let listView = null; // kept across navigation, so a half-written new conversation survives
const conversationComposers = new Map(); // drafts and in-flight uploads survive navigation

function composerFor(id) {
  if (!conversationComposers.has(id)) {
    conversationComposers.set(id, new Composer({
      store, connection, conversationID: id,
      isActive: () => store.openID === id && ['running', 'paused', 'queued'].includes(store.open?.runState?.run?.status),
    }));
  }
  return conversationComposers.get(id);
}

function route() {
  const hash = location.hash || '#/';
  if (hash === '#/archive') return { name: 'archive' };
  const match = hash.match(/^#\/c\/([0-9A-Fa-f-]{36})$/);
  if (match) return { name: 'conversation', id: match[1].toUpperCase() };
  return { name: 'list' };
}

async function openConversation(id) {
  const result = await connection.request('conversation.open', { conversationID: id });
  if (!result.ok && result.error === 'conversationNotFound' && store.openID === id) {
    location.hash = '#/';
  }
}

// Reading on the phone clears the same marker as opening a conversation on the Mac.
// A hidden tab must not silently mark messages as read.
function markOpenRead() {
  if (document.visibilityState !== 'visible' || !connection.isLive || !store.open || store.open.conversation.id !== store.openID) return;
  connection.request('conversation.setUnread', { conversationID: store.openID, isUnread: false });
}

function render() {
  const current = route();
  closePicker();
  closeViewer();
  closeConversationActions();
  view?.dispose();
  app.replaceChildren();
  view = null;
  if (current.name === 'list' || current.name === 'archive') {
    store.setOpen(null);
    listView ||= new ListView({ store, connection });
    listView.setMode(current.name === 'archive');
    listView.composer.render();
    app.append(listView.element);
    return;
  }
  store.setOpen(current.id);
  view = new ConversationView({ store, connection, conversationID: current.id, composer: composerFor(current.id) });
  renderQuestion(view.questionSlot, store, connection);
  app.append(view.element);
  if (connection.isLive) openConversation(current.id);
}

/// Every composer that exists (the list's keeps its draft while a conversation is open).
function composers() {
  return [listView?.composer, ...conversationComposers.values()].filter(Boolean);
}

connection.addEventListener('event', (e) => {
  const event = e.detail;
  if (event.type === 'hello' && event.protocolVersion !== PROTOCOL_VERSION) {
    // This page and Limare no longer speak the same protocol: stop rather than guess.
    connection.halt();
    return;
  }
  if (event.type === 'conversations.changed') {
    for (const id of event.removed) {
      conversationComposers.get(id)?.dispose();
      conversationComposers.delete(id);
    }
  }
  store.apply(event);
});
connection.addEventListener('status', (e) => {
  renderBanner(banner, e.detail);
  view?.onConnection();
  listView?.composer.render();
  renderApprovals(approvalLayer, store, connection);
  renderQuestion(view?.questionSlot, store, connection);
});

store.addEventListener('hello', () => {
  // A conversation can have been archived on the Mac while this page was disconnected.
  for (const [id, composer] of conversationComposers) {
    if (!store.conversations.has(id)) {
      composer.dispose();
      conversationComposers.delete(id);
    }
  }
  for (const composer of composers()) composer.onHello();
  listView?.onHello();
  // Everything is rebuilt from the server after each connect.
  if (store.openID) openConversation(store.openID);
  // The list is up; fetch the markdown renderer before a conversation needs it.
  setTimeout(loadMarkdown, 1000);
});
store.addEventListener('list', () => {
  if (route().name !== 'conversation') listView?.renderGroups();
  view?.updateSummary();
});
store.addEventListener('archive', () => { if (route().name === 'archive') listView?.renderGroups(); });
store.addEventListener('catalog', () => {
  for (const composer of composers()) composer.render();
  refreshPicker();
});
store.addEventListener('settings', () => view?.composer.onSettings());
store.addEventListener('compactions', () => view?.onCompactions());
store.addEventListener('snapshot', () => { view?.onSnapshot(); markOpenRead(); });
store.addEventListener('earlier', (e) => view?.onEarlier(e.detail));
store.addEventListener('message', (e) => view?.onMessage(e.detail));
store.addEventListener('run', () => {
  const wasActive = view?.wasActive;
  view?.updateRun();
  if (wasActive && view && !view.wasActive) markOpenRead();
});
store.addEventListener('openSummary', () => view?.updateSummary());
store.addEventListener('openRemoved', () => { location.hash = '#/'; });
store.addEventListener('approvals', () => renderApprovals(approvalLayer, store, connection));
store.addEventListener('questions', () => renderQuestion(view?.questionSlot, store, connection));

window.addEventListener('hashchange', render);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') markOpenRead(); });
renderBanner(banner, connection.status);
render();
connection.start();
