import React, { useState, useRef, useEffect } from 'react';
import limareAvatar from '../assets/limare-avatar.png';
import limareAvatarDark from '../assets/limare-avatar-dark.png';
import {
  IconMessage,
  IconGear,
  IconArchive,
  IconSend,
  IconStop,
  IconMoreHorizontal,
  IconSearch,
} from './components/Icons';
import { MarkdownBlockRenderer } from './components/MarkdownRenderer';
import { WorkSurface } from './components/WorkSurface';
import { SettingsView } from './components/SettingsView';
import { classifyIntent, containsCJK } from './data/intent';
import { INTRO_SCRIPT } from './data/introScript';
import { PRIVACY_SCRIPT } from './data/privacyScript';
import { CORPUS_ZH, CORPUS_EN } from './data/corpus';
import {
  FAKE_PROJECTS,
  FAKE_CONVERSATIONS,
  ConversationItem,
} from './data/mockData';
import { ScriptBlock, Script } from './types/script';

export interface ChatMessage {
  id: string;
  sender: 'user' | 'assistant';
  blocks?: ScriptBlock[];
  rawText?: string;
  status?: 'completed' | 'cancelled' | 'interrupted' | 'running';
  modelName?: string;
}

export function App() {
  // Theme & Font Settings
  const [theme, setTheme] = useState<'system' | 'light' | 'dark'>(() => {
    return (localStorage.getItem('limare_theme') as 'system' | 'light' | 'dark') || 'system';
  });
  const [isSystemDark, setIsSystemDark] = useState(() => {
    if (typeof window !== 'undefined' && window.matchMedia) {
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return false;
  });

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    const handleChange = (e: MediaQueryListEvent) => {
      setIsSystemDark(e.matches);
    };
    mediaQuery.addEventListener('change', handleChange);
    return () => mediaQuery.removeEventListener('change', handleChange);
  }, []);

  const isDarkMode = theme === 'dark' || (theme === 'system' && isSystemDark);

  const [fontSize, setFontSize] = useState({
    interface: '13px',
    conversation: '15px',
    code: '13px',
  });

  // Apply theme to html tag
  useEffect(() => {
    localStorage.setItem('limare_theme', theme);
    if (theme === 'system') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', theme);
    }
  }, [theme]);

  // Apply font size overrides
  useEffect(() => {
    document.documentElement.style.setProperty('--fs-interface', fontSize.interface);
    document.documentElement.style.setProperty('--fs-conversation', fontSize.conversation);
    document.documentElement.style.setProperty('--fs-code', fontSize.code);
  }, [fontSize]);

  // Screen View Mode: 'chat' | 'settings'
  const [currentScreen, setCurrentScreen] = useState<'chat' | 'settings'>('chat');

  // Work Surface Panel State (#17-#21)
  const [isWorkSurfaceOpen, setIsWorkSurfaceOpen] = useState(false);
  const [mainAreaWidth, setMainAreaWidth] = useState(1000);

  // Sidebar / Mobile Drawer State (#16)
  const [isSidebarOpenMobile, setIsSidebarOpenMobile] = useState(false);
  const [sidebarSearch, setSidebarSearch] = useState('');

  // Conversations State
  const [conversations, setConversations] = useState<ConversationItem[]>(FAKE_CONVERSATIONS);
  const [activeConvId, setActiveConvId] = useState<string>('c-1');
  const [archivedCount, setArchivedCount] = useState(5);
  const [activeActionMenuConvId, setActiveActionMenuConvId] = useState<string | null>(null);

  // Messages per conversation (in memory)
  const [conversationMessages, setConversationMessages] = useState<Record<string, ChatMessage[]>>({
    'c-1': [
      {
        id: 'init-1',
        sender: 'user',
        rawText: 'What is Limare?',
      },
      {
        id: 'init-2',
        sender: 'assistant',
        blocks: INTRO_SCRIPT,
        status: 'completed',
        modelName: 'claude-sonnet-5',
      },
    ],
    'c-what-is-limare': [
      {
        id: 'wil-u',
        sender: 'user',
        rawText: 'What is Limare?',
      },
      {
        id: 'wil-a',
        sender: 'assistant',
        blocks: INTRO_SCRIPT,
        status: 'completed',
        modelName: 'claude-sonnet-5',
      },
    ],
    'c-privacy-policy': [
      {
        id: 'priv-u',
        sender: 'user',
        rawText: "Limare's privacy policy",
      },
      {
        id: 'priv-a',
        sender: 'assistant',
        blocks: PRIVACY_SCRIPT,
        status: 'completed',
        modelName: 'claude-sonnet-5',
      },
    ],
  });

  // Composer Input & Popover Candidates
  const [inputText, setInputText] = useState('');
  const [isInputFocused, setIsInputFocused] = useState(false);
  const [selectedCandidateIdx, setSelectedCandidateIdx] = useState(0);
  const [selectedModel, setSelectedModel] = useState('claude-sonnet-5');
  const [showModelPicker, setShowModelPicker] = useState(false);

  // Streaming Engine State (Lifted to App layer for §6.3.2 lifecycle)
  const [streamingConvId, setStreamingConvId] = useState<string | null>(null);
  const [streamingBlocks, setStreamingBlocks] = useState<ScriptBlock[]>([]);
  const [currentBlockIdx, setCurrentBlockIdx] = useState<number>(0);
  const [currentStreamText, setCurrentStreamText] = useState<string>('');
  const [isAutoScrollLocked, setIsAutoScrollLocked] = useState(false);

  // Recent random corpus circular buffer (avoid immediate consecutive repeats)
  const recentCorpusRef = useRef<string[]>([]);

  // References
  const transcriptRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const streamAbortControllerRef = useRef<boolean>(false);
  const mainStageRef = useRef<HTMLDivElement>(null);

  // Monitor main area width for side-by-side vs full takeover (#21)
  useEffect(() => {
    const checkWidth = () => {
      if (mainStageRef.current) {
        setMainAreaWidth(mainStageRef.current.clientWidth);
      }
    };
    checkWidth();
    window.addEventListener('resize', checkWidth);
    return () => window.removeEventListener('resize', checkWidth);
  }, []);

  // Filter conversations
  const filteredConversations = conversations.filter((c) =>
    c.title.toLowerCase().includes(sidebarSearch.toLowerCase())
  );

  const activeMessages = conversationMessages[activeConvId] || [];

  // Helper to get active title from normal or project conversations
  const getActiveTitle = () => {
    const normal = conversations.find((c) => c.id === activeConvId);
    if (normal) return normal.title;
    for (const p of FAKE_PROJECTS) {
      const pc = p.conversations.find((c) => c.id === activeConvId);
      if (pc) return pc.title;
    }
    return 'Conversation';
  };

  // Stop currently running stream
  const stopCurrentStream = (reason: 'cancelled' | 'interrupted') => {
    if (!streamingConvId) return;
    streamAbortControllerRef.current = true;

    // Finalize running message
    setConversationMessages((prev) => {
      const msgs = [...(prev[streamingConvId] || [])];
      const lastMsgIdx = msgs.length - 1;
      if (lastMsgIdx >= 0 && msgs[lastMsgIdx].sender === 'assistant') {
        const finalBlocks = [...streamingBlocks];
        // §6.3.1 If current block has >= 2 characters typed, keep as plain text paragraph
        if (currentStreamText.length >= 2) {
          finalBlocks.push({
            kind: 'paragraph',
            md: currentStreamText,
            plain: currentStreamText,
          });
        }
        msgs[lastMsgIdx] = {
          ...msgs[lastMsgIdx],
          blocks: finalBlocks,
          status: reason,
        };
      }
      return { ...prev, [streamingConvId]: msgs };
    });

    setStreamingConvId(null);
    setStreamingBlocks([]);
    setCurrentStreamText('');
  };

  // Dispatch streaming player for a script
  const playScript = async (targetConvId: string, script: Script) => {
    streamAbortControllerRef.current = false;
    setStreamingConvId(targetConvId);
    setStreamingBlocks([]);
    setCurrentBlockIdx(0);
    setCurrentStreamText('');

    const isReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Fast-path for reduced motion: render all blocks at once
    if (isReducedMotion) {
      setConversationMessages((prev) => ({
        ...prev,
        [targetConvId]: [
          ...(prev[targetConvId] || []),
          {
            id: `msg-${Date.now()}`,
            sender: 'assistant',
            blocks: script,
            status: 'completed',
            modelName: selectedModel,
          },
        ],
      }));
      setStreamingConvId(null);
      return;
    }

    // Add running assistant message stub
    const assistantMsgId = `msg-${Date.now()}`;
    setConversationMessages((prev) => ({
      ...prev,
      [targetConvId]: [
        ...(prev[targetConvId] || []),
        {
          id: assistantMsgId,
          sender: 'assistant',
          blocks: [],
          status: 'running',
          modelName: selectedModel,
        },
      ],
    }));

    const committedBlocks: ScriptBlock[] = [];

    for (let bIndex = 0; bIndex < script.length; bIndex++) {
      if (streamAbortControllerRef.current) break;
      const block = script[bIndex];
      setCurrentBlockIdx(bIndex);

      // Delay before block (compressed for blistering ~1000 tok/s throughput)
      if (block.delayBefore) {
        await new Promise((res) => setTimeout(res, Math.min((block.delayBefore ?? 0) * 0.15, 20)));
        if (streamAbortControllerRef.current) break;
      }

      // If code or table, insert instantaneously without character streaming
      if (block.kind === 'code' || block.kind === 'table') {
        committedBlocks.push(block);
        setStreamingBlocks([...committedBlocks]);
        continue;
      }

      // For paragraph, heading, list, quote, link: stream chunk by chunk (~1000 tokens/s speed)
      const plainText = block.plain || block.md;
      let curPos = 0;

      while (curPos < plainText.length) {
        if (streamAbortControllerRef.current) break;

        // Advance 7-13 characters per tick to simulate token bursts
        const chunkSize = Math.floor(Math.random() * 7) + 7;
        curPos = Math.min(curPos + chunkSize, plainText.length);
        setCurrentStreamText(plainText.slice(0, curPos));

        // Auto-scroll if not locked
        if (!isAutoScrollLocked && transcriptRef.current) {
          transcriptRef.current.scrollTop = transcriptRef.current.scrollHeight;
        }

        if (curPos < plainText.length) {
          await new Promise((res) => setTimeout(res, 8));
        }
      }

      if (streamAbortControllerRef.current) break;

      // On block completion, swap in complete Markdown
      committedBlocks.push(block);
      setStreamingBlocks([...committedBlocks]);
      setCurrentStreamText('');
      await new Promise((res) => setTimeout(res, 20));
    }

    if (!streamAbortControllerRef.current) {
      // Completed successfully
      setConversationMessages((prev) => {
        const msgs = [...(prev[targetConvId] || [])];
        const lastIdx = msgs.length - 1;
        if (lastIdx >= 0) {
          msgs[lastIdx] = {
            ...msgs[lastIdx],
            blocks: committedBlocks,
            status: 'completed',
          };
        }
        return { ...prev, [targetConvId]: msgs };
      });
      setStreamingConvId(null);
      setStreamingBlocks([]);
      setCurrentStreamText('');

      // Auto-scroll to bottom on finish
      if (transcriptRef.current) {
        transcriptRef.current.scrollTop = transcriptRef.current.scrollHeight;
      }
    }
  };

  // Pick random sentence avoiding immediate repeats
  const pickRandomCorpus = (rawInput: string): string => {
    const isCJK = containsCJK(rawInput);
    const pool = isCJK ? CORPUS_ZH : CORPUS_EN;
    const candidates = pool.filter((item) => !recentCorpusRef.current.includes(item));
    const finalPool = candidates.length > 0 ? candidates : pool;
    const picked = finalPool[Math.floor(Math.random() * finalPool.length)];

    recentCorpusRef.current.push(picked);
    if (recentCorpusRef.current.length > 5) {
      recentCorpusRef.current.shift();
    }
    return picked;
  };

  // Submit message handler
  const handleSendMessage = (messageText: string) => {
    const trimmed = messageText.trim();
    if (!trimmed) return;

    // If currently running, stop it
    if (streamingConvId) {
      stopCurrentStream('cancelled');
      return;
    }

    const intent = classifyIntent(trimmed);

    // Append user message
    const userMsg: ChatMessage = {
      id: `usr-${Date.now()}`,
      sender: 'user',
      rawText: trimmed,
    };

    setConversationMessages((prev) => ({
      ...prev,
      [activeConvId]: [...(prev[activeConvId] || []), userMsg],
    }));

    setInputText('');
    setIsInputFocused(false);

    // Route Script
    let targetScript: Script = [];
    if (intent === 'intro') {
      targetScript = INTRO_SCRIPT;
    } else if (intent === 'privacy') {
      targetScript = PRIVACY_SCRIPT;
    } else {
      const sentence = pickRandomCorpus(trimmed);
      targetScript = [
        {
          kind: 'paragraph',
          md: sentence,
          plain: sentence,
          delayBefore: 60,
        },
      ];
    }

    playScript(activeConvId, targetScript);
  };

  // Conversation action handlers
  const handleNewConversation = () => {
    if (streamingConvId) {
      stopCurrentStream('interrupted');
    }
    const newId = `c-${Date.now()}`;
    const newConv: ConversationItem = {
      id: newId,
      title: 'New Conversation',
      updatedAt: 'Just now',
    };
    setConversations([newConv, ...conversations]);
    setActiveConvId(newId);
    setConversationMessages((prev) => ({ ...prev, [newId]: [] }));
  };

  const handleSelectConversation = (id: string) => {
    if (streamingConvId && streamingConvId !== id) {
      stopCurrentStream('interrupted');
    }
    setActiveConvId(id);
    setIsSidebarOpenMobile(false);
  };

  const handleArchiveConversation = (id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    if (streamingConvId === id) {
      stopCurrentStream('interrupted');
    }
    setConversations(conversations.filter((c) => c.id !== id));
    setArchivedCount((prev) => prev + 1);
    setActiveActionMenuConvId(null);
    if (activeConvId === id) {
      const remaining = conversations.filter((c) => c.id !== id);
      if (remaining.length > 0) {
        setActiveConvId(remaining[0].id);
      } else {
        handleNewConversation();
      }
    }
  };

  // Keyboard shortcut & Global / Handler
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Global '/' focus candidate popover if not in input/textarea (K5)
      if (
        e.key === '/' &&
        document.activeElement?.tagName !== 'INPUT' &&
        document.activeElement?.tagName !== 'TEXTAREA'
      ) {
        e.preventDefault();
        inputRef.current?.focus();
        setIsInputFocused(true);
        return;
      }

      // Global Esc handling (K3)
      if (e.key === 'Escape') {
        if (showModelPicker) {
          setShowModelPicker(false);
          return;
        }
        if (activeActionMenuConvId) {
          setActiveActionMenuConvId(null);
          return;
        }
        if (isInputFocused) {
          setIsInputFocused(false);
          // Draft retained, do not clear
          return;
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [showModelPicker, activeActionMenuConvId, isInputFocused]);

  const candidates = ['What is Limare?', "Limare's privacy policy"];

  return (
    <div className="window-frame">
      {/* Title Bar */}
      <header className="titlebar">
        <div className="titlebar-left">
          <img
            src={isDarkMode ? limareAvatarDark : limareAvatar}
            alt="Limare"
            className="app-icon-img"
          />
          <span className="app-title">Limare</span>
          <span className="demo-badge">Demo</span>
        </div>

        <div className="titlebar-center">
          {getActiveTitle()}
        </div>

        <div className="titlebar-right">
          {/* Work Surface Toggle Button (#17) */}
          <button
            className={`header-btn ${isWorkSurfaceOpen ? 'active' : ''}`}
            onClick={() => setIsWorkSurfaceOpen(!isWorkSurfaceOpen)}
            title="Toggle Work Surface"
          >
            Work Surface
          </button>
        </div>
      </header>

      {/* Main App Body */}
      <div className="app-body">
          {currentScreen === 'settings' ? (
            <SettingsView
              onBack={() => setCurrentScreen('chat')}
              theme={theme}
              setTheme={setTheme}
              fontSize={fontSize}
              setFontSize={setFontSize}
            />
          ) : (
            <>
              {/* Sidebar */}
              <aside className={`sidebar ${isSidebarOpenMobile ? 'open' : ''}`}>
                <div className="sidebar-header">
                  <button className="new-conv-btn" onClick={handleNewConversation}>
                    <IconMessage size={14} /> New Conversation
                  </button>
                  <div className="sidebar-search">
                    <IconSearch size={13} />
                    <input
                      placeholder="Search (⌘K)"
                      value={sidebarSearch}
                      onChange={(e) => setSidebarSearch(e.target.value)}
                    />
                  </div>
                </div>

                <div className="sidebar-content">
                  {/* Projects Section */}
                  <div>
                    <div className="sidebar-section-title">
                      <span>Projects</span>
                      <span>+</span>
                    </div>
                    {FAKE_PROJECTS.map((p) => (
                      <div key={p.id}>
                        <div className="sidebar-item" style={{ fontWeight: 600 }}>
                          <span className="sidebar-item-title">📁 {p.name}</span>
                        </div>
                        {p.conversations.map((pc) => (
                          <div
                            key={pc.id}
                            style={{ paddingLeft: 22 }}
                            className={`sidebar-item ${pc.id === activeConvId ? 'active' : ''}`}
                            onClick={() => {
                              setActiveConvId(pc.id);
                              setIsSidebarOpenMobile(false);
                            }}
                          >
                            <span className="sidebar-item-title">💬 {pc.title}</span>
                          </div>
                        ))}
                      </div>
                    ))}
                  </div>

                  {/* Conversations Section */}
                  <div>
                    <div className="sidebar-section-title">
                      <span>Conversations</span>
                      <span>+</span>
                    </div>
                    {filteredConversations.length === 0 ? (
                      <div style={{ padding: '8px 12px', fontSize: 12, color: 'var(--text-muted)' }}>
                        No conversations found
                      </div>
                    ) : (
                      filteredConversations.map((conv) => (
                        <div
                          key={conv.id}
                          className={`sidebar-item ${conv.id === activeConvId ? 'active' : ''}`}
                          onClick={() => handleSelectConversation(conv.id)}
                        >
                          <span className="sidebar-item-title">💬 {conv.title}</span>
                          <span
                            className="sidebar-item-actions"
                            onClick={(e) => {
                              e.stopPropagation();
                              setActiveActionMenuConvId(
                                activeActionMenuConvId === conv.id ? null : conv.id
                              );
                            }}
                          >
                            <IconMoreHorizontal size={14} />
                          </span>

                          {/* Context Action Menu (#3, #12) */}
                          {activeActionMenuConvId === conv.id && (
                            <div
                              className="action-menu"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <div
                                className="action-menu-item"
                                onClick={(e) => handleArchiveConversation(conv.id, e)}
                              >
                                <IconArchive size={14} />
                                <span>Archive</span>
                              </div>
                            </div>
                          )}
                        </div>
                      ))
                    )}
                  </div>
                </div>

                <div className="sidebar-footer">
                  <div className="sidebar-item" style={{ color: 'var(--text-2)' }}>
                    <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <IconArchive size={14} /> Archived Conversations
                    </span>
                    <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>
                      {archivedCount}
                    </span>
                  </div>
                  <div
                    className="sidebar-item"
                    onClick={() => setCurrentScreen('settings')}
                    style={{ color: 'var(--text)' }}
                  >
                    <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <IconGear size={14} /> Settings
                    </span>
                  </div>
                </div>
              </aside>

              {/* Chat Main Area + Work Surface */}
              <div className="main-stage" ref={mainStageRef}>
                {/* Check if WorkSurface should take over entire main stage (#21) */}
                {isWorkSurfaceOpen && mainAreaWidth < 708 ? (
                  <WorkSurface
                    isOpen={isWorkSurfaceOpen}
                    onClose={() => setIsWorkSurfaceOpen(false)}
                    isNarrow={true}
                  />
                ) : (
                  <>
                    <main className="chat-container">
                      <div className="chat-header">
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                          <button
                            className="header-btn"
                            style={{ display: window.innerWidth < 720 ? 'flex' : 'none' }}
                            onClick={() => setIsSidebarOpenMobile(!isSidebarOpenMobile)}
                          >
                            ☰
                          </button>
                          <span>
                            {getActiveTitle()}
                          </span>
                        </div>
                      </div>

                      {/* Messages Transcript */}
                      <div
                        className="transcript-area"
                        ref={transcriptRef}
                        onScroll={() => {
                          if (transcriptRef.current) {
                            const { scrollTop, scrollHeight, clientHeight } = transcriptRef.current;
                            const isAtBottom = scrollHeight - scrollTop - clientHeight < 80;
                            setIsAutoScrollLocked(!isAtBottom);
                          }
                        }}
                      >
                        <div className="transcript-inner">
                          {activeMessages.length === 0 && !streamingConvId && (
                            <div className="chat-empty-state">
                              <div className="chat-empty-icon">
                                <img
                                  src={isDarkMode ? limareAvatarDark : limareAvatar}
                                  alt="Limare"
                                  className="chat-empty-app-icon"
                                />
                              </div>
                              <div className="chat-empty-title">Start a conversation</div>
                              <div className="chat-empty-subtitle">
                                Desktop harness tools are active. Type a message below to begin.
                              </div>
                            </div>
                          )}

                          {activeMessages.map((msg) => (
                            <div
                              key={msg.id}
                              className={`message-row ${msg.sender === 'user' ? 'user' : 'assistant'}`}
                            >
                              {msg.sender === 'user' ? (
                                <div className="user-bubble">{msg.rawText}</div>
                              ) : (
                                <div className="assistant-body">
                                  {msg.blocks?.map((block, idx) => (
                                    <MarkdownBlockRenderer key={idx} block={block} />
                                  ))}
                                  {msg.status && (
                                    <div className="status-line">
                                      <span
                                        className={`status-dot ${
                                          msg.status === 'running' ? 'active' : ''
                                        }`}
                                      />
                                      <span>
                                        {msg.modelName || selectedModel} ·{' '}
                                        {msg.status === 'completed'
                                          ? 'Done'
                                          : msg.status === 'cancelled'
                                          ? 'Cancelled'
                                          : msg.status === 'interrupted'
                                          ? 'Interrupted'
                                          : 'Generating...'}
                                      </span>
                                    </div>
                                  )}
                                </div>
                              )}
                            </div>
                          ))}

                          {/* Live Streaming Render for Active Conversation */}
                          {streamingConvId === activeConvId && (
                            <div className="message-row assistant">
                              <div className="assistant-body">
                                {streamingBlocks.map((block, idx) => (
                                  <MarkdownBlockRenderer key={idx} block={block} />
                                ))}
                                {currentStreamText !== '' && (
                                  <MarkdownBlockRenderer
                                    block={
                                      INTRO_SCRIPT[currentBlockIdx] || {
                                        kind: 'paragraph',
                                        md: currentStreamText,
                                      }
                                    }
                                    isStreaming={true}
                                    streamText={currentStreamText}
                                  />
                                )}
                                <div className="status-line">
                                  <span className="status-dot active" />
                                  <span>{selectedModel} · Generating...</span>
                                </div>
                              </div>
                            </div>
                          )}
                        </div>
                      </div>

                      {/* Composer Dock */}
                      <div className="composer-dock">
                        {/* Scroll To Bottom Button */}
                        {isAutoScrollLocked && (
                          <button
                            className="scroll-bottom-btn"
                            onClick={() => {
                              if (transcriptRef.current) {
                                transcriptRef.current.scrollTop =
                                  transcriptRef.current.scrollHeight;
                                setIsAutoScrollLocked(false);
                              }
                            }}
                          >
                            ↓ Jump to Latest
                          </button>
                        )}

                        <div className="composer-box">
                          {/* Candidates Popover (#2, §6.2) */}
                          {isInputFocused && inputText.trim() === '' && (
                            <div className="candidate-popover">
                              {candidates.map((cand, idx) => (
                                <div
                                  key={cand}
                                  className={`candidate-item ${
                                    selectedCandidateIdx === idx ? 'highlighted' : ''
                                  }`}
                                  onMouseDown={(e) => {
                                    e.preventDefault();
                                    handleSendMessage(cand);
                                  }}
                                >
                                  <span>✦</span>
                                  <span>{cand}</span>
                                </div>
                              ))}
                              <div className="candidate-footer">
                                Or type anything for a random sentence...
                              </div>
                            </div>
                          )}

                          <textarea
                            ref={inputRef}
                            className="composer-input"
                            placeholder="Message Limare... (Shift+Return for new line)"
                            value={inputText}
                            rows={1}
                            onFocus={() => setIsInputFocused(true)}
                            onBlur={() => {
                              // delay slightly so mouse clicks on candidate fire
                              setTimeout(() => setIsInputFocused(false), 200);
                            }}
                            onChange={(e) => setInputText(e.target.value)}
                            onKeyDown={(e) => {
                              // K1: Check composition
                              if (e.nativeEvent.isComposing) {
                                return;
                              }

                              // K4: Candidates arrow navigation
                              if (isInputFocused && inputText.trim() === '') {
                                if (e.key === 'ArrowDown') {
                                  e.preventDefault();
                                  setSelectedCandidateIdx((prev) => (prev + 1) % candidates.length);
                                  return;
                                }
                                if (e.key === 'ArrowUp') {
                                  e.preventDefault();
                                  setSelectedCandidateIdx(
                                    (prev) => (prev - 1 + candidates.length) % candidates.length
                                  );
                                  return;
                                }
                                if (e.key === 'Enter' && !e.shiftKey) {
                                  e.preventDefault();
                                  handleSendMessage(candidates[selectedCandidateIdx]);
                                  return;
                                }
                              }

                              // Enter to send or stop
                              if (e.key === 'Enter' && !e.shiftKey) {
                                e.preventDefault();
                                if (streamingConvId) {
                                  stopCurrentStream('cancelled');
                                } else {
                                  handleSendMessage(inputText);
                                }
                              }
                            }}
                          />

                          <div className="composer-toolbar">
                            <div style={{ position: 'relative' }}>
                              <div
                                className="model-chip"
                                onClick={() => setShowModelPicker(!showModelPicker)}
                              >
                                <span>🧠</span>
                                <span>{selectedModel}</span>
                              </div>

                              {showModelPicker && (
                                <div
                                  className="candidate-popover"
                                  style={{
                                    bottom: 'calc(100% + 4px)',
                                    width: 180,
                                  }}
                                >
                                  {['claude-sonnet-5', 'gpt-5.6-sol', 'gemini-3-flash', 'deepseek-v4'].map(
                                    (m) => (
                                      <div
                                        key={m}
                                        className="candidate-item"
                                        onClick={() => {
                                          setSelectedModel(m);
                                          setShowModelPicker(false);
                                        }}
                                      >
                                        {m} {selectedModel === m ? '✓' : ''}
                                      </div>
                                    )
                                  )}
                                </div>
                              )}
                            </div>

                            <button
                              className={`send-btn ${
                                streamingConvId
                                  ? 'stop'
                                  : inputText.trim()
                                  ? 'ready'
                                  : ''
                              }`}
                              onClick={() => {
                                if (streamingConvId) {
                                  stopCurrentStream('cancelled');
                                } else {
                                  handleSendMessage(inputText);
                                }
                              }}
                              title={streamingConvId ? 'Stop Generation' : 'Send Message'}
                            >
                              {streamingConvId ? <IconStop size={12} /> : <IconSend size={13} />}
                            </button>
                          </div>
                        </div>

                        <div className="composer-disclaimer">
                          <div>Limare can make mistakes. Review tool calls before relying on changes.</div>
                          <div className="demo-license-note">
                            Interactive UI Demo · Simulated Data · GPLv3 ·{' '}
                            <a
                              href="/download/"
                            >
                              Source and release preparation
                            </a>
                            {' · '}<a href="/privacy/">Privacy</a>
                            {' · '}<a href="/security/">Security</a>
                            {' · '}<a href="/support/">Support</a>
                            {' · '}0.1.0
                          </div>
                        </div>
                      </div>
                    </main>

                    {/* Work Surface Panel (Side-by-side mode) */}
                    <WorkSurface
                      isOpen={isWorkSurfaceOpen}
                      onClose={() => setIsWorkSurfaceOpen(false)}
                      isNarrow={false}
                    />
                  </>
                )}
              </div>
            </>
          )}
        </div>
    </div>
  );
}
export default App;
