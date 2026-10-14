import { h, clear } from '../dom.js';

const TEXT = {
  connecting: '正在连接…',
  reconnecting: '连接中断，正在重连…',
  offline: '网络已断开，恢复后自动重连',
  unreachable: '无法连接到 Mac 上的 Limare，正在重试…',
  signin: '登录已过期',
};

export function renderBanner(banner, status) {
  clear(banner);
  if (status === 'outdated') {
    banner.hidden = false;
    banner.className = 'banner danger';
    banner.append('Limare 已更新，请刷新页面 ', h('button', { class: 'small', onclick: () => location.reload() }, '刷新'));
    return;
  }
  if (status === 'live') {
    banner.hidden = true;
    return;
  }
  banner.hidden = false;
  banner.className = status === 'signin' || status === 'unreachable' ? 'banner danger' : 'banner';
  banner.append(TEXT[status] || status);
  if (status === 'signin') {
    banner.append(' ', h('button', { class: 'small', onclick: () => location.reload() }, '重新登录'));
  }
}
