import { describe, it, expect } from 'vitest';
import { CORPUS_ZH, CORPUS_EN } from '../src/data/corpus';
import { classifyIntent, normalizeInput } from '../src/data/intent';
import { INTRO_SCRIPT } from '../src/data/introScript';
import { PRIVACY_SCRIPT } from '../src/data/privacyScript';

describe('Corpus constraints', () => {
  it('Chinese pool has exactly 50 items and <= 20 codepoints', () => {
    expect(CORPUS_ZH.length).toBe(50);
    expect(new Set(CORPUS_ZH).size).toBe(50);
    for (const item of CORPUS_ZH) {
      const codepoints = Array.from(item.trim()).length;
      expect(codepoints).toBeLessThanOrEqual(20);
      expect(item).not.toMatch(/[\r\n]/);
    }
  });

  it('English pool has exactly 50 items and <= 20 words', () => {
    expect(CORPUS_EN.length).toBe(50);
    expect(new Set(CORPUS_EN).size).toBe(50);
    for (const item of CORPUS_EN) {
      const words = item.trim().split(/\s+/).filter(Boolean).length;
      expect(words).toBeLessThanOrEqual(20);
      expect(item).not.toMatch(/[\r\n]/);
    }
  });
});

describe('Intent classification', () => {
  const table: [string, string, 'intro' | 'privacy' | 'random'][] = [
    ['What is Limare?', 'what is limare', 'intro'],
    ["What's Limare?", "what's limare", 'intro'],
    ['  WHAT IS LIMARE  ', 'what is limare', 'intro'],
    ["Limare's privacy policy", "limare's privacy policy", 'privacy'],
    ['privacy policy', 'privacy policy', 'privacy'],
    ['隐私政策', '隐私政策', 'privacy'],
    ["What is Limare's privacy policy?", "what is limare's privacy policy", 'privacy'],
    ['Google privacy policy', 'google privacy policy', 'random'],
    ['how does privacy work', 'how does privacy work', 'random'],
    ['Privacy is dead', 'privacy is dead', 'random'],
    ['你好', '你好', 'random'],
    ['how are you', 'how are you', 'random'],
  ];

  for (const [raw, expectedNorm, expectedIntent] of table) {
    it(`evaluates: "${raw}" -> ${expectedIntent}`, () => {
      expect(normalizeInput(raw)).toBe(expectedNorm);
      expect(classifyIntent(raw)).toBe(expectedIntent);
    });
  }
});

describe('Script block and plain text integrity', () => {
  it('plain text in INTRO_SCRIPT contains no markdown symbols', () => {
    for (const block of INTRO_SCRIPT) {
      if (block.plain) {
        // forbidden markdown symbols in plain
        expect(block.plain).not.toMatch(/[#*`_\[\]()|>]/);
      }
    }
  });

  it('plain text in PRIVACY_SCRIPT contains no markdown symbols', () => {
    for (const block of PRIVACY_SCRIPT) {
      if (block.plain) {
        expect(block.plain).not.toMatch(/[#*`_\[\]()|>]/);
      }
    }
  });
});
