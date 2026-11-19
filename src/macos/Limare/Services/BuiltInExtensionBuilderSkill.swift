import Foundation

enum BuiltInExtensionBuilderSkill {
    static let skillID = "extension-card-builder"
    static let version = "1.0.0"

    static func targetDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Limare/skills", isDirectory: true)
            .appendingPathComponent(skillID, isDirectory: true)
    }

    static func targetFileURL(fileManager: FileManager = .default) -> URL {
        targetDirectoryURL(fileManager: fileManager).appendingPathComponent("SKILL.md")
    }

    /// Idempotently syncs the built-in `extension-card-builder` meta-skill to Application Support
    /// only when missing or outdated. Callers using custom test roots should skip this.
    static func syncIfNeeded(fileManager: FileManager = .default) {
        let dirURL = targetDirectoryURL(fileManager: fileManager)
        let fileURL = dirURL.appendingPathComponent("SKILL.md")

        if fileManager.fileExists(atPath: fileURL.path),
           let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let parsed = SkillParser.parse(skillMD: existing)
            if parsed.version == version && existing == markdownContent {
                return
            }
        }

        do {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try markdownContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort sync; SkillStore continues without crashing if disk is read-only.
        }
    }

    static let markdownContent: String = """
---
name: extension-card-builder
description: Standard workflow for connecting, deploying, or integrating any external tool, CLI, API, email, or MCP service into Limare as a user-manageable Extension Card.
version: 1.0.0
hidden: true
---

# Limare Extension Card Builder Workflow

When the user asks to install, deploy, connect, or integrate any external tool, CLI project, API service, or workflow (e.g., `agent-reach`, GitHub, email, Firecrawl, Obsidian, Notion), follow this 5-step workflow so the capability works reliably and appears as a clean Extension Card in **Settings → Extensions**.

## Step 1: Explore & Choose the Lowest-Friction Channel

Before proposing or running setup, inspect what is already available on this Mac using `shell_execute` (e.g., `which gh`, `which npx`, `which uv`, `which python3`) or read the project documentation the user provided.

Choose the integration channel in this strict priority order:

1. **Local Mature/Official CLI + Skill Card (Preferred)**:
   - Use this whenever the tool has a CLI or installable local package (e.g., `gh` for GitHub, `agent-reach`, `himalaya` for IMAP/SMTP email, cloud CLIs).
   - Advantages: Official CLIs handle their own OAuth/login (`gh auth login`), keep tokens out of Limare prompts, and save context window tokens because `SKILL.md` is loaded on demand.
2. **Universal Open Standard Protocols (No Vendor Lock-in)**:
   - For email: prefer standard **IMAP + SMTP** with an App Password over proprietary OAuth where possible.
   - For calendars/contacts: prefer CalDAV / CardDAV or local macOS tools when appropriate.
3. **MCP Server via `mcp_manage` (Structured Remote/Stdio Tools)**:
   - Use this when the service explicitly exposes a well-maintained stdio or HTTP MCP server (e.g., Firecrawl MCP, remote PAT-authenticated MCP) and no simpler CLI exists.

### When to Call `ask_user_question`
If there is a real product trade-off or choice (e.g., local CLI vs. remote token, read-only vs. read-write permissions, free local setup vs. paid cloud API key), **you MUST call `ask_user_question`** before configuring. Never guess the user's permission preference or paid/free tier choice.

## Step 2: Enforce Security & OAuth Red Lines

- **No Public Hosted OAuth**: Limare is a local macOS app without pre-registered public OAuth client IDs for Google Workspace, GitHub, etc. Do **NOT** attempt bare OAuth flows that require a pre-registered `client_id` unless the server supports Dynamic Client Registration (DCR) or the user explicitly brings their own `client_id`.
- **Never Collect Secrets in Chat**: NEVER ask the user to paste API keys, passwords, or tokens into the chat conversation, and NEVER put secret literals in tool arguments or `SKILL.md`.
  - For MCP servers: use `mcp_manage` `create` / `patch` with `${secret:ENV_OR_HEADER_NAME}`, then call `mcp_manage(action: "authenticate", ...)` so Limare collects the secret in its own Touch ID secure window.
  - For CLI login: instruct the user on the exact interactive login command (or run non-secret status checks) and wait for confirmation.
- **No Unapproved Side Edits**: Do not edit Limare's internal `mcp_servers.json` or `secrets` files manually; always use `mcp_manage` for MCP servers and `file_write` / `file_edit` for `SKILL.md`.

## Step 3: Install & Smoke-Test Before Declaring Success

1. Install required CLI dependencies via `shell_execute` (use `sandbox_permissions: "require_escalated"` with a clear justification if installation writes outside the working directory, or give the user the exact Terminal command if `sudo` is needed).
2. If an MCP server was added via `mcp_manage`, verify `mcp_manage(action: "status", ...)` reports `.connected` with tools discovered (or guide the user through the native authentication prompt first).
3. Run at least one **read-only smoke test** (e.g., `<cli> --version`, `gh auth status`, or a safe read-only query) to verify the integration genuinely works. Never report an extension card as ready if the smoke test failed.

## Step 4: Write the Extension Card (`SKILL.md`)

Save the card file using `file_write`:
- **Global extension (default)**: `~/.limare/skills/<slug>/SKILL.md`
- **Project-specific extension** (only if user requested project-only scope): `<workspace>/.agents/skills/<slug>/SKILL.md`

Use lowercase kebab-case for `<slug>` (e.g., `agent-reach`, `github`, `email-imap`, `firecrawl`).

### Required Frontmatter & Card Metadata Template

```markdown
---
name: <Human-Friendly Card Title, e.g. GitHub or Agent Reach>
description: <One clear sentence describing what this extension lets the user do.>
version: 1.0.0
icon: <Optional valid macOS SF Symbol name, e.g. flame.fill, envelope.fill, globe, terminal, chevron.left.forwardslash.chevron.right>
color: <One of: amber | coral | sage | slate | plum | stone>
examples:
  - "<Practical prompt 1 the user can click to try immediately>"
  - "<Practical prompt 2>"
mcp_servers:
  - <Optional: exact server_id created via mcp_manage so both appear as ONE unified card>
---

# <Card Title> Instructions

## Scope & Permissions
- Explicitly document the access boundary the user chose (e.g., Read-only vs. Read-write).
- If read-only was chosen, state explicitly which write/destructive commands or tools are FORBIDDEN.

## How to Use
- Exact CLI commands, flags, or MCP tool names verified during Step 3.
- Common workflows and error handling tips.
```

> Note on `examples`: Write 2–3 concrete, high-value prompts in the user's language. Omit `mcp_servers` if the card uses a CLI/Skill only.

## Step 5: Deliver & Guide the User

Tell the user clearly:
1. What integration route and permission boundary were configured, and what the smoke test verified.
2. That the new **<Card Title>** card is now live in **Settings → Extensions**, where they can toggle it on/off, inspect its underlying commands/services, or click any example prompt to start using it immediately.
"""
}
