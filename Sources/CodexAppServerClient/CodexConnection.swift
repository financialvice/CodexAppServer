import Foundation
import CodexAppServerProtocol

public enum VersionPolicy: Sendable {
    case exact
    case allowMismatch
}

public struct LocalServerOptions: Sendable {
    public var codexExecutable: String?
    public var workingDirectory: URL?
    public var environment: [String: String]

    public init(
        codexExecutable: String? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.codexExecutable = codexExecutable
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct RemoteServerOptions: Sendable {
    public var url: URL
    public var authToken: String?
    public var codexVersion: String?

    public init(url: URL, authToken: String? = nil, codexVersion: String? = nil) {
        self.url = url
        self.authToken = authToken
        self.codexVersion = codexVersion
    }
}

public enum CodexConnection: Sendable {
    case localManaged(LocalServerOptions = .init())
    case remote(RemoteServerOptions)
}

public struct CodexClientOptions: Sendable {
    public var experimentalAPI: Bool
    public var versionPolicy: VersionPolicy
    public var clientInfo: ClientInfo

    public init(
        experimentalAPI: Bool = true,
        versionPolicy: VersionPolicy = .exact,
        clientInfo: ClientInfo
    ) {
        self.experimentalAPI = experimentalAPI
        self.versionPolicy = versionPolicy
        self.clientInfo = clientInfo
    }
}

public enum ConnectionState: Sendable {
    case connecting
    case connected
    case initialized
    case disconnected
}

public enum CodexEvent: Sendable {
    case connectionStateChanged(ConnectionState)
    case notification(ServerNotificationEvent)
    case serverRequest(AnyTypedServerRequest)
    case disconnected(String)
    case unknownMessage(method: String, rawJSON: Data)
}

public enum CodexClientError: Error, LocalizedError, Sendable {
    case executableLookupFailed(String)
    case missingRemoteVersion
    case versionMismatch(expected: String, actual: String)
    case unsupportedBearerTransport(URL)
    case invalidRemoteURL(String)
    case notConnected
    case connectionClosed(String)
    case rpcError(code: Int, message: String)
    case invalidResponse(String)
    case processLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableLookupFailed(let executable):
            "Unable to execute codex binary: \(executable)"
        case .missingRemoteVersion:
            "Remote connections require an explicit codexVersion when using exact version policy"
        case .versionMismatch(let expected, let actual):
            "Codex version mismatch. Expected \(expected), got \(actual)"
        case .unsupportedBearerTransport(let url):
            "Bearer auth requires wss:// or loopback ws:// URLs: \(url.absoluteString)"
        case .invalidRemoteURL(let value):
            "Invalid remote URL: \(value)"
        case .notConnected:
            "WebSocket is not connected"
        case .connectionClosed(let message):
            "Connection closed: \(message)"
        case .rpcError(_, let message):
            "RPC error: \(message)"
        case .invalidResponse(let message):
            "Invalid response: \(message)"
        case .processLaunchFailed(let message):
            "Failed to launch codex app-server: \(message)"
        }
    }
}
