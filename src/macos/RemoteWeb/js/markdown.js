// markdown-it (138 KB) is loaded only once a conversation is shown, so the list appears without
// it. Until it arrives, messages show as plain text and are redrawn when it is ready.
//
// Raw HTML in model output is escaped, never rendered (html: false). markdown-it's own link
// validation already refuses javascript:, vbscript:, file: and non-image data: URLs.
let md = null;
let loading = null;

export function loadMarkdown() {
  loading ||= import('../vendor/markdown-it.esm.min.js').then(({ default: markdownit }) => {
    const instance = markdownit({ html: false, linkify: true, breaks: false });
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
export function fillMarkdown(element, text) {
  if (md) {
    element.innerHTML = md.render(text); // html disabled: escaped
  } else {
    element.classList.add('plain');
    element.textContent = text;
  }
}
