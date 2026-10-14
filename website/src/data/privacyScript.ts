import { Script } from '../types/script';
import { PRIVACY_POLICY } from '../content/privacy';

export const PRIVACY_SCRIPT: Script = PRIVACY_POLICY.trim().split(/\n\n+/).map(md => ({
  kind: md.startsWith('#') ? 'heading' : md.startsWith('|') ? 'table' : md.startsWith('- ') ? 'list' : 'paragraph',
  md,
  delayBefore: 120,
}));
