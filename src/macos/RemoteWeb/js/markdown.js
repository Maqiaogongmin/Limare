// markdown-it (138 KB) is loaded only once a conversation is shown, so the list appears without
// it. Until it arrives, messages show as plain text and are redrawn when it is ready.
//
// Raw HTML in model output is escaped, never rendered (html: false). markdown-it's own link
// validation already refuses javascript:, vbscript:, file: and non-image data: URLs.
import { copyButton } from './clipboard.js';
import { t } from './i18n.js';

let md = null;
let loading = null;
let generativeLoading = null;

function fenceClosed(lines, token) {
  const line = lines[token.map[1] - 1] || '';
  const match = line.match(/^ {0,3}(`+|~+)[ \t]*$/);
  return !!match && match[1][0] === token.markup[0] && match[1].length >= token.markup.length;
}

function wrapCode(element) {
  for (const pre of element.querySelectorAll('pre')) {
    const code = pre.querySelector('code');
    if (!code) continue;
    const wrapper = document.createElement('div');
    wrapper.className = 'code-block';
    pre.replaceWith(wrapper);
    wrapper.append(pre, copyButton(code.textContent, t('Copy code'), 'copy-code'));
  }
}

export function loadMarkdown() {
  loading ||= import('../vendor/markdown-it.esm.min.js').then(({ default: markdownit }) => {
    const instance = markdownit({ html: false, linkify: true, breaks: false });
    const defaultFence = instance.renderer.rules.fence;
    instance.renderer.rules.fence = (tokens, idx, options, env, self) => {
      const token = tokens[idx];
      if (env.generative && token.level === 0 && token.info.trim() === 'spec') {
        const index = env.generative.length;
        env.generative.push({ input: token.content, closed: fenceClosed(env.lines, token), fallback: defaultFence(tokens, idx, options, env, self) });
        return `<div class="gen-placeholder" data-gen-index="${index}"><span class="spinner"></span></div>`;
      }
      return defaultFence(tokens, idx, options, env, self);
    };
    const defaultLinkOpen = instance.renderer.rules.link_open
      || ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
    instance.renderer.rules.link_open = (tokens, idx, options, env, self) => {
      tokens[idx].attrSet('target', '_blank');
      tokens[idx].attrSet('rel', 'noopener noreferrer');
      return defaultLinkOpen(tokens, idx, options, env, self);
    };
    md = instance;
  });
  return loading;
}

export const isMarkdownReady = () => md !== null;

/// Fills `element` with `text` as markdown, or as plain text while markdown-it is still loading.
export function fillMarkdown(element, text, generative = null) {
  if (md) {
    const env = { lines: generative ? text.split(/\r\n?|\n/) : null, generative: generative ? [] : null };
    element.innerHTML = md.render(text, env); // html disabled: escaped
    wrapCode(element);
    if (env.generative?.length) {
      generativeLoading ||= import('./generative-ui.js');
      generativeLoading.then(({ GenerativeSurface }) => {
        for (const [index, block] of env.generative.entries()) {
          const slot = element.querySelector(`[data-gen-index="${index}"]`);
          if (!slot?.isConnected) continue; // a newer streaming render replaced this one
          const key = `${generative.id}#${index}`;
          let surface = generative.cache.get(key);
          if (!surface) { surface = new GenerativeSurface(); generative.cache.set(key, surface); }
          surface.update(block.input, block.closed, generative.streaming);
          if (surface.host.dataset.valid === 'true') {
            const messages = slot.closest('.messages');
            const stick = messages && messages.scrollHeight - messages.scrollTop - messages.clientHeight < 80;
            slot.replaceWith(surface.host);
            if (stick) messages.scrollTop = messages.scrollHeight;
          } else if (!generative.streaming || block.closed) {
            // Invalid/unsupported finished output remains available as its original code.
            slot.classList.remove('gen-placeholder');
            slot.innerHTML = block.fallback;
            wrapCode(slot);
          }
        }
      }).catch(() => {
        for (const [index, block] of env.generative.entries()) {
          const slot = element.querySelector(`[data-gen-index="${index}"]`);
          if (slot?.isConnected) { slot.classList.remove('gen-placeholder'); slot.innerHTML = block.fallback; wrapCode(slot); }
        }
      });
    }
  } else {
    element.classList.add('plain');
    element.textContent = text;
  }
}
