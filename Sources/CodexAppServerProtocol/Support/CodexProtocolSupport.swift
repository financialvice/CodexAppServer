import Foundation

/// A typed client-to-server RPC method.
///
/// Each Codex RPC method is represented by a marker enum (e.g. ``RPC/ThreadStart``)
/// that declares its wire name plus the request/response payload types. Use with
/// `CodexClient.call(_:params:)`.
public protocol CodexRPCMethod: Sendable {
    /// Request parameters serialised onto the wire.
    associatedtype Params: Encodable & Sendable
    /// Successful-response payload decoded off the wire.
    associatedtype Response: Decodable & Sendable

    /// Wire-format method identifier.
    static var method: ClientRequestMethod { get }
}

/// A typed server-to-client notification method.
///
/// Notifications have no response. Observe the full stream through
/// `CodexClient.events(bufferSize:)`, or subscribe to a single typed feed via
/// `CodexClient.notifications(of:bufferSize:)`.
public protocol CodexServerNotificationMethod: Sendable {
    /// Notification params decoded off the wire.
    associatedtype Params: Decodable & Sendable

    /// Wire-format method identifier.
    static var method: NotificationMethod { get }
}

/// A typed server-to-client request method.
///
/// Server requests must be answered: respond with
/// `CodexClient.respond(to:result:)` or `CodexClient.reject(_:code:message:)`.
public protocol CodexServerRequestMethod: Sendable {
    /// Incoming-request params decoded off the wire.
    associatedtype Params: Decodable & Sendable
    /// Successful-response payload encoded onto the wire.
    associatedtype Response: Encodable & Sendable

    /// Wire-format method identifier.
    static var method: ServerRequestMethod { get }
}

/// Namespace for every client-to-server RPC method exposed by this Codex binding.
///
/// Enumerate the full method surface via ``RPC/allMethods``.
public enum RPC {}

/// Namespace for every server-to-client notification method exposed by this Codex binding.
///
/// Enumerate the full notification surface via ``ServerNotifications/all``.
public enum ServerNotifications {}

/// Namespace for every server-to-client request method exposed by this Codex binding.
///
/// Enumerate the full request surface via ``ServerRequests/all``.
public enum ServerRequests {}

public struct EmptyParams: Encodable, Sendable {
    public init() {}
}

public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

public struct TypedServerRequest<Method: CodexServerRequestMethod>: Sendable {
    public let id: RequestId
    public let params: Method.Params

    public init(id: RequestId, params: Method.Params) {
        self.id = id
        self.params = params
    }
}
