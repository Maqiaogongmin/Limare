import Foundation

public enum GPTLiveError: LocalizedError, Equatable, Sendable {
    case invalidModel(String)
    case unsupportedProtocol(String)
    case oauthNotSupported
    case missingAPIKey
    case invalidEndpoint(String)
    case connectionClosed(String)
    case handshakeTimedOut(Int)
    case serverError(code: String?, message: String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let model):
            return "Model '\(model)' is not a GPT-Live model."
        case .unsupportedProtocol(let proto):
            return "Protocol '\(proto)' does not support GPT-Live sessions."
        case .oauthNotSupported:
            return "ChatGPT OAuth does not authorize GPT-Live WebSocket sessions (API Key required)."
        case .missingAPIKey:
            return "API key is required for GPT-Live sessions."
        case .invalidEndpoint(let msg):
            return msg
        case .connectionClosed(let reason):
            return "GPT-Live WebSocket closed: \(reason)"
        case .handshakeTimedOut(let seconds):
            return "GPT-Live handshake timed out after \(seconds)s waiting for session.started."
        case .serverError(let code, let message):
            if let code, !code.isEmpty {
                return "GPT-Live error [\(code)]: \(message)"
            }
            return "GPT-Live error: \(message)"
        case .encodingFailed(let msg):
            return msg
        }
    }
}

public enum OpenAIGPTLiveRouting {
    public static func isGPTLiveModel(_ modelID: String) -> Bool {
        let bare = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return bare.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("gpt-live")
    }

    public static func webSocketURL(for provider: ProviderConfiguration) throws -> URL {
        guard provider.protocolAdapter == .responses || provider.protocolAdapter == .chatCompletions else {
            throw GPTLiveError.unsupportedProtocol(provider.protocolAdapter.rawValue)
        }
        guard provider.authenticationMode != .oauth else {
            throw GPTLiveError.oauthNotSupported
        }

        let httpURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: provider.appendV1Suffix,
            endpoint: "live/sessions"
        )
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            throw GPTLiveError.invalidEndpoint("Invalid GPT-Live endpoint URL.")
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: throw GPTLiveError.invalidEndpoint("Unsupported URL scheme for GPT-Live WebSocket.")
        }
        guard let wsURL = components.url else {
            throw GPTLiveError.invalidEndpoint("Failed to construct GPT-Live WebSocket URL.")
        }
        return wsURL
    }

    public static func makeWebSocketRequest(
        provider: ProviderConfiguration,
        apiKey: String?
    ) throws -> URLRequest {
        if provider.authenticationMode != .none {
            let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                throw GPTLiveError.missingAPIKey
            }
        }
        let wsURL = try webSocketURL(for: provider)
        var request = URLRequest(url: wsURL)
        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )
        return request
    }
}

public struct GPTLiveAudioFormat: Codable, Equatable, Sendable {
    public let type: String
    public let rate: Int

    public init(type: String = "audio/pcm", rate: Int = 24_000) {
        self.type = type
        self.rate = rate
    }
}

public enum GPTLiveDelegationConfig: Equatable, Sendable {
    case client
    case responses(model: String, instructions: String? = nil, toolJSONPayloads: [Data] = [])

    func toDictionary() -> [String: Any] {
        switch self {
        case .client:
            return ["type": "client"]
        case .responses(let model, let instructions, let toolJSONPayloads):
            var responsesObj: [String: Any] = ["model": model]
            if let instructions, !instructions.isEmpty {
                responsesObj["instructions"] = instructions
            }
            if !toolJSONPayloads.isEmpty {
                let parsedTools = toolJSONPayloads.compactMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
                if !parsedTools.isEmpty {
                    responsesObj["tools"] = parsedTools
                }
            }
            return [
                "type": "responses",
                "responses": responsesObj,
            ]
        }
    }
}

public struct GPTLiveSessionConfig: Equatable, Sendable {
    public let model: String
    public let instructions: String?
    public let voice: String
    public let audioFormat: GPTLiveAudioFormat
    public let delegation: GPTLiveDelegationConfig

    public init(
        model: String,
        instructions: String? = nil,
        voice: String = "marin",
        audioFormat: GPTLiveAudioFormat = GPTLiveAudioFormat(),
        delegation: GPTLiveDelegationConfig = .client
    ) {
        self.model = model
        self.instructions = instructions
        self.voice = voice
        self.audioFormat = audioFormat
        self.delegation = delegation
    }
}

public struct GPTLiveSessionInfo: Equatable, Sendable {
    public let id: String
    public let expiresAt: Int?
    public let status: String

    public init(id: String, expiresAt: Int? = nil, status: String) {
        self.id = id
        self.expiresAt = expiresAt
        self.status = status
    }
}

public enum GPTLiveClientEvent: Equatable, Sendable {
    case sessionStart(eventID: String = "evt_\(UUID().uuidString.prefix(8))", config: GPTLiveSessionConfig)
    case inputAudioAppend(eventID: String = "evt_\(UUID().uuidString.prefix(8))", base64Audio: String)
    case inputAudioMuted(eventID: String = "evt_\(UUID().uuidString.prefix(8))")
    case inputAudioUnmuted(eventID: String = "evt_\(UUID().uuidString.prefix(8))")
    case sessionUpdate(eventID: String = "evt_\(UUID().uuidString.prefix(8))", instructions: String? = nil, voice: String? = nil)
    case rawJSON(Data)

    public func encodedJSONData() throws -> Data {
        let dict: [String: Any]
        switch self {
        case .sessionStart(let eventID, let config):
            var sessionObj: [String: Any] = [
                "model": config.model,
                "audio": [
                    "format": [
                        "type": config.audioFormat.type,
                        "rate": config.audioFormat.rate,
                    ],
                    "output": [
                        "voice": config.voice,
                    ],
                ],
                "delegation": config.delegation.toDictionary(),
            ]
            if let instructions = config.instructions, !instructions.isEmpty {
                sessionObj["instructions"] = instructions
            }
            dict = [
                "type": "session.start",
                "event_id": eventID,
                "session": sessionObj,
            ]
        case .inputAudioAppend(let eventID, let base64Audio):
            dict = [
                "type": "session.input_audio.append",
                "event_id": eventID,
                "audio": base64Audio,
            ]
        case .inputAudioMuted(let eventID):
            dict = [
                "type": "session.input_audio.muted",
                "event_id": eventID,
            ]
        case .inputAudioUnmuted(let eventID):
            dict = [
                "type": "session.input_audio.unmuted",
                "event_id": eventID,
            ]
        case .sessionUpdate(let eventID, let instructions, let voice):
            var sessionObj: [String: Any] = [:]
            if let instructions { sessionObj["instructions"] = instructions }
            if let voice { sessionObj["audio"] = ["output": ["voice": voice]] }
            dict = [
                "type": "session.update",
                "event_id": eventID,
                "session": sessionObj,
            ]
        case .rawJSON(let data):
            return data
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            throw GPTLiveError.encodingFailed("Failed to encode GPT-Live client event.")
        }
        return data
    }

    public func encodedJSONString() throws -> String {
        let data = try encodedJSONData()
        guard let str = String(data: data, encoding: .utf8) else {
            throw GPTLiveError.encodingFailed("Failed to encode GPT-Live client event as UTF-8.")
        }
        return str
    }
}

public enum GPTLiveServerEvent: Equatable, Sendable {
    case sessionStarted(GPTLiveSessionInfo)
    case inputTranscriptDelta(String)
    case outputTranscriptDelta(String)
    case outputAudioDelta(Data)
    case delegationRequested(id: String?, rawJSON: String)
    case error(code: String?, message: String)
    case unknown(type: String, rawJSON: String)

    public static func decode(from jsonString: String) -> GPTLiveServerEvent {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            return .unknown(type: "invalid_json", rawJSON: jsonString)
        }

        switch type {
        case "session.started":
            let session = root["session"] as? [String: Any] ?? [:]
            let id = (session["id"] as? String) ?? ""
            let expiresAt = session["expires_at"] as? Int
            let status = (session["status"] as? String) ?? "active"
            return .sessionStarted(GPTLiveSessionInfo(id: id, expiresAt: expiresAt, status: status))

        case "session.input_transcript.delta":
            let delta = (root["delta"] as? String) ?? (root["text"] as? String) ?? ""
            return .inputTranscriptDelta(delta)

        case "session.output_transcript.delta":
            let delta = (root["delta"] as? String) ?? (root["text"] as? String) ?? ""
            return .outputTranscriptDelta(delta)

        case "session.output_audio.delta", "output_audio.delta", "response.audio.delta":
            let b64 = (root["delta"] as? String) ?? (root["audio"] as? String) ?? ""
            let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) ?? Data()
            return .outputAudioDelta(decoded)

        case "delegation.requested", "session.delegation.requested":
            let id = (root["delegation_id"] as? String) ?? (root["id"] as? String)
            return .delegationRequested(id: id, rawJSON: jsonString)

        case "error":
            let errObj = root["error"] as? [String: Any]
            let code = (errObj?["code"] as? String) ?? (root["code"] as? String)
            let message = (errObj?["message"] as? String) ?? (root["message"] as? String) ?? "Unknown server error"
            return .error(code: code, message: message)

        default:
            return .unknown(type: type, rawJSON: jsonString)
        }
    }
}

public protocol GPTLiveWebSocketTransport: Sendable {
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    func close()
}

private final class URLSessionGPTLiveWebSocketTransport: GPTLiveWebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(session: URLSession, request: URLRequest) {
        self.task = session.webSocketTask(with: request)
        self.task.resume()
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            throw GPTLiveError.connectionClosed("Unsupported WebSocket frame.")
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public final class OpenAIGPTLiveSession: @unchecked Sendable {
    public let sessionInfo: GPTLiveSessionInfo
    public let events: AsyncThrowingStream<GPTLiveServerEvent, Error>

    private let transport: any GPTLiveWebSocketTransport
    private let receiveTask: Task<Void, Never>

    init(
        sessionInfo: GPTLiveSessionInfo,
        transport: any GPTLiveWebSocketTransport
    ) {
        self.sessionInfo = sessionInfo
        self.transport = transport

        var continuationRef: AsyncThrowingStream<GPTLiveServerEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<GPTLiveServerEvent, Error> { continuation in
            continuationRef = continuation
        }
        self.events = stream

        let continuation = continuationRef!
        self.receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let raw = try await transport.receiveText()
                    let event = GPTLiveServerEvent.decode(from: raw)
                    continuation.yield(event)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func send(_ event: GPTLiveClientEvent) async throws {
        let jsonString = try event.encodedJSONString()
        try await transport.sendText(jsonString)
    }

    public func sendPCM16Audio(_ pcm16Data: Data) async throws {
        try await send(.inputAudioAppend(base64Audio: pcm16Data.base64EncodedString()))
    }

    public func setMuted(_ muted: Bool) async throws {
        try await send(muted ? .inputAudioMuted() : .inputAudioUnmuted())
    }

    public func close() {
        receiveTask.cancel()
        transport.close()
    }
}

public final class OpenAIGPTLiveClient: Sendable {
    public typealias TransportFactory = @Sendable (URLRequest) throws -> any GPTLiveWebSocketTransport
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    public static let defaultHandshakeTimeoutSeconds = 15

    private let transportFactory: TransportFactory
    private let sleeper: Sleeper

    public init(
        session: URLSession = .shared,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.transportFactory = { request in
            URLSessionGPTLiveWebSocketTransport(session: session, request: request)
        }
        self.sleeper = sleeper
    }

    public init(
        transportFactory: @escaping TransportFactory,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.transportFactory = transportFactory
        self.sleeper = sleeper
    }

    public func startSession(
        provider: ProviderConfiguration,
        apiKey: String?,
        config: GPTLiveSessionConfig,
        timeoutSeconds: Int = defaultHandshakeTimeoutSeconds
    ) async throws -> OpenAIGPTLiveSession {
        guard OpenAIGPTLiveRouting.isGPTLiveModel(config.model) else {
            throw GPTLiveError.invalidModel(config.model)
        }

        let request = try OpenAIGPTLiveRouting.makeWebSocketRequest(provider: provider, apiKey: apiKey)
        let transport = try transportFactory(request)
        let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)

        do {
            let startPayload = try GPTLiveClientEvent.sessionStart(config: config).encodedJSONString()
            try await transport.sendText(startPayload)

            let info = try await waitForSessionStarted(
                transport: transport,
                timeoutSeconds: timeoutSeconds,
                secrets: secrets
            )
            return OpenAIGPTLiveSession(sessionInfo: info, transport: transport)
        } catch {
            transport.close()
            if error is CancellationError {
                throw CancellationError()
            }
            if let liveError = error as? GPTLiveError {
                throw liveError
            }
            throw GPTLiveError.connectionClosed(SecretMasker.redact(error.localizedDescription, secrets: secrets))
        }
    }

    public func probeConnection(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        timeoutSeconds: Int = defaultHandshakeTimeoutSeconds
    ) async throws -> GPTLiveSessionInfo {
        let session = try await startSession(
            provider: provider,
            apiKey: apiKey,
            config: GPTLiveSessionConfig(model: modelID, delegation: .client),
            timeoutSeconds: timeoutSeconds
        )
        let info = session.sessionInfo
        session.close()
        return info
    }

    private func waitForSessionStarted(
        transport: any GPTLiveWebSocketTransport,
        timeoutSeconds: Int,
        secrets: [String]
    ) async throws -> GPTLiveSessionInfo {
        let sleeper = self.sleeper
        return try await withThrowingTaskGroup(of: GPTLiveSessionInfo.self) { group in
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let raw = try await transport.receiveText()
                    let event = GPTLiveServerEvent.decode(from: raw)
                    switch event {
                    case .sessionStarted(let info):
                        return info
                    case .error(let code, let message):
                        throw GPTLiveError.serverError(
                            code: code,
                            message: SecretMasker.redact(message, secrets: secrets)
                        )
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await sleeper(UInt64(max(1, timeoutSeconds)) * 1_000_000_000)
                throw GPTLiveError.handshakeTimedOut(timeoutSeconds)
            }

            do {
                guard let info = try await group.next() else {
                    throw GPTLiveError.connectionClosed("Handshake stream ended unexpectedly.")
                }
                group.cancelAll()
                return info
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
