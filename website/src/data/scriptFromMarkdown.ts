import MarkdownIt from 'markdown-it';
import type { Script, BlockKind } from '../types/script';

const parser = new MarkdownIt({ html: false, linkify: true });

// Top-level token ranges keep nested lists, quotes, and fenced examples intact.
export function toChatScript(text: string): Script {
  const lines = text.trim().split('\n');
  return parser.parse(lines.join('\n'), {}).filter(token => token.level === 0 && token.map).map(token => {
    const [start, end] = token.map!;
    const kinds: Record<string, BlockKind> = {
      heading_open: 'heading', bullet_list_open: 'list', ordered_list_open: 'list',
      blockquote_open: 'quote', table_open: 'table', fence: 'code', code_block: 'code',
    };
    return {
      kind: kinds[token.type] ?? 'paragraph', md: lines.slice(start, end).join('\n'),
      ...(token.type === 'fence' ? { lang: token.info.trim(), filename: token.info.trim() === 'text' ? 'Example' : token.info.trim() } : {}),
      delayBefore: 120,
    };
  });
}
