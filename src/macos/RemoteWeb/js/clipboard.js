import { h } from './dom.js';
import { t } from './i18n.js';

// Clipboard access can be unavailable on HTTP or denied by the browser. The fallback
// stays inside the tap handler so older mobile browsers can still accept the request.
export async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(text); return true; } catch { /* try fallback */ }
  }
  const field = h('textarea', { readonly: true, 'aria-hidden': 'true' });
  field.value = text;
  Object.assign(field.style, { position: 'fixed', top: '0', left: '-9999px', opacity: '0' });
  document.body.append(field);
  field.focus();
  field.select();
  field.setSelectionRange(0, field.value.length);
  let copied = false;
  try { copied = document.execCommand('copy'); } catch { /* show failure */ }
  field.remove();
  return copied;
}

export function copyButton(text, label, className) {
  let reset;
  const button = h('button', { type: 'button', class: className, 'aria-label': label, onclick: async () => {
    clearTimeout(reset);
    const success = await copyText(text);
    button.textContent = success ? t('Copied') : t('Copy failed');
    reset = setTimeout(() => { button.textContent = label; }, 2000);
  } }, label);
  return button;
}
