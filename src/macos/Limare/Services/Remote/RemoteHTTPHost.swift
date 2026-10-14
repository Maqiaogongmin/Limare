#if canImport(Vapor) && canImport(JWTKit)
import CryptoKit
import Foundation
import Vapor

/// The embedded HTTP/WebSocket server. It listens only on 127.0.0.1 (Cloudflare Tunnel is the
/// one way in), verifies the Access token on every request, serves the Remote page, and bridges
/// each WebSocket to the session endpoint on the main actor. It holds no Limare state.
actor RemoteHTTPHost: RemoteTransportHost {
    private let configuration: RemoteAccessConfiguration
    private let verifier: CloudflareAccessVerifier
    private let endpoint: any RemoteSessionEndpoint
    private let webRoot: URL
    /// Where refused requests are reported (Limare's log); Vapor's own logger goes nowhere visible.
    private let report: @Sendable (String) -> Void
    /// Where uploads are written while they arrive; each is deleted once the session has taken it in.
    private let uploadDirectory: URL
    private var application: Application?

    init(configuration: RemoteAccessConfiguration, verifier: CloudflareAccessVerifier, endpoint: any RemoteSessionEndpoint, webRoot: URL,
         uploadDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("limare-remote-uploads", isDirectory: true),
         report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.verifier = verifier
        self.endpoint = endpoint
        self.webRoot = webRoot
        self.uploadDirectory = uploadDirectory
        self.report = report
    }

    /// Starts serving and returns the bound port.
    func start() async throws -> Int {
        if let application, let port = application.http.server.shared.localAddress?.port { return port }
        // Explicit arguments: Vapor must not parse Limare's own command line.
        let app = try await Application.make(Environment(name: "production", arguments: ["limare"]))
        app.logger.logLevel = .warning
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = configuration.port
        // No response compression here: Cloudflare already compresses for the browser, and Vapor's
        // compressor reuses one ETag for both encodings without `Vary`, so a cache can hand out
        // compressed bytes as plain JavaScript (the page then never starts).
        app.middleware = Middlewares()
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        app.middleware.use(RemoteAccessGate(configuration: configuration, verifier: verifier, report: report))
        app.middleware.use(RemotePageMiddleware(webRoot: webRoot, fingerprint: RemoteAssets.fingerprint(of: webRoot)))
        // Everything not under the versioned prefix (manifest, icons): revalidated on every load.
        app.middleware.use(FileMiddleware(publicDirectory: webRoot.path + "/", defaultFile: "index.html", cachePolicy: .noCache))
        app.get("healthz") { _ in "ok" }

        let configuration = self.configuration
        let endpoint = self.endpoint
        let report = self.report
        let uploadDirectory = self.uploadDirectory
        app.on(.POST, "attachments", body: .stream) { request async -> Response in
            await Self.receiveUpload(request, configuration: configuration, endpoint: endpoint, directory: uploadDirectory, report: report)
        }
        app.on(.GET, "files", ":conversation", ":source", ":id") { request async throws -> Response in
            try await Self.serveFile(request, endpoint: endpoint)
        }
        app.webSocket("ws", maxFrameSize: .init(integerLiteral: 256 * 1024), shouldUpgrade: { request in
            if let rejection = RemoteAccessPolicy.check(origin: request.headers.first(name: .origin), configuration: configuration) {
                report("Refused a WebSocket: \(rejection.rawValue)")
                return nil
            }
            return [:]
        }, onUpgrade: { request, socket in
            await Self.serve(socket, expiresAt: request.storage[RemoteIdentityKey.self]?.expiresAt, endpoint: endpoint)
        })

        do {
            try await app.asyncBoot()
            try await app.server.start(address: nil)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        application = app
        return app.http.server.shared.localAddress?.port ?? configuration.port
    }

    func stop() async {
        guard let app = application else { return }
        application = nil
        await app.server.shutdown()
        try? await app.asyncShutdown()
    }

    /// `POST /attachments?connection=<id>&filename=<name>`: the body, streamed to a file of its own
    /// (never more than `RemoteWire.maxUploadBytes`), handed to the session, then deleted.
    private static func receiveUpload(_ request: Request, configuration: RemoteAccessConfiguration, endpoint: any RemoteSessionEndpoint,
                                      directory: URL, report: @Sendable (String) -> Void) async -> Response {
        // A state-changing request: same-origin only, like the WebSocket upgrade.
        if let rejection = RemoteAccessPolicy.check(origin: request.headers.first(name: .origin), configuration: configuration) {
            report("Refused an upload: \(rejection.rawValue)")
            return Response(status: .forbidden)
        }
        guard let connectionID = request.query[UUID.self, at: "connection"], await endpoint.mayUpload(connectionID: connectionID) else {
            return uploadError(.conflict, RemoteUploadError(code: "uploadRefused", message: "连接已断开，或附件已达 \(RemoteWire.maxPendingAttachments) 个。"))
        }
        let tooLarge = RemoteUploadError(code: "tooLarge", message: "文件超过 \(RemoteWire.maxUploadBytes / 1024 / 1024) MB。")
        if let length = request.headers.first(name: .contentLength).flatMap(Int.init), length > RemoteWire.maxUploadBytes {
            return uploadError(.payloadTooLarge, tooLarge)
        }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(RemoteAccessPolicy.uploadFilename(request.query[String.self, at: "filename"]))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var received = 0
            for try await chunk in request.body {
                received += chunk.readableBytes
                guard received <= RemoteWire.maxUploadBytes else { return uploadError(.payloadTooLarge, tooLarge) }
                try handle.write(contentsOf: Data(buffer: chunk))
            }
        } catch {
            return uploadError(.badRequest, RemoteUploadError(code: "uploadFailed", message: "上传中断：\(error.localizedDescription)"))
        }
        switch await endpoint.receiveUpload(at: file, connectionID: connectionID) {
        case .success(let attachment):
            let response = Response(status: .ok)
            try? response.content.encode(attachment, as: .json)
            return response
        case .failure(let error):
            return uploadError(.unprocessableEntity, error)
        }
    }

    /// `GET /files/<conversation>/<source>/<id>`: a file a card of that conversation names (see
    /// `RemoteFile`). The session finds it; nothing in the address is a path.
    private static func serveFile(_ request: Request, endpoint: any RemoteSessionEndpoint) async throws -> Response {
        // Only the page reads files: never a request another site's page started.
        if request.headers.first(name: "Sec-Fetch-Site") == "cross-site" { return Response(status: .forbidden) }
        guard let conversationID = request.parameters.get("conversation", as: UUID.self),
              let source = request.parameters.get("source").flatMap(RemoteFile.Source.init(rawValue:)),
              let id = request.parameters.get("id", as: UUID.self),
              let file = await endpoint.file(conversationID: conversationID, source: source, id: id) else {
            return Response(status: .notFound)
        }
        let response = try await request.fileio.asyncStreamFile(at: file.location.path)
        for (name, value) in RemoteFile.headers(filename: file.filename, preview: file.preview) {
            response.headers.replaceOrAdd(name: name, value: value)
        }
        return response
    }

    private static func uploadError(_ status: HTTPResponseStatus, _ error: RemoteUploadError) -> Response {
        let response = Response(status: status)
        try? response.content.encode(["code": error.code, "message": error.message], as: .json)
        return response
    }

    /// Commands a client may have waiting before its connection is closed.
    static let commandBacklog = 64

    /// One client: commands are handled strictly in arrival order on the main actor. A client that
    /// gets more than `commandBacklog` commands ahead is disconnected rather than have one dropped:
    /// the waiting commands are an unbroken prefix of what it sent, and it reconnects to a snapshot.
    private static func serve(_ socket: WebSocket, expiresAt: Date?, endpoint: any RemoteSessionEndpoint) async {
        let connection = WebSocketClientConnection(socket: socket)
        let (frames, continuation) = AsyncStream<RemoteCommandFrame>.makeStream(bufferingPolicy: .bufferingOldest(commandBacklog))
        socket.pingInterval = .seconds(30)
        // Socket callbacks are bound to its event loop. Registered there before the session starts,
        // so they are in place before the hello (written through the same loop) reaches the client.
        socket.eventLoop.execute {
            socket.onText { socket, text in
                guard let frame = try? JSONDecoder().decode(RemoteCommandFrame.self, from: Data(text.utf8)) else {
                    _ = socket.close(code: .unacceptableData)
                    return
                }
                if case .dropped = continuation.yield(frame) {
                    continuation.finish()
                    _ = socket.close(code: .policyViolation)
                }
            }
            socket.onClose.whenComplete { _ in continuation.finish() }
            if let expiresAt {
                // The Access session ends with its token; the client reconnects through Access.
                let remaining = max(0, Int64(expiresAt.timeIntervalSinceNow))
                _ = socket.eventLoop.scheduleTask(in: .seconds(remaining)) { _ = socket.close(code: .policyViolation) }
            }
        }
        Task {
            await endpoint.connect(connection)
            for await frame in frames {
                await endpoint.handle(frame, from: connection)
            }
            await endpoint.disconnect(connection)
        }
    }
}

/// Versioned addresses for the page's files. Safari's memory cache can hand a reloaded page old
/// modules even when they are marked `no-cache`, and a new `main.js` importing an old `list.js`
/// stops the page. So the page's files live under `/v/<fingerprint>/`, where the fingerprint
/// changes whenever any file does; `index.html` (never stored) names the current one.
enum RemoteAssets {
    static let placeholder = "__ASSET_BASE__"
    static let immutable = "public, max-age=31536000, immutable"

    /// A digest of every file's path and contents under `webRoot`.
    static func fingerprint(of webRoot: URL) -> String {
        let root = webRoot.standardizedFileURL.path
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []).sorted()
        var hash = SHA256()
        for relative in files {
            let path = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            hash.update(data: Data(relative.utf8))
            hash.update(data: data)
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The file `relative` names inside `webRoot`, or nil if it is outside it or not a regular file.
    static func file(_ relative: String, in webRoot: URL) -> URL? {
        let root = webRoot.standardizedFileURL.path
        let candidate = webRoot.appendingPathComponent(relative).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !relative.isEmpty, candidate.path.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return candidate
    }
}

/// `/` and `/index.html` with the asset placeholder filled in; `/v/<fingerprint>/…` as immutable files.
private struct RemotePageMiddleware: AsyncMiddleware {
    let webRoot: URL
    let fingerprint: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .GET || request.method == .HEAD else { return try await next.respond(to: request) }
        let path = request.url.path
        if path == "/" || path == "/index.html" {
            guard let template = try? String(contentsOf: webRoot.appendingPathComponent("index.html"), encoding: .utf8) else {
                return Response(status: .notFound)
            }
            let response = Response(status: .ok, body: .init(string: template.replacingOccurrences(of: RemoteAssets.placeholder, with: "v/\(fingerprint)/")))
            response.headers.contentType = .html
            return response
        }
        guard path.hasPrefix("/v/") else { return try await next.respond(to: request) }
        // An address from another build: the page that asked for it is stale and reloads.
        let prefix = "/v/\(fingerprint)/"
        guard path.hasPrefix(prefix), let file = RemoteAssets.file(String(path.dropFirst(prefix.count)), in: webRoot) else {
            return Response(status: .notFound)
        }
        let response = try await request.fileio.asyncStreamFile(at: file.path)
        response.headers.replaceOrAdd(name: .cacheControl, value: RemoteAssets.immutable)
        return response
    }
}

private struct RemoteIdentityKey: StorageKey {
    typealias Value = CloudflareAccessVerifier.Identity
}

/// Every request: the public hostname and a valid Access token, or 403. Adds the security headers.
private struct RemoteAccessGate: AsyncMiddleware {
    let configuration: RemoteAccessConfiguration
    let verifier: CloudflareAccessVerifier
    let report: @Sendable (String) -> Void

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let rejection = RemoteAccessPolicy.check(host: request.headers.first(name: .host), configuration: configuration) {
            return refuse(request, rejection)
        }
        guard let token = request.headers.first(name: RemoteAccessPolicy.tokenHeader), !token.isEmpty else {
            return refuse(request, .missingToken)
        }
        do {
            request.storage[RemoteIdentityKey.self] = try await verifier.verify(token)
        } catch {
            return refuse(request, error)
        }
        let response = try await next.respond(to: request)
        // A response with a policy of its own (a served file) keeps it.
        for (name, value) in RemoteAccessPolicy.responseHeaders where response.headers.first(name: name) == nil {
            response.headers.add(name: name, value: value)
        }
        response.headers.replaceOrAdd(name: .cacheControl, value: RemoteAccessPolicy.cacheControl(
            path: request.url.path, current: response.headers.first(name: .cacheControl)))
        return response
    }

    private func refuse(_ request: Request, _ rejection: RemoteAccessRejection) -> Response {
        report("Refused \(request.method) \(request.url.path): \(rejection.rawValue)")
        return Response(status: .forbidden)
    }
}

/// A WebSocket as the hub sees it. A client that stops reading is disconnected rather than
/// buffered without bound; it reconnects and gets a fresh snapshot.
private final class WebSocketClientConnection: RemoteClientConnection, @unchecked Sendable {
    static let maxPendingSends = 256

    let id = UUID()
    private let socket: WebSocket
    private let lock = NSLock()
    private var pendingSends = 0

    init(socket: WebSocket) {
        self.socket = socket
    }

    func send(_ text: String) {
        let overloaded = lock.withLock { () -> Bool in
            pendingSends += 1
            return pendingSends > Self.maxPendingSends
        }
        if overloaded {
            _ = socket.close(code: .unknown(1013))
            return
        }
        let promise = socket.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.pendingSends -= 1 }
        }
        socket.send(text, promise: promise)
    }

    func close() {
        _ = socket.close(code: .goingAway)
    }
}
#endif
