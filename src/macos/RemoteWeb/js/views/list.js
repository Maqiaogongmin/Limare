import { h, clear, icon, relativeTime } from '../dom.js';
import { Composer } from './composer.js';

const GROUP_PREVIEW = 6; // conversations shown per project before "查看全部"
const NO_PROJECT = 'none';
const expandedGroups = new Set(); // which groups the reader opened, kept across redraws

export function runBadge(run) {
  if (!run) return null;
  const label = { running: '运行中', pausing: '正在暂停', paused: '已暂停' }[run] || run;
  return h('span', { class: `badge ${run}` }, h('span', { class: 'dot' }), label);
}

function row(c) {
  return h('button', { class: 'conv', onclick: () => { location.hash = `#/c/${c.id}`; } },
    h('span', { class: 'conv-title' }, c.title || '新对话'),
    c.hasPendingApproval ? h('span', { class: 'badge approval' }, '待批准') : null,
    runBadge(c.run),
    h('span', { class: 'conv-time' }, c.isPinned ? '置顶' : relativeTime(c.updatedAt)));
}

/// The conversation list, grouped by project as in the Mac sidebar, with a composer for new
/// conversations underneath. The `+` on a group starts the new conversation in that project.
export class ListView {
  constructor({ store, connection }) {
    this.store = store;
    this.composer = new Composer({ store, connection });
    this.groups = h('div', { class: 'groups' });
    this.list = h('div', { class: 'list' }, this.groups);
    this.element = h('section', { class: 'conversation' },
      h('header', { class: 'topbar' }, h('h1', {}, 'Limare')),
      this.list, this.composer.element);
    this.renderGroups();
  }

  renderGroups() {
    const scroll = this.list.scrollTop;
    clear(this.groups);
    if (!this.store.listLoaded) {
      this.groups.append(h('div', { class: 'empty' }, '正在载入对话…'));
      return;
    }
    const byProject = new Map(this.store.projects.map((p) => [p.id, []]));
    const loose = [];
    for (const c of this.store.sortedConversations()) {
      (c.projectID && byProject.has(c.projectID) ? byProject.get(c.projectID) : loose).push(c);
    }
    this.groups.append(h('div', { class: 'groups-title' }, '项目'));
    for (const project of this.store.projects) {
      this.groups.append(this.group(project.id, project.name, 'folder', byProject.get(project.id)));
    }
    this.groups.append(this.group(NO_PROJECT, '无项目', 'inbox', loose));
    this.list.scrollTop = scroll;
  }

  group(key, name, glyph, conversations) {
    const expanded = expandedGroups.has(key);
    const shown = expanded ? conversations : conversations.slice(0, GROUP_PREVIEW);
    const start = () => {
      this.composer.setProject(key === NO_PROJECT ? null : key);
      this.composer.focus();
    };
    return h('div', { class: 'group' },
      h('div', { class: 'group-head' },
        icon(glyph, 18),
        h('span', { class: 'group-name' }, name),
        h('button', { class: 'group-add', 'aria-label': `在「${name}」中新建对话`, onclick: start }, icon('plus', 18))),
      shown.length ? shown.map(row) : h('div', { class: 'group-empty' }, '还没有对话'),
      conversations.length > GROUP_PREVIEW
        ? h('button', {
          class: 'group-more',
          onclick: () => {
            if (expanded) expandedGroups.delete(key); else expandedGroups.add(key);
            this.renderGroups();
          },
        }, expanded ? '收起' : `查看全部 (${conversations.length})`)
        : null);
  }
}
