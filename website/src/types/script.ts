export type BlockKind =
  | 'heading'
  | 'paragraph'
  | 'list'
  | 'quote'
  | 'code'
  | 'table'
  | 'link'
  | 'thinking'
  | 'tool';

export interface ScriptBlock {
  kind: BlockKind;
  md: string;
  plain?: string;
  delayBefore?: number;
  perItem?: boolean;
  emphasis?: boolean;
  href?: string;
  lang?: string;
  filename?: string;
}

export type Script = ScriptBlock[];
