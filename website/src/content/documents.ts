import MarkdownIt from 'markdown-it';
import security from '../../../SECURITY.md?raw';
import support from '../../../SUPPORT.md?raw';
import { INTRO_SCRIPT } from '../data/introPreviewScript';
import { PRIVACY_POLICY } from './privacy';
import type { Script } from '../types/script';
import type { WorkspaceFileItem } from '../data/mockData';
import { CONFIG } from '../config';

export const documentScript = (text: string): Script => text.trim().split(/\n\n+/).map(md => ({
  kind: md.startsWith('#') ? 'heading' : md.startsWith('|') ? 'table' : md.startsWith('- ') ? 'list' : 'paragraph',
  md: /^[#|]|^- /.test(md) ? md : md.replace(/\n/g, ' '), delayBefore: 120,
}));
const insideUI = (text: string) => text.replaceAll('https://limare.app/privacy/', '/#privacy')
  .replaceAll('](SECURITY.md)', '](/#security)');
const securityPreview = documentScript(insideUI(security));
const supportPreview = documentScript(insideUI(support));
const privacyPreview: Script = PRIVACY_POLICY.trim().split(/\n\n+/).map(md => ({
  kind: md.startsWith('#') ? 'heading' : md.startsWith('|') ? 'table' : md.startsWith('- ') ? 'list' : 'paragraph',
  md, delayBefore: 120,
}));
export { SECURITY_SCRIPT, SUPPORT_SCRIPT } from '../data/helpScripts';
const markdown = new MarkdownIt({ html: false, linkify: true });
const escape = (text: string) => markdown.utils.escapeHtml(text);

export const DOCUMENTS = [
  { id: 'intro', title: 'What is Limare?', stem: 'what-is-limare', conversation: 'c-what-is-limare', prompt: 'What is Limare?', script: INTRO_SCRIPT },
  { id: 'privacy', title: 'Privacy Policy', stem: 'privacy-rules', conversation: 'c-privacy-policy', prompt: "Limare's privacy policy", script: privacyPreview },
  { id: 'security', title: 'Security', stem: 'security', conversation: 'c-security', prompt: 'Security', script: securityPreview },
  { id: 'support', title: 'Support', stem: 'support', conversation: 'c-support', prompt: 'Support', script: supportPreview },
].map(doc => ({ ...doc, markdown: insideUI(doc.script.map(block => block.md).join('\n\n')) }));

export function documentBody(doc: typeof DOCUMENTS[number]) {
  if (doc.id === 'intro') {
    const description = doc.script[1].md;
    const capabilities = doc.script.find(block => block.kind === 'list')!;
    const cards = capabilities.md.split('\n').map(item => `<div class="webpage-card markdown-body">${markdown.render(item.replace(/^- /, ''))}</div>`).join('');
    const remaining = doc.script.filter((_block, index) => index > 3);
    return `<div class="webpage-root"><div class="webpage-hero"><div class="webpage-tag">macOS Native Agent</div><h1 class="webpage-title">What is Limare?</h1><div class="webpage-sub">${markdown.render(description)}</div></div><div class="webpage-grid">${cards}</div>${remaining.map(block => `<section class="${block.kind === 'quote' ? 'webpage-callout' : 'webpage-section'} markdown-body">${markdown.render(block.md)}</section>`).join('')}</div>`;
  }
  const sections = doc.markdown.split(/(?=^## )/m);
  return `<div class="webpage-root"><div class="webpage-header-row"><div><div class="webpage-tag">Limare Document</div><h1 class="webpage-title">${escape(doc.title)}</h1><div style="font-size:12px;color:var(--text-muted)">Limare ${escape(CONFIG.version)} · ${escape(CONFIG.developerName)}</div></div></div>${sections.map(section => `<section class="webpage-section markdown-body">${markdown.render(section.replace(/^# [^\n]+\n?/, ''))}</section>`).join('')}</div>`;
}

export function documentFiles(doc: typeof DOCUMENTS[number]): WorkspaceFileItem[] {
  const sections = doc.script.map(block => ({ type: block.kind, markdown: insideUI(block.md) }));
  const json = JSON.stringify({ title: doc.title, version: CONFIG.version, developer: CONFIG.developerName,
    contact: CONFIG.privacyContact, document: sections }, null, 2);
  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>${escape(doc.title)} — Limare</title>\n<style>body{font:15px system-ui;line-height:1.6;margin:32px auto;max-width:860px;padding:0 24px;color:#252525}section{margin:24px 0}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:8px}pre{overflow:auto;background:#f4f4f4;padding:16px}a{color:#246ac4}</style>\n</head>\n<body>\n${documentBody(doc)}\n</body>\n</html>`;
  return ([['markdown','md',doc.markdown],['html','html',html],['json','json',json]] as const).map(([type,extension,content]) => ({
    path: `${doc.stem}.${extension}`, name: `${doc.stem}.${extension}`, type,
    size: `${(new TextEncoder().encode(content).length / 1024).toFixed(1)} KB`, content,
    ...(type === 'html' ? { previewUrl: `https://limare.app/${doc.stem}.html` } : {}),
  }));
}
