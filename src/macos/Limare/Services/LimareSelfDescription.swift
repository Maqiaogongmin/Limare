import Foundation

/// What the model is told about the app it lives in: its capabilities, what only the user can do
/// and where, and the sandbox it runs in (Codex states its sandbox and approval policy the same
/// way). Only state that changes the model's behavior and rarely changes is included, so the
/// prompt cache stays warm; counts and lists are read through tools. Details live in each
/// tool's own description.
enum LimareSelfDescription {
    struct Facts: Sendable, Equatable {
        var permissionMode: PermissionMode
        var computerUse: ComputerUseCapabilityStatus
        var computerUseToolAvailable: Bool
        var browserAvailable: Bool
        var delegationAvailable: Bool
        var modelUseAvailable: Bool
        var mcpAvailable: Bool
        var schedulingAvailable = false
        var askUserQuestionAvailable = false
    }

    static func section(_ facts: Facts) -> String {
        var lines = [
            "# About Limare, the app you run in",
            "Settings pages: General, Personalization, Permissions, Remote Access, Providers, Model Groups, Skills, MCP, Hooks. When something needs the user, say exactly where to go; when a tool can do it, do it yourself.",
            "- shell_execute: " + shellLine(facts.permissionMode) + " sudo does not work (give the user the Terminal command).",
            "- Permission mode \"\(facts.permissionMode.displayName)\": \(facts.permissionMode.detail) Set in Settings → Permissions.",
            "- Never ask for secrets (API keys, tokens, passwords) in the conversation or put them in tool arguments; Limare collects them in its own secure window. Model provider keys go in Settings → Providers.",
        ]
        if facts.mcpAvailable {
            lines.append("- MCP servers add tools; manage them with mcp_manage (steps in its description).")
        }
        if facts.schedulingAvailable {
            lines.append("- Work for later or on a repeat: create a scheduled task with schedule_manage (Schedules in the sidebar).")
        }
        if facts.askUserQuestionAvailable {
            lines.append("- ask_user_question shows the user a card of choices and waits for their decision; use it at real forks, not for permission or secrets.")
        }
        lines.append("- Skills: folders with a SKILL.md in ~/.agents/skills/<name>/ or <project>/.agents/skills/; the user enables and rescans them in Settings → Skills.")
        lines.append("- Hooks come from ~/.codex/hooks.json, <project>/.codex/hooks.json or packages imported in Settings → Hooks; a new hook runs only after the user trusts it there.")
        if facts.browserAvailable {
            lines.append("- browser_use drives Limare's per-conversation browser; for a login, ask the user to sign in in that tab.")
        }
        lines.append("- Computer Use (operating other Mac apps): " + computerUseLine(facts))
        if facts.modelUseAvailable {
            lines.append("- model_use asks another model; providers and groups are in Settings → Providers and Model Groups.")
        }
        lines.append(facts.delegationAvailable
            ? "- delegate_task hands a self-contained task to a subagent."
            : "- Subagents are off in this conversation; the user can turn them on in the composer.")
        lines.append("- Remote Access (phone, via Cloudflare Tunnel) is set up only by the user in Settings → Remote Access.")
        lines.append("- A long conversation slows every request; the user can type /compact (or choose Compact Conversation in its menu) to have you read a summary of the earlier turns instead.")
        return lines.joined(separator: "\n")
    }

    private static func shellLine(_ mode: PermissionMode) -> String {
        mode == .fullAccess
            ? "In Full access it runs outside the sandbox with the user's own rights: it writes anywhere, opens apps and URLs (`open` a local server's address to show the user a page in their browser), uses AppleScript, and runs tools that sandbox themselves, such as swift build and xcodebuild."
            : "It runs in a sandbox: it reads files, uses the network and can serve on local ports, but writes only to its working folder and temp, cannot open apps or URLs or use AppleScript, and cannot touch Limare's own data. For more, set sandbox_permissions \"require_escalated\" with a justification, which asks for approval and runs that command outside the sandbox. The file tools also work outside the working folder."
    }

    private static func computerUseLine(_ facts: Facts) -> String {
        switch facts.computerUse {
        case .disabled:
            return "off; the user turns it on in Settings → General."
        case .needsScreenRecording:
            return "needs macOS Screen Recording permission: System Settings → Privacy & Security → Screen Recording."
        case .needsAccessibility:
            return "needs macOS Accessibility permission: System Settings → Privacy & Security → Accessibility."
        case .runtimeUnavailable:
            return "unavailable in this build."
        case .ready:
            return facts.computerUseToolAvailable
                ? "available here as computer_use."
                : "on, but not offered to this request (another conversation may be using it); it is offered again with the user's next message. There is no per-conversation switch."
        }
    }
}
