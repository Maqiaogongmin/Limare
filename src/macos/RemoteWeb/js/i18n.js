// The page's text in Limare's language. The Mac fills index.html with this page's strings,
// translated from Limare's string catalog, so the phone and the Mac share one set of
// translations. A key is the English text; `%@`, `%lld` and `%d` (or `%1$@`…) mark arguments.
// Keys must be string literals: `script/localization.py sync-web` collects them.

const table = (() => {
  try {
    return JSON.parse(globalThis.document?.getElementById('limare-strings')?.textContent || '{}');
  } catch {
    return {};
  }
})();

export const language = globalThis.document?.documentElement.lang || 'en';

export function t(key, ...args) {
  let next = 0;
  return (table[key] ?? key).replace(/%(?:(\d+)\$)?(?:@|lld|d)/g, (_, position) => {
    const value = args[position ? Number(position) - 1 : next++];
    return value === undefined ? '' : String(value);
  });
}
