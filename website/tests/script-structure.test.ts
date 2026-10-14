import { describe, it, expect } from 'vitest';
import { INTRO_SCRIPT } from '../src/data/introScript';
import { PRIVACY_SCRIPT } from '../src/data/privacyScript';

describe('Rich text structure verification', () => {
  it('INTRO_SCRIPT covers rich text and ends with the closed release entry', () => {
    const kinds = new Set(INTRO_SCRIPT.map((b) => b.kind));
    expect(kinds.has('code')).toBe(true);
    expect(kinds.has('table')).toBe(true);
    expect(kinds.has('list')).toBe(true);
    expect(kinds.has('quote')).toBe(true);
    expect(kinds.has('link')).toBe(true);

    const lastBlock = INTRO_SCRIPT[INTRO_SCRIPT.length - 1];
    expect(lastBlock.kind).toBe('link');
    expect(lastBlock.plain).toBe('Release preparation');
    expect(lastBlock.emphasis).toBe(true);
    expect(lastBlock.href).toBeDefined();
  });

  it('PRIVACY_SCRIPT contains structured breakdown and valid markdown', () => {
    const kinds = new Set(PRIVACY_SCRIPT.map((b) => b.kind));
    expect(kinds.has('heading')).toBe(true);
    expect(kinds.has('paragraph')).toBe(true);
    expect(kinds.has('table')).toBe(true);
    expect(kinds.has('list')).toBe(true);
  });
});
