import { h, clear, icon, relativeTime } from '../dom.js';
import { Composer } from './composer.js';
import { t } from '../i18n.js';

const GROUP_PREVIEW = 6; // conversations shown per project before "Show All"
const NO_PROJECT = 'none';
const expandedGroups = new Set(); // which groups the reader opened, kept across redraws

export function runBadge(run) {
  if (!run) return null;
  const label = { running: t('Running'), pausing: t('Pausing…'), paused: t('Paused') }[run] || run;
  return h('span', { class: `badge ${run}` }, h('span', { class: 'dot' }), label);
}

function row(c) {
  return h('button', { class: 'conv', onclick: () => { location.hash = `#/c/${c.id}`; } },
    h('span', { class: 'conv-title' }, c.title || t('Untitled')),
    c.hasPendingApproval ? h('span', { class: 'badge approval' }, t('Needs approval')) : null,
    c.hasPendingQuestion ? h('span', { class: 'badge question' }, t('Needs an answer')) : null,
    runBadge(c.run),
    h('span', { class: 'conv-time' }, c.isPinned ? t('Pinned') : relativeTime(c.updatedAt)));
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
      this.groups.append(h('div', { class: 'empty' }, t('Loading conversations…')));
      return;
    }
    const byProject = new Map(this.store.projects.map((p) => [p.id, []]));
    const loose = [];
    for (const c of this.store.sortedConversations()) {
      (c.projectID && byProject.has(c.projectID) ? byProject.get(c.projectID) : loose).push(c);
    }
    this.groups.append(h('div', { class: 'groups-title' }, t('Projects')));
    for (const project of this.store.projects) {
      this.groups.append(this.group(project.id, project.name, 'folder', byProject.get(project.id)));
    }
    this.groups.append(this.group(NO_PROJECT, t('No Project'), 'inbox', loose));
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
        h('button', { class: 'group-add', 'aria-label': t('New Conversation in %@', name), onclick: start }, icon('plus', 18))),
      shown.length ? shown.map(row) : h('div', { class: 'group-empty' }, t('No conversations yet')),
      conversations.length > GROUP_PREVIEW
        ? h('button', {
          class: 'group-more',
          onclick: () => {
            if (expanded) expandedGroups.delete(key); else expandedGroups.add(key);
            this.renderGroups();
          },
        }, expanded ? t('Show Less') : t('Show All (%lld)', conversations.length))
        : null);
  }
}
