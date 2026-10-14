# Limare 0.1.0 — release candidate notes

This document describes the intended first release. Public downloads remain
closed until release validation completes.

- Native macOS AI agent with projects, conversations, local memory, shell and
  file tools, a browser, Computer Use, MCP, Skills, Hooks, speech, and optional
  user-configured Remote Access.
- User-controlled model credentials: API keys, supported third-party OAuth,
  and provider-issued credentials. Model/tool data can leave the Mac through
  the services the user selects.
- Apple Silicon (`arm64`), macOS **15.0+**. Intel is outside this release scope.
- First installation uses a Developer ID signed, notarized, stapled DMG.
- Updates use **Limare > Check for Updates…** only. Automatic checks,
  automatic installation, and optional Sparkle system profiling are disabled.
  Follow GitHub Releases and security materials for announcements.

Known limitations: no Intel support; the main app is not Apple App Sandbox;
third-party service retention and deletion are outside Limare's control;
native MCP SDK OAuth sign-in remains gated off (this is separate from model
Provider OAuth such as ChatGPT and OpenRouter);
`mail@limare.app` receives reports but cannot currently send replies. Exact
runtime limitations must be updated from the final candidate's acceptance
results before publication.

Final publication must record: source commit/tag, build number, dependency
lock hashes, build tools, final DMG SHA-256, and validation evidence. No
placeholder binary or checksum may be published.
