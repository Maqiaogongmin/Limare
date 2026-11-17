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
    h('span', { class: `conv-title${c.isUnread ? ' unread' : ''}` }, c.title || t('Untitled')),
    c.isUnread ? h('span', { class: 'unread-dot', 'aria-label': t('Unread'), title: t('Unread') }) : null,
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
    this.connection = connection;
    this.archiveMode = false;
    this.queries = { active: '', archive: '' };
    this.archiveError = null;
    this.restoring = new Set();
    this.composer = new Composer({ store, connection });
    this.search = h('input', { type: 'search', placeholder: t('Search'), 'aria-label': t('Search'), autocomplete: 'off' });
    this.search.addEventListener('input', () => { this.queries[this.archiveMode ? 'archive' : 'active'] = this.search.value; this.renderGroups(); });
    this.heading = h('h1', {}, 'Limare');
    this.modeButton = h('button', { class: 'list-mode-button', onclick: () => { location.hash = this.archiveMode ? '#/' : '#/archive'; } });
    this.groups = h('div', { class: 'groups' });
    this.list = h('div', { class: 'list' }, this.groups);
    this.element = h('section', { class: 'conversation' },
      h('header', { class: 'topbar' }, this.heading, this.modeButton),
      h('div', { class: 'list-search' }, icon('search', 18), this.search),
      this.list, this.composer.element);
    this.setMode(false);
  }

  setMode(archiveMode) {
    this.archiveMode = archiveMode;
    this.heading.textContent = archiveMode ? t('Archived Conversations') : 'Limare';
    this.modeButton.textContent = archiveMode ? t('Back') : t('Archived');
    this.search.value = this.queries[archiveMode ? 'archive' : 'active'];
    this.composer.element.hidden = archiveMode;
    this.renderGroups();
    if (archiveMode && this.connection.isLive && !this.store.archivedLoaded) this.loadArchive();
  }

  async loadArchive() {
    this.archiveError = null;
    const result = await this.connection.request('archive.list');
    if (!result.ok) this.archiveError = result.error;
    if (this.archiveMode) this.renderGroups();
  }

  onHello() {
    if (this.archiveMode) this.loadArchive();
  }

  async restore(id) {
    if (this.restoring.has(id)) return;
    this.restoring.add(id);
    this.renderGroups();
    const result = await this.connection.request('archive.restore', { conversationID: id });
    this.restoring.delete(id);
    if (result.ok) location.hash = `#/c/${id}`;
    else { this.archiveError = result.error; this.renderGroups(); }
  }

  renderGroups() {
    const scroll = this.list.scrollTop;
    clear(this.groups);
    if (!this.store.listLoaded) {
      this.groups.append(h('div', { class: 'empty' }, t('Loading conversations…')));
      return;
    }
    if (this.archiveMode) {
      if (this.archiveError) {
        this.groups.append(h('div', { class: 'empty' }, t('Could not load archived conversations.'),
          h('button', { class: 'small', onclick: () => this.loadArchive() }, t('Retry'))));
      } else if (!this.store.archivedLoaded) {
        this.groups.append(h('div', { class: 'empty' }, t('Loading…')));
      } else {
        const query = this.search.value.trim().toLocaleLowerCase();
        const matching = this.store.archived.filter((c) => (c.title || t('Untitled')).toLocaleLowerCase().includes(query) || (c.projectName || '').toLocaleLowerCase().includes(query));
        if (!matching.length) {
          this.groups.append(h('div', { class: 'empty' }, query ? t('No results for "%@"', this.search.value.trim()) : t('No Archived Conversations')));
        }
        for (const c of matching) {
          this.groups.append(h('div', { class: 'archived-row' },
            h('div', { class: 'archived-info' }, h('div', { class: 'archived-title' }, c.title || t('Untitled')),
              h('div', { class: 'archived-detail' }, [c.projectName || t('No Project'), relativeTime(c.archivedAt)].join(' · '))),
            h('button', { class: 'small', disabled: this.restoring.has(c.id) || !this.connection.isLive, onclick: () => this.restore(c.id) }, t('Restore'))));
        }
      }
      this.list.scrollTop = scroll;
      return;
    }
    const query = this.search.value.trim().toLocaleLowerCase();
    if (query) {
      const matchingProjects = this.store.projects.filter((p) => p.name.toLocaleLowerCase().includes(query));
      const matchingConversations = this.store.sortedConversations().filter((c) => (c.title || t('Untitled')).toLocaleLowerCase().includes(query));
      if (!matchingProjects.length && !matchingConversations.length) {
        this.groups.append(h('div', { class: 'empty' }, t('No results for "%@"', this.search.value.trim())));
      }
      if (matchingProjects.length) {
        this.groups.append(h('div', { class: 'groups-title' }, t('Projects')));
        for (const project of matchingProjects) {
          this.groups.append(this.group(project.id, project.name, 'folder', this.store.sortedConversations().filter((c) => c.projectID === project.id)));
        }
      }
      if (matchingConversations.length) {
        this.groups.append(h('div', { class: 'groups-title' }, t('Conversations')));
        this.groups.append(...matchingConversations.map(row));
      }
      this.list.scrollTop = 0;
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
