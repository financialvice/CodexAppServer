import Foundation
import CodexAppServerProtocol

// MARK: - Per-thread filtered streams

extension CodexClient {
    /// Subscribe to events scoped to a single `threadId`.
    ///
    /// Filters the multicast stream to only events whose payload carries a matching
    /// `threadId` (extracted reflectively from the notification or server-request params).
    /// System events (``CodexEvent/connectionStateChanged(_:)``,
    /// ``CodexEvent/lagged(skipped:)``, ``CodexEvent/processLog(line:)``,
    /// ``CodexEvent/invalidMessage(rawJSON:errorDescription:)``,
    /// ``CodexEvent/unknownMessage(method:rawJSON:)``) are not thread-scoped and pass
    /// through to every per-thread subscriber so per-thread UIs can still observe lifecycle
    /// changes.
    ///
    /// Pair with `RPC.ThreadStart` (or `RPC.ThreadResume`) to drive a single thread's
    /// view without having to maintain a `[threadId: ThreadState]` router yourself.
    ///
    /// ```swift
    /// let thread = try await client.call(RPC.ThreadStart.self, params: ThreadStartParams(ephemeral: true))
    /// for await event in await client.events(forThread: thread.thread.id) {
    ///     // only events for this thread (plus system lifecycle events)
    /// }
    /// ```
    public func events(
        forThread threadId: String,
        bufferSize: Int = 1024
    ) -> AsyncStream<CodexEvent> {
        let base = events(bufferSize: bufferSize)
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if Task.isCancelled { break }
                    if eventBelongs(event, toThread: threadId) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Typed notification stream filtered to a single thread.
    ///
    /// Combines ``CodexClient/notifications(of:bufferSize:)`` with the same threadId-extraction trick
    /// used by ``events(forThread:bufferSize:)``. Notifications whose params struct doesn't
    /// carry a matching `threadId` field are dropped.
    public func notifications<Method: CodexServerNotificationMethod>(
        of method: Method.Type,
        forThread threadId: String,
        bufferSize: Int = 1024
    ) async -> AsyncStream<Method.Params> where Method.Params: Sendable {
        let base = events(forThread: threadId, bufferSize: bufferSize)
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if Task.isCancelled { break }
                    if case .notification(let notification) = event,
                       notification.method == Method.method,
                       let params = extractNotificationParams(notification, as: Method.self) {
                        continuation.yield(params)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Typed observability accessors

extension CodexClient {
    /// Stream of connection lifecycle transitions.
    ///
    /// Useful when you want to drive a "Connected / Reconnecting / Disconnected" UI badge
    /// without exhaustively switching on the full ``CodexEvent`` enum. The stream emits the
    /// initial state on subscription is *not* guaranteed; subscribe before connecting if
    /// you need the full lifecycle.
    public func connectionStates(
        bufferSize: Int = 16
    ) -> AsyncStream<ConnectionState> {
        let base = events(bufferingPolicy: .bufferingNewest(bufferSize))
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if Task.isCancelled { break }
                    if case .connectionStateChanged(let state) = event {
                        continuation.yield(state)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Typed stream of one specific server-to-client request method.
    ///
    /// Mirrors ``CodexClient/notifications(of:bufferSize:)`` for the request side. Each yielded
    /// value is a fully-typed `TypedServerRequest` ready to be answered with
    /// ``respond(to:result:)`` or ``reject(_:code:message:)`` (using the convenience
    /// `ApprovalResponse.init(intent:)` for approval-shaped responses).
    ///
    /// ```swift
    /// for await request in await client.serverRequests(of: ServerRequests.ExecCommandApproval.self) {
    ///     try await client.respond(to: request, result: .init(intent: .allowOnce))
    /// }
    /// ```
    public func serverRequests<Method: CodexServerRequestMethod>(
        of method: Method.Type,
        bufferSize: Int = 1024
    ) -> AsyncStream<TypedServerRequest<Method>> {
        let base = events(bufferSize: bufferSize)
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if Task.isCancelled { break }
                    if case .serverRequest(let request) = event,
                       request.method == Method.method,
                       let typed = extractTypedServerRequest(request, as: Method.self) {
                        continuation.yield(typed)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if os(macOS)
    /// Stream of stderr lines from the locally-managed codex process.
    ///
    /// Available only for ``CodexConnection/localManaged(_:)``. Backed by
    /// ``CodexEvent/processLog(line:)`` events.
    public func processLogs(
        bufferSize: Int = 256
    ) -> AsyncStream<String> {
        let base = events(bufferingPolicy: .bufferingNewest(bufferSize))
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if Task.isCancelled { break }
                    if case .processLog(let line) = event {
                        continuation.yield(line)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}

// MARK: - Turn streaming convenience

extension CodexClient {
    /// Start a turn and stream its agent message deltas in one call.
    ///
    /// Wraps the four-step "subscribe before TurnStart, capture turnId, filter deltas by
    /// turnId, finish on TurnCompleted" recipe that every chat-style consumer reinvents.
    ///
    /// The events stream is opened *before* the `RPC.TurnStart` call so no deltas can
    /// arrive in the gap between the server starting the turn and the client knowing the
    /// `turnId`. The returned stream finishes when the matching `ServerNotifications.TurnCompleted`
    /// arrives, the connection drops, or the consuming task is cancelled.
    ///
    /// To stop a turn that is still streaming, cancel the consuming task **and** call
    /// `RPC.TurnInterrupt` with the `(threadId, turnId)` you can recover from the first
    /// yielded delta — `Task.cancel()` alone does not stop the server.
    ///
    /// ```swift
    /// for try await delta in client.streamTurn(input: [.text("hi")], threadId: thread.id) {
    ///     bubble.text += delta.delta
    /// }
    /// ```
    ///
    /// - Throws: Any error ``call(_:params:)`` would throw from `RPC.TurnStart`.
    public func streamTurn(
        input: [UserInput],
        threadId: String
    ) async throws -> AsyncStream<AgentMessageDeltaNotification> {
        let baseEvents = events()
        let response = try await call(
            RPC.TurnStart.self,
            params: TurnStartParams(input: input, threadId: threadId)
        )
        let turnId = response.turn.id

        return AsyncStream { continuation in
            let task = Task {
                for await event in baseEvents {
                    if Task.isCancelled { break }
                    guard case .notification(let notification) = event else { continue }
                    switch notification {
                    case .itemAgentMessageDelta(let delta) where delta.turnId == turnId:
                        continuation.yield(delta)
                    case .turnCompleted(let completed) where completed.turn.id == turnId:
                        continuation.finish()
                        return
                    default:
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Reflection helpers

private func extractNotificationParams<Method: CodexServerNotificationMethod>(
    _ notification: ServerNotificationEvent,
    as method: Method.Type
) -> Method.Params? {
    let mirror = Mirror(reflecting: notification)
    for child in mirror.children {
        if let params = child.value as? Method.Params {
            return params
        }
    }
    return nil
}

private func extractTypedServerRequest<Method: CodexServerRequestMethod>(
    _ request: AnyTypedServerRequest,
    as method: Method.Type
) -> TypedServerRequest<Method>? {
    let mirror = Mirror(reflecting: request)
    for child in mirror.children {
        if let typed = child.value as? TypedServerRequest<Method> {
            return typed
        }
    }
    return nil
}

/// True if the event's payload references the given thread, or it's a system event that
/// should be visible to every per-thread subscriber.
private func eventBelongs(_ event: CodexEvent, toThread threadId: String) -> Bool {
    switch event {
    case .notification(let notification):
        return extractThreadId(fromNotification: notification) == threadId
    case .serverRequest(let request):
        return extractThreadId(fromServerRequest: request) == threadId
    case .connectionStateChanged, .lagged, .processLog, .invalidMessage, .unknownMessage:
        return true
    }
}

private func extractThreadId(fromNotification notification: ServerNotificationEvent) -> String? {
    let mirror = Mirror(reflecting: notification)
    for child in mirror.children {
        if let value = readThreadId(from: child.value) {
            return value
        }
    }
    return nil
}

private func extractThreadId(fromServerRequest request: AnyTypedServerRequest) -> String? {
    let mirror = Mirror(reflecting: request)
    for child in mirror.children {
        // child.value is TypedServerRequest<X>; read its .params
        let typedMirror = Mirror(reflecting: child.value)
        for typedChild in typedMirror.children where typedChild.label == "params" {
            if let value = readThreadId(from: typedChild.value) {
                return value
            }
        }
    }
    return nil
}

/// Read a `threadId: String` (or `String?` non-nil) field off any value via reflection.
private func readThreadId(from value: Any) -> String? {
    let mirror = Mirror(reflecting: value)
    for child in mirror.children where child.label == "threadId" {
        if let str = child.value as? String {
            return str
        }
        if let optional = child.value as? String? {
            return optional
        }
    }
    return nil
}
