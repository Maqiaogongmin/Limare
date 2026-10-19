import { h } from '../dom.js';
import { fillMarkdown } from '../markdown.js';
import { fileCard, fileList } from './files.js';

const TOOL_STATE = {
  queued: '等待中', awaitingApproval: '等待批准', running: '运行中', completed: '完成',
  failed: '失败', timedOut: '超时', cancelled: '已取消', denied: '已拒绝', interrupted: '已中断',
};

const MESSAGE_STATE = { failed: '失败', interrupted: '已中断' };

/// A disclosure whose body is built the first time it is opened: most are never opened, and a
/// long conversation has hundreds of them.
export function disclosure(props, summary, openSet, key, buildBody) {
  const details = h('details', props, summary);
  let built = false;
  const build = () => {
    if (built) return;
    built = true;
    details.append(buildBody());
  };
  if (openSet.has(key)) {
    build();
    details.open = true;
  }
  details.addEventListener('toggle', () => {
    if (details.open) { build(); openSet.add(key); } else openSet.delete(key);
  });
  return details;
}

/// As the Mac's tool row shows it: nothing under a second, where the time says nothing to the
/// reader (`ToolCallDurationFormat`).
function duration(ms) {
  if (ms == null || ms < 1000) return null;
  if (ms < 60000) return `${(Math.floor(ms / 100) / 10).toFixed(1)}s`;
  const seconds = Math.floor(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}

/// A tool call, and under it, as on the Mac, the workspace file a file tool reads or writes. A
/// call that completed shows no state, as on the Mac; its summary is the Mac's.
function toolCall(tool, openTools) {
  const state = [tool.state === 'completed' ? null : TOOL_STATE[tool.state] || tool.state, duration(tool.durationMs)].filter(Boolean).join(' · ');
  const details = disclosure({ class: 'tool', dataset: { toolId: tool.id } },
    h('summary', {},
      h('span', { class: 'tool-name' }, tool.name),
      tool.summary ? h('span', { class: 'tool-summary' }, tool.summary) : null,
      state ? h('span', { class: `tool-state ${tool.state}` }, state) : null),
    openTools, tool.id,
    () => h('div', { class: 'tool-body' },
      tool.input ? [h('h4', {}, '输入'), h('pre', {}, tool.input), tool.inputTruncated ? h('div', { class: 'truncated' }, '已截断，完整内容在 Mac 上查看') : null] : null,
      tool.output ? [h('h4', {}, '输出'), h('pre', {}, tool.output), tool.outputTruncated ? h('div', { class: 'truncated' }, '已截断，完整内容在 Mac 上查看') : null] : null,
      tool.errorMessage && tool.errorMessage !== tool.output ? [h('h4', {}, '错误'), h('pre', {}, tool.errorMessage)] : null));
  return tool.file ? [details, fileCard(tool.file)] : details;
}

/// One message as an element. Re-rendered whole on every upsert; `ui` keeps which disclosure
/// sections the user opened so a re-render does not collapse them. `hidesReasoning`: a folded
/// turn's answer, whose reasoning is in the turn's history. `files`: the delivered files shown
/// under the message, its own unless a folded turn gathers them on its answer.
export function renderMessage(message, ui, { hidesReasoning = false, files = message.files } = {}) {
  if (message.role === 'user') {
    return h('article', { class: `msg msg-user${message.isSystemNotice ? ' msg-notice' : ''} state-${message.state}`, dataset: { id: message.id } },
      h('div', { class: 'bubble' }, message.content),
      fileList(message.attachments, { thumbnails: true }),
      MESSAGE_STATE[message.state] ? h('div', { class: 'msg-meta' }, MESSAGE_STATE[message.state]) : null);
  }

  const streaming = message.state === 'streaming';
  const article = h('article', { class: `msg msg-assistant state-${message.state}`, dataset: { id: message.id } });
  if (message.reasoning && !hidesReasoning) {
    article.append(disclosure({ class: 'reasoning' },
      h('summary', {}, streaming && !message.content ? '思考中…' : '思考过程'),
      ui.openReasoning, message.id,
      () => h('div', { class: 'reasoning-text' }, message.reasoning)));
  }
  if (message.content) {
    const body = h('div', { class: 'markdown' });
    fillMarkdown(body, message.content);
    article.append(body);
  }
  if (message.toolCalls.length) {
    article.append(h('div', { class: 'tools' }, message.toolCalls.flatMap((t) => toolCall(t, ui.openTools))));
  }
  if (streaming && !message.content && !message.toolCalls.length) {
    article.append(h('div', { class: 'typing' }, h('span'), h('span'), h('span')));
  }
  const shown = fileList([...message.attachments, ...files]);
  if (shown) article.append(shown);
  const meta = [MESSAGE_STATE[message.state], message.model].filter(Boolean).join(' · ');
  if (meta && !streaming) article.append(h('div', { class: 'msg-meta' }, meta));
  return article;
}
