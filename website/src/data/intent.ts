export type Intent = 'intro' | 'privacy' | 'random';

const PRIVACY_ALIASES = [
  'privacy policy',
  'limare privacy policy',
  'limare\'s privacy policy',
  'limares privacy policy',
  'limare\'s privacy',
  'limare privacy',
  'what is limare\'s privacy policy',
  '隐私政策',
  'limare 隐私政策',
  'limare的隐私政策',
  'limare 的隐私政策',
];

const INTRO_ALIASES = [
  'limare',
  'what is limare',
  'what\'s limare',
  'whats limare',
  'what is limare about',
  'about limare',
  'tell me about limare',
  'limare 是什么',
  'limare是什么',
  '什么是 limare',
  '什么是limare',
  '介绍一下 limare',
  '介绍 limare',
  'limare 介绍',
];

export function normalizeInput(raw: string): string {
  let s = raw.trim().toLowerCase();
  // normalize curly quotes to straight quotes
  s = s.replace(/[\u2018\u2019]/g, "'");
  // collapse whitespace
  s = s.replace(/\s+/g, ' ');
  // remove trailing punctuations
  s = s.replace(/[?!.。,，？！]+$/, '');
  return s.trim();
}

export function classifyIntent(raw: string): Intent {
  const normalized = normalizeInput(raw);
  if (PRIVACY_ALIASES.includes(normalized)) {
    return 'privacy';
  }
  if (INTRO_ALIASES.includes(normalized)) {
    return 'intro';
  }
  return 'random';
}

export function containsCJK(text: string): boolean {
  return /[\u4e00-\u9fa5\u3040-\u30ff\u3400-\u4dbf]/.test(text);
}
