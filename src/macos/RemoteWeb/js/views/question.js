import { h, clear } from '../dom.js';
import { t } from '../i18n.js';

const built = new Map(); // card id → { element, refresh }, kept while the card waits

/// The question card the open conversation waits on (`ask_user_question`), as on the Mac: each
/// question's options, an Other answer, Skip and Submit, in the conversation page above the
/// composer, so the reader can still scroll the conversation, leave it, or send a message
/// instead (which ends the card unanswered). A card keeps what the reader filled in while its id
/// still waits: leaving the conversation and coming back, another card appearing or ending, or a
/// reconnect's hello only updates whether it can be sent.
export function renderQuestion(slot, store, connection) {
  for (const id of built.keys()) {
    if (!store.questions.some((q) => q.id === id)) built.delete(id);
  }
  if (!slot) return;
  const card = store.openID ? store.questions.find((q) => q.conversationID === store.openID) : null;
  if (!card) {
    clear(slot);
    return;
  }
  let shown = built.get(card.id);
  if (!shown) {
    shown = build(card, connection);
    built.set(card.id, shown);
  }
  if (slot.firstChild !== shown.element || slot.childNodes.length !== 1) slot.replaceChildren(shown.element);
  shown.refresh();
}

function build(card, connection) {
  let busy = false;
  const showHeaders = card.questions.length > 1; // as the Mac: one question needs no chip
  const states = card.questions.map((q, index) => buildQuestion(q, index, card.id, showHeaders, () => refresh()));

  const skip = h('button', { title: t("Don't answer; end this turn and wait for your message") }, t('Skip'));
  const submit = h('button', { class: 'primary' }, t('Submit'));

  const send = async (payload) => {
    if (busy) return;
    busy = true;
    refresh();
    const result = await connection.request('question.answer', { questionID: card.id, ...payload });
    if (!result.ok && result.error !== 'questionNotPending') {
      busy = false;
      refresh();
    }
  };
  skip.addEventListener('click', () => send({ skip: true, answers: [] }));
  submit.addEventListener('click', () => send({ skip: false, answers: states.map((s) => s.answer()) }));

  function refresh() {
    const live = connection.isLive;
    skip.disabled = busy || !live;
    submit.disabled = busy || !live || !states.every((s) => s.isAnswered());
    for (const s of states) s.setDisabled(busy);
  }

  const element = h('div', { class: 'question-card', role: 'group', 'aria-label': t('Needs your decision') },
    h('div', { class: 'questions' }, states.map((s) => s.element)),
    h('div', { class: 'buttons' }, skip, submit));
  return { element, refresh };
}

/// One question: radio buttons (or checkboxes for multiSelect), then Other with its text.
function buildQuestion(q, index, cardID, showHeader, onChange) {
  const name = `q-${cardID}-${index}`;
  const type = q.multiSelect ? 'checkbox' : 'radio';
  const optionInputs = q.options.map(() => h('input', { type, name }));
  const otherInput = h('input', { type, name });
  const otherText = h('textarea', { rows: '2', placeholder: t('Write your answer'), hidden: true });

  const syncOther = () => {
    otherText.hidden = !otherInput.checked;
    if (otherInput.checked && document.activeElement !== otherText) otherText.focus();
    onChange();
  };
  optionInputs.forEach((input) => input.addEventListener('change', syncOther));
  otherInput.addEventListener('change', syncOther);
  otherText.addEventListener('input', onChange);

  const rows = q.options.map((option, i) => h('label', { class: 'option' },
    optionInputs[i],
    h('span', { class: 'option-text' },
      h('span', { class: 'option-label' }, option.label),
      option.description ? h('span', { class: 'option-detail' }, option.description) : null)));

  const element = h('div', { class: 'q' },
    showHeader && q.header.trim() ? h('span', { class: 'q-header' }, q.header) : null,
    h('h2', {}, q.question),
    h('div', { class: 'options' },
      rows,
      h('label', { class: 'option' }, otherInput, h('span', { class: 'option-text' }, h('span', { class: 'option-label' }, t('Other')))),
      otherText));

  const selectedLabels = () => q.options.filter((_, i) => optionInputs[i].checked).map((o) => o.label);
  const filledOther = () => (otherInput.checked && otherText.value.trim() ? otherText.value : null);

  return {
    element,
    // The Mac's rule: an option or a non-blank Other; one of the two for a single choice.
    isAnswered: () => selectedLabels().length > 0 || filledOther() !== null,
    answer: () => ({ selectedLabels: selectedLabels(), otherText: filledOther() }),
    setDisabled: (disabled) => {
      [...optionInputs, otherInput].forEach((input) => { input.disabled = disabled; });
      otherText.disabled = disabled;
    },
  };
}
