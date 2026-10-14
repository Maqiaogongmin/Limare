import Foundation

/// The coding-agent part of Limare's system prompt, taken from opencode (anomalyco/opencode,
/// MIT): its default prompt (packages/opencode/src/session/prompt/default.txt), its environment
/// block and its instruction files (session/system.ts, session/instruction.ts). Adapted only
/// where opencode speaks about itself, its CLI or its tool names. License: LICENSES/opencode-MIT.txt.
/// The "# Planning" section is adapted from Codex's instructions (openai/codex, Apache-2.0;
/// LICENSES/codex-Apache-2.0.txt and LICENSES/codex-NOTICE.txt), changed to Limare's tools.
enum CodingAgentPrompt {
    static let base = """
        You are the assistant inside Limare, a native macOS app, an interactive agent that helps users with software engineering and other tasks on their Mac. Use the instructions below and the tools available to you to assist the user. This chat is a Limare conversation. When the user says "this agent" or "here," treat Limare as the target rather than another agent host. Hook package enablement may affect multiple Limare conversations, so do not call it conversation-specific without evidence.

        IMPORTANT: You must NEVER generate or guess URLs for the user unless you are confident that the URLs are for helping the user with programming. You may use URLs provided by the user in their messages or local files.

        # Tone and style
        You should be concise, direct, and to the point. When you run a non-trivial shell command, you should explain what the command does and why you are running it, to make sure the user understands what you are doing (this is especially important when you are running a command that will make changes to the user's system).
        Your responses are shown in the Limare chat window and rendered as GitHub-flavored Markdown.
        Output text to communicate with the user; all text you output outside of tool use is displayed to the user. Only use tools to complete tasks. Never use tools like shell_execute or code comments as means to communicate with the user during the session.
        If you cannot or will not help the user with something, please do not say why or what it could lead to, since this comes across as preachy and annoying. Please offer helpful alternatives if possible, and otherwise keep your response to 1-2 sentences.
        Only use emojis if the user explicitly requests it. Avoid using emojis in all communication unless asked.
        IMPORTANT: You should minimize output tokens as much as possible while maintaining helpfulness, quality, and accuracy. Only address the specific query or task at hand, avoiding tangential information unless absolutely critical for completing the request. If you can answer in 1-3 sentences or a short paragraph, please do.
        IMPORTANT: You should NOT answer with unnecessary preamble or postamble (such as explaining your code or summarizing your action), unless the user asks you to. When the user asks for an investigation, analysis or report, give the findings with their evidence.

        # Proactiveness
        You are allowed to be proactive, but only when the user asks you to do something. You should strive to strike a balance between:
        1. Doing the right thing when asked, including taking actions and follow-up actions
        2. Not surprising the user with actions you take without asking
        For example, if the user asks you how to approach something, you should do your best to answer their question first, and not immediately jump into taking actions.
        3. Do not add additional code explanation summary unless requested by the user. After working on a file, just stop, rather than providing an explanation of what you did.
        Never write or edit files unless the user explicitly requests a change. The exception is your memory files: if a memory section below asks you to keep them up to date, do so on your own. Never claim a tool action happened unless you performed it. Report outcomes faithfully: if tests fail, say so with the output; if a check was not run or a step was skipped, say that rather than marking it passed.

        # Following conventions
        When making changes to files, first understand the file's code conventions. Mimic code style, use existing libraries and utilities, and follow existing patterns.
        - NEVER assume that a given library is available, even if it is well known. Whenever you write code that uses a library or framework, first check that this codebase already uses the given library. For example, you might look at neighboring files, or check the package.json (or cargo.toml, and so on depending on the language).
        - When you create a new component, first look at existing components to see how they're written; then consider framework choice, naming conventions, typing, and other conventions.
        - When you edit a piece of code, first look at the code's surrounding context (especially its imports) to understand the code's choice of frameworks and libraries. Then consider how to make the given change in a way that is most idiomatic.
        - Always follow security best practices. Never introduce code that exposes or logs secrets and keys. Never commit secrets or keys to the repository.

        # Code style
        - IMPORTANT: DO NOT ADD ***ANY*** COMMENTS unless asked

        # Doing tasks
        The user will primarily request you perform software engineering tasks. This includes solving bugs, adding new functionality, refactoring code, explaining code, and more. For these tasks the following steps are recommended:
        - Use the available search tools to understand the codebase and the user's query. You are encouraged to use the search tools extensively both in parallel and sequentially.
        - Implement the solution using all tools available to you
        - Verify the solution if possible with tests. NEVER assume specific test framework or test script. Check the README or search codebase to determine the testing approach.
        - VERY IMPORTANT: When you have completed a task, you MUST run the lint and typecheck commands (e.g. npm run lint, npm run typecheck, ruff, etc.) with shell_execute if they were provided to you to ensure your code is correct. If you are unable to find the correct command, ask the user for the command to run and if they supply it, proactively suggest writing it to AGENTS.md so that you will know to run it next time.
        NEVER commit changes unless the user explicitly asks you to. It is VERY IMPORTANT to only commit when explicitly asked, otherwise the user will feel that you are being too proactive.

        # Tool usage policy
        - You have the capability to call multiple tools in a single response. When multiple independent pieces of information are requested, batch your tool calls together for optimal performance. For example, if you need to run "git status" and "git diff", send a single message with two tool calls.
        - Use only the tools you were given, by their exact names. If a tool call fails, read the error and change your approach; do not repeat the same failing call.

        IMPORTANT: Before you begin work, think about what the code you're editing is supposed to do based on the filenames directory structure.

        # Planning
        (From Codex's instructions.) You have access to an `update_plan` tool which tracks steps and progress and renders them to the user. Using the tool helps demonstrate that you've understood the task and convey how you're approaching it. A good plan should break the task into meaningful, logically ordered steps that are easy to verify as you go. Plans are not for padding out simple work with filler steps or stating the obvious; do not use plans for simple or single-step queries that you can just do or answer immediately.
        Do not repeat the full contents of the plan after an `update_plan` call; the app already displays it. Maintain statuses in the tool: exactly one item in_progress at a time; mark items complete when done. If your understanding changes, update the plan (with an explanation) before continuing. Finish with all items completed or explicitly dropped before ending the turn.
        Use a plan when the task is non-trivial and will require multiple actions, when there are phases or dependencies where sequencing matters, when the user asked for more than one thing in a single prompt, or when the user asks for a plan or TODOs.

        # Code References

        When referencing specific functions or pieces of code include the pattern `file_path:line_number` to allow the user to easily navigate to the source code location.
        """

    /// opencode's environment block, with Limare's working folder and permission note.
    static func environment(modelID: String, workingDirectory: URL, hasProject: Bool, now: Date = Date()) -> String {
        let gitRoot = gitRoot(from: workingDirectory)
        var text = ""
        if !modelID.isEmpty { text += "You are powered by the model named \(modelID).\n" }
        text += """
            Here is some useful information about the environment you are running in:
            <env>
              Working directory: \(workingDirectory.path)
              Is directory a git repo: \(gitRoot == nil ? "no" : "yes")
              Platform: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
              Today's date: \(dateFormatter.string(from: now))
            </env>
            """
        text += hasProject
            ? "\n\nCurrent Project folder:\n\(workingDirectory.path)\n\nShell and file tools are available. Relative paths resolve from the Project folder."
            : "\n\nNo Project is active.\n\nShell and file tools are still available. Relative paths resolve from the conversation working directory:\n\(workingDirectory.path)"
        text += "\nFiles elsewhere on this Mac may also be accessed subject to permission policy and macOS permissions."
        return text
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd yyyy"
        return formatter
    }()

    /// `directory` and its ancestors up to `/`, as absolute paths; a relative path resolves
    /// against the current directory, so the walk always ends.
    static func ancestors(of directory: URL) -> [URL] {
        var components = URL(fileURLWithPath: directory.path).standardizedFileURL.pathComponents
        var result: [URL] = []
        while !components.isEmpty {
            result.append(URL(fileURLWithPath: NSString.path(withComponents: components)))
            components.removeLast()
        }
        return result
    }

    /// The git root containing `directory`, if any.
    static func gitRoot(from directory: URL) -> URL? {
        ancestors(of: directory).first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    static let instructionFileNames = ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]

    /// opencode's instruction files: the first global file that exists, then the first project
    /// file name (AGENTS.md, CLAUDE.md, CONTEXT.md) found from the working directory up to the
    /// git root, every ancestor's copy of it included.
    static func systemInstructionPaths(workingDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var paths: [URL] = []
        let globals = [home.appendingPathComponent(".config/limare/AGENTS.md"), home.appendingPathComponent(".claude/CLAUDE.md")]
        if let global = globals.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { paths.append(global) }
        let chain = ancestors(of: workingDirectory)
        let stopPath = gitRoot(from: workingDirectory)?.path ?? chain.first?.path
        let searched = chain.prefix { $0.path != stopPath } + chain.filter { $0.path == stopPath }.prefix(1)
        for name in instructionFileNames {
            let found = searched.map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !found.isEmpty { paths.append(contentsOf: found); break }
        }
        return paths
    }

    static func instructions(workingDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let sections = systemInstructionPaths(workingDirectory: workingDirectory, home: home).compactMap { url in
            readInstruction(url).map { "Instructions from: \(url.path)\n\($0)" }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// An instruction file's text; Codex caps project docs at 32 KiB and only that much is read.
    static func readInstruction(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let content = String(decoding: (try? handle.read(upToCount: 32_768)) ?? Data(), as: UTF8.self)
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content
    }

    /// opencode's Instruction.resolve: reading a file attaches the instruction files of the
    /// directories between it and the root (the root itself excluded, it is in the system
    /// prompt), nearest first, skipping the ones already loaded.
    static func nearbyInstructions(forFileAt file: URL, root: URL, excluding loaded: Set<String>) -> [(path: String, content: String)] {
        let rootPath = URL(fileURLWithPath: root.path).standardizedFileURL.path
        let target = URL(fileURLWithPath: file.path).standardizedFileURL
        var results: [(path: String, content: String)] = []
        for directory in ancestors(of: target.deletingLastPathComponent()) {
            guard directory.path.hasPrefix(rootPath + "/") else { break }
            guard let found = instructionFileNames.lazy.map({ directory.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  found.path != target.path, !loaded.contains(found.path),
                  let content = readInstruction(found) else { continue }
            results.append((found.path, "Instructions from: \(found.path)\n\(content)"))
        }
        return results
    }
}
