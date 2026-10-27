import { h, clear } from '../dom.js';
import { t } from '../i18n.js';

/// The request Limare is waiting on, over every page (the Mac shows the same one).
export function renderApprovals(layer, store, connection) {
  clear(layer);
  const approval = store.approvals[0];
  if (!approval) return;
  let busy = false;
  const resolve = async (approved, buttons) => {
    if (busy) return;
    busy = true;
    buttons.forEach((b) => { b.disabled = true; });
    const result = await connection.request('approval.resolve', { kind: approval.kind, approvalID: approval.id, approved });
    if (!result.ok && result.error !== 'approvalNotPending') {
      busy = false;
      buttons.forEach((b) => { b.disabled = false; });
    }
  };

  const deny = h('button', {}, t('Deny'));
  const allow = h('button', { class: 'primary' }, approval.kind === 'app' ? t('Allow This App') : t('Allow'));
  deny.addEventListener('click', () => resolve(false, [deny, allow]));
  allow.addEventListener('click', () => resolve(true, [deny, allow]));
  if (!connection.isLive) { deny.disabled = true; allow.disabled = true; }

  const from = approval.conversationID
    ? h('div', { class: 'from' }, t('From'), ' ',
      h('button', { onclick: () => { location.hash = `#/c/${approval.conversationID}`; } }, approval.conversationTitle || t('Conversation')))
    : null;

  const body = approval.kind === 'app'
    ? [h('h2', {}, t('Allow Computer Use to control “%@”?', approval.appName)), from,
      h('div', { class: 'field' }, h('h4', {}, t('Application')), h('pre', {}, approval.bundleID))]
    : [h('h2', {}, t('%@ needs approval', approval.toolName)), from,
      approval.summary ? h('div', { class: 'field' }, approval.summary) : null,
      h('div', { class: 'flags' },
        approval.isHighRisk ? h('span', { class: 'badge high' }, t('High risk')) : null,
        approval.requestsNetwork ? h('span', { class: 'badge' }, t('Uses the network')) : null),
      approval.command ? h('div', { class: 'field' }, h('h4', {}, t('Command')), h('pre', {}, approval.command)) : null,
      approval.affectedPaths.length ? h('div', { class: 'field' }, h('h4', {}, t('Paths')), h('pre', {}, approval.affectedPaths.join('\n'))) : null,
      approval.environmentKeys.length ? h('div', { class: 'field' }, h('h4', {}, t('Environment variables (values hidden)')), h('pre', {}, approval.environmentKeys.join(', '))) : null,
      approval.reason ? h('div', { class: 'field' }, h('h4', {}, t('Reason')), approval.reason) : null];

  layer.append(h('div', { class: 'sheet-backdrop' },
    h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true' },
      body,
      h('div', { class: 'buttons' }, deny, allow),
      store.approvals.length > 1 ? h('div', { class: 'more' }, t('Waiting for approval: %lld more', store.approvals.length - 1)) : null)));
}
