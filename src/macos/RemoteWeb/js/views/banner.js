import { h, clear } from '../dom.js';
import { t } from '../i18n.js';

const TEXT = {
  connecting: t('Connecting…'),
  reconnecting: t('Connection lost; reconnecting…'),
  offline: t('Offline; reconnects when the network returns'),
  unreachable: t("Can't reach Limare on the Mac; retrying…"),
  signin: t('Your sign-in has expired'),
};

export function renderBanner(banner, status) {
  clear(banner);
  if (status === 'outdated') {
    banner.hidden = false;
    banner.className = 'banner danger';
    banner.append(t('Limare was updated. Reload the page.'), ' ', h('button', { class: 'small', onclick: () => location.reload() }, t('Reload')));
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
    banner.append(' ', h('button', { class: 'small', onclick: () => location.reload() }, t('Sign In Again')));
  }
}
