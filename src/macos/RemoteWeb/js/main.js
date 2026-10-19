import { Connection } from './connection.js';
import { Store } from './store.js';
import { ListView } from './views/list.js';
import { ConversationView } from './views/conversation.js';
import { renderApprovals } from './views/approval.js';
import { renderBanner } from './views/banner.js';
import { loadMarkdown } from './markdown.js';
import { refreshPicker, closePicker } from './picker.js';
import { closeViewer } from './views/files.js';

const PROTOCOL_VERSION = 6;
window.limareStarted = true; // every module loaded; boot.js stands down

const app = document.getElementById('app');
const banner = document.getElementById('banner');
const approvalLayer = document.getElementById('approval-layer');
const connection = new Connection();
const store = new Store();
let view = null; // the ConversationView on screen, if any
let listView = null; // kept across navigation, so a half-written new conversation survives

function route() {
  const hash = location.hash || '#/';
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

function render() {
  const current = route();
  closePicker();
  closeViewer();
  app.replaceChildren();
  view = null;
  if (current.name === 'list') {
    store.setOpen(null);
    listView ||= new ListView({ store, connection });
    listView.renderGroups();
    listView.composer.render();
    app.append(listView.element);
    return;
  }
  store.setOpen(current.id);
  view = new ConversationView({ store, connection, conversationID: current.id });
  app.append(view.element);
  if (connection.isLive) openConversation(current.id);
}

/// Every composer that exists (the list's keeps its draft while a conversation is open).
function composers() {
  return [listView?.composer, view?.composer].filter(Boolean);
}

connection.addEventListener('event', (e) => {
  const event = e.detail;
  if (event.type === 'hello' && event.protocolVersion !== PROTOCOL_VERSION) {
    // This page and Limare no longer speak the same protocol: stop rather than guess.
    connection.halt();
    return;
  }
  store.apply(event);
});
connection.addEventListener('status', (e) => {
  renderBanner(banner, e.detail);
  view?.onConnection();
  listView?.composer.render();
  renderApprovals(approvalLayer, store, connection);
});

store.addEventListener('hello', () => {
  for (const composer of composers()) composer.onHello();
  // Everything is rebuilt from the server after each connect.
  if (store.openID) openConversation(store.openID);
  // The list is up; fetch the markdown renderer before a conversation needs it.
  setTimeout(loadMarkdown, 1000);
});
store.addEventListener('list', () => {
  if (route().name === 'list') listView?.renderGroups();
  view?.updateSummary();
});
store.addEventListener('catalog', () => {
  for (const composer of composers()) composer.render();
  refreshPicker();
});
store.addEventListener('settings', () => view?.composer.onSettings());
store.addEventListener('compactions', () => view?.onCompactions());
store.addEventListener('snapshot', () => view?.onSnapshot());
store.addEventListener('earlier', (e) => view?.onEarlier(e.detail));
store.addEventListener('message', (e) => view?.onMessage(e.detail));
store.addEventListener('run', () => view?.updateRun());
store.addEventListener('openSummary', () => view?.updateSummary());
store.addEventListener('openRemoved', () => { location.hash = '#/'; });
store.addEventListener('approvals', () => renderApprovals(approvalLayer, store, connection));

window.addEventListener('hashchange', render);
renderBanner(banner, connection.status);
render();
connection.start();
