import React, { useState, useMemo } from 'react';
import MarkdownIt from 'markdown-it';
import {
  IconFolder,
  IconGlobe,
  IconClose,
  IconPlus,
  IconArrowLeft,
} from './Icons';
import { FAKE_WORKSPACE_FILES } from '../data/mockData';
import { DOCUMENTS, documentBody } from '../content/documents';

const mdParser = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
});

export interface TabItem {
  id: string;
  type: 'files' | 'browser';
  title: string;
}

interface WorkSurfaceProps {
  isOpen: boolean;
  onClose: () => void;
  isNarrow?: boolean;
}

// Syntax highlighter for JSON
function highlightJSON(jsonStr: string): string {
  const escaped = jsonStr
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
  return escaped.replace(
    /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g,
    (match) => {
      let cls = 'json-num';
      if (/^"/.test(match)) {
        if (/:$/.test(match)) {
          cls = 'json-key';
        } else {
          cls = 'json-str';
        }
      } else if (/true|false/.test(match)) {
        cls = 'json-bool';
      } else if (/null/.test(match)) {
        cls = 'json-null';
      }
      return `<span class="${cls}">${match}</span>`;
    }
  );
}

// Syntax highlighter for HTML
function highlightHTML(htmlStr: string): string {
  const escaped = htmlStr
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  return escaped
    .replace(/(&lt;!DOCTYPE[^&]*&gt;)/gi, '<span class="html-doctype">$1</span>')
    .replace(/(&lt;\/?[a-zA-Z0-9\-]+)/g, '<span class="html-tag">$1</span>')
    .replace(/(&gt;)/g, '<span class="html-tag">$1</span>')
    .replace(/([a-zA-Z\-]+)=(&quot;[^&]*&quot;)/g, '<span class="html-attr">$1</span>=<span class="html-val">$2</span>');
}

export const WorkSurface: React.FC<WorkSurfaceProps> = ({ isOpen, onClose, isNarrow }) => {
  const [tabs, setTabs] = useState<TabItem[]>([
    { id: 'tab-files', type: 'files', title: 'Files' },
    { id: 'tab-browser', type: 'browser', title: 'Browser' },
  ]);
  const [activeTabId, setActiveTabId] = useState<string>('tab-files');
  const [selectedFile, setSelectedFile] = useState<string>('what-is-limare.md');
  const [showAddMenu, setShowAddMenu] = useState<boolean>(false);

  // Markdown view toggle: 'preview' | 'source'
  const [mdViewMode, setMdViewMode] = useState<'preview' | 'source'>('preview');

  // Browser tab state
  const [browserUrl, setBrowserUrl] = useState<string>('https://limare.app/what-is-limare.html');
  const [isReloading, setIsReloading] = useState<boolean>(false);

  if (!isOpen) return null;
  const browserDocument = DOCUMENTS.find(doc => browserUrl.includes(`${doc.stem}.html`)) ?? DOCUMENTS[0];
  const navigateBrowser = (offset: number) => {
    const index = DOCUMENTS.indexOf(browserDocument);
    const doc = DOCUMENTS[(index + offset + DOCUMENTS.length) % DOCUMENTS.length];
    setBrowserUrl(`https://limare.app/${doc.stem}.html`);
  };

  const currentTab = tabs.find((t) => t.id === activeTabId);
  const currentFileItem = FAKE_WORKSPACE_FILES.find((f) => f.path === selectedFile) || FAKE_WORKSPACE_FILES[0];

  const handleCloseTab = (id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    const nextTabs = tabs.filter((t) => t.id !== id);
    setTabs(nextTabs);
    if (activeTabId === id && nextTabs.length > 0) {
      setActiveTabId(nextTabs[0].id);
    }
  };

  const handleAddTab = (type: 'files' | 'browser') => {
    const newId = `tab-${type}-${Date.now()}`;
    const newTab: TabItem = {
      id: newId,
      type,
      title: type === 'files' ? 'Files' : 'Browser',
    };
    setTabs([...tabs, newTab]);
    setActiveTabId(newId);
    setShowAddMenu(false);
  };

  // Open HTML in Browser window
  const openInBrowser = (url: string) => {
    setBrowserUrl(url);
    const existingBrowser = tabs.find((t) => t.type === 'browser');
    if (existingBrowser) {
      setActiveTabId(existingBrowser.id);
    } else {
      const newId = `tab-browser-${Date.now()}`;
      setTabs([...tabs, { id: newId, type: 'browser', title: 'Browser' }]);
      setActiveTabId(newId);
    }
  };

  const handleReloadBrowser = () => {
    setIsReloading(true);
    setTimeout(() => setIsReloading(false), 300);
  };

  return (
    <aside className={`work-surface ${isNarrow ? 'fullscreen' : ''}`}>
      {/* Top Tab Strip */}
      <div className="ws-tab-strip">
        {isNarrow && (
          <button
            className="ws-tab-add"
            onClick={onClose}
            title="Back to conversation"
            style={{ marginRight: 6 }}
          >
            <IconArrowLeft size={14} />
          </button>
        )}

        {tabs.map((tab) => (
          <div
            key={tab.id}
            className={`ws-tab ${tab.id === activeTabId ? 'active' : ''}`}
            onClick={() => setActiveTabId(tab.id)}
          >
            {tab.type === 'files' ? <IconFolder size={13} /> : <IconGlobe size={13} />}
            <span>{tab.title}</span>
            <span
              className="ws-tab-close"
              onClick={(e) => handleCloseTab(tab.id, e)}
            >
              <IconClose size={10} />
            </span>
          </div>
        ))}

        <div style={{ position: 'relative' }}>
          <button
            className="ws-tab-add"
            onClick={() => setShowAddMenu(!showAddMenu)}
            title="Open panel"
          >
            <IconPlus size={13} />
          </button>

          {showAddMenu && (
            <div
              className="candidate-popover"
              style={{
                top: 32,
                bottom: 'auto',
                left: 0,
                width: 140,
                zIndex: 60,
              }}
            >
              <div className="candidate-item" onClick={() => handleAddTab('files')}>
                <IconFolder size={13} /> Files
              </div>
              <div className="candidate-item" onClick={() => handleAddTab('browser')}>
                <IconGlobe size={13} /> Browser
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Surface Content Body */}
      <div className="ws-content">
        {tabs.length === 0 ? (
          <div className="ws-launcher">
            <div
              className="ws-launcher-card"
              onClick={() => handleAddTab('files')}
            >
              <div className="ws-card-left">
                <IconFolder size={20} />
                <div>
                  <div className="ws-card-title">Files</div>
                  <div className="ws-card-desc">Browse workspace documents (.md, .json, .html)</div>
                </div>
              </div>
              <span>›</span>
            </div>

            <div
              className="ws-launcher-card"
              onClick={() => handleAddTab('browser')}
            >
              <div className="ws-card-left">
                <IconGlobe size={20} />
                <div>
                  <div className="ws-card-title">Browser</div>
                  <div className="ws-card-desc">Preview rendered HTML web pages</div>
                </div>
              </div>
              <span>›</span>
            </div>
          </div>
        ) : currentTab?.type === 'files' ? (
          /* Files View: Split Left (Files List) & Right (Code / Formatted Preview) */
          <div style={{ display: 'flex', width: '100%', height: '100%', overflow: 'hidden' }}>
            {/* Left Files Tree */}
            <div
              style={{
                width: 'var(--ws-files-tree-w)',
                borderRight: '1px solid var(--border)',
                backgroundColor: 'var(--surface-2)',
                padding: '8px',
                overflowY: 'auto',
                flexShrink: 0,
              }}
            >
              <div
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  color: 'var(--text-muted)',
                  marginBottom: 8,
                  padding: '2px 6px',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                }}
              >
                <span>WORKSPACE FILES</span>
                <span>{FAKE_WORKSPACE_FILES.length}</span>
              </div>

              {FAKE_WORKSPACE_FILES.map((file) => {
                const isSelected = selectedFile === file.path;
                const fileBadgeClass =
                  file.type === 'markdown'
                    ? 'badge-md'
                    : file.type === 'json'
                    ? 'badge-json'
                    : 'badge-html';

                return (
                  <div
                    key={file.path}
                    onClick={() => {
                      setSelectedFile(file.path);
                      if (file.type === 'html' && file.previewUrl) {
                        setBrowserUrl(file.previewUrl);
                      }
                    }}
                    className={`ws-file-item ${isSelected ? 'active' : ''}`}
                    title={file.path}
                  >
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0, flex: 1 }}>
                      <span className={`ws-file-badge ${fileBadgeClass}`}>
                        {file.type === 'markdown' ? 'MD' : file.type === 'json' ? '{ }' : 'HTML'}
                      </span>
                      <span className="ws-file-name">{file.name}</span>
                    </div>
                    <span className="ws-file-size">{file.size}</span>
                  </div>
                );
              })}
            </div>

            {/* Right File Inspector / Content */}
            <div
              style={{
                flex: 1,
                display: 'flex',
                flexDirection: 'column',
                backgroundColor: 'var(--bg)',
                overflow: 'hidden',
              }}
            >
              {/* Header Bar */}
              <div className="ws-file-header">
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontWeight: 600, fontSize: 13, color: 'var(--text)' }}>
                    {currentFileItem.name}
                  </span>
                  <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
                    {currentFileItem.size}
                  </span>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  {/* Markdown: Preview vs Source switch */}
                  {currentFileItem.type === 'markdown' && (
                    <div className="segmented-control" style={{ transform: 'scale(0.9)', transformOrigin: 'right center' }}>
                      <button
                        className={`segmented-btn ${mdViewMode === 'preview' ? 'active' : ''}`}
                        onClick={() => setMdViewMode('preview')}
                      >
                        Preview
                      </button>
                      <button
                        className={`segmented-btn ${mdViewMode === 'source' ? 'active' : ''}`}
                        onClick={() => setMdViewMode('source')}
                      >
                        Source
                      </button>
                    </div>
                  )}

                  {/* HTML: Quick jump to Browser preview */}
                  {currentFileItem.type === 'html' && currentFileItem.previewUrl && (
                    <button
                      className="header-btn"
                      onClick={() => openInBrowser(currentFileItem.previewUrl!)}
                      style={{
                        backgroundColor: 'var(--accent-soft)',
                        color: 'var(--accent)',
                        borderColor: 'var(--accent)',
                        fontWeight: 600,
                      }}
                      title="Preview this HTML file in Browser window"
                    >
                      <IconGlobe size={12} /> Open in Browser
                    </button>
                  )}
                </div>
              </div>

              {/* Inspector Content Body */}
              <div className="ws-file-body">
                {currentFileItem.type === 'markdown' ? (
                  mdViewMode === 'preview' ? (
                    <div
                      className="markdown-body ws-md-preview"
                      dangerouslySetInnerHTML={{
                        __html: mdParser.render(currentFileItem.content),
                      }}
                    />
                  ) : (
                    <CodeEditorView
                      code={currentFileItem.content}
                      lang="markdown"
                    />
                  )
                ) : currentFileItem.type === 'json' ? (
                  <CodeEditorView
                    code={currentFileItem.content}
                    highlighted={highlightJSON(currentFileItem.content)}
                    lang="json"
                  />
                ) : (
                  <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
                    <div className="ws-html-banner">
                      <span>🌐 Live preview available in Browser window</span>
                      <button
                        className="btn-secondary"
                        style={{ padding: '3px 8px', fontSize: 11 }}
                        onClick={() => openInBrowser(currentFileItem.previewUrl!)}
                      >
                        Launch Browser Tab ↗
                      </button>
                    </div>
                    <div style={{ flex: 1, minHeight: 0 }}>
                      <CodeEditorView
                        code={currentFileItem.content}
                        highlighted={highlightHTML(currentFileItem.content)}
                        lang="html"
                      />
                    </div>
                  </div>
                )}
              </div>
            </div>
          </div>
        ) : (
          /* Browser View: Full Rendered Demonstration Page */
          <div className="ws-browser-container">
            {/* Browser Navigation Header */}
            <div className="ws-browser-bar">
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <button
                  className="ws-nav-btn"
                  title="Back"
                  onClick={() => navigateBrowser(-1)}
                >
                  ←
                </button>
                <button
                  className="ws-nav-btn"
                  title="Forward"
                  onClick={() => navigateBrowser(1)}
                >
                  →
                </button>
                <button
                  className={`ws-nav-btn ${isReloading ? 'spin' : ''}`}
                  title="Reload"
                  onClick={handleReloadBrowser}
                >
                  ↻
                </button>
              </div>

              {/* Address bar */}
              <div className="ws-browser-address-box">
                <span className="ws-lock-icon">🔒</span>
                <span className="ws-url-text">{browserUrl}</span>
              </div>

              {/* Quick page switch pills */}
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                {DOCUMENTS.map(doc => (
                  <button key={doc.id} className={`ws-pill-btn ${browserDocument.id === doc.id ? 'active' : ''}`}
                    onClick={() => setBrowserUrl(`https://limare.app/${doc.stem}.html`)}>
                    {doc.id === 'intro' ? 'Overview' : doc.id === 'privacy' ? 'Privacy' : doc.title}
                  </button>
                ))}
              </div>
            </div>

            {/* Browser Render Canvas */}
            <div className="ws-browser-canvas">
              <div dangerouslySetInnerHTML={{ __html: documentBody(browserDocument) }} />
            </div>
          </div>
        )}
      </div>
    </aside>
  );
};

// Component for Code Viewer with Line Numbers
const CodeEditorView: React.FC<{
  code: string;
  highlighted?: string;
  lang?: string;
}> = ({ code, highlighted }) => {
  const lines = useMemo(() => code.split('\n'), [code]);

  return (
    <div className="code-editor-container">
      {/* Line Numbers */}
      <div className="code-line-numbers">
        {lines.map((_, i) => (
          <div key={i}>{i + 1}</div>
        ))}
      </div>

      {/* Code Text */}
      <div className="code-content-area">
        {highlighted ? (
          <pre
            className="code-highlighted-pre"
            dangerouslySetInnerHTML={{ __html: highlighted }}
          />
        ) : (
          <pre className="code-raw-pre">{code}</pre>
        )}
      </div>
    </div>
  );
};
