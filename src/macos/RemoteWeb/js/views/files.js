import { h, clear, icon, formatBytes } from '../dom.js';
import { fillMarkdown, loadMarkdown } from '../markdown.js';
import { t } from '../i18n.js';

// The files a message shows, as the Mac's FileArtifactCard does, and their preview. What a file
// previews as is the Mac's decision (`file.preview`, from FilePreviewClassifier); this page only
// renders each kind. A file the Mac does not preview is saved: the phone then handles it as the
// Mac's default app would.

const TYPE = { markdown: 'Markdown', text: t('Text'), code: t('Code'), image: t('Image'), pdf: 'PDF', html: 'HTML' };

function typeName(file) {
  if (file.preview === 'code' && file.language) return file.language;
  if (file.preview) return TYPE[file.preview];
  const ext = file.filename.includes('.') ? file.filename.split('.').pop().toUpperCase() : '';
  return ext ? t('%@ File', ext) : t('File');
}

function subtitle(file) {
  return [typeName(file), file.byteCount != null ? formatBytes(file.byteCount) : null].filter(Boolean).join(' · ');
}

/// A card that opens `file`: its preview over the page, or saving it when it has none.
export function fileCard(file) {
  const detail = h('span', { class: 'file-detail' }, subtitle(file));
  const body = [
    icon(file.preview === 'image' ? 'image' : 'file', 18),
    h('span', { class: 'file-text' }, h('span', { class: 'file-name' }, file.filename), detail),
  ];
  if (!file.preview) {
    const card = h('button', { class: 'file-card', type: 'button' }, body);
    const text = { preparing: t('Preparing…'), tapAgain: t('Ready; tap again to save') };
    card.addEventListener('click', saver(file, (state, message) => {
      detail.textContent = state === 'failed' ? t("Couldn't save: %@", message) : text[state] ?? subtitle(file);
    }));
    return card;
  }
  return h('button', { class: 'file-card', type: 'button', onclick: () => openViewer(file) }, body);
}

// MARK: - Saving

/// A click handler that saves `file` through the system share sheet (Save to Files, AirDrop,
/// another app), so the page stays where it is: a download link would replace the page, and in
/// the home-screen app nothing leads back. Where sharing files is not offered, the file downloads.
/// `status(state, message)` shows where it is: 'preparing', 'tapAgain', 'failed' (with why), or
/// null when idle.
///
/// Sharing must start from a tap. When fetching the file took long enough that the tap no longer
/// counts, the file is kept and the next tap shares it at once.
function saver(file, status) {
  let ready = null; // the fetched file, waiting for a tap
  let busy = false;
  return async () => {
    if (busy) return;
    if (ready) {
      const waiting = ready;
      ready = null;
      status(null);
      await deliver(waiting, file.filename);
      return;
    }
    busy = true;
    status('preparing');
    let fetched;
    try {
      const response = await fetch(file.url, { credentials: 'same-origin' });
      if (!response.ok) throw new Error(response.status === 404 ? t('The file is gone') : `HTTP ${response.status}`);
      const blob = await response.blob();
      fetched = new File([blob], file.filename, { type: blob.type || 'application/octet-stream' });
    } catch (error) {
      busy = false;
      status('failed', error.message);
      return;
    }
    busy = false;
    status(null);
    if (await deliver(fetched, file.filename) === 'needsTap') {
      ready = fetched;
      status('tapAgain');
    }
  };
}

/// Shares `file`, or downloads it where sharing files is not offered. 'needsTap' when the share
/// sheet refused to open outside a tap.
async function deliver(file, filename) {
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
    } catch (error) {
      if (error.name === 'NotAllowedError') return 'needsTap';
      // AbortError: the sheet was dismissed.
    }
    return 'done';
  }
  const url = URL.createObjectURL(file);
  const link = h('a', { href: url, download: filename, hidden: true });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return 'done';
}

/// An image attachment as the Mac shows it in a user message: the picture, which opens the preview.
export function imageThumbnail(file) {
  return h('button', { class: 'file-thumb', type: 'button', 'aria-label': file.filename, onclick: () => openViewer(file) },
    h('img', { src: file.url, alt: file.filename, loading: 'lazy' }));
}

/// The cards for `files`: image attachments (`thumbnails`) as pictures, the rest as cards.
export function fileList(files, { thumbnails = false } = {}) {
  if (!files.length) return null;
  return h('div', { class: 'files' }, files.map((f) => (thumbnails && f.preview === 'image' ? imageThumbnail(f) : fileCard(f))));
}

// MARK: - Preview

let layer = null;

/// Closes the preview without going back (the page navigated elsewhere).
export function closeViewer() {
  if (layer) clear(layer);
}

/// The preview fills the screen. It takes a history entry, so the phone's back gesture closes it.
function openViewer(file) {
  if (!layer) {
    layer = h('div', { id: 'viewer-layer' });
    document.body.append(layer);
    window.addEventListener('popstate', () => { if (layer.firstChild) clear(layer); });
  }
  const content = h('div', { class: 'viewer-body' });
  const close = () => history.back();
  const save = h('button', { class: 'small', type: 'button' }, t('Save'));
  const label = { preparing: t('Preparing…'), tapAgain: t('Tap to Save'), failed: t('Retry') };
  save.addEventListener('click', saver(file, (state) => { save.textContent = label[state] ?? t('Save'); }));
  layer.replaceChildren(h('div', { class: 'viewer', role: 'dialog', 'aria-modal': 'true', 'aria-label': file.filename },
    h('div', { class: 'viewer-head' },
      h('button', { class: 'icon-button', type: 'button', 'aria-label': t('Close'), onclick: close }, icon('close', 20)),
      h('span', { class: 'viewer-title' }, h('span', { class: 'file-name' }, file.filename), h('span', { class: 'file-detail' }, subtitle(file))),
      save),
    content));
  history.pushState({ viewer: true }, '');
  fill(content, file);
}

async function fill(content, file) {
  if (file.preview === 'image') {
    content.append(h('img', { class: 'viewer-image', src: file.url, alt: file.filename }));
    return;
  }
  if (file.preview === 'pdf') {
    // The browser's own PDF viewer, inside the preview: in the home-screen app a page opened
    // outside it has no way back.
    content.append(h('iframe', { class: 'viewer-frame', src: file.url, title: file.filename }));
    return;
  }
  if (file.preview === 'html') {
    // Passive, as the Mac previews HTML: the response's own policy sandboxes it (no script,
    // nothing from the network). A `sandbox` attribute as well would leave the frame blank: the
    // sandboxed frame no longer counts as 'self' for the response's frame-ancestors.
    content.append(h('iframe', { class: 'viewer-frame', src: file.url, title: file.filename }));
    return;
  }
  content.append(h('div', { class: 'viewer-status' }, t('Loading…')));
  let text;
  try {
    const response = await fetch(file.url, { credentials: 'same-origin' });
    if (!response.ok) throw new Error(response.status === 404 ? t('The file is gone') : `HTTP ${response.status}`);
    text = await response.text();
    if (file.preview === 'markdown') await loadMarkdown();
  } catch (error) {
    content.replaceChildren(h('div', { class: 'viewer-status' }, t("Couldn't preview: %@", error.message)));
    return;
  }
  if (file.preview === 'markdown') {
    const body = h('div', { class: 'markdown viewer-markdown' });
    fillMarkdown(body, text);
    content.replaceChildren(body);
  } else {
    content.replaceChildren(h('pre', { class: 'viewer-text' }, text));
  }
}
