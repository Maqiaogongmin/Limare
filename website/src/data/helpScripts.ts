import { toChatScript } from './scriptFromMarkdown';

export const SECURITY_SCRIPT = toChatScript(`# Security

*Permissions, credentials, and private reporting for Limare 0.1.0.*

> **Report security issues privately:** [mail@limare.app](mailto:mail@limare.app).
> The address receives reports, but cannot currently send replies. There is no promised response deadline.

---

## Know the boundaries

| Surface | What it can do | What to review |
| --- | --- | --- |
| Models and MCP servers | Process prompts, context, and tool inputs | Selected services and their data policies |
| Shell commands and Hooks | Run programs, change files, contact services | Command, target paths, and permissions |
| Computer Use | Observe screens and operate approved apps | Screen Recording, Accessibility, target-app approvals |
| Updates | Check for a release when you request it | **Limare → Check for Updates…** |

### Permission controls are a boundary, not a safety guarantee

Limare supports **Apple Silicon · macOS 15.0+**. The main app does **not** use Apple App Sandbox. Model, website, tool, and automation behavior depends on your configuration and permissions. Read the [Privacy Policy](/#privacy) for transmission and deletion boundaries.

## Before sharing a report

1. Record the affected **Limare version** and the observed behavior.
2. Describe the impact and the smallest reproduction you can provide.
3. Review every attachment.
   - Remove API keys and access or refresh tokens.
   - Remove personal information and private workspace contents.
   - Keep only the sanitized details needed to reproduce the problem.
4. Send the report privately; do not publish vulnerability details or secrets in an issue.

### A minimal report

\`\`\`text
Affected version: 0.1.0
Summary: <describe the suspected issue>
Impact: <what could be exposed or changed>
Reproduction:
  1. <smallest first step>
  2. <observed result>
Attachments: <sanitized evidence only>
\`\`\`

> **This is a report template.** Replace the placeholders with sanitized observations; never paste a live credential into the example.

---

## Release and security notices

- Security fixes are announced through **GitHub Releases** and the repository's security materials.
- Update checks are *user-triggered*; Limare does not check for fixes in the background.
- The signed and notarized release is available through [GitHub Releases](https://github.com/Maqiaogongmin/Limare/releases/latest).
- If an artifact is unsafe, downloads and its update feed may be withdrawn.
  - Preserve its version and hash for investigation.
  - Fixes use a **new version and tag**, rather than replacing the source behind an existing tag.

For general troubleshooting, see [Support](/#support).
`);

export const SUPPORT_SCRIPT = toChatScript(`# Support

**Limare 0.1.0** · Apple Silicon · macOS 15.0+

> Start with a short description of what you expected and what actually happened. Share only the evidence needed to explain the problem.

## Choose a reporting channel

| Report | Channel | Visibility |
| --- | --- | --- |
| Ordinary bug or usage problem | [GitHub Issues](https://github.com/Maqiaogongmin/Limare/issues) | Public |
| Private installation or privacy report | [mail@limare.app](mailto:mail@limare.app) | Private |
| Suspected vulnerability or leaked credential | Private email; see [Security](/#security) | Keep details private |

**Email limitation:** this address can receive mail, but cannot currently send replies. Public, non-sensitive issue discussions provide a follow-up channel.

---

## Prepare a useful bug report

1. Identify your environment.
   - Limare version and build, if available.
   - macOS version and Mac architecture.
2. Describe the behavior.
   - **Expected:** what you wanted to happen.
   - **Actual:** what appeared instead.
3. Give the smallest reproduction.
4. Attach sanitized logs or screenshots only when they help.

### Example report structure

\`\`\`text
Limare version: 0.1.0
macOS version: <your installed version>
Mac architecture: Apple Silicon

Expected: <intended behavior>
Actual:   <observed behavior>
Steps:
  1. <action>
  2. <action>

Evidence: <sanitized log or screenshot, if needed>
\`\`\`

> Keep **keys, tokens, private conversations, and personal identifiers** out of reports and screenshots. Security details belong in a private report.

## Before enabling optional features

Read the [Privacy Policy](/#privacy), then review the services and permissions used by each feature:

- **Model and tool access**
  - Selected provider or MCP server.
  - Conversation context and tool inputs sent to that service.
- **Browser, voice, and Computer Use**
  - Website requests, audio processing, screenshots, and macOS permissions as applicable.
- **Remote Access**
  - Your Cloudflare configuration and external access boundary.

---

### Checking for updates

Use **Limare → Check for Updates…** to check manually. There is no background update notification. Follow GitHub Releases for version and security announcements.

### Download status

Download the signed and notarized **Limare 0.1.0** from [GitHub Releases](https://github.com/Maqiaogongmin/Limare/releases/tag/v0.1.0). The release includes SHA-256 checksums and the exact source tag. See [What is Limare?](/#intro) for the download entry.
`);
