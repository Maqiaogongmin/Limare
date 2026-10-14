// What the page shows, rebuilt from server events. Disposable: a reconnect replaces all of it.
export class Store extends EventTarget {
  constructor() {
    super();
    this.conversations = new Map();
    this.approvals = [];
    this.openID = null;
    this.open = null; // { conversation, messages: [], hasEarlier, runState, settings, compactions }
    this.projects = []; // in the Mac sidebar's order
    this.models = { choices: [], defaultModel: null };
    this.commands = []; // what the composer offers after "/"
    this.connectionID = null; // names this connection to POST /attachments
    this.protocolVersion = null;
    this.listLoaded = false; // until the first hello, the list is unknown, not empty
  }

  emit(kind, detail) {
    this.dispatchEvent(new CustomEvent(kind, { detail }));
  }

  setOpen(id) {
    this.openID = id;
    this.open = null;
  }

  apply(event) {
    switch (event.type) {
      case 'hello':
        this.protocolVersion = event.protocolVersion;
        this.listLoaded = true;
        this.connectionID = event.connectionID;
        this.conversations = new Map(event.conversations.map((c) => [c.id, c]));
        this.projects = event.projects;
        this.models = event.models;
        this.approvals = event.approvals;
        this.commands = event.commands;
        this.emit('list');
        this.emit('catalog');
        this.emit('approvals');
        this.emit('hello');
        break;
      case 'conversations.changed':
        for (const summary of event.upserts) this.conversations.set(summary.id, summary);
        for (const id of event.removed) this.conversations.delete(id);
        this.emit('list');
        if (this.openID && event.removed.includes(this.openID)) this.emit('openRemoved');
        else if (this.openID && event.upserts.some((s) => s.id === this.openID)) this.emit('openSummary');
        break;
      case 'conversation.snapshot':
        if (event.conversation.id !== this.openID) return;
        this.open = {
          conversation: event.conversation, messages: event.messages, hasEarlier: event.hasEarlier,
          runState: event.runState, settings: event.settings, compactions: event.compactions,
        };
        this.emit('snapshot');
        break;
      case 'conversation.settings':
        if (!this.open || event.conversationID !== this.openID) return;
        this.open.settings = event.settings;
        this.emit('settings');
        break;
      case 'conversation.compactions':
        if (!this.open || event.conversationID !== this.openID) return;
        this.open.compactions = event.compactions;
        this.emit('compactions');
        break;
      case 'projects.changed':
        this.projects = event.projects;
        this.emit('list');
        this.emit('catalog');
        break;
      case 'models.changed':
        this.models = event.models;
        this.emit('catalog');
        break;
      case 'conversation.earlier':
        if (!this.open || event.conversationID !== this.openID) return;
        this.open.messages = [...event.messages, ...this.open.messages];
        this.open.hasEarlier = event.hasEarlier;
        this.emit('earlier', event.messages);
        break;
      case 'message.upsert': {
        if (!this.open || event.conversationID !== this.openID) return;
        const index = this.open.messages.findIndex((m) => m.id === event.message.id);
        if (index >= 0) this.open.messages[index] = event.message;
        else this.open.messages.push(event.message);
        this.emit('message', event.message);
        break;
      }
      case 'run.changed':
        if (!this.open || event.conversationID !== this.openID) return;
        this.open.runState = event.runState;
        this.emit('run');
        break;
      case 'approvals.changed':
        this.approvals = event.approvals;
        this.emit('approvals');
        break;
      default:
        break;
    }
  }

  summary(id) {
    return this.conversations.get(id) || (this.open && this.open.conversation.id === id ? this.open.conversation : null);
  }

  project(id) {
    return this.projects.find((p) => p.id === id) || null;
  }

  /// The model menu entry for `ref`, or null if the Mac no longer offers it.
  choice(ref) {
    return ref ? this.models.choices.find((c) => sameModel(c.model, ref)) || null : null;
  }

  sortedConversations() {
    return [...this.conversations.values()].sort((a, b) => {
      if (a.isPinned !== b.isPinned) return a.isPinned ? -1 : 1;
      return new Date(b.updatedAt) - new Date(a.updatedAt);
    });
  }
}

export function sameModel(a, b) {
  if (!a || !b || a.kind !== b.kind) return false;
  return a.kind === 'group' ? a.groupID === b.groupID : a.providerID === b.providerID && a.modelID === b.modelID;
}
