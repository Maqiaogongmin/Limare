import React, { useMemo } from 'react';
import MarkdownIt from 'markdown-it';
import { ScriptBlock } from '../types/script';

const md = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
});

export const MarkdownBlockRenderer: React.FC<{
  block: ScriptBlock;
  isStreaming?: boolean;
  streamText?: string;
}> = ({ block, isStreaming, streamText }) => {
  // If streaming intermediate state and plain text is provided, display plain text only (no raw markdown tokens)
  if (isStreaming && streamText !== undefined) {
    return (
      <div className="plain-typing">
        {streamText}
        <span className="typing-cursor" />
      </div>
    );
  }

  if (block.kind === 'code') {
    return (
      <div className="code-container">
        <div className="code-header">
          <span>{block.filename || block.lang || 'code'}</span>
          <button
            className="copy-btn"
            onClick={() => {
              const codeOnly = block.md.replace(/^```[^\n]*\n/, '').replace(/\n```$/, '');
              navigator.clipboard?.writeText(codeOnly);
            }}
          >
            Copy
          </button>
        </div>
        <pre className="code-pre">
          <code>{block.md.replace(/^```[^\n]*\n/, '').replace(/\n```$/, '')}</code>
        </pre>
      </div>
    );
  }

  if (block.kind === 'link' && block.emphasis && block.href) {
    return (
      <div style={{ margin: '14px 0' }}>
        <a
          href={block.href}
          className="download-link-emphasis"
          target="_blank"
          rel="noopener noreferrer"
        >
          {block.plain || 'Download here'}
        </a>
      </div>
    );
  }

  const renderedHtml = useMemo(() => {
    return md.render(block.md);
  }, [block.md]);

  return (
    <div
      className="markdown-body"
      dangerouslySetInnerHTML={{ __html: renderedHtml }}
    />
  );
};
