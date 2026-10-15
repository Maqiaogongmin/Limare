// Work Surface keeps the presentation approved before chat-only formatting changes.
import { Script } from '../types/script';
import { CONFIG } from '../config';

export const INTRO_SCRIPT: Script = [
  {
    kind: 'heading',
    md: '# Limare',
    plain: 'Limare',
    delayBefore: 60,
  },
  {
    kind: 'paragraph',
    md: 'Limare is a native macOS engineering agent running directly on your Mac. It turns your workspace into an intelligent environment with local-first storage, user-controlled credentials, and modular tool integrations. Model and tool data may be sent to the services you select.',
    plain: 'Limare is a native macOS engineering agent running directly on your Mac. It turns your workspace into an intelligent environment with local-first storage, user-controlled credentials, and modular tool integrations. Model and tool data may be sent to the services you select.',
    delayBefore: 120,
  },
  {
    kind: 'heading',
    md: '## Core Capabilities',
    plain: 'Core Capabilities',
    delayBefore: 120,
  },
  {
    kind: 'list',
    perItem: true,
    md: `- **Native macOS Experience**: Built with SwiftUI, AppKit, WebKit, and supporting services.
- **User-controlled Credentials**: API keys, supported third-party OAuth, and provider-issued credentials; remote or local model endpoints.
- **Extensible Architecture**: Full support for Model Context Protocol (MCP), Skills, and Lifecycle Hooks.
- **Computer Use & Permissions**: Observe and operate approved apps; tool results or screenshots may enter model context.`,
    plain: `Native macOS Experience: Built with SwiftUI, AppKit, WebKit, and supporting services.
User-controlled Credentials: API keys, supported third-party OAuth, provider-issued credentials, and local or remote models.
Extensible Architecture: Full support for Model Context Protocol MCP, Skills, and Lifecycle Hooks.
Computer Use and Permissions: Observe and operate approved apps; tool results or screenshots may enter model context.`,
    delayBefore: 140,
  },
  {
    kind: 'table',
    md: `| Component | Description | Local Scope |
|---|---|---|
| **Chat & Work Surface** | Dual pane workspace with live previews | Local memory & files |
| **Model Groups** | Smart routing and automated fallbacks | Direct HTTPS to providers |
| **MCP Servers** | Dynamic tools via stdio and Streamable HTTP | Third-party tools; MCP credentials in Keychain |
| **Remote Access** | Secure companion web UI on 127.0.0.1 | Cloudflare Tunnel only |`,
    delayBefore: 180,
  },
  {
    kind: 'quote',
    md: '> "Your code and credentials stay yours. No Limare-operated model relay. Third-party services have their own privacy policies."',
    plain: 'Your code and credentials stay yours. No Limare-operated model relay. Third-party services have their own privacy policies.',
    delayBefore: 140,
  },
  {
    kind: 'code',
    lang: 'bash',
    filename: 'Terminal',
    md: `\`\`\`bash
# Build and run directly from source on macOS
git clone https://github.com/Maqiaogongmin/Limare.git
cd Limare
./script/build_and_run.sh
\`\`\``,
    delayBefore: 180,
  },
  {
    kind: 'paragraph',
    md: CONFIG.downloadEnabled ? 'Version 0.1.0 is available for Apple Silicon and macOS 15.0+.' : 'Version 0.1.0 targets Apple Silicon and macOS 15.0+. Downloads will open after release validation.',
    plain: CONFIG.downloadEnabled ? 'Version 0.1.0 is available for Apple Silicon and macOS 15.0+.' : 'Version 0.1.0 targets Apple Silicon and macOS 15.0+. Downloads will open after release validation.',
    delayBefore: 120,
  },
  {
    kind: CONFIG.downloadEnabled ? 'link' : 'paragraph',
    emphasis: true,
    href: CONFIG.downloadEnabled ? CONFIG.downloadURL : undefined,
    md: CONFIG.downloadEnabled ? `[**Download here**](${CONFIG.downloadURL})` : '**Downloads are not yet available.** Release validation is in progress.',
    plain: CONFIG.downloadEnabled ? 'Download here' : 'Downloads are not yet available. Release validation is in progress.',
    delayBefore: 120,
  },
];
