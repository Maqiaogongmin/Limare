// The one WebSocket to Limare. It never stores Limare state: after every (re)connect the server
// sends `hello`, and the page asks again for whatever it shows.
const BACKOFF_SECONDS = [1, 2, 4, 8, 15];
const REQUEST_TIMEOUT_MS = 15000;
// The server greets every connection at once; a socket that opens but stays silent is dead.
const HELLO_TIMEOUT_MS = 15000;

export class Connection extends EventTarget {
  constructor() {
    super();
    this.status = 'connecting'; // connecting | live (greeted) | reconnecting | offline | signin | unreachable | outdated
    this.halted = false; // set for good once the server speaks another protocol version
    this.socket = null;
    this.attempt = 0;
    this.pending = new Map();
    this.retryTimer = null;
    window.addEventListener('online', () => this.reconnectNow());
    window.addEventListener('offline', () => this.setStatus('offline'));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.status !== 'live' && this.status !== 'signin') this.reconnectNow();
    });
  }

  start() {
    this.connect();
  }

  get isLive() {
    return this.status === 'live';
  }

  setStatus(status) {
    if (this.status === status || (this.halted && status !== 'outdated')) return;
    this.status = status;
    this.dispatchEvent(new CustomEvent('status', { detail: status }));
  }

  connect() {
    clearTimeout(this.retryTimer);
    if (this.socket || this.halted) return;
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    const socket = new WebSocket(`${scheme}://${location.host}/ws`);
    this.socket = socket;
    const helloTimer = setTimeout(() => socket.close(), HELLO_TIMEOUT_MS);
    socket.onmessage = (message) => {
      if (this.socket !== socket) return;
      if (this.status !== 'live') {
        clearTimeout(helloTimer);
        this.attempt = 0;
        this.setStatus('live');
      }
      let event;
      try { event = JSON.parse(message.data); } catch { return; }
      if (event.type === 'command.result') {
        const waiter = this.pending.get(event.requestID);
        if (waiter) {
          this.pending.delete(event.requestID);
          clearTimeout(waiter.timer);
          waiter.resolve(event);
        }
        return;
      }
      this.dispatchEvent(new CustomEvent('event', { detail: event }));
    };
    socket.onclose = () => {
      clearTimeout(helloTimer);
      if (this.socket !== socket) return;
      this.socket = null;
      for (const [, waiter] of this.pending) {
        clearTimeout(waiter.timer);
        waiter.resolve({ ok: false, error: 'disconnected' });
      }
      this.pending.clear();
      this.diagnoseAndRetry();
    };
  }

  /// Why the socket is gone decides what to show: an expired Access session needs the user,
  /// everything else is retried.
  async diagnoseAndRetry() {
    if (!navigator.onLine) {
      this.setStatus('offline');
      return;
    }
    try {
      const response = await fetch('/healthz', { redirect: 'manual', cache: 'no-store', credentials: 'same-origin' });
      if (response.type === 'opaqueredirect' || response.status === 401 || response.status === 403) {
        this.setStatus('signin');
        return;
      }
      this.setStatus(response.ok ? 'reconnecting' : 'unreachable');
    } catch {
      this.setStatus(navigator.onLine ? 'unreachable' : 'offline');
    }
    const delay = BACKOFF_SECONDS[Math.min(this.attempt, BACKOFF_SECONDS.length - 1)];
    this.attempt += 1;
    this.retryTimer = setTimeout(() => this.connect(), delay * 1000);
  }

  reconnectNow() {
    if (this.socket || this.halted || this.status === 'signin') return;
    this.attempt = 0;
    this.connect();
  }

  /// The server speaks another protocol version (Limare was updated, or this tab is newer):
  /// close for good and send nothing more; only reloading the page talks to it again.
  halt() {
    this.halted = true;
    clearTimeout(this.retryTimer);
    const socket = this.socket;
    this.socket = null;
    socket?.close();
    for (const [, waiter] of this.pending) {
      clearTimeout(waiter.timer);
      waiter.resolve({ ok: false, error: 'outdated' });
    }
    this.pending.clear();
    this.setStatus('outdated');
  }

  /// Sends one command; resolves with its `command.result` (never rejects).
  request(type, fields = {}) {
    if (this.halted || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.resolve({ ok: false, error: 'disconnected' });
    }
    const requestID = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestID);
        resolve({ ok: false, error: 'timeout' });
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(requestID, { resolve, timer });
      this.socket.send(JSON.stringify({ type, requestID, ...fields }));
    });
  }
}
