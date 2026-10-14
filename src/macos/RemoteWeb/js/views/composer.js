import { h, clear, icon, formatBytes } from '../dom.js';
import { openPicker, refreshPicker } from '../picker.js';
import { sameModel } from '../store.js';
import { uploadFile } from '../upload.js';

const ERRORS = {
  disconnected: '未连接到 Limare，消息可能没有发送。重连后请查看对话记录。',
  outdated: 'Limare 已更新，请刷新页面后再发送。',
  timeout: 'Limare 没有及时回应，消息可能已发送。请查看对话记录。',
  conversationNotFound: '找不到这个对话。',
  attachmentNotFound: '附件已失效，请重新添加。',
  modelNotAvailable: '这个模型已不可用。',
  levelNotAvailable: '这个模型不支持该思考等级。',
  runActive: '运行中不能切换模型或思考等级。',
};

/// The commands the draft is typing, as the Mac composer finds them (`ComposerCommand.matches`):
/// a "/" then part of a name and nothing else. Names starting with it first, then containing it.
function matchCommands(commands, draft) {
  if (!draft.startsWith('/')) return [];
  const query = draft.slice(1).toLowerCase();
  if (/[\s/]/.test(query)) return [];
  if (!query) return commands;
  const starts = (c) => c.name.toLowerCase().startsWith(query);
  return [...commands.filter(starts), ...commands.filter((c) => !starts(c) && c.name.toLowerCase().includes(query))];
}

// The Mac's limits (AttachmentStore and the composer); the server checks them again.
const MAX_ATTACHMENTS = 8;
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_FILE_BYTES = 50 * 1024 * 1024;

/// The message box. With no conversation it starts a new one and lets the reader choose its
/// project, model and thinking level first; in a conversation, model and thinking are the
/// conversation's own (changed on the Mac's owner right away) and the buttons follow its run.
/// It keeps only what is being written: text, uploads in flight and the new conversation's choices.
export class Composer {
  constructor({ store, connection, conversationID = null, isActive = () => false }) {
    this.store = store;
    this.connection = connection;
    this.conversationID = conversationID;
    this.isActive = isActive;
    this.attachments = []; // { key, name, size, progress, status: uploading|ready|failed, id, message, connectionID }
    this.sending = false;
    // New conversation only. `model` null = Limare's default; `thinking` undefined = the model's default.
    this.projectID = null;
    this.model = null;
    this.thinking = undefined;
    // The "/" menu: the highlighted row, and the draft it was closed on (Escape) until the draft changes.
    this.commandSelection = 0;
    this.commandDismissedDraft = null;

    this.menu = h('div', { class: 'command-menu', role: 'listbox', 'aria-label': '命令', hidden: true });
    this.strip = h('div', { class: 'attachment-strip', hidden: true });
    this.input = h('textarea', { rows: '1', placeholder: conversationID ? '给 Limare 发消息' : '新对话：输入第一条消息', enterkeyhint: 'send', 'aria-label': '消息' });
    this.input.addEventListener('input', () => {
      this.commandSelection = 0;
      if (this.input.value !== this.commandDismissedDraft) this.commandDismissedDraft = null;
      this.autosize();
      this.renderSend();
      this.renderMenu();
    });
    this.input.addEventListener('keydown', (e) => this.handleMenuKey(e));
    this.fileInput = h('input', { type: 'file', multiple: true, hidden: true });
    this.fileInput.addEventListener('change', () => {
      this.addFiles([...this.fileInput.files]);
      this.fileInput.value = '';
    });
    this.tools = h('div', { class: 'composer-tools' });
    this.send = h('div', { class: 'composer-send' });
    this.error = h('div', { class: 'error', hidden: true });
    this.element = h('form', { class: 'composer', onsubmit: (e) => e.preventDefault() },
      this.menu,
      h('div', { class: 'composer-box' }, this.strip, this.input, h('div', { class: 'composer-row' }, this.tools, this.send)),
      this.error, this.fileInput);
    this.render();
  }

  // State ----------------------------------------------------------------------

  get uploading() {
    return this.attachments.some((a) => a.status === 'uploading');
  }

  readyAttachmentIDs() {
    return this.attachments.filter((a) => a.status === 'ready').map((a) => a.id);
  }

  /// The model shown for a new conversation: the chosen one, else Limare's default.
  newModelChoice() {
    return this.store.choice(this.model || this.store.models.defaultModel);
  }

  /// The thinking menu that applies now, with the reader's choice marked.
  thinkingMenu() {
    if (this.conversationID) return this.store.open?.settings?.thinking || null;
    const menu = this.newModelChoice()?.thinking;
    if (!menu || this.thinking === undefined) return menu || null;
    const options = menu.options.map((o) => ({ ...o, isSelected: o.level === this.thinking }));
    return { label: options.find((o) => o.isSelected)?.label || menu.label, options };
  }

  modelLabel() {
    const thinking = this.thinkingMenu();
    const model = this.conversationID ? this.store.open?.settings?.modelLabel : this.newModelChoice()?.label;
    return [model || '选择模型', thinking ? thinking.label : null].filter(Boolean).join(' · ');
  }

  setProject(projectID) {
    this.projectID = projectID;
    this.render();
  }

  focus() {
    this.input.focus();
  }

  // Rendering ------------------------------------------------------------------

  render() {
    this.renderStrip();
    this.renderTools();
    this.renderSend();
    this.renderMenu();
  }

  /// Commands take no attachments, so the menu stays closed while files are attached (as on the Mac).
  commandMatches() {
    if (this.attachments.length || this.input.value === this.commandDismissedDraft) return [];
    return matchCommands(this.store.commands, this.input.value);
  }

  /// Opens above the composer, over the transcript. A tap runs a command; on a keyboard,
  /// Up/Down move, Return runs, Tab completes, Escape closes.
  renderMenu() {
    const matches = this.commandMatches();
    clear(this.menu);
    this.menu.hidden = matches.length === 0;
    const selection = Math.min(this.commandSelection, matches.length - 1);
    matches.forEach((command, index) => {
      this.menu.append(h('button', {
        type: 'button', class: `command${index === selection ? ' selected' : ''}`, role: 'option', 'aria-selected': String(index === selection),
        // Keeps the focus, and the phone's keyboard, in the message box.
        onpointerdown: (e) => e.preventDefault(),
        onclick: () => this.runCommand(command),
      }, h('span', { class: 'command-name' }, `/${command.name}`), h('span', { class: 'command-summary' }, command.summary)));
    });
  }

  handleMenuKey(e) {
    const matches = this.commandMatches();
    if (!matches.length || e.isComposing) return;
    const index = Math.min(this.commandSelection, matches.length - 1);
    switch (e.key) {
      case 'ArrowDown': this.commandSelection = (index + 1) % matches.length; break;
      case 'ArrowUp': this.commandSelection = (index - 1 + matches.length) % matches.length; break;
      case 'Tab': this.input.value = `/${matches[index].name}`; this.renderSend(); break;
      case 'Enter':
        if (e.shiftKey) return;
        this.runCommand(matches[index]);
        break;
      case 'Escape': this.commandDismissedDraft = this.input.value; break;
      default: return;
    }
    e.preventDefault();
    this.renderMenu();
  }

  /// A command is its invocation sent as the input; Limare runs it instead of adding a message.
  runCommand(command) {
    this.input.value = `/${command.name}`;
    this.submit('send');
  }

  autosize() {
    this.input.style.height = 'auto';
    this.input.style.height = `${Math.min(this.input.scrollHeight, window.innerHeight * 0.4)}px`;
  }

  renderStrip() {
    clear(this.strip);
    this.strip.hidden = this.attachments.length === 0;
    for (const attachment of this.attachments) {
      const state = attachment.status === 'uploading' ? `${Math.round(attachment.progress * 100)}%`
        : attachment.status === 'failed' ? attachment.message : formatBytes(attachment.size);
      this.strip.append(h('div', { class: `attachment ${attachment.status}` },
        icon('file', 16),
        h('span', { class: 'attachment-name' }, attachment.name),
        h('span', { class: 'attachment-state' }, state),
        h('button', { type: 'button', class: 'attachment-remove', 'aria-label': `移除 ${attachment.name}`, onclick: () => this.removeAttachment(attachment) }, icon('close', 14))));
    }
  }

  renderTools() {
    clear(this.tools);
    const live = this.connection.isLive;
    this.tools.append(h('button', {
      type: 'button', class: 'tool-button', 'aria-label': '添加附件',
      disabled: !live || this.attachments.length >= MAX_ATTACHMENTS,
      onclick: () => this.fileInput.click(),
    }, icon('plus', 20)));
    if (!this.conversationID) {
      const project = this.projectID ? this.store.project(this.projectID) : null;
      this.tools.append(h('button', {
        type: 'button', class: 'chip-button', disabled: !live, onclick: () => this.pickProject(),
      }, icon(project ? 'folder' : 'inbox', 15), h('span', {}, project ? project.name : '无项目'), icon('chevron', 14)));
    }
    const locked = this.conversationID && this.isActive();
    this.tools.append(h('button', {
      type: 'button', class: 'chip-button model', disabled: !live || locked,
      title: locked ? '运行中不能切换模型' : '', onclick: () => this.pickModel(),
    }, h('span', {}, this.modelLabel()), icon('chevron', 14)));
  }

  renderSend() {
    clear(this.send);
    const live = this.connection.isLive;
    const hasContent = this.input.value.trim() !== '' || this.readyAttachmentIDs().length > 0;
    const disabled = !live || this.sending || this.uploading || !hasContent;
    if (this.conversationID && this.isActive()) {
      this.send.append(
        h('button', { type: 'button', class: 'small', disabled, onclick: () => this.submit('steer') }, '插入'),
        h('button', { type: 'button', class: 'small primary', disabled, onclick: () => this.submit('queue') }, '排队'));
    } else {
      this.send.append(h('button', { type: 'button', class: 'send-button primary', 'aria-label': '发送', disabled, onclick: () => this.submit('send') }, icon('up', 20)));
    }
  }

  showError(code) {
    this.error.hidden = !code;
    this.error.textContent = code ? (ERRORS[code] || code) : '';
  }

  // Store events ---------------------------------------------------------------

  /// A new connection: uploads made on the old one were discarded by Limare with it.
  onHello() {
    const lost = this.attachments.filter((a) => a.connectionID && a.connectionID !== this.store.connectionID);
    if (lost.length) {
      this.attachments = this.attachments.filter((a) => !lost.includes(a));
      this.showError('连接已重新建立，之前上传的附件已失效，请重新添加。');
    }
    this.render();
  }

  // Choices --------------------------------------------------------------------

  pickProject() {
    openPicker({
      title: '项目',
      build: () => [{
        title: '新对话放在',
        items: [
          { label: '无项目', selected: this.projectID === null, onSelect: () => { this.setProject(null); return true; } },
          ...this.store.projects.map((p) => ({
            label: p.name, detail: p.isPinned ? '置顶' : '', selected: this.projectID === p.id,
            onSelect: () => { this.setProject(p.id); return true; },
          })),
        ],
      }],
    });
  }

  pickModel() {
    openPicker({
      title: '模型与思考',
      build: () => {
        const current = this.conversationID ? this.store.open?.settings?.model : (this.model || this.store.models.defaultModel);
        const bySection = new Map();
        for (const choice of this.store.models.choices) {
          if (!bySection.has(choice.section)) bySection.set(choice.section, []);
          bySection.get(choice.section).push(choice);
        }
        const sections = [...bySection].map(([title, choices]) => ({
          title,
          items: choices.map((choice) => ({
            label: choice.label,
            selected: sameModel(choice.model, current),
            onSelect: () => this.chooseModel(choice.model),
          })),
        }));
        const thinking = this.thinkingMenu();
        if (thinking) {
          sections.unshift({
            title: '思考等级',
            items: thinking.options.map((option) => ({
              label: option.label, selected: option.isSelected, onSelect: () => this.chooseThinking(option.level),
            })),
          });
        }
        return sections;
      },
    });
  }

  async chooseModel(model) {
    if (!this.conversationID) {
      this.model = model;
      this.thinking = undefined;
      this.render();
      return false;
    }
    const result = await this.connection.request('conversation.setModel', { conversationID: this.conversationID, model });
    this.showError(result.ok ? null : result.error);
    return !result.ok;
  }

  async chooseThinking(level) {
    if (!this.conversationID) {
      this.thinking = level;
      this.render();
      return false;
    }
    const result = await this.connection.request('conversation.setThinking', { conversationID: this.conversationID, level });
    this.showError(result.ok ? null : result.error);
    return !result.ok;
  }

  /// Called when the conversation's settings arrive, so the button and an open sheet follow.
  onSettings() {
    this.renderTools();
    refreshPicker();
  }

  // Attachments ----------------------------------------------------------------

  addFiles(files) {
    this.showError(null);
    for (const file of files) {
      if (this.attachments.length >= MAX_ATTACHMENTS) {
        this.showError(`最多 ${MAX_ATTACHMENTS} 个附件。`);
        break;
      }
      const limit = (file.type || '').startsWith('image/') ? MAX_IMAGE_BYTES : MAX_FILE_BYTES;
      const attachment = { key: crypto.randomUUID(), name: file.name || '附件', size: file.size, progress: 0, status: 'uploading', id: null, message: '', connectionID: this.store.connectionID };
      this.attachments.push(attachment);
      if (file.size > limit) {
        attachment.status = 'failed';
        attachment.message = `超过 ${limit / 1024 / 1024} MB`;
        continue;
      }
      uploadFile(file, this.store.connectionID, (progress) => {
        attachment.progress = progress;
        this.renderStrip();
      }).then((result) => {
        if (!this.attachments.includes(attachment)) {
          // Removed while uploading: let Limare drop it too.
          if (result.ok) this.connection.request('attachment.discard', { attachmentID: result.attachment.id });
          return;
        }
        if (result.ok) {
          attachment.status = 'ready';
          attachment.id = result.attachment.id;
          attachment.name = result.attachment.filename;
          attachment.size = result.attachment.byteCount;
        } else {
          attachment.status = 'failed';
          attachment.message = result.message;
        }
        this.render();
      });
    }
    this.render();
  }

  removeAttachment(attachment) {
    this.attachments = this.attachments.filter((a) => a !== attachment);
    if (attachment.status === 'ready') this.connection.request('attachment.discard', { attachmentID: attachment.id });
    this.render();
  }

  // Sending --------------------------------------------------------------------

  async submit(mode) {
    const text = this.input.value.trim();
    const attachmentIDs = this.readyAttachmentIDs();
    if ((!text && !attachmentIDs.length) || this.sending || this.uploading) return;
    this.sending = true;
    this.showError(null);
    this.renderSend();
    const fields = { text, mode, attachmentIDs };
    if (this.conversationID) {
      fields.conversationID = this.conversationID;
    } else {
      if (this.projectID) fields.projectID = this.projectID;
      if (this.model) fields.model = this.model;
      if (this.thinking !== undefined && this.thinking !== null) fields.thinking = this.thinking;
    }
    const result = await this.connection.request('input.submit', fields);
    this.sending = false;
    if (result.ok) {
      this.input.value = '';
      this.attachments = this.attachments.filter((a) => a.status !== 'ready');
      this.autosize();
      if (!this.conversationID && result.conversationID) {
        this.model = null;
        this.thinking = undefined;
        location.hash = `#/c/${result.conversationID}`;
        return;
      }
    } else {
      this.showError(result.error);
    }
    this.render();
  }
}
