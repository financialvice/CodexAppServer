import Foundation
import CodexAppServerProtocol

public actor CodexClient {
    public nonisolated let events: AsyncStream<CodexEvent>
    public private(set) var serverInfo: InitializeResponse?

    private let eventContinuation: AsyncStream<CodexEvent>.Continuation
    private let encoder = newJSONEncoder()
    private let decoder = newJSONDecoder()

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var delegate: WebSocketOpenDelegate?
    private var listenTask: Task<Void, Never>?
#if os(macOS)
    private var localProcess: LocalCodexAppServerProcess?
#endif
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var connected = false

    public init() {
        var continuation: AsyncStream<CodexEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation!
    }

    deinit {
        listenTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
#if os(macOS)
        if let localProcess {
            Task {
                await localProcess.stop()
            }
        }
#endif
        eventContinuation.finish()
    }

    public static func connect(
        _ connection: CodexConnection,
        options: CodexClientOptions
    ) async throws -> CodexClient {
        let client = CodexClient()
        try await client.bootstrap(connection, options: options)
        return client
    }

    public func call<Method: CodexRPCMethod>(
        _ method: Method.Type,
        params: Method.Params
    ) async throws -> Method.Response {
        let data = try await request(method: method.method.rawValue, params: params)
        return try decoder.decode(Method.Response.self, from: data)
    }

    public func respond<Method: CodexServerRequestMethod>(
        to request: TypedServerRequest<Method>,
        result: Method.Response
    ) async throws {
        try await sendResponse(id: request.id, result: result)
    }

    public func reject(
        requestID: RequestId,
        code: Int = -32001,
        message: String
    ) async throws {
        let idObject = try jsonObject(from: requestID)
        let payload: [String: Any] = [
            "id": idObject,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        try await send(jsonObject: payload)
    }

    public func reject(
        _ request: AnyTypedServerRequest,
        code: Int = -32001,
        message: String
    ) async throws {
        try await reject(requestID: request.id, code: code, message: message)
    }

    public func disconnect() async {
        await shutdown(reason: nil)
    }

    private func bootstrap(
        _ connection: CodexConnection,
        options: CodexClientOptions
    ) async throws {
        emit(.connectionStateChanged(.connecting))

        let connectionInfo: (url: URL, authToken: String?)
        switch connection {
#if os(macOS)
        case .localManaged(let localOptions):
            let process = try await LocalCodexAppServerProcess.launch(
                options: localOptions,
                versionPolicy: options.versionPolicy
            )
            self.localProcess = process
            connectionInfo = (process.websocketURL, nil)
#endif
        case .remote(let remoteOptions):
            try validate(remoteOptions: remoteOptions, policy: options.versionPolicy)
            connectionInfo = (remoteOptions.url, remoteOptions.authToken)
        }

        try await openWebSocket(url: connectionInfo.url, authToken: connectionInfo.authToken)
        emit(.connectionStateChanged(.connected))

        let capabilities = InitializeCapabilities(
            experimentalApi: options.experimentalAPI,
            optOutNotificationMethods: nil
        )

        let response = try await call(
            RPC.Initialize.self,
            params: InitializeParams(
                capabilities: capabilities,
                clientInfo: options.clientInfo
            )
        )
        try validate(serverInfo: response, policy: options.versionPolicy)
        self.serverInfo = response
        try await sendInitializedNotification()
        emit(.connectionStateChanged(.initialized))
    }

    private func validate(remoteOptions: RemoteServerOptions, policy: VersionPolicy) throws {
        if let authToken = remoteOptions.authToken, !authToken.isEmpty,
           !supportsBearerToken(url: remoteOptions.url) {
            throw CodexClientError.unsupportedBearerTransport(remoteOptions.url)
        }
        if policy == .exact {
            guard let remoteVersion = remoteOptions.codexVersion else {
                throw CodexClientError.missingRemoteVersion
            }
            try CodexVersionChecker.validate(
                actual: remoteVersion,
                expected: CodexBindingMetadata.codexVersion,
                policy: policy
            )
        }
    }

    private func validate(serverInfo: InitializeResponse, policy: VersionPolicy) throws {
        guard policy == .exact else { return }
        guard let actualVersion = CodexVersionChecker.parseVersion(from: serverInfo.userAgent) else {
            throw CodexClientError.invalidResponse(
                "unable to parse codex version from initialize.userAgent: \(serverInfo.userAgent)"
            )
        }
        try CodexVersionChecker.validate(
            actual: actualVersion,
            expected: CodexBindingMetadata.codexVersion,
            policy: policy
        )
    }

    private func openWebSocket(url: URL, authToken: String?) async throws {
        let delegate = WebSocketOpenDelegate()
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024

        self.delegate = delegate
        self.session = session
        self.webSocketTask = task

        task.resume()
        do {
            try await delegate.waitUntilOpen()
        } catch {
            session.invalidateAndCancel()
            self.delegate = nil
            self.session = nil
            self.webSocketTask = nil
            throw error
        }

        connected = true
        listenTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func request(method: String, params: (any Encodable)?) async throws -> Data {
        guard let task = webSocketTask, connected else {
            throw CodexClientError.notConnected
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = [
            "id": requestID,
            "method": method,
        ]
        if let params {
            payload["params"] = try jsonObject(from: AnyEncodableBox(params))
        }

        let data = try JSONSerialization.data(withJSONObject: payload)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            Task {
                do {
                    try await send(text: data, via: task)
                } catch {
                    if let pending = self.pendingRequests.removeValue(forKey: requestID) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func sendInitializedNotification() async throws {
        try await send(jsonObject: ["method": "initialized"])
    }

    private func sendResponse<Result: Encodable>(id: RequestId, result: Result) async throws {
        let payload: [String: Any] = [
            "id": try jsonObject(from: id),
            "result": try jsonObject(from: result),
        ]
        try await send(jsonObject: payload)
    }

    private func send(jsonObject: [String: Any]) async throws {
        guard let task = webSocketTask, connected else {
            throw CodexClientError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        try await send(text: data, via: task)
    }

    private func send(text data: Data, via task: URLSessionWebSocketTask) async throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexClientError.invalidResponse("failed to encode websocket frame as UTF-8")
        }
        try await task.send(.string(string))
    }

    private func jsonObject(from value: some Encodable) throws -> Any {
        let encoded = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: encoded)
    }

    private func receiveLoop() async {
        while connected, let task = webSocketTask {
            do {
                let message = try await task.receive()
                await handle(message: message)
            } catch {
                await shutdown(reason: error.localizedDescription)
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            return
        }

        switch routeIncomingData(data, decoder: decoder) {
        case .response(let id, let responseData, let error):
            handleResponse(id: id, data: responseData, error: error)
        case .event(let event):
            emit(event)
        case .ignored:
            return
        }
    }

    private func handleResponse(id: Int, data: Data, error: IncomingError?) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(
                throwing: CodexClientError.rpcError(code: error.code, message: error.message)
            )
            return
        }
        if let resultData = extractResultData(from: data) {
            continuation.resume(returning: resultData)
        } else {
            continuation.resume(returning: Data("{}".utf8))
        }
    }

    private func extractResultData(from data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] else {
            return nil
        }
        if result is NSNull {
            return Data("{}".utf8)
        }
        return try? JSONSerialization.data(withJSONObject: result)
    }

    private func shutdown(reason: String?) async {
#if os(macOS)
        guard connected || session != nil || localProcess != nil else { return }
#else
        guard connected || session != nil else { return }
#endif

        connected = false

        let listenTask = self.listenTask
        self.listenTask = nil
        listenTask?.cancel()

        let pendingRequests = self.pendingRequests
        self.pendingRequests.removeAll()
        for (_, continuation) in pendingRequests {
            continuation.resume(
                throwing: CodexClientError.connectionClosed(reason ?? "disconnected")
            )
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()

        webSocketTask = nil
        session = nil
        delegate = nil

#if os(macOS)
        if let localProcess {
            self.localProcess = nil
            await localProcess.stop()
        }
#endif

        emit(.connectionStateChanged(.disconnected))
        if let reason {
            emit(.disconnected(reason))
        }
        eventContinuation.finish()
    }

    private func emit(_ event: CodexEvent) {
        eventContinuation.yield(event)
    }
}

private struct IncomingEnvelope: Decodable {
    let id: IncomingRequestID?
    let method: String?
    let error: IncomingError?
}

struct IncomingError: Decodable, Sendable {
    let code: Int
    let message: String
}

private enum IncomingRequestID: Decodable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
            return
        }
        self = .string(try container.decode(String.self))
    }

    var integerValue: Int? {
        if case .integer(let value) = self {
            return value
        }
        return nil
    }
}

enum IncomingMessageDisposition: Sendable {
    case response(id: Int, data: Data, error: IncomingError?)
    case event(CodexEvent)
    case ignored
}

func routeIncomingData(_ data: Data, decoder: JSONDecoder) -> IncomingMessageDisposition {
    let envelope: IncomingEnvelope
    do {
        envelope = try decoder.decode(IncomingEnvelope.self, from: data)
    } catch {
        return .event(.invalidMessage(rawJSON: data, errorDescription: error.localizedDescription))
    }

    if let integerID = envelope.id?.integerValue, envelope.method == nil {
        return .response(id: integerID, data: data, error: envelope.error)
    }

    if let method = envelope.method, envelope.id == nil {
        if let event = try? ServerNotificationEvent(from: data, decoder: decoder) {
            return .event(.notification(event))
        }
        return .event(.unknownMessage(method: method, rawJSON: data))
    }

    if envelope.id != nil, let method = envelope.method {
        if let request = try? AnyTypedServerRequest(from: data, decoder: decoder) {
            return .event(.serverRequest(request))
        }
        return .event(.unknownMessage(method: method, rawJSON: data))
    }

    return .event(
        .invalidMessage(
            rawJSON: data,
            errorDescription: "unrecognized JSON-RPC message shape"
        )
    )
}

private struct AnyEncodableBox: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let state = WebSocketOpenState()

    func waitUntilOpen() async throws {
        try await state.waitUntilOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task {
            await state.open()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task {
            await state.fail(with: error)
        }
    }
}

private actor WebSocketOpenState {
    private enum State {
        case pending([CheckedContinuation<Void, Error>])
        case open
        case failed(Error)
    }

    private var state: State = .pending([])

    func waitUntilOpen() async throws {
        switch state {
        case .open:
            return
        case .failed(let error):
            throw error
        case .pending(var continuations):
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                state = .pending(continuations)
            }
        }
    }

    func open() {
        guard case .pending(let continuations) = state else { return }
        state = .open
        for continuation in continuations {
            continuation.resume()
        }
    }

    func fail(with error: Error) {
        guard case .pending(let continuations) = state else { return }
        state = .failed(error)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

private func supportsBearerToken(url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
        return false
    }
    if scheme == "wss" {
        return true
    }
    guard scheme == "ws" else { return false }
    if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
        return true
    }
    return false
}
