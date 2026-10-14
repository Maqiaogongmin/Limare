import Foundation
import UniformTypeIdentifiers

// Remote wire v5: JSON text frames on the `/ws` WebSocket. Server events always carry whole
// objects (never deltas, never sequence numbers); a client that reconnects asks for fresh
// snapshots and rebuilds everything it shows from them. A conversation arrives as its latest
// page of messages; older pages are asked for as the reader scrolls back. Attachments are
// uploaded over HTTP (`POST /attachments`) and named by id when the input is submitted.
// v4: composer commands ("/compact") are admitted like any input; `hello` lists them and a
// conversation carries its compaction lines.
// v5: the files a message shows as cards (its attachments, a turn's deliverables, a file tool's
// target) are `RemoteFile`s, read at `GET /files/<conversation>/<source>/<id>`.

enum RemoteWire {
    static let protocolVersion = 5
    /// The longest input text a client may submit.
    static let maxInputCharacters = 64 * 1024
    static let maxRequestIDLength = 64
    /// At most this many attachments wait unsent per connection (= the Mac composer's limit).
    static let maxPendingAttachments = 8
    /// The largest upload accepted; images are further held to the Mac's 25 MB by AttachmentStore.
    static let maxUploadBytes = 50 * 1024 * 1024

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Projections

struct RemoteConversationSummary: Codable, Equatable, Sendable {
    enum RunBadge: String, Codable, Sendable {
        case running, pausing, paused
    }

    let id: UUID
    let title: String
    let updatedAt: Date
    let projectID: UUID?
    let projectName: String?
    let isPinned: Bool
    let run: RunBadge?
    let hasPendingApproval: Bool
}

struct RemoteProjectSummary: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isPinned: Bool
}

/// A model a conversation can use: a Model Group or one provider's model.
enum RemoteModelRef: Codable, Equatable, Sendable {
    case group(String)
    case direct(providerID: UUID, modelID: String)

    private enum CodingKeys: String, CodingKey {
        case kind, groupID, providerID, modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "group": self = .group(try container.decode(String.self, forKey: .groupID))
        case "direct": self = .direct(providerID: try container.decode(UUID.self, forKey: .providerID), modelID: try container.decode(String.self, forKey: .modelID))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown model kind '\(kind)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let groupID):
            try container.encode("group", forKey: .kind)
            try container.encode(groupID, forKey: .groupID)
        case .direct(let providerID, let modelID):
            try container.encode("direct", forKey: .kind)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(modelID, forKey: .modelID)
        }
    }
}

/// The thinking-level menu as the Mac composer shows it. `level` nil is "the group's default".
struct RemoteThinking: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        let level: String?
        let label: String
        let isSelected: Bool
    }

    let label: String
    let options: [Option]
}

/// One entry of the model menu; `thinking` is what a new conversation on this model would offer.
struct RemoteModelChoice: Codable, Equatable, Sendable {
    let model: RemoteModelRef
    let label: String
    /// "Model Groups", or the provider's name.
    let section: String
    let thinking: RemoteThinking?
}

struct RemoteModelCatalog: Codable, Equatable, Sendable {
    let choices: [RemoteModelChoice]
    /// What a new conversation uses unless another model is chosen.
    let defaultModel: RemoteModelRef?
}

/// A command the composer offers after "/" (the Mac's `ComposerCommand`). It is run by
/// submitting its invocation as the input text.
struct RemoteComposerCommand: Codable, Equatable, Sendable {
    let name: String
    let summary: String
}

/// The Compact command in a conversation's transcript: a line after the message that was last
/// when each finished one ran, and one at the end while one runs or after one failed.
struct RemoteCompactions: Codable, Equatable, Sendable {
    struct Finished: Codable, Equatable, Sendable {
        let afterMessageID: UUID
        let tokensBefore: Int
        let tokensAfter: Int
    }

    struct Current: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case running, failed
        }

        let state: State
        let since: Date?
        let message: String?
    }

    let finished: [Finished]
    let current: Current?
}

/// The open conversation's composer settings.
struct RemoteConversationSettings: Codable, Equatable, Sendable {
    let model: RemoteModelRef?
    let modelLabel: String
    let thinking: RemoteThinking?
}

struct RemoteAttachment: Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let kind: String
    let byteCount: Int
}

/// A file a message shows as a card, as the Mac's `FileArtifactCard` does. `preview` is how the
/// Mac previews it (`FilePreviewClassifier`: markdown, text, code, image, pdf, html), nil when it
/// does not; the page renders by that kind alone, so a type the Mac learns to preview needs
/// nothing new on the page. `url` reads it, relative to the page.
struct RemoteFile: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable, CaseIterable {
        /// An attachment of a message in the conversation, named by its id.
        case attachment
        /// An artifact of the conversation, named by its id.
        case artifact
        /// The workspace file a file tool call of the conversation names, by the call's id.
        case toolCall
    }

    let source: Source
    let id: UUID
    let url: String
    let filename: String
    let byteCount: Int?
    let preview: String?
    /// The language of a `code` preview ("Swift").
    let language: String?

    init(source: Source, id: UUID, conversationID: UUID, filename: String, byteCount: Int?, preview: String?, language: String? = nil) {
        self.source = source
        self.id = id
        self.url = Self.path(conversationID: conversationID, source: source, id: id)
        self.filename = filename
        self.byteCount = byteCount
        self.preview = preview
        self.language = language
    }

    static func path(conversationID: UUID, source: Source, id: UUID) -> String {
        "files/\(conversationID.uuidString)/\(source.rawValue)/\(id.uuidString)"
    }

    /// The response headers for a file of `filename` previewed as `preview`. A previewable file is
    /// shown inline; anything else is a download, so the phone handles it as Finder's default app
    /// would on the Mac. HTML and SVG stay passive as in the Mac's preview: sandboxed, no script,
    /// nothing loaded from the network. Text kinds are plain text, whatever their extension.
    static func headers(filename: String, preview: String?) -> [(String, String)] {
        let ext = (filename as NSString).pathExtension
        let type: String
        switch preview {
        case "markdown", "text", "code":
            type = "text/plain; charset=utf-8"
        case "html":
            type = "text/html; charset=utf-8"
        default:
            type = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
        var headers = [
            ("Content-Type", type),
            ("X-Content-Type-Options", "nosniff"),
            ("Cache-Control", "private, no-cache"),
            ("Content-Disposition", "\(preview == nil ? "attachment" : "inline"); filename*=UTF-8''\(encodedFilename(filename))"),
        ]
        // Framed only by the page itself, whose preview shows HTML and PDF in an iframe.
        if preview == "html" || ext.lowercased() == "svg" {
            headers.append(("Content-Security-Policy", "sandbox; default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; frame-ancestors 'self'"))
        } else if preview == "pdf" {
            headers.append(("Content-Security-Policy", "frame-ancestors 'self'"))
        }
        return headers
    }

    private static func encodedFilename(_ filename: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
    }
}

struct RemoteToolCall: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let state: String
    let approvalState: String
    let input: String
    let inputTruncated: Bool
    let output: String
    let outputTruncated: Bool
    let errorMessage: String?
    let durationMs: Int?
    /// The workspace file a file tool reads or writes, shown as a card under the call.
    let file: RemoteFile?
}

struct RemoteMessage: Codable, Equatable, Sendable {
    let id: UUID
    let role: String
    let state: String
    let content: String
    let reasoning: String?
    let isSystemNotice: Bool
    let model: String?
    let attachments: [RemoteFile]
    let toolCalls: [RemoteToolCall]
    /// The files this message's tool calls delivered to the user (the Mac's `TurnDeliverables`);
    /// a folded turn shows all of its messages' on its answer.
    let files: [RemoteFile]
}

struct RemoteRun: Codable, Equatable, Sendable {
    let id: UUID
    let status: String
    let isPausing: Bool
    let startedAt: Date
    let error: String?
    /// What the run is doing, in the words the Mac shows ("Running command", "Waiting for approval").
    let statusText: String?
}

/// A conversation's run and the inputs queued behind it.
struct RemoteRunState: Codable, Equatable, Sendable {
    let run: RemoteRun?
    let queuedCount: Int
    let queueHeld: Bool
}

struct RemoteApproval: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A tool call waiting for PermissionStore.
        case tool
        /// A Computer Use app waiting for ComputerUseAppAuthorizationStore.
        case app
    }

    let kind: Kind
    let id: UUID
    let conversationID: UUID?
    let conversationTitle: String?
    let toolName: String?
    let summary: String?
    let reason: String?
    let command: String?
    let affectedPaths: [String]
    let environmentKeys: [String]
    let requestsNetwork: Bool
    let isHighRisk: Bool
    let appName: String?
    let bundleID: String?
}

// MARK: - Client → server

enum RemoteCommand: Equatable, Sendable {
    enum SubmitMode: String, Sendable {
        case send, queue, steer
    }

    case openConversation(UUID)
    /// The page of messages just before `before`, the oldest message the client has.
    case loadEarlier(conversationID: UUID, before: UUID)
    /// `model` and `thinking` only for a new conversation (no `conversationID`).
    case submit(conversationID: UUID?, projectID: UUID?, text: String, mode: SubmitMode,
                attachmentIDs: [UUID] = [], model: RemoteModelRef? = nil, thinking: String? = nil)
    case setModel(conversationID: UUID, model: RemoteModelRef)
    /// `level` nil returns to the default (a Model Group's own level).
    case setThinking(conversationID: UUID, level: String?)
    case discardAttachment(UUID)
    case stop(UUID)
    case pause(UUID)
    case resume(UUID)
    case resumeQueue(UUID)
    case clearQueue(UUID)
    case resolveApproval(kind: RemoteApproval.Kind, id: UUID, approved: Bool)

    var name: String {
        switch self {
        case .openConversation: "conversation.open"
        case .loadEarlier: "conversation.loadEarlier"
        case .submit: "input.submit"
        case .setModel: "conversation.setModel"
        case .setThinking: "conversation.setThinking"
        case .discardAttachment: "attachment.discard"
        case .stop: "run.stop"
        case .pause: "run.pause"
        case .resume: "run.resume"
        case .resumeQueue: "queue.resume"
        case .clearQueue: "queue.clear"
        case .resolveApproval: "approval.resolve"
        }
    }
}

/// One command frame. Decoding accepts only the frozen command set with all its required fields;
/// anything else fails, and the server closes the connection.
struct RemoteCommandFrame: Decodable, Equatable, Sendable {
    let requestID: String
    let command: RemoteCommand

    init(requestID: String, command: RemoteCommand) {
        self.requestID = requestID
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case type, requestID, conversationID, beforeMessageID, projectID, text, mode, kind, approvalID, approved
        case attachmentIDs, model, thinking, level, attachmentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        guard !requestID.isEmpty, requestID.count <= RemoteWire.maxRequestIDLength else {
            throw DecodingError.dataCorruptedError(forKey: .requestID, in: container, debugDescription: "requestID must be 1-\(RemoteWire.maxRequestIDLength) characters")
        }
        func conversation() throws -> UUID { try container.decode(UUID.self, forKey: .conversationID) }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "conversation.open":
            command = .openConversation(try conversation())
        case "conversation.loadEarlier":
            command = .loadEarlier(conversationID: try conversation(), before: try container.decode(UUID.self, forKey: .beforeMessageID))
        case "input.submit":
            let text = try container.decode(String.self, forKey: .text)
            guard text.count <= RemoteWire.maxInputCharacters else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "text is longer than \(RemoteWire.maxInputCharacters) characters")
            }
            let rawMode = try container.decode(String.self, forKey: .mode)
            guard let mode = RemoteCommand.SubmitMode(rawValue: rawMode) else {
                throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "unknown mode '\(rawMode)'")
            }
            let attachmentIDs = try container.decodeIfPresent([UUID].self, forKey: .attachmentIDs) ?? []
            guard attachmentIDs.count <= RemoteWire.maxPendingAttachments else {
                throw DecodingError.dataCorruptedError(forKey: .attachmentIDs, in: container, debugDescription: "more than \(RemoteWire.maxPendingAttachments) attachments")
            }
            command = .submit(
                conversationID: try container.decodeIfPresent(UUID.self, forKey: .conversationID),
                projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
                text: text,
                mode: mode,
                attachmentIDs: attachmentIDs,
                model: try container.decodeIfPresent(RemoteModelRef.self, forKey: .model),
                thinking: try container.decodeIfPresent(String.self, forKey: .thinking)
            )
        case "conversation.setModel":
            command = .setModel(conversationID: try conversation(), model: try container.decode(RemoteModelRef.self, forKey: .model))
        case "conversation.setThinking":
            // `level` must be present; null means "default".
            guard container.contains(.level) else {
                throw DecodingError.keyNotFound(CodingKeys.level, .init(codingPath: container.codingPath, debugDescription: "level is required (null for the default)"))
            }
            command = .setThinking(conversationID: try conversation(), level: try container.decodeIfPresent(String.self, forKey: .level))
        case "attachment.discard":
            command = .discardAttachment(try container.decode(UUID.self, forKey: .attachmentID))
        case "run.stop": command = .stop(try conversation())
        case "run.pause": command = .pause(try conversation())
        case "run.resume": command = .resume(try conversation())
        case "queue.resume": command = .resumeQueue(try conversation())
        case "queue.clear": command = .clearQueue(try conversation())
        case "approval.resolve":
            command = .resolveApproval(
                kind: try container.decode(RemoteApproval.Kind.self, forKey: .kind),
                id: try container.decode(UUID.self, forKey: .approvalID),
                approved: try container.decode(Bool.self, forKey: .approved)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown command '\(type)'")
        }
    }
}

// MARK: - Server → client

enum RemoteServerEvent: Encodable, Equatable, Sendable {
    /// Sent once when a connection opens: everything the list, the composer menus and the approval
    /// layer need. `connectionID` names this connection to `POST /attachments`.
    case hello(connectionID: UUID, conversations: [RemoteConversationSummary], projects: [RemoteProjectSummary],
               models: RemoteModelCatalog, approvals: [RemoteApproval], commands: [RemoteComposerCommand])
    /// The open conversation from its latest page on: on open, and whenever the messages the
    /// client has changed other than by appending. `hasEarlier` says older messages exist.
    case conversationSnapshot(conversation: RemoteConversationSummary, messages: [RemoteMessage], hasEarlier: Bool, runState: RemoteRunState,
                              settings: RemoteConversationSettings, compactions: RemoteCompactions)
    case conversationSettings(conversationID: UUID, settings: RemoteConversationSettings)
    case conversationCompactions(conversationID: UUID, compactions: RemoteCompactions)
    case projectsChanged(projects: [RemoteProjectSummary])
    case modelsChanged(models: RemoteModelCatalog)
    /// The answer to `conversation.loadEarlier`: the messages just before the client's oldest one.
    case conversationEarlier(conversationID: UUID, messages: [RemoteMessage], hasEarlier: Bool)
    case conversationsChanged(upserts: [RemoteConversationSummary], removed: [UUID])
    case messageUpsert(conversationID: UUID, message: RemoteMessage)
    case runChanged(conversationID: UUID, runState: RemoteRunState)
    case approvalsChanged(approvals: [RemoteApproval])
    case commandResult(requestID: String, ok: Bool, error: String?, admission: String?, conversationID: UUID?)

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, connectionID, conversations, projects, models, approvals, commands, conversation, messages, hasEarlier, runState, settings
        case compactions
        case upserts, removed, conversationID, message, requestID, ok, error, admission
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let connectionID, let conversations, let projects, let models, let approvals, let commands):
            try container.encode("hello", forKey: .type)
            try container.encode(RemoteWire.protocolVersion, forKey: .protocolVersion)
            try container.encode(connectionID, forKey: .connectionID)
            try container.encode(conversations, forKey: .conversations)
            try container.encode(projects, forKey: .projects)
            try container.encode(models, forKey: .models)
            try container.encode(approvals, forKey: .approvals)
            try container.encode(commands, forKey: .commands)
        case .conversationSnapshot(let conversation, let messages, let hasEarlier, let runState, let settings, let compactions):
            try container.encode("conversation.snapshot", forKey: .type)
            try container.encode(conversation, forKey: .conversation)
            try container.encode(messages, forKey: .messages)
            try container.encode(hasEarlier, forKey: .hasEarlier)
            try container.encode(runState, forKey: .runState)
            try container.encode(settings, forKey: .settings)
            try container.encode(compactions, forKey: .compactions)
        case .conversationSettings(let conversationID, let settings):
            try container.encode("conversation.settings", forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(settings, forKey: .settings)
        case .conversationCompactions(let conversationID, let compactions):
            try container.encode("conversation.compactions", forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(compactions, forKey: .compactions)
        case .projectsChanged(let projects):
            try container.encode("projects.changed", forKey: .type)
            try container.encode(projects, forKey: .projects)
        case .modelsChanged(let models):
            try container.encode("models.changed", forKey: .type)
            try container.encode(models, forKey: .models)
        case .conversationEarlier(let conversationID, let messages, let hasEarlier):
            try container.encode("conversation.earlier", forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(messages, forKey: .messages)
            try container.encode(hasEarlier, forKey: .hasEarlier)
        case .conversationsChanged(let upserts, let removed):
            try container.encode("conversations.changed", forKey: .type)
            try container.encode(upserts, forKey: .upserts)
            try container.encode(removed, forKey: .removed)
        case .messageUpsert(let conversationID, let message):
            try container.encode("message.upsert", forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(message, forKey: .message)
        case .runChanged(let conversationID, let runState):
            try container.encode("run.changed", forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(runState, forKey: .runState)
        case .approvalsChanged(let approvals):
            try container.encode("approvals.changed", forKey: .type)
            try container.encode(approvals, forKey: .approvals)
        case .commandResult(let requestID, let ok, let error, let admission, let conversationID):
            try container.encode("command.result", forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(ok, forKey: .ok)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(admission, forKey: .admission)
            try container.encodeIfPresent(conversationID, forKey: .conversationID)
        }
    }
}

// MARK: - Session boundary

/// One connected client as the hub sees it. The transport implements it; `send` must be safe to
/// call from the main actor and keep the order of calls.
protocol RemoteClientConnection: AnyObject, Sendable {
    var id: UUID { get }
    func send(_ text: String)
    func close()
}

/// Why an upload was not taken: `code` for the page, `message` for the person.
struct RemoteUploadError: Error, Equatable, Sendable {
    let code: String
    let message: String
}

/// A file `GET /files/...` serves: where it is on disk, and what its response says about it.
struct RemoteServedFile: Equatable, Sendable {
    let location: URL
    let filename: String
    let preview: String?
}

/// What the transport needs from the session: the hub, behind a seam that keeps Vapor out of it.
@MainActor
protocol RemoteSessionEndpoint: AnyObject, Sendable {
    func connect(_ connection: RemoteClientConnection)
    func disconnect(_ connection: RemoteClientConnection)
    func handle(_ frame: RemoteCommandFrame, from connection: RemoteClientConnection)
    /// Whether connection `connectionID` is open and may add another attachment (checked before
    /// the body is read).
    func mayUpload(connectionID: UUID) -> Bool
    /// Takes in a file the transport has written (and will delete afterwards) as a pending
    /// attachment of connection `connectionID`.
    func receiveUpload(at file: URL, connectionID: UUID) async -> Result<RemoteAttachment, RemoteUploadError>
    /// The file a card of conversation `conversationID` names, if it is still there.
    func file(conversationID: UUID, source: RemoteFile.Source, id: UUID) -> RemoteServedFile?
}

/// A transport that serves the remote session (the embedded Vapor server in the app).
protocol RemoteTransportHost: Sendable {
    /// Starts serving and returns the bound port.
    func start() async throws -> Int
    func stop() async
}
