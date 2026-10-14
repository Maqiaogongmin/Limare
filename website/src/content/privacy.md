# Limare Privacy Policy

Developer: **Maqiaogongmin** · Policy version: **0.1.0** · Effective date: **2026-10-14**

Contact: [mail@limare.app](mailto:mail@limare.app). This address accepts incoming reports; replies from this address are currently unavailable. Use the public issue tracker for follow-up on non-sensitive problems once the source repository is published. Do not post credentials or private data in public issues.

## Local-first, with third-party services you choose

Limare is a native macOS AI agent. The developer does not operate a Limare account service, model relay, or conversation storage backend. Local-first storage does not mean that data never leaves your Mac. When you use models, tools, websites, speech, Computer Use, or Remote Access, relevant data can be sent to the services you configure or visit.

## Local storage and credentials

| Category | Local storage | Boundary |
| --- | --- | --- |
| Provider keys and OAuth state | Permission-restricted JSON file | Not Keychain or application-level encryption |
| Remote Access Tunnel credentials | Permission-restricted JSON file | Cloudflare may retain separate records |
| Production MCP credentials | macOS Keychain | Third-party revocation is separate |
| Conversations, memory, and logs | Local files | Workspace files and backups can need separate removal |

Conversations, project configuration, memory, diagnostic records, and attachment metadata are stored locally, primarily in `~/Library/Application Support/app.limare.Limare`, with caches under `~/Library/Caches/app.limare.Limare`. Files created by the agent can also be stored in your chosen workspaces. Local records remain until removed through the relevant controls or by deleting the associated files. Backups and diagnostic records can require separate removal.

Provider API keys and Provider OAuth state are stored in `secrets/provider-secrets.json`. OAuth records can include access/refresh state and account metadata such as email, subject, workspace ID, and granted scopes. Remote Access Tunnel credentials are stored in `secrets/remote-secrets.json`. These are permission-restricted JSON files, with a private directory and owner-only file access; they are not Keychain storage or application-level encrypted databases. Their protection also depends on your macOS account, device security, backups, and FileVault configuration. Credential migration can create a local legacy backup.

Production MCP credentials, including configured header/environment secrets and supported OAuth token/client-secret records, use macOS Keychain. Different credential types have different storage and deletion paths. Logging out or removing a credential does not revoke every credential previously issued by a third-party service; use that service's controls when revocation is needed.

In 0.1.0, native MCP SDK OAuth sign-in remains gated off; preserved MCP OAuth configuration or credential records do not mean that this sign-in path is enabled. This is separate from model Provider OAuth such as ChatGPT and OpenRouter.

## Models and authentication

Prompts, conversation context, memory excerpts, tool results, images, and attachments included in a model request are sent to your selected provider. Authentication can use API keys, third-party OAuth such as ChatGPT login, or provider-issued credentials such as OpenRouter browser authorization. BYOK is one supported method, not the only method. Local model endpoints can avoid a remote model provider, but other enabled tools or services can still use the network.

Provider retention, training, and cross-border processing are governed by that provider's policies and your account settings. Limare cannot delete data already received by a provider.

## Tools, Computer Use, browser, and Hooks

MCP servers and other tools receive their inputs and can return data from the systems they access. Those systems may retain content, credentials, or audit logs under their own policies.

Computer Use reads application/window information, Accessibility elements (including labels, values, and positions), screen contents, screenshots, and action results. It uses local Limare and `cua-driver` components. Tool results and images may subsequently enter model context and be sent to your selected model provider. Accessibility, Screen Recording, target-app approvals, and the active permission mode govern availability and actions.

The built-in browser uses a persistent WebKit website data store. Cookies, login sessions, site storage, and caches can survive app restarts. Websites receive ordinary browser requests and data you submit. The browser's data-clearing control removes its profile's stored website data; it does not erase data already retained by a website. Preview web views can use a different, non-persistent store.

Hooks execute user-configured commands and exchange tool context and standard input/output with local processes. Commands and agent tools may read or change files, run programs, or contact other services. Limare's permission controls are not a guarantee of safe execution, and the main app does not use Apple App Sandbox.

## Speech and macOS permissions

Microphone access enables voice input. Cloud speech recognition sends audio to the configured service; system recognition uses Apple capabilities and is not guaranteed to be fully on-device in every configuration. Cloud text-to-speech sends the text to be spoken to its provider; system speech uses macOS voices.

Screen Recording enables screen observation; Accessibility enables supported interface observation and control. Speech Recognition enables system transcription. Filesystem access enables work in selected paths. AppleEvents automation, when invoked and supported, is subject to macOS authorization for the target app. Grant only the permissions needed for the features you use.

## Remote Access, model directory, and updates

Remote Access is optional and user-configured. The local service listens on loopback and external access uses the user's Cloudflare Tunnel/Access configuration. Conversations, tool state, attachment metadata, and identity/request metadata may pass through Cloudflare. Cloudflare may retain access and security logs. Disable Remote Access to stop that access path; deleting local credentials does not delete Cloudflare logs or revoke every Cloudflare credential.

Model-directory refreshes contact `models.dev` and expose ordinary request metadata such as IP address and request time; they are distinct from requests containing model conversation content.

Limare 0.1.0 provides a manual Sparkle update check from the Limare application menu. Automatic checks, automatic installation, and optional system profiling are disabled. Clicking Check for Updates requests the HTTPS appcast at `limare.app`; downloading an update contacts its Release/CDN host. Those services receive IP address, User-Agent, request time, and ordinary network metadata. No additional tracking parameters are configured.

## Website and reports you send

The website stores your theme preference in browser `localStorage`. The 0.1.0 website does not include third-party analytics. Hosting/CDN services can still process IP address, User-Agent, request time, and security/access logs. Websites opened from the site have their own policies.

Information you voluntarily email or include in an issue, such as a description or sanitized diagnostic attachment, is processed by the mail or issue-hosting services used to receive it and by the developer to investigate your report. Public issues are visible to others. Include only the information needed, and remove secrets and personal data before sending logs or screenshots. Report records may be retained while needed for investigation or maintenance; contact the developer about removal where applicable.

## Deletion and changes

- Review local conversations, memory, logs, and migration backups separately.
- Use browser data clearing for the browser profile's cookies and site storage.
- Use third-party account controls for remote retention or credential revocation.

Use the relevant conversation, provider, MCP, Remote Access, and browser controls to remove their local records. Local memory, logs, migration backups, and workspace files can require separate deletion. Removing Limare.app does not automatically erase Application Support, Keychain items, browser data, or files the agent wrote to your workspaces. Limare cannot erase third-party copies, mail records, public issue copies, or other people's backups.

Limare is intended for people able to authorize and understand model and tool access, and is not designed specifically for children. Depending on the services selected, data may be processed outside your country. The policy will be reviewed when authentication, permissions, data flows, updates, or analytics change; a revised policy will state its version and effective date. Contact [mail@limare.app](mailto:mail@limare.app) with privacy or security concerns.
