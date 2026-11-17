// Parse the same newline-delimited JSON patches as the Mac. Path writes mirror
// json-render and include budgets because an untrusted stream can expand by copying
// a subtree many times. An invalid or oversized patch is dropped, as on the Mac.
const MAX_DEPTH = 100;
const MAX_NODES = 50_000;
const MAX_BYTES = 4_000_000;
const MAX_WORK = 200_000;
const encoder = new TextEncoder();
const utf8 = (value) => encoder.encode(value).length;

// Counts repeated subtrees every time they appear. A cycle is never a JSON value.
export function measure(value, work = { count: 0 }) {
  const seen = new Set();
  let nodes = 0, bytes = 0, maxDepth = 0;
  const visit = (item, depth) => {
    if (++work.count > MAX_WORK || ++nodes > MAX_NODES || depth > MAX_DEPTH) throw new Error('limit');
    maxDepth = Math.max(maxDepth, depth);
    if (item === null) bytes += 4;
    else if (typeof item === 'string') bytes += utf8(item);
    else if (typeof item === 'number') bytes += 8;
    else if (typeof item === 'boolean') bytes += item ? 4 : 5;
    else if (typeof item === 'object') {
      if (seen.has(item)) throw new Error('cycle');
      seen.add(item);
      bytes += 2;
      for (const [key, child] of Object.entries(item)) {
        if (!Array.isArray(item)) bytes += utf8(key) + 3;
        if (bytes > MAX_BYTES) throw new Error('limit');
        visit(child, depth + 1);
      }
      seen.delete(item);
    } else throw new Error('invalid');
    if (bytes > MAX_BYTES) throw new Error('limit');
  };
  visit(value, 1);
  return { nodes, bytes, depth: maxDepth };
}

const clone = (value) => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
export function allowedPath(path) {
  if (typeof path !== 'string' || !path.startsWith('/')) return false;
  let depth = 0;
  for (let i = 0; i < path.length; i++) if (path[i] === '/' && ++depth > MAX_DEPTH) return false;
  return !path.split('/').some((part) => part.replace(/~1/g, '/').replace(/~0/g, '~') === '__proto__');
}
const segments = (path) => path.slice(1).split('/').map((s) => s.replace(/~1/g, '/').replace(/~0/g, '~'));
const indexFor = (array, token) => /^\d+$/.test(token) && Number(token) <= array.length ? Number(token) : null;
const container = (v) => v !== null && typeof v === 'object';

function read(root, path) {
  let value = root;
  for (const part of path) {
    if (!container(value)) return undefined;
    const key = Array.isArray(value) ? indexFor(value, part) : part;
    if (key === null || !Object.hasOwn(value, key)) return undefined;
    value = value[key];
  }
  return value;
}

// Like json-render's writers, but treats null as a missing container. All paths are
// checked before use; arrays remain dense and `add` inserts rather than replacing.
function write(root, path, value, add) {
  let current = root;
  for (let i = 0; i < path.length; i++) {
    const part = path[i], last = i === path.length - 1, next = path[i + 1];
    const index = Array.isArray(current) ? indexFor(current, part) : null;
    if (Array.isArray(current) && part !== '-' && index === null) return false;
    if (last) {
      if (Array.isArray(current)) {
        if (part === '-') current.push(value);
        else if (add) current.splice(index, 0, value);
        else current[index] = value;
      } else current[part] = value;
      return true;
    }
    if (Array.isArray(current) && part === '-') return false;
    const key = Array.isArray(current) ? index : part;
    if (!Object.hasOwn(current, key) || !container(current[key])) current[key] = /^\d+$/.test(next) || next === '-' ? [] : {};
    current = current[key];
  }
  return false;
}

// A patch can create all of its intermediate containers, not just its leaf.
// Charge those too, so many deeply nested paths cannot evade the node budget.
function newContainers(root, path) {
  let current = root, nodes = 0, bytes = 0;
  for (let i = 0; i < path.length - 1; i++) {
    const part = path[i];
    const key = Array.isArray(current) ? indexFor(current, part) : part;
    if (Array.isArray(current) && (part === '-' || key === null)) break;
    const child = container(current) && Object.hasOwn(current, key) ? current[key] : undefined;
    if (!container(child)) { nodes++; bytes += utf8(part) + 5; current = null; }
    else current = child;
  }
  return { nodes, bytes };
}

function remove(root, path) {
  const parent = read(root, path.slice(0, -1)), key = path[path.length - 1];
  if (!container(parent)) return;
  if (Array.isArray(parent)) {
    const index = indexFor(parent, key);
    if (index !== null && index < parent.length) parent.splice(index, 1);
  } else delete parent[key];
}

export function setStatePath(root, path, value) {
  if (!allowedPath(path)) return false;
  const parts = segments(path);
  if (parts.length > MAX_DEPTH) return false;
  return write(root, parts, value, false);
}

export class SpecStream {
  constructor() { this.reset(); }

  reset() {
    this.result = {};
    this.work = { count: 0 };
    this.nodes = 1;
    this.bytes = 2;
    this.inputBytes = 0;
    this.input = '';
    this.pending = '';
    this.finalized = false;
    this.oversized = false;
  }

  update(input, finalized) {
    if (!input.startsWith(this.input) || (this.finalized && input !== this.input)) this.reset();
    if (this.finalized && input === this.input) return this.result;
    const suffix = input.slice(this.input.length);
    this.input = input;
    this.inputBytes += utf8(suffix);
    if (this.inputBytes > MAX_BYTES) this.oversized = true;
    if (this.oversized) return { root: '', elements: {} };
    const lines = (this.pending + suffix).split('\n');
    this.pending = lines.pop();
    if (finalized && this.pending) { lines.push(this.pending); this.pending = ''; }
    for (const line of lines) {
      if (this.work.count > MAX_WORK) break;
      this.applyLine(line);
    }
    this.finalized = finalized;
    return this.result;
  }

  applyLine(line) {
    if (!line.trim()) return;
    let patch;
    try { patch = JSON.parse(line); } catch { return; }
    if (!patch || !allowedPath(patch.path) || !['add', 'replace', 'remove', 'move', 'copy', 'test'].includes(patch.op)) return;
    if ((patch.op === 'copy' || patch.op === 'move') && !allowedPath(patch.from)) return;
    const path = segments(patch.path), from = patch.from ? segments(patch.from) : null;
    if (path.length > MAX_DEPTH || (from && from.length > MAX_DEPTH)) return;
    try {
      const existing = read(this.result, path);
      if (patch.op === 'test') {
        if (existing !== undefined) measure(existing, this.work);
        if (patch.value !== undefined) measure(patch.value, this.work);
        return; // a failed test is dropped; successful tests leave no changes
      }
      if (patch.op === 'remove') {
        if (existing !== undefined) { const old = measure(existing, this.work); this.nodes = Math.max(0, this.nodes - old.nodes); this.bytes = Math.max(0, this.bytes - old.bytes); }
        remove(this.result, path);
        return;
      }
      const source = from ? (patch.from === '/' ? this.result : read(this.result, from)) : undefined;
      const value = from ? source ?? null : patch.value ?? null;
      const added = measure(value, this.work);
      const parent = read(this.result, path.slice(0, -1));
      // A move may remove a destination ancestor, so charge its whole path conservatively.
      const extra = patch.op === 'move' ? { nodes: path.length, bytes: utf8(patch.path) + 5 * path.length } : newContainers(this.result, path);
      // add inserts in arrays; move conservatively does not credit its destination.
      const removedValue = patch.op === 'move' ? read(this.result, from) : (patch.op !== 'add' || !Array.isArray(parent)) ? existing : undefined;
      const removed = removedValue === undefined ? { nodes: 0, bytes: 0 } : measure(removedValue, this.work);
      if (path.length + added.depth > MAX_DEPTH || this.nodes - removed.nodes + added.nodes + extra.nodes > MAX_NODES || this.bytes - removed.bytes + added.bytes + extra.bytes > MAX_BYTES) return;
      const written = clone(value);
      if (patch.op === 'move') remove(this.result, from);
      write(this.result, path, written, patch.op !== 'replace');
      this.nodes = Math.max(0, this.nodes - removed.nodes + added.nodes + extra.nodes);
      this.bytes = Math.max(0, this.bytes - removed.bytes + added.bytes + extra.bytes);
    } catch { /* A bad test or an over-budget write has no effect. */ }
  }
}

export function compileSpec(input, finalized) { return new SpecStream().update(input, finalized); }

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
function equal(a, b) {
  if (Object.is(a, b)) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && equal(a[key], b[key]));
}
const pointer = (parts) => '/' + parts.map((s) => s.replace(/~/g, '~0').replace(/\//g, '~1')).join('/');

// Match the desktop renderer's state transition: unchanged initial values retain local
// edits; only paths that change in a later streamed spec are applied to the live state.
export function mergeInitialState(previous, next, current) {
  const changes = [], removals = [];
  const diff = (a, b, path, depth) => {
    if ((!isObject(a) || !isObject(b) || depth >= 20) && equal(a, b)) return;
    if (depth < 20 && (isObject(a) || isObject(b))) {
      if (a !== undefined && !isObject(a)) removals.push(path);
      for (const key of new Set([...Object.keys(isObject(a) ? a : {}), ...Object.keys(isObject(b) ? b : {})])) {
        diff(isObject(a) ? a[key] : undefined, isObject(b) ? b[key] : undefined, [...path, key], depth + 1);
      }
      if (b !== undefined && !isObject(b)) changes.push([path, b]);
      return;
    }
    if (a !== undefined) removals.push(path);
    if (b !== undefined) changes.push([path, b]);
  };
  diff(previous ?? {}, next ?? {}, [], 0);
  const state = clone(current ?? {});
  for (const path of removals) if (path.length && allowedPath(pointer(path))) remove(state, path);
  for (const [path, value] of changes) if (path.length && allowedPath(pointer(path))) write(state, path, clone(value), false);
  return state;
}
