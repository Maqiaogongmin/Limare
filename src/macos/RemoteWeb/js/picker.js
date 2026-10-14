import { h, clear } from './dom.js';

// A bottom sheet of choices (project, model, thinking level). One at a time, over every page.
let layer = null;
let current = null; // the open sheet's render function

export function closePicker() {
  current = null;
  if (layer) clear(layer);
}

/// Redraws the open sheet (if any) from the current state.
export function refreshPicker() {
  current?.();
}

/// `build()` returns the sheet's sections: [{ title, items: [{ label, detail, selected, disabled, onSelect }] }].
/// It is called again after every choice, so the sheet always shows the current state.
export function openPicker({ title, build }) {
  if (!layer) {
    layer = h('div', { id: 'picker-layer' });
    document.body.append(layer);
  }
  const render = () => {
    clear(layer);
    const sections = build();
    const sheet = h('div', { class: 'sheet picker', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
      h('div', { class: 'picker-head' }, h('h2', {}, title), h('button', { class: 'small', onclick: closePicker }, '完成')),
      sections.map((section) => h('div', { class: 'picker-section' },
        section.title ? h('h4', {}, section.title) : null,
        section.items.map((item) => h('button', {
          class: `picker-item${item.selected ? ' selected' : ''}`,
          disabled: item.disabled,
          onclick: async () => {
            const close = await item.onSelect();
            if (close) closePicker(); else render();
          },
        }, h('span', { class: 'picker-label' }, item.label), item.detail ? h('span', { class: 'picker-detail' }, item.detail) : null)))));
    const backdrop = h('div', { class: 'sheet-backdrop' }, sheet);
    backdrop.addEventListener('click', (event) => { if (event.target === backdrop) closePicker(); });
    layer.append(backdrop);
  };
  current = render;
  render();
}
