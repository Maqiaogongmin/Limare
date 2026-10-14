import React, { useState } from 'react';
import limareAvatar from '../../assets/limare-avatar.png';
import limareAvatarDark from '../../assets/limare-avatar-dark.png';
import {
  IconArrowLeft,
  IconGear,
  IconSearch,
} from './Icons';

export type SettingsScreen =
  | 'general'
  | 'personalization'
  | 'permissions'
  | 'remote-access'
  | 'providers'
  | 'model-groups'
  | 'skills'
  | 'mcp'
  | 'hooks'
  | 'logs';

interface SettingsViewProps {
  onBack: () => void;
  theme: 'system' | 'light' | 'dark';
  setTheme: (t: 'system' | 'light' | 'dark') => void;
  fontSize: { interface: string; conversation: string; code: string };
  setFontSize: React.Dispatch<
    React.SetStateAction<{ interface: string; conversation: string; code: string }>
  >;
}

export const SettingsView: React.FC<SettingsViewProps> = ({
  onBack,
  theme,
  setTheme,
  fontSize,
  setFontSize,
}) => {
  const [activeTab, setActiveTab] = useState<SettingsScreen>('general');
  const isDarkMode = theme === 'dark' || (theme === 'system' && typeof window !== 'undefined' && window.matchMedia('(prefers-color-scheme: dark)').matches);

  // Search states for simulated views
  const [providerSearch, setProviderSearch] = useState('');
  const [skillSearch, setSkillSearch] = useState('');
  const [mcpSearch, setMcpSearch] = useState('');
  const [hookSearch, setHookSearch] = useState('');
  const [logSearch, setLogSearch] = useState('');

  // Interactive toggle feedbacks
  const [computerUseEnabled, setComputerUseEnabled] = useState(true);
  const [activePermissionMode, setActivePermissionMode] = useState<'Ask for approval' | 'Approve for me' | 'Full access'>('Full access');
  const [remoteAccessEnabled, setRemoteAccessEnabled] = useState(true);
  const [showAddProviderModal, setShowAddProviderModal] = useState(false);

  // Selected item states
  const [selectedProviderId, setSelectedProviderId] = useState('p-anthropic');
  const [selectedSkillFilter, setSelectedSkillFilter] = useState<'All' | 'Project' | 'Global'>('All');
  const [selectedModelGroup, setSelectedModelGroup] = useState('chat');

  // Realistic mock data matching actual screenshots with 10 industry leaders (Hohai removed, 7 added)
  const mockProviders = [
    {
      id: 'p-anthropic',
      name: 'Anthropic',
      modelsCount: 9,
      url: 'https://api.anthropic.com',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'claude-sonnet-5', context: '1M context · Flagship reasoning' },
        { name: 'claude-opus-5', context: '1M context · Deep autonomous reasoning' },
        { name: 'claude-haiku-4-5', context: '200K context · Low latency' },
      ],
    },
    {
      id: 'p-openai',
      name: 'OpenAI',
      modelsCount: 15,
      url: 'https://api.openai.com/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'gpt-5.6-sol', context: '400K context · Next-gen frontier' },
        { name: 'gpt-5.5', context: '400K context · Multimodal reasoning' },
        { name: 'o4-mini', context: '200K context · Fast reasoning' },
      ],
    },
    {
      id: 'p-deepseek',
      name: 'DeepSeek',
      modelsCount: 4,
      url: 'https://api.deepseek.com',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'deepseek-v4', context: '128K context · 1T MoE reasoning' },
        { name: 'deepseek-reasoner (R2)', context: '128K context · Autonomous reasoning' },
      ],
    },
    {
      id: 'p-gemini',
      name: 'Google Gemini',
      modelsCount: 48,
      url: 'https://generativelanguage.googleapis.com',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'gemini-3.1-pro', context: '2M context · Native multimodal reasoning' },
        { name: 'gemini-3-flash', context: '1M context · Ultra low latency' },
      ],
    },
    {
      id: 'p-ollama',
      name: 'Ollama (Local)',
      modelsCount: 8,
      url: 'http://localhost:11434',
      service: 'Custom / Local',
      sampleModels: [
        { name: 'deepseek-v4:16b', context: '128K context · 100% offline' },
        { name: 'llama4:70b', context: '128K context · Local host' },
      ],
    },
    {
      id: 'p-xai',
      name: 'xAI (Grok)',
      modelsCount: 6,
      url: 'https://api.x.ai/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'grok-4.6', context: '256K context · SOTA code & vision' },
        { name: 'grok-4-mini', context: '256K context · Fast reasoning' },
      ],
    },
    {
      id: 'p-groq',
      name: 'Groq',
      modelsCount: 12,
      url: 'https://api.groq.com/openai/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'llama-4-scout-versatile', context: '128K context · ~1,500 T/s LPU' },
        { name: 'deepseek-v4-distill-llama-70b', context: '128K context · Ultra fast' },
      ],
    },
    {
      id: 'p-mistral',
      name: 'Mistral AI',
      modelsCount: 16,
      url: 'https://api.mistral.ai/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'mistral-large-3', context: '256K context · Multilingual agent' },
        { name: 'codestral-25', context: '256K context · Advanced code synthesis' },
      ],
    },
    {
      id: 'p-together',
      name: 'Together AI',
      modelsCount: 92,
      url: 'https://api.together.xyz/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'meta-llama/Llama-4-Scout-Instruct', context: '128K context' },
        { name: 'deepseek-ai/DeepSeek-V4', context: '128K context' },
      ],
    },
    {
      id: 'p-openrouter',
      name: 'OpenRouter',
      modelsCount: 135,
      url: 'https://openrouter.ai/api/v1',
      service: 'Direct Cloud',
      sampleModels: [
        { name: 'anthropic/claude-sonnet-5', context: '1M context · Fallback auto' },
        { name: 'openai/gpt-5.6-sol', context: '400K context · Route load balancing' },
      ],
    },
  ];

  const mockSkills = [
    { id: 's-1', name: 'agent-reach', scope: 'Global', desc: 'MUST USE when user wants to research/search on the internet', checked: true },
    { id: 's-2', name: 'cua-driver', scope: 'Global', desc: 'Required host-generated bearer token when local MCP endpoint is enabled.', checked: false },
    { id: 's-3', name: 'find-skills', scope: 'Global', desc: 'Helps users discover and install agent skills', checked: true },
    { id: 's-4', name: 'flutter-add-integration-test', scope: 'Global', desc: 'Configures Flutter Driver for permanent integration tests.', checked: false },
    { id: 's-5', name: 'flutter-fix-layout-issues', scope: 'Global', desc: 'Fixes Flutter layout errors using Dart and Flutter MCP tools.', checked: false },
  ];

  const mockMcps = [
    { id: 'm-1', name: 'github', type: 'Local Command', tools: 27, connected: true },
    { id: 'm-2', name: 'github-test', type: 'Remote Server', tools: 46, connected: true },
    { id: 'm-3', name: 'huggingface', type: 'Remote Server', tools: 4, connected: true },
  ];

  const mockHooks = [
    { id: 'h-1', name: 'agentmemory', type: 'Imported Package', trusted: true, automations: 6, checked: true },
  ];

  const mockLogs = [
    { id: 'l-1', tag: 'ContextLifecycle', time: '09:15:33', level: 'INFO', msg: 'model=deepseek-flash window=1000000 estimated=316143 budget=878217 factor=1.0' },
    { id: 'l-2', tag: 'Permission', time: '09:15:40', level: 'INFO', msg: 'Full Access active; bypassed approval for shell_execute.' },
    { id: 'l-3', tag: 'Tool', time: '09:15:40', level: 'INFO', msg: 'Starting shell_execute in the selected demo workspace.' },
    { id: 'l-4', tag: 'Tool', time: '09:15:40', level: 'INFO', msg: 'shell_execute finished with exit code 0.' },
    { id: 'l-5', tag: 'Hooks', time: '09:15:40', level: 'INFO', msg: 'Hook completed: source="agentmemory", event="PostToolUse", duration=175.6ms' },
  ];

  return (
    <div className="settings-view">
      <nav className="settings-sidebar">
        <button className="settings-back-btn" onClick={onBack}>
          <IconArrowLeft size={14} /> Back to Limare
        </button>

        <div className="settings-nav-group-title">Preferences</div>
        <div
          className={`settings-nav-item ${activeTab === 'general' ? 'active' : ''}`}
          onClick={() => setActiveTab('general')}
        >
          <IconGear size={14} /> General
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'personalization' ? 'active' : ''}`}
          onClick={() => setActiveTab('personalization')}
        >
          Personalization
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'permissions' ? 'active' : ''}`}
          onClick={() => setActiveTab('permissions')}
        >
          Permissions
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'remote-access' ? 'active' : ''}`}
          onClick={() => setActiveTab('remote-access')}
        >
          Remote Access
        </div>

        <div className="settings-nav-group-title">Models</div>
        <div
          className={`settings-nav-item ${activeTab === 'providers' ? 'active' : ''}`}
          onClick={() => setActiveTab('providers')}
        >
          Providers
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'model-groups' ? 'active' : ''}`}
          onClick={() => setActiveTab('model-groups')}
        >
          Model Groups
        </div>

        <div className="settings-nav-group-title">Extensions</div>
        <div
          className={`settings-nav-item ${activeTab === 'skills' ? 'active' : ''}`}
          onClick={() => setActiveTab('skills')}
        >
          Skills
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'mcp' ? 'active' : ''}`}
          onClick={() => setActiveTab('mcp')}
        >
          MCP
        </div>
        <div
          className={`settings-nav-item ${activeTab === 'hooks' ? 'active' : ''}`}
          onClick={() => setActiveTab('hooks')}
        >
          Hooks
        </div>

        <div className="settings-nav-group-title">Advanced</div>
        <div
          className={`settings-nav-item ${activeTab === 'logs' ? 'active' : ''}`}
          onClick={() => setActiveTab('logs')}
        >
          Logs
        </div>
      </nav>

      <main className="settings-detail">
        <div className="settings-page-inner">
          {/* General Page */}
          {activeTab === 'general' && (
            <>
              <h2 className="settings-page-title">General</h2>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Appearance</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Theme</div>
                      <div className="settings-row-sub">Controls how Limare looks.</div>
                    </div>
                    <div className="segmented-control">
                      <button
                        className={`segmented-btn ${theme === 'system' ? 'active' : ''}`}
                        onClick={() => setTheme('system')}
                      >
                        System
                      </button>
                      <button
                        className={`segmented-btn ${theme === 'light' ? 'active' : ''}`}
                        onClick={() => setTheme('light')}
                      >
                        Light
                      </button>
                      <button
                        className={`segmented-btn ${theme === 'dark' ? 'active' : ''}`}
                        onClick={() => setTheme('dark')}
                      >
                        Dark
                      </button>
                    </div>
                  </div>

                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Interface</div>
                      <div className="settings-row-sub">Controls text used across navigation, settings, controls and supporting UI.</div>
                    </div>
                    <select
                      className="select-control"
                      value={fontSize.interface}
                      onChange={(e) =>
                        setFontSize((prev) => ({ ...prev, interface: e.target.value }))
                      }
                    >
                      <option value="12px">12 pt</option>
                      <option value="13px">13 pt</option>
                      <option value="14px">14 pt</option>
                      <option value="15px">15 pt</option>
                    </select>
                  </div>

                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Conversation</div>
                      <div className="settings-row-sub">Controls user messages, Agent responses and rich-text reading surfaces.</div>
                    </div>
                    <select
                      className="select-control"
                      value={fontSize.conversation}
                      onChange={(e) =>
                        setFontSize((prev) => ({ ...prev, conversation: e.target.value }))
                      }
                    >
                      <option value="14px">14 pt</option>
                      <option value="15px">15 pt</option>
                      <option value="16px">16 pt</option>
                    </select>
                  </div>

                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Code</div>
                      <div className="settings-row-sub">Controls code blocks, source views and diff/code-oriented surfaces.</div>
                    </div>
                    <select
                      className="select-control"
                      value={fontSize.code}
                      onChange={(e) =>
                        setFontSize((prev) => ({ ...prev, code: e.target.value }))
                      }
                    >
                      <option value="12px">12 pt</option>
                      <option value="13px">13 pt</option>
                      <option value="14px">14 pt</option>
                    </select>
                  </div>
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Composer & Run</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">When Agent is Running</div>
                      <div className="settings-row-sub">Injects the instruction immediately into the currently active run.</div>
                    </div>
                    <select className="select-control" defaultValue="Steer active turn">
                      <option>Steer active turn</option>
                      <option>Queue message</option>
                    </select>
                  </div>
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Capabilities</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Computer Use</div>
                      <div className="settings-row-sub">Allow Limare to use desktop observation and control when a task requires it.</div>
                    </div>
                    <label className="switch">
                      <input
                        type="checkbox"
                        checked={computerUseEnabled}
                        onChange={(e) => setComputerUseEnabled(e.target.checked)}
                      />
                      <span className="slider"></span>
                    </label>
                  </div>
                  {computerUseEnabled && (
                    <div className="inline-status">
                      ✓ Ready. Each action still requires app approval and the current permission mode.
                    </div>
                  )}
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Workspace</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-info">
                      <div className="settings-row-label">Default Workspace</div>
                      <div className="settings-row-sub">No default workspace selected. Standalone conversations use the existing fallback behavior.</div>
                    </div>
                    <button className="btn-secondary">Choose...</button>
                  </div>
                </div>
              </div>
            </>
          )}

          {/* Personalization Page */}
          {activeTab === 'personalization' && (
            <>
              <h2 className="settings-page-title">Personalization</h2>

              <div className="settings-card" style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
                <div
                  style={{
                    width: 44,
                    height: 44,
                    borderRadius: '50%',
                    backgroundColor: 'var(--surface-2)',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    border: '1px solid var(--border-light)',
                    flexShrink: 0,
                  }}
                >
                  <img
                    src={isDarkMode ? limareAvatarDark : limareAvatar}
                    alt="Limare"
                    style={{
                      width: 32,
                      height: 32,
                      objectFit: 'contain',
                    }}
                  />
                </div>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 600 }}>
                    Limare <span style={{ fontSize: 10, padding: '2px 6px', background: 'var(--border)', borderRadius: 4 }}>AUTO</span>
                  </div>
                  <div style={{ fontSize: 13, color: 'var(--text-2)' }}>No custom response style set.</div>
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Identity</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-label">Avatar</div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <div
                        style={{
                          width: 28,
                          height: 28,
                          borderRadius: '50%',
                          backgroundColor: 'var(--surface-2)',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          border: '1px solid var(--border-light)',
                          flexShrink: 0,
                        }}
                      >
                        <img
                          src={isDarkMode ? limareAvatarDark : limareAvatar}
                          alt="Limare"
                          style={{
                            width: 20,
                            height: 20,
                            objectFit: 'contain',
                          }}
                        />
                      </div>
                      <button className="btn-secondary">Change Avatar...</button>
                    </div>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Name</div>
                    <input className="input-control" defaultValue="Limare" style={{ maxWidth: 380 }} />
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Style</div>
                    <input className="input-control" placeholder="e.g. Warm, direct, opinionated" style={{ maxWidth: 380 }} />
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Language</div>
                    <select className="select-control" defaultValue="Auto" style={{ width: 100 }}>
                      <option>Auto</option>
                      <option>English</option>
                      <option>中文</option>
                    </select>
                  </div>
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header" style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <div className="settings-section-title">Personality Prompt</div>
                  <span style={{ fontSize: 12, color: 'var(--text-muted)' }}>0 / 2,000 tokens</span>
                </div>
                <div className="settings-card">
                  <textarea
                    className="input-control"
                    rows={7}
                    placeholder="Describe how Limare should think, behave, and converse..."
                    style={{ resize: 'none' }}
                  />
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 10 }}>
                  <button className="btn-secondary">↺ Restore Default</button>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button className="btn-secondary">Reload</button>
                    <button className="btn-secondary" style={{ backgroundColor: '#007aff', color: '#fff', border: 'none' }}>Save</button>
                  </div>
                </div>
              </div>
            </>
          )}

          {/* Permissions Page */}
          {activeTab === 'permissions' && (
            <>
              <h2 className="settings-page-title">Permissions</h2>
              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Permission Modes</div>
                </div>
                <div className="settings-card" style={{ gap: 16 }}>
                  {/* Mode 1 */}
                  <div
                    style={{ display: 'flex', gap: 12, cursor: 'pointer' }}
                    onClick={() => setActivePermissionMode('Ask for approval')}
                  >
                    <input type="radio" checked={activePermissionMode === 'Ask for approval'} readOnly style={{ marginTop: 4 }} />
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                      <div style={{ fontWeight: 600, fontSize: 14, display: 'flex', alignItems: 'center', gap: 6 }}>
                        Ask for approval <span style={{ fontSize: 11, padding: '1px 6px', background: 'rgba(0,122,255,0.12)', color: '#007aff', borderRadius: 10 }}>Recommended</span>
                      </div>
                      <div style={{ fontSize: 13, color: 'var(--text-2)' }}>
                        Works freely inside the current Project folder. Asks you before using the network, crossing Project folder boundaries, or running high-risk commands.
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>Reviewer: <strong style={{ color: 'var(--text)' }}>You</strong></div>
                    </div>
                  </div>

                  <div style={{ height: 1, backgroundColor: 'var(--border-light)' }} />

                  {/* Mode 2 */}
                  <div
                    style={{ display: 'flex', gap: 12, cursor: 'pointer' }}
                    onClick={() => setActivePermissionMode('Approve for me')}
                  >
                    <input type="radio" checked={activePermissionMode === 'Approve for me'} readOnly style={{ marginTop: 4 }} />
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                      <div style={{ fontWeight: 600, fontSize: 14 }}>Approve for me</div>
                      <div style={{ fontSize: 13, color: 'var(--text-2)' }}>
                        Keeps the same Project folder boundary and safety checks. Actions that require additional access are reviewed automatically by an isolated AI reviewer.
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>Reviewer: <strong style={{ color: 'var(--text)' }}>Automatic review</strong></div>
                    </div>
                  </div>

                  <div style={{ height: 1, backgroundColor: 'var(--border-light)' }} />

                  {/* Mode 3 */}
                  <div
                    style={{ display: 'flex', gap: 12, cursor: 'pointer' }}
                    onClick={() => setActivePermissionMode('Full access')}
                  >
                    <input type="radio" checked={activePermissionMode === 'Full access'} readOnly style={{ marginTop: 4 }} />
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                      <div style={{ fontWeight: 600, fontSize: 14, display: 'flex', alignItems: 'center', gap: 6 }}>
                        Full access <span style={{ fontSize: 11, padding: '1px 6px', background: 'rgba(255,59,48,0.12)', color: '#ff3b30', borderRadius: 10 }}>Danger</span>
                      </div>
                      <div style={{ fontSize: 13, color: 'var(--text-2)' }}>
                        Can access files outside the Project folder, use the network, and execute shell commands without normal approval gates.
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>Reviewer: <strong style={{ color: 'var(--text)' }}>None</strong></div>
                      <div style={{ fontSize: 12, color: '#ff3b30' }}>Higher risk of data loss, leaks, or unintended system modifications.</div>
                    </div>
                  </div>
                </div>

                <div style={{ fontSize: 12, color: 'var(--text-muted)', marginTop: 8 }}>
                  Limare enforces application-level project boundaries on file and shell tool execution.
                </div>
              </div>
            </>
          )}

          {/* Remote Access Page */}
          {activeTab === 'remote-access' && (
            <>
              <h2 className="settings-page-title">Remote Access</h2>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Remote Access</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-label">Enable Remote Access</div>
                    <label className="switch">
                      <input
                        type="checkbox"
                        checked={remoteAccessEnabled}
                        onChange={(e) => setRemoteAccessEnabled(e.target.checked)}
                      />
                      <span className="slider"></span>
                    </label>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Server</div>
                    <span style={{ fontSize: 13, color: 'var(--text-2)' }}>Listening on 127.0.0.1:47615</span>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Tunnel</div>
                    <span style={{ fontSize: 13, color: 'var(--text-2)' }}>Connected</span>
                  </div>
                </div>
                <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>
                  Use this Limare from your phone's browser while Limare runs on this Mac. Limare listens only on 127.0.0.1; Cloudflare Tunnel is the only way in, and Cloudflare Access signs in the one person allowed.
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Cloudflare Tunnel</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-label">Public hostname</div>
                    {/* Mock synthetic domain only */}
                    <span style={{ fontSize: 13, color: 'var(--text)' }}>limare.example.com</span>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Local port</div>
                    <span style={{ fontSize: 13, color: 'var(--text)' }}>47615</span>
                  </div>
                  <div className="settings-row">
                    <input className="input-control" value="••••••••••••••••••••••••" readOnly style={{ maxWidth: 340 }} />
                    <button className="btn-secondary">Replace</button>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>
                    ✓ Tunnel token is saved in Limare private storage.
                  </div>
                </div>
              </div>

              <div className="settings-section">
                <div className="settings-section-header">
                  <div className="settings-section-title">Cloudflare Access</div>
                </div>
                <div className="settings-card">
                  <div className="settings-row">
                    <div className="settings-row-label">Team domain</div>
                    <span style={{ fontSize: 13, color: 'var(--text)' }}>myteam.cloudflareaccess.com</span>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Application AUD tag</div>
                    <span style={{ fontSize: 12, color: 'var(--text-2)', fontFamily: 'var(--mono)' }}>73fd803f5cd123456789...demo</span>
                  </div>
                  <div className="settings-row">
                    <div className="settings-row-label">Owner email</div>
                    <span style={{ fontSize: 13, color: 'var(--text)' }}>user@example.com</span>
                  </div>
                </div>
              </div>

              <button className="btn-secondary" style={{ marginTop: 8, alignSelf: 'flex-start' }}>
                Save and Restart Remote Access
              </button>
            </>
          )}

          {/* Providers Page */}
          {activeTab === 'providers' && (
            <>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 className="settings-page-title">Providers</h2>
                <button className="btn-secondary" onClick={() => setShowAddProviderModal(true)}>
                  + Add Provider
                </button>
              </div>

              <div style={{ display: 'flex', gap: 16, marginTop: 12 }}>
                {/* Providers left list */}
                <div style={{ width: 220, display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div className="sidebar-search" style={{ marginBottom: 8 }}>
                    <IconSearch size={13} />
                    <input
                      placeholder="Filter..."
                      value={providerSearch}
                      onChange={(e) => setProviderSearch(e.target.value)}
                    />
                  </div>
                  {mockProviders
                    .filter((p) => p.name.toLowerCase().includes(providerSearch.toLowerCase()))
                    .map((p) => (
                      <div
                        key={p.id}
                        className={`sidebar-item ${selectedProviderId === p.id ? 'active' : ''}`}
                        onClick={() => setSelectedProviderId(p.id)}
                        style={{ flexDirection: 'column', alignItems: 'flex-start', gap: 2 }}
                      >
                        <div style={{ fontWeight: 600 }}>{p.name}</div>
                        <div style={{ fontSize: 11, color: 'var(--text-muted)' }}>{p.modelsCount} models</div>
                      </div>
                    ))}
                </div>

                {/* Provider right detail */}
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 16 }}>
                  {(() => {
                    const cur = mockProviders.find((p) => p.id === selectedProviderId) || mockProviders[0];
                    return (
                      <>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                          <div>
                            <div style={{ fontSize: 18, fontWeight: 700 }}>{cur.name}</div>
                            <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>{cur.url}</div>
                          </div>
                          <button className="btn-secondary" style={{ backgroundColor: '#007aff', color: '#fff', border: 'none' }}>
                            Save Changes
                          </button>
                        </div>

                        <div className="settings-section">
                          <div className="settings-section-title">Connection</div>
                          <div className="settings-card">
                            <div className="settings-row">
                              <div className="settings-row-label">Service</div>
                              <select className="select-control" value={cur.service || 'Direct Cloud'} onChange={() => {}}>
                                <option>Custom / Local</option>
                                <option>Direct Cloud</option>
                              </select>
                            </div>
                            <div className="settings-row">
                              <div className="settings-row-label">Base URL</div>
                              <input className="input-control" defaultValue={cur.url} key={cur.url} />
                            </div>
                            <div className="settings-row">
                              <div className="settings-row-label">API Key</div>
                              <div style={{ display: 'flex', gap: 8, flex: 1, justifyContent: 'flex-end' }}>
                                <input className="input-control" value="••••••••••••••••••••••••" readOnly style={{ maxWidth: 260 }} />
                                <button className="btn-secondary">Replace</button>
                              </div>
                            </div>
                            <div style={{ fontSize: 12, color: 'var(--text-muted)' }}>
                              ✓ API Key is saved in Limare private storage.
                            </div>
                          </div>
                        </div>

                        <div className="settings-section">
                          <div className="settings-section-title">Models</div>
                          <div className="settings-card">
                            {cur.sampleModels ? (
                              cur.sampleModels.map((m, idx) => (
                                <div key={idx} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
                                  <input type="checkbox" defaultChecked />
                                  <span style={{ fontWeight: 600 }}>{m.name}</span>
                                  <span style={{ fontSize: 11, color: 'var(--text-muted)' }}>{m.context}</span>
                                </div>
                              ))
                            ) : (
                              <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
                                <input type="checkbox" defaultChecked />
                                <span style={{ fontWeight: 600 }}>{cur.name}-default</span>
                              </div>
                            )}
                          </div>
                        </div>
                      </>
                    );
                  })()}
                </div>
              </div>
            </>
          )}

          {/* Model Groups Page */}
          {activeTab === 'model-groups' && (
            <>
              <h2 className="settings-page-title">Model Groups</h2>
              <div style={{ display: 'flex', gap: 16, marginTop: 12 }}>
                <div style={{ width: 220, display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--text-muted)', textTransform: 'uppercase' }}>Groups</div>
                  {['chat', 'subagents', 'image-gen', 'TTS', 'vedio-gen'].map((g) => (
                    <div
                      key={g}
                      className={`sidebar-item ${selectedModelGroup === g ? 'active' : ''}`}
                      onClick={() => setSelectedModelGroup(g)}
                      style={{ justifyContent: 'space-between' }}
                    >
                      <span>{g}</span>
                      <span style={{ fontSize: 10, padding: '1px 6px', background: 'var(--border)', borderRadius: 4 }}>
                        1 model
                      </span>
                    </div>
                  ))}
                  <button className="btn-secondary" style={{ marginTop: 8 }}>+ New Group</button>
                </div>

                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 16 }}>
                  <div className="settings-section">
                    <div className="settings-section-title">Common Tasks</div>
                    <div className="settings-card">
                      <div className="settings-row">
                        <div className="settings-row-label">Chat</div>
                        <select className="select-control" defaultValue="chat">
                          <option>chat</option>
                          <option>claude-sonnet-5</option>
                        </select>
                      </div>
                      <div className="settings-row">
                        <div className="settings-row-label">Images</div>
                        <select className="select-control" defaultValue="None">
                          <option>None</option>
                          <option>vision-preview</option>
                        </select>
                      </div>
                      <div className="settings-row">
                        <div className="settings-row-label">Voice Input</div>
                        <select className="select-control" defaultValue="System Speech (Auto)">
                          <option>System Speech (Auto)</option>
                        </select>
                      </div>
                    </div>
                  </div>

                  <div className="settings-section">
                    <div className="settings-section-title">Extra Help</div>
                    <div className="settings-card">
                      <div className="settings-row">
                        <div className="settings-row-label">Helper model</div>
                        <select className="select-control" defaultValue="subagents">
                          <option>subagents</option>
                        </select>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </>
          )}

          {/* Skills Page */}
          {activeTab === 'skills' && (
            <>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 className="settings-page-title">Skills</h2>
                <button className="btn-secondary">↻ Rescan</button>
              </div>

              <div style={{ display: 'flex', gap: 10, margin: '12px 0' }}>
                <div className="sidebar-search" style={{ flex: 1 }}>
                  <IconSearch size={13} />
                  <input
                    placeholder="Search skills..."
                    value={skillSearch}
                    onChange={(e) => setSkillSearch(e.target.value)}
                  />
                </div>
                <div className="segmented-control">
                  {(['All', 'Project', 'Global'] as const).map((mode) => (
                    <button
                      key={mode}
                      className={`segmented-btn ${selectedSkillFilter === mode ? 'active' : ''}`}
                      onClick={() => setSelectedSkillFilter(mode)}
                    >
                      {mode}
                    </button>
                  ))}
                </div>
              </div>

              <div className="settings-card" style={{ padding: 0 }}>
                {mockSkills
                  .filter((s) => s.name.toLowerCase().includes(skillSearch.toLowerCase()))
                  .map((sk) => (
                    <div
                      key={sk.id}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        padding: '12px 16px',
                        borderBottom: '1px solid var(--border-light)',
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                        <input type="checkbox" defaultChecked={sk.checked} />
                        <div>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontWeight: 600 }}>
                            {sk.name}
                            <span style={{ fontSize: 10, padding: '1px 6px', background: 'var(--border)', borderRadius: 4 }}>
                              {sk.scope}
                            </span>
                          </div>
                          <div style={{ fontSize: 12, color: 'var(--text-2)' }}>{sk.desc}</div>
                        </div>
                      </div>
                      <span style={{ color: 'var(--text-muted)' }}>›</span>
                    </div>
                  ))}
              </div>
            </>
          )}

          {/* MCP Page */}
          {activeTab === 'mcp' && (
            <>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 className="settings-page-title">MCP</h2>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn-secondary">↻ Refresh All</button>
                  <button className="btn-secondary">+ Add MCP</button>
                </div>
              </div>

              <div className="sidebar-search" style={{ margin: '12px 0' }}>
                <IconSearch size={13} />
                <input
                  placeholder="Search connections..."
                  value={mcpSearch}
                  onChange={(e) => setMcpSearch(e.target.value)}
                />
              </div>

              <div className="settings-card" style={{ padding: 0 }}>
                {mockMcps
                  .filter((m) => m.name.toLowerCase().includes(mcpSearch.toLowerCase()))
                  .map((m) => (
                    <div
                      key={m.id}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        padding: '12px 16px',
                        borderBottom: '1px solid var(--border-light)',
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                        <input type="checkbox" defaultChecked={m.connected} />
                        <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: '#34c759' }} />
                        <span style={{ fontWeight: 600 }}>{m.name}</span>
                        <span style={{ fontSize: 10, padding: '1px 6px', background: 'var(--border)', borderRadius: 4 }}>
                          {m.type}
                        </span>
                      </div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{ fontSize: 12, color: '#34c759' }}>Connected · {m.tools} tools</span>
                        <span style={{ color: 'var(--text-muted)' }}>›</span>
                      </div>
                    </div>
                  ))}
              </div>
            </>
          )}

          {/* Hooks Page */}
          {activeTab === 'hooks' && (
            <>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 className="settings-page-title">Hooks</h2>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn-secondary">↻ Reload</button>
                  <button className="btn-secondary">+ Import...</button>
                </div>
              </div>

              <div className="sidebar-search" style={{ margin: '12px 0' }}>
                <IconSearch size={13} />
                <input
                  placeholder="Search hooks..."
                  value={hookSearch}
                  onChange={(e) => setHookSearch(e.target.value)}
                />
              </div>

              <div className="settings-card" style={{ padding: 0 }}>
                {mockHooks
                  .filter((h) => h.name.toLowerCase().includes(hookSearch.toLowerCase()))
                  .map((h) => (
                    <div
                      key={h.id}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        padding: '12px 16px',
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                        <input type="checkbox" defaultChecked={h.checked} />
                        <span style={{ width: 8, height: 8, borderRadius: '50%', backgroundColor: '#34c759' }} />
                        <span style={{ fontWeight: 600 }}>{h.name}</span>
                        <span style={{ fontSize: 10, padding: '1px 6px', background: 'var(--border)', borderRadius: 4 }}>
                          {h.type}
                        </span>
                        <span style={{ fontSize: 10, padding: '1px 6px', background: 'rgba(52,199,89,0.15)', color: '#34c759', borderRadius: 4 }}>
                          Trusted
                        </span>
                      </div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{ fontSize: 12, color: 'var(--text-muted)' }}>{h.automations} automations</span>
                        <span style={{ color: 'var(--text-muted)' }}>›</span>
                      </div>
                    </div>
                  ))}
              </div>
            </>
          )}

          {/* Logs Page */}
          {activeTab === 'logs' && (
            <>
              <h2 className="settings-page-title">Logs</h2>
              <div style={{ fontSize: 13, color: 'var(--text-2)', marginBottom: 8 }}>
                Recent, bounded diagnostic records cover runtime lifecycle, routing, tools, integrations, and errors.
              </div>

              <div className="sidebar-search" style={{ margin: '10px 0 16px' }}>
                <IconSearch size={13} />
                <input
                  placeholder="Filter log records..."
                  value={logSearch}
                  onChange={(e) => setLogSearch(e.target.value)}
                />
              </div>

              <div className="settings-card" style={{ fontFamily: 'var(--mono)', fontSize: 12, padding: 12 }}>
                {mockLogs
                  .filter((l) => l.msg.toLowerCase().includes(logSearch.toLowerCase()))
                  .map((l) => (
                    <div key={l.id} style={{ display: 'flex', gap: 12, padding: '4px 0', borderBottom: '1px solid var(--border-light)' }}>
                      <span style={{ color: 'var(--text-muted)' }}>{l.time}</span>
                      <span style={{ color: '#007aff', fontWeight: 600 }}>[{l.tag}]</span>
                      <span style={{ flex: 1, color: 'var(--text)' }}>{l.msg}</span>
                      <span style={{ color: 'var(--text-muted)', fontSize: 10 }}>{l.level}</span>
                    </div>
                  ))}
              </div>
            </>
          )}
        </div>
      </main>

      {/* Simulated Add Provider Modal */}
      {showAddProviderModal && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundColor: 'rgba(0,0,0,0.5)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 100,
          }}
          onClick={() => setShowAddProviderModal(false)}
        >
          <div
            className="settings-card"
            style={{ width: 380, backgroundColor: 'var(--surface)', padding: 20 }}
            onClick={(e) => e.stopPropagation()}
          >
            <div style={{ fontWeight: 600, fontSize: 16 }}>Add Provider</div>
            <div style={{ fontSize: 12, color: 'var(--text-2)', margin: '8px 0 16px' }}>
              Synthetic dialog. Credentials are not saved to any backend.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <input className="input-control" placeholder="Provider Name (e.g. Local Server)" />
              <input className="input-control" placeholder="API Key / Token" type="password" />
            </div>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 16 }}>
              <button className="btn-secondary" onClick={() => setShowAddProviderModal(false)}>
                Cancel
              </button>
              <button
                className="btn-secondary"
                style={{ backgroundColor: '#007aff', color: '#fff', border: 'none' }}
                onClick={() => {
                  alert('Provider added (simulated)');
                  setShowAddProviderModal(false);
                }}
              >
                Save
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
