import Foundation

public protocol CodexRPCMethod {
    associatedtype Params: Encodable & Sendable
    associatedtype Response: Decodable & Sendable

    static var method: ClientRequestMethod { get }
}

public protocol CodexServerNotificationMethod {
    associatedtype Params: Decodable & Sendable

    static var method: NotificationMethod { get }
}

public protocol CodexServerRequestMethod {
    associatedtype Params: Decodable & Sendable
    associatedtype Response: Encodable & Sendable

    static var method: ServerRequestMethod { get }
}

public enum RPC {}
public enum ServerNotifications {}
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
