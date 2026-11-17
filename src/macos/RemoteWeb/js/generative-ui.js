// Mobile counterpart of NativeCatalog. Specs and state stay in this page: buttons
// and switches can only change local state; they cannot invoke tools or navigate.
import { h } from './dom.js';
import { t } from './i18n.js';
import { SpecStream, measure, mergeInitialState, setStatePath, allowedPath } from './spec-stream.js';
import { getByPath, resolveElementProps, resolveBindings, resolveActionParam,
  evaluateVisibility, splitRepeatVisibility, resolveRepeatStatePath, resolveRepeatItemStatePath } from '../vendor/json-render-core.esm.js';

const TYPES = new Set(['Stack', 'Grid', 'Card', 'Heading', 'Text', 'Metric', 'Badge', 'Alert', 'List', 'ListItem', 'Progress', 'Separator', 'Button', 'Switch', 'BarChart', 'LineChart', 'Row', 'Column', 'Toggle', 'Divider']);
const COLORS = new Set(['blue', 'green', 'orange', 'red', 'purple', 'pink', 'teal', 'indigo', 'yellow', 'brown', 'gray', 'mint', 'cyan']);
const GLYPHS = { 'chart.bar': '▥', 'chart.bar.fill': '▥', 'checkmark': '✓', 'checkmark.circle': '✓', 'star': '☆', 'star.fill': '★', 'heart': '♡', 'heart.fill': '♥', 'info.circle': 'ⓘ', 'exclamationmark.triangle': '⚠', 'calendar': '▦', 'person': '●', 'bolt': 'ϟ', 'arrow.up': '↑', 'arrow.down': '↓' };
const NS = 'http://www.w3.org/2000/svg';
const text = (v) => v == null ? '' : typeof v === 'object' ? '' : String(v);
const obj = (v) => v && typeof v === 'object' && !Array.isArray(v) ? v : {};
const safePath = allowedPath;
const copied = (v) => v === undefined ? undefined : JSON.parse(JSON.stringify(v));
const color = (name) => COLORS.has(name) ? ` tint-${name}` : '';
const symbol = (name) => typeof name === 'string' && Object.hasOwn(GLYPHS, name) ? h('span', { class: 'gen-symbol', 'aria-hidden': 'true' }, GLYPHS[name]) : null;

// The upstream prop resolver builds ordinary objects. Strip prototype setters from
// untrusted model data before handing it values to resolve.
function clean(value) {
  if (Array.isArray(value)) return value.map(clean);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => key !== '__proto__').map(([key, child]) => [key, clean(child)]));
}

function svg(tag, attrs = {}, content) {
  const node = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
  if (content != null) node.textContent = String(content);
  return node;
}

// Bounds template expansion before the upstream resolver allocates its result.
function checkProps(value, ctx, budget, depth = 0) {
  if (++budget.work > 50_000 || depth > 100) throw new Error('limit');
  if (typeof value === 'string') budget.bytes += value.length * 3;
  else if (Array.isArray(value)) value.forEach((v) => checkProps(v, ctx, budget, depth + 1));
  else if (value && typeof value === 'object') {
    if (typeof value.$template === 'string') {
      budget.bytes += value.$template.length * 3;
      for (const match of value.$template.matchAll(/\$\{([^}]+)\}/g)) {
        const key = match[1];
        const resolved = key.startsWith('/') ? getByPath(ctx.stateModel, key)
          : (ctx.repeatItem === undefined ? undefined : getByPath(ctx.repeatItem, key)) ?? getByPath(ctx.stateModel, '/' + key);
        if (resolved != null) budget.bytes += String(resolved).length * 3;
        if (budget.bytes > 32_000_000) throw new Error('limit');
      }
    } else {
      for (const [key, child] of Object.entries(value)) { budget.bytes += key.length * 3; checkProps(child, ctx, budget, depth + 1); }
    }
  }
  if (budget.bytes > 32_000_000) throw new Error('limit');
}

function chart(kind, props) {
  const xKey = text(props.xKey) || 'x', yKey = text(props.yKey) || 'y';
  const data = Array.isArray(props.data) ? props.data : [];
  const rows = data.slice(0, 1000);
  const points = rows.map((row, index) => {
    const r = obj(row), yValue = Object.hasOwn(r, yKey) ? r[yKey] : null, xValue = Object.hasOwn(r, xKey) ? r[xKey] : null;
    const raw = text(yValue).replace(/[^0-9.\-]/g, '');
    const value = typeof yValue === 'number' ? yValue : raw ? Number(raw) : NaN;
    return { label: text(xValue) || String(index + 1), value };
  }).filter((p) => Number.isFinite(p.value));
  const wrapper = h('div', { class: `gen-chart${color(props.tint)}` });
  if (props.title) wrapper.append(h('div', { class: 'gen-chart-title' }, text(props.title)));
  if (!points.length) { wrapper.append(h('div', { class: 'gen-chart-empty', role: 'img', 'aria-label': t('No chart data') })); return wrapper; }
  const width = Math.max(400, Math.min(4000, points.length * 42));
  const height = Math.max(120, Math.min(360, Number(props.height) || 180));
  const left = 48, right = 12, top = 12, bottom = 32;
  const plotW = width - left - right, plotH = height - top - bottom;
  let min = Math.min(0, ...points.map((p) => p.value)), max = Math.max(0, ...points.map((p) => p.value));
  if (max === min) max = min + 1;
  const scale = Math.max(1, Math.abs(min), Math.abs(max));
  const low = min / scale, high = max / scale;
  const y = (v) => top + (high - v / scale) / (high - low) * plotH;
  const canvas = svg('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': text(props.title) || t('Chart') });
  canvas.style.width = '100%';
  canvas.style.minWidth = `${points.length > 9 ? width : 0}px`;
  for (let i = 0; i <= 4; i++) {
    const value = (low + (high - low) * i / 4) * scale, py = y(value);
    canvas.append(svg('line', { x1: left, x2: width - right, y1: py, y2: py, class: 'gen-gridline' }),
      svg('text', { x: left - 5, y: py + 4, 'text-anchor': 'end', class: 'gen-axis' }, Number(value.toPrecision(3))));
  }
  const step = plotW / points.length, zero = y(0);
  const positions = points.map((point, i) => [left + step * (i + .5), y(point.value)]);
  if (kind === 'LineChart' && positions.length > 1) {
    canvas.append(svg('polyline', { points: positions.map(([x, py]) => `${x},${py}`).join(' '), class: 'gen-line' }));
  }
  points.forEach((point, i) => {
    const [x, py] = positions[i];
    const mark = kind === 'BarChart'
      ? svg('rect', { x: x - step * .3, y: Math.min(py, zero), width: step * .6, height: Math.max(1, Math.abs(py - zero)), rx: 3, class: 'gen-mark' })
      : svg('circle', { cx: x, cy: py, r: 3.5, class: 'gen-mark' });
    mark.append(svg('title', {}, `${point.label}: ${point.value}`));
    canvas.append(mark);
    if (points.length <= 12 || i % Math.ceil(points.length / 12) === 0) {
      canvas.append(svg('text', { x, y: height - 9, 'text-anchor': 'middle', class: 'gen-axis' }, point.label.length > 10 ? point.label.slice(0, 9) + '…' : point.label));
    }
  });
  const details = h('table', { class: 'gen-chart-data' }, h('caption', {}, text(props.title) || t('Chart')),
    h('tbody', {}, points.map((p) => h('tr', {}, h('th', { scope: 'row' }, p.label), h('td', {}, String(p.value))))));
  wrapper.append(h('div', { class: 'gen-chart-scroll' }, canvas), details);
  if (data.length > rows.length) wrapper.append(h('div', { class: 'gen-muted' }, t('Showing the first %lld of %lld rows', rows.length, data.length)));
  return wrapper;
}

export class GenerativeSurface {
  constructor() {
    this.host = h('div', { class: 'gen-ui' });
    this.compiler = new SpecStream();
    this.input = null;
    this.initial = {};
    this.state = {};
    this.localSwitches = new Map();
    this.spec = {};
  }

  update(input, closed, streaming) {
    if (this.input !== null && !input.startsWith(this.input)) {
      this.initial = {}; this.state = {}; this.localSwitches.clear();
    }
    const next = this.compiler.update(input, closed || !streaming);
    this.state = mergeInitialState(this.initial, obj(next.state), this.state);
    this.initial = copied(obj(next.state));
    this.input = input;
    this.spec = next;
    this.streaming = streaming;
    this.closed = closed;
    this.render();
  }

  render() {
    const spec = this.spec;
    if (typeof spec.root !== 'string' || !spec.elements || Array.isArray(spec.elements) || typeof spec.elements !== 'object' ||
        !Object.hasOwn(spec.elements, spec.root) || !TYPES.has(spec.elements[spec.root]?.type)) {
      this.host.replaceChildren();
      this.host.dataset.valid = 'false';
      return;
    }
    this.host.dataset.valid = 'true';
    const focused = this.host.contains(document.activeElement) ? document.activeElement?.dataset.genKey : null;
    const budget = { work: 0, nodes: 0, bytes: 0, idBytes: 0 };
    let root;
    try { root = this.element(spec.root, { stateModel: this.state }, new Set(), budget, 1); }
    catch { this.host.dataset.valid = 'false'; root = null; }
    this.host.replaceChildren(...(root ? [root] : []));
    if (focused) this.host.querySelector(`[data-gen-key="${CSS.escape(focused)}"]`)?.focus({ preventScroll: true });
    if (budget.truncated) this.host.append(h('div', { class: 'gen-incomplete' }, t('Some content could not be displayed.')));
    if (!this.streaming && !this.closed) this.host.append(h('div', { class: 'gen-incomplete' }, t('Output incomplete')));
  }

  element(key, ctx, ancestors, budget, depth) {
    if (++budget.work > 50_000 || ++budget.nodes > 10_000 || depth > 100 || ancestors.has(key)) { budget.truncated = true; return null; }
    const element = Object.hasOwn(this.spec.elements, key) ? this.spec.elements[key] : null;
    if (!element || !TYPES.has(element.type)) return null;
    const nextAncestors = new Set(ancestors).add(key);
    let idLength = (ctx.repeatIdentity || '').length;
    for (const part of nextAncestors) idLength += String(part).length + 1;
    budget.idBytes += idLength * 3;
    if (budget.idBytes > 4_000_000) { budget.truncated = true; return null; }
    const split = element.repeat && ctx.repeatItem === undefined ? splitRepeatVisibility(element.visible) : { container: element.visible };
    if (split.container !== undefined && !evaluateVisibility(split.container, ctx)) return null;
    const raw = obj(element.props);
    checkProps(raw, ctx, budget);
    const sanitized = clean(raw);
    const props = resolveElementProps(sanitized, ctx);
    // Resolved values may refer to large state strings; charge each rendered copy.
    checkProps(props, ctx, budget);
    const bindings = resolveBindings(sanitized, ctx);
    const children = [];
    if (element.repeat) {
      const path = resolveRepeatStatePath(element.repeat.statePath, ctx.repeatBasePath);
      const items = path === undefined ? [] : getByPath(this.state, path);
      if (Array.isArray(items)) {
        for (let i = 0; i < items.length; i++) {
          if (budget.work >= 50_000 || budget.nodes >= 10_000) { budget.truncated = true; break; }
          const identity = element.repeat.key && items[i] && typeof items[i] === 'object' ? items[i][element.repeat.key] ?? i : i;
          const id = String(identity);
          if ((id.length + path.length + (ctx.repeatIdentity || '').length) * 3 + budget.idBytes > 4_000_000) { budget.truncated = true; break; }
          const itemCtx = { stateModel: this.state, repeatItem: items[i], repeatIndex: i, repeatBasePath: resolveRepeatItemStatePath(path, i), repeatIdentity: `${ctx.repeatIdentity || ''}/${id}` };
          if (split.itemFilter !== undefined && !evaluateVisibility(split.itemFilter, itemCtx)) continue;
          for (const child of Array.isArray(element.children) ? element.children : []) {
            const built = this.element(child, itemCtx, nextAncestors, budget, depth + 1);
            if (built) children.push(built);
          }
        }
      }
    } else {
      for (const child of Array.isArray(element.children) ? element.children : []) {
        const built = this.element(child, ctx, nextAncestors, budget, depth + 1);
        if (built) children.push(built);
      }
    }
    return this.component(element, props, bindings, children, ctx, `${[...nextAncestors].join('/')}:${ctx.repeatIdentity || ''}`);
  }

  write(path, value) {
    if (!safePath(path)) return false;
    try {
      const next = copied(this.state);
      if (!setStatePath(next, path, copied(value))) return false;
      measure(next);
      this.state = next;
      return true;
    } catch { return false; /* An invalid or oversized local state write is ignored. */ }
  }

  emit(element, name, ctx) {
    const binding = element.on?.[name];
    for (const action of Array.isArray(binding) ? binding : binding ? [binding] : []) {
      if (!['setState', 'pushState', 'removeState'].includes(action?.action)) continue;
      const fresh = { ...ctx, stateModel: this.state };
      let params;
      try {
        checkProps(obj(action.params), fresh, { work: 0, bytes: 0 });
        params = Object.fromEntries(Object.entries(clean(obj(action.params))).map(([k, v]) => [k, resolveActionParam(v, fresh)]));
      } catch { continue; }
      if (!safePath(params.statePath)) continue;
      if (action.action === 'setState') this.write(params.statePath, params.value ?? null);
      if (action.action === 'pushState') {
        const current = getByPath(this.state, params.statePath);
        const items = Array.isArray(current) ? [...current] : [];
        const expand = (v) => v === '$id' || (v && typeof v === 'object' && Object.keys(v).length === 1 && v.$id === true) ? crypto.randomUUID() : Array.isArray(v) ? v.map(expand)
          : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, expand(x)])) : v;
        items.push(expand(params.value ?? null));
        if (this.write(params.statePath, items) && safePath(params.clearStatePath)) this.write(params.clearStatePath, '');
      }
      if (action.action === 'removeState') {
        const current = getByPath(this.state, params.statePath), index = params.index;
        if (Array.isArray(current) && Number.isInteger(index) && index >= 0 && index < current.length) {
          const items = [...current]; items.splice(index, 1); this.write(params.statePath, items);
        }
      }
    }
    this.render();
  }

  component(element, props, bindings, children, ctx, key) {
    const type = element.type, tint = color(props.tint);
    if (['Stack', 'Row', 'Column', 'Grid'].includes(type)) {
      const direction = type === 'Row' ? 'horizontal' : type === 'Column' ? 'vertical' : props.direction;
      const node = h('div', { class: `gen-${type === 'Grid' ? 'grid' : 'stack'}${direction === 'horizontal' ? ' horizontal' : ''}` }, children);
      const gaps = { none: 0, xs: 4, sm: 8, md: 12, lg: 16, xl: 24 };
      if (Object.hasOwn(gaps, props.gap)) node.style.gap = `${gaps[props.gap]}px`;
      else if (typeof props.gap === 'number') node.style.gap = `${Math.max(0, Math.min(64, props.gap))}px`;
      if (type === 'Grid') node.classList.add(`cols-${Math.max(1, Math.min(6, Math.floor(Number(props.columns) || 2)))}`);
      const align = { start: 'flex-start', center: 'center', end: 'flex-end', stretch: 'stretch' };
      const justify = { start: 'flex-start', center: 'center', end: 'flex-end', between: 'space-between', around: 'space-around' };
      if (Object.hasOwn(align, props.align)) node.style.alignItems = align[props.align];
      if (Object.hasOwn(justify, props.justify)) node.style.justifyContent = justify[props.justify];
      return node;
    }
    if (type === 'Card') return h('section', { class: `gen-card${tint}` }, props.title || props.description ? h('div', { class: 'gen-card-head' }, symbol(props.icon), h('div', {}, props.title ? h('div', { class: 'gen-card-title' }, text(props.title)) : null, props.description ? h('div', { class: 'gen-muted' }, text(props.description)) : null)) : null, ...children);
    if (type === 'Heading') return h(['h1', 'h2', 'h3', 'h4'].includes(props.level) ? props.level : 'h3', { class: 'gen-heading' }, text(props.text));
    if (type === 'Text') return h('div', { class: `gen-text gen-text-${['lead', 'caption', 'muted', 'code'].includes(props.variant) ? props.variant : 'body'}` }, text(props.text));
    if (type === 'Metric') return h('div', { class: `gen-metric${tint}` }, h('div', { class: 'gen-muted' }, symbol(props.icon), text(props.label)), h('div', { class: 'gen-metric-value' }, text(props.value)), props.detail ? h('div', { class: 'gen-muted' }, props.trend === 'up' ? '↑ ' : props.trend === 'down' ? '↓ ' : '', text(props.detail)) : null);
    if (type === 'Badge') return h('span', { class: `gen-badge gen-variant-${['secondary', 'success', 'warning', 'destructive', 'outline'].includes(props.variant) ? props.variant : 'default'}` }, text(props.text));
    if (type === 'Alert') return h('div', { class: `gen-alert gen-alert-${['success', 'warning', 'error'].includes(props.type) ? props.type : 'info'}`, role: 'note' }, h('strong', {}, text(props.title)), props.message ? h('div', {}, text(props.message)) : null);
    if (type === 'List') return h('div', { class: 'gen-list' }, props.title ? h('div', { class: 'gen-list-title' }, text(props.title)) : null, ...children);
    if (type === 'ListItem') return h('div', { class: `gen-list-item${tint}` }, symbol(props.icon), h('div', { class: 'gen-list-text' }, h('div', {}, text(props.title)), props.subtitle ? h('div', { class: 'gen-muted' }, text(props.subtitle)) : null), props.trailing ? h('span', { class: 'gen-muted' }, text(props.trailing)) : null, ...children);
    if (type === 'Progress') {
      const max = Number(props.max) > 0 ? Number(props.max) : 100, value = Math.max(0, Math.min(max, Number(props.value) || 0));
      return h('div', { class: `gen-progress${tint}` }, props.label ? h('div', {}, text(props.label)) : null, h('progress', { value, max, 'aria-label': text(props.label) || t('Progress') }));
    }
    if (type === 'Separator' || type === 'Divider') return h('hr', { class: 'gen-separator' });
    if (type === 'Button') return h('button', { type: 'button', dataset: { genKey: key }, class: `gen-button${props.variant === 'primary' ? ' primary' : props.variant === 'danger' ? ' danger' : ''}`, disabled: !!props.disabled, onclick: () => this.emit(element, 'press', ctx) }, symbol(props.icon), text(props.label || props.text));
    if (type === 'Switch' || type === 'Toggle') {
      const bound = bindings.checked, checked = bound ? !!getByPath(this.state, bound) : this.localSwitches.get(key) ?? !!props.checked;
      const control = h('input', { type: 'checkbox', role: 'switch', dataset: { genKey: key }, 'aria-label': text(props.label) });
      control.checked = checked;
      control.addEventListener('change', () => { if (bound) this.write(bound, control.checked); else this.localSwitches.set(key, control.checked); this.emit(element, 'change', ctx); });
      return h('label', { class: 'gen-switch' }, h('span', { class: 'gen-switch-label' }, h('span', {}, text(props.label)), props.description ? h('span', { class: 'gen-muted' }, text(props.description)) : null), control);
    }
    if (type === 'BarChart' || type === 'LineChart') return chart(type, props);
    return null;
  }
}
