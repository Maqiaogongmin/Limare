import { h } from '../dom.js';
import { t } from '../i18n.js';

let layer = null;

export function closeConversationActions() {
  layer?.remove();
  layer = null;
}

// The actions use the Mac's conversation store; no browser-side copy is the source of truth.
export function openConversationActions(store, connection, id, showError) {
  closeConversationActions();
  const show = (content, label) => {
    closeConversationActions();
    const sheet = h('div', { class: 'sheet conversation-actions', role: 'dialog', 'aria-modal': 'true', 'aria-label': label }, content);
    layer = h('div', { class: 'sheet-backdrop' }, sheet);
    layer.addEventListener('click', (event) => { if (event.target === layer) closeConversationActions(); });
    document.body.append(layer);
  };
  const run = async (type, fields = {}) => {
    if (!connection.isLive) { closeConversationActions(); showError('disconnected'); return; }
    const activeLayer = layer;
    activeLayer?.querySelectorAll('button').forEach((button) => { button.disabled = true; });
    const result = await connection.request(type, { conversationID: id, ...fields });
    if (layer === activeLayer) closeConversationActions();
    showError(result.ok ? null : result.error);
  };
  const rename = () => {
    const input = h('input', { class: 'rename-input', type: 'text', maxlength: '200', 'aria-label': t('Conversation Title') });
    input.value = store.summary(id)?.title || '';
    const save = h('button', { type: 'submit', class: 'primary' }, t('Save'));
    const update = () => { save.disabled = !input.value.trim(); };
    input.addEventListener('input', update);
    const form = h('form', { onsubmit: (event) => { event.preventDefault(); if (input.value.trim()) run('conversation.rename', { title: input.value.trim() }); } },
      h('h2', {}, t('Rename Conversation')), input,
      h('div', { class: 'buttons' }, h('button', { type: 'button', onclick: closeConversationActions }, t('Cancel')), save));
    show(form, t('Rename Conversation'));
    update();
    input.focus();
    input.select();
  };
  const archive = () => show([
    h('h2', {}, t('Archive Conversation')),
    h('p', { class: 'action-description' }, t('Archiving stops any active run. You can restore this conversation later.')),
    h('div', { class: 'buttons' }, h('button', { onclick: closeConversationActions }, t('Cancel')),
      h('button', { class: 'danger', onclick: () => run('conversation.archive') }, t('Archive Conversation'))),
  ], t('Archive Conversation'));
  const summary = store.summary(id);
  if (!summary) return;
  const move = () => {
    const choices = [{ id: null, name: t('No Project') }, ...store.projects];
    show([
      h('div', { class: 'picker-head' }, h('h2', {}, t('Move to Project')), h('button', { class: 'small', onclick: closeConversationActions }, t('Cancel'))),
      h('p', { class: 'action-description' }, t('Moving may change the conversation’s working folder.')),
      ...choices.map((project) => h('button', {
        class: `picker-item${project.id === (summary.projectID || null) ? ' selected' : ''}`,
        onclick: () => project.id === (summary.projectID || null) ? closeConversationActions() : run('conversation.move', { projectID: project.id }),
      }, h('span', { class: 'picker-label' }, project.name))),
    ], t('Move to Project'));
  };
  show([
    h('div', { class: 'picker-head' }, h('h2', {}, t('Conversation Actions')), h('button', { class: 'small', onclick: closeConversationActions }, t('Done'))),
    h('button', { class: 'action-item', onclick: rename }, t('Rename')),
    h('button', { class: 'action-item', onclick: () => run('conversation.setPinned', { isPinned: !summary.isPinned }) }, summary.isPinned ? t('Unpin Conversation') : t('Pin Conversation')),
    h('button', { class: 'action-item', onclick: () => run('conversation.setUnread', { isUnread: !summary.isUnread }) }, summary.isUnread ? t('Mark as Read') : t('Mark as Unread')),
    h('button', { class: 'action-item', onclick: move }, t('Move to Project')),
    h('button', { class: 'action-item', onclick: archive }, t('Archive Conversation')),
  ], t('Conversation Actions'));
}
