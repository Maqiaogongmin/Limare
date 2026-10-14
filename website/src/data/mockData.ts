import { DOCUMENTS, documentFiles } from '../content/documents';
export interface ProjectItem {
  id: string;
  name: string;
  conversations: { id: string; title: string }[];
}

export interface ConversationItem {
  id: string;
  title: string;
  updatedAt: string;
  archived?: boolean;
}

export interface ProviderItem {
  id: string;
  name: string;
  type: string;
  status: 'Ready' | 'Configured' | 'Disabled';
  models: string[];
}

export interface ModelGroupItem {
  id: string;
  name: string;
  routing: 'Auto' | 'Round Robin' | 'Priority';
  primaryModel: string;
}

export interface SkillItem {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
}

export interface McpItem {
  id: string;
  name: string;
  transport: 'stdio' | 'http';
  toolsCount: number;
  enabled: boolean;
}

export interface HookItem {
  id: string;
  name: string;
  event: string;
  trusted: boolean;
}

export interface LogItem {
  id: string;
  level: 'info' | 'warn' | 'error';
  time: string;
  message: string;
}

export const FAKE_PROJECTS: ProjectItem[] = [
  {
    id: 'proj-what-is-limare',
    name: 'What is Limare',
    conversations: [
      { id: 'c-what-is-limare', title: 'Download here' },
    ],
  },
  {
    id: 'proj-document',
    name: 'Limare Document',
    conversations: [
      { id: 'c-privacy-policy', title: 'Privacy Policy' },
    ],
  },
];

export const FAKE_CONVERSATIONS: ConversationItem[] = [
  { id: 'c-security', title: 'Security', updatedAt: 'Just now' },
  { id: 'c-support', title: 'Support', updatedAt: 'Just now' },
];

export const FAKE_PROVIDERS: ProviderItem[] = [
  { id: 'p-1', name: 'Anthropic', type: 'Direct API', status: 'Ready', models: ['claude-sonnet-5', 'claude-opus-5', 'claude-haiku-4-5'] },
  { id: 'p-2', name: 'OpenAI', type: 'Direct API', status: 'Ready', models: ['gpt-5.6-sol', 'gpt-5.5', 'o4-mini'] },
  { id: 'p-3', name: 'Google Gemini', type: 'Direct API', status: 'Ready', models: ['gemini-3.1-pro', 'gemini-3-flash'] },
  { id: 'p-4', name: 'Ollama (Local)', type: 'Self Hosted', status: 'Configured', models: ['deepseek-v4:16b', 'llama4:70b'] },
];

export const FAKE_MODEL_GROUPS: ModelGroupItem[] = [
  { id: 'mg-1', name: 'Default Fast', routing: 'Auto', primaryModel: 'gemini-3-flash' },
  { id: 'mg-2', name: 'Coding Heavy', routing: 'Priority', primaryModel: 'claude-sonnet-5' },
  { id: 'mg-3', name: 'Reasoning Specialist', routing: 'Auto', primaryModel: 'gpt-5.6-sol' },
];

export const FAKE_SKILLS: SkillItem[] = [
  { id: 's-1', name: 'smart-search', description: 'Intelligent multi-engine router for online research.', enabled: true },
  { id: 's-2', name: 'officecli', description: 'Parse, edit and render Office documents natively.', enabled: true },
  { id: 's-3', name: 'opencli-browser', description: 'Drive Chrome browser instances with selector contracts.', enabled: false },
];

export const FAKE_MCPS: McpItem[] = [
  { id: 'm-1', name: 'github', transport: 'stdio', toolsCount: 27, enabled: true },
  { id: 'm-2', name: 'huggingface', transport: 'http', toolsCount: 4, enabled: true },
  { id: 'm-3', name: 'postgres-dev', transport: 'stdio', toolsCount: 12, enabled: false },
];

export const FAKE_HOOKS: HookItem[] = [
  { id: 'h-1', name: 'session-init-audit', event: 'session.start', trusted: true },
  { id: 'h-2', name: 'agentmemory-logger', event: 'agent.memory.write', trusted: true },
  { id: 'h-3', name: 'pre-shell-safeguard', event: 'tool.before_execute', trusted: true },
];

export const FAKE_LOGS: LogItem[] = [
  { id: 'l-1', level: 'info', time: '14:02:11', message: 'Model provider Anthropic handshake verified' },
  { id: 'l-2', level: 'info', time: '14:02:15', message: 'WorkSurface FileWatcher initialized: ~/Developer/Limare' },
  { id: 'l-3', level: 'warn', time: '14:03:00', message: 'Local sandbox write escalation not requested (default profile active)' },
  { id: 'l-4', level: 'info', time: '14:05:22', message: 'MCP server "github" tools list refreshed (27 tools loaded)' },
];

export interface WorkspaceFileItem {
  path: string;
  name: string;
  type: 'markdown' | 'json' | 'html';
  size: string;
  content: string;
  previewUrl?: string;
}

export const FAKE_WORKSPACE_FILES: WorkspaceFileItem[] = DOCUMENTS.flatMap(documentFiles);
