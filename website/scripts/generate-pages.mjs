import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import MarkdownIt from 'markdown-it';

const website = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.dirname(website);
const markdown = new MarkdownIt({ html: false, linkify: true });
const pages = [
  ['privacy', 'Privacy Policy', path.join(website, 'src/content/privacy.md')],
  ['security', 'Security', path.join(root, 'SECURITY.md')],
  ['support', 'Support', path.join(root, 'SUPPORT.md')],
];
const navigation = '<nav><a href="/">Limare</a><a href="/privacy/">Privacy</a><a href="/security/">Security</a><a href="/support/">Support</a><a href="/download/">Download</a></nav>';
const document = (slug, title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} — Limare</title><meta name="description" content="Limare ${title}"><link rel="icon" type="image/png" href="/assets/limare-icon.png"><link rel="canonical" href="https://limare.app/${slug}/"><link rel="stylesheet" href="/release.css"></head><body>${navigation}<main>${body}</main><footer>Limare 0.1.0 · Apple Silicon · macOS 15.0+ · Maqiaogongmin</footer></body></html>`;
for (const [slug, title, source] of pages) {
  const text = await readFile(source, 'utf8');
  const directory = path.join(website, 'public', slug);
  await mkdir(directory, { recursive: true });
  const siteText = text.replaceAll('](SECURITY.md)', '](/security/)').replaceAll('](SUPPORT.md)', '](/support/)');
  await writeFile(path.join(directory, 'index.html'), document(slug, title, markdown.render(siteText)));
}
// Release download links stay closed until the public artifact has been validated.
const download = '<h1>Limare 0.1.0</h1><p>Release preparation is in progress. Public downloads are not yet available.</p><p>Apple Silicon · macOS 15.0+. The release will provide corresponding source and a signed, notarized DMG.</p><p><a href="/privacy/">Read the privacy policy</a> · <a href="/support/">Support</a></p>';
await mkdir(path.join(website, 'public/download'), { recursive: true });
await writeFile(path.join(website, 'public/download/index.html'), document('download', 'Download', download));
