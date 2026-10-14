import { describe, it, expect } from 'vitest';
import { CORPUS_ZH, CORPUS_EN } from '../src/data/corpus';
import { containsCJK } from '../src/data/intent';

describe('Corpus selection policy', () => {
  it('selects Chinese pool if input contains CJK', () => {
    const input = '今天天气怎么样？';
    expect(containsCJK(input)).toBe(true);
  });

  it('selects English pool if input does not contain CJK', () => {
    const input = 'How is the weather today?';
    expect(containsCJK(input)).toBe(false);
  });

  it('both pools satisfy uniqueness and count constraints', () => {
    expect(CORPUS_ZH.length).toBe(50);
    expect(CORPUS_EN.length).toBe(50);
    expect(new Set(CORPUS_ZH).size).toBe(50);
    expect(new Set(CORPUS_EN).size).toBe(50);
  });
});
