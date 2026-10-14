import { h, clear } from '../dom.js';

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

  const deny = h('button', {}, '拒绝');
  const allow = h('button', { class: 'primary' }, approval.kind === 'app' ? '允许此应用' : '允许');
  deny.addEventListener('click', () => resolve(false, [deny, allow]));
  allow.addEventListener('click', () => resolve(true, [deny, allow]));
  if (!connection.isLive) { deny.disabled = true; allow.disabled = true; }

  const from = approval.conversationID
    ? h('div', { class: 'from' }, '来自 ',
      h('button', { onclick: () => { location.hash = `#/c/${approval.conversationID}`; } }, approval.conversationTitle || '对话'))
    : null;

  const body = approval.kind === 'app'
    ? [h('h2', {}, `允许 Computer Use 操作「${approval.appName}」？`), from,
      h('div', { class: 'field' }, h('h4', {}, '应用'), h('pre', {}, approval.bundleID))]
    : [h('h2', {}, `${approval.toolName} 需要批准`), from,
      approval.summary ? h('div', { class: 'field' }, approval.summary) : null,
      h('div', { class: 'flags' },
        approval.isHighRisk ? h('span', { class: 'badge high' }, '高风险') : null,
        approval.requestsNetwork ? h('span', { class: 'badge' }, '访问网络') : null),
      approval.command ? h('div', { class: 'field' }, h('h4', {}, '命令'), h('pre', {}, approval.command)) : null,
      approval.affectedPaths.length ? h('div', { class: 'field' }, h('h4', {}, '路径'), h('pre', {}, approval.affectedPaths.join('\n'))) : null,
      approval.environmentKeys.length ? h('div', { class: 'field' }, h('h4', {}, '环境变量（值已隐藏）'), h('pre', {}, approval.environmentKeys.join(', '))) : null,
      approval.reason ? h('div', { class: 'field' }, h('h4', {}, '原因'), approval.reason) : null];

  layer.append(h('div', { class: 'sheet-backdrop' },
    h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true' },
      body,
      h('div', { class: 'buttons' }, deny, allow),
      store.approvals.length > 1 ? h('div', { class: 'more' }, `还有 ${store.approvals.length - 1} 个请求等待批准`) : null)));
}
