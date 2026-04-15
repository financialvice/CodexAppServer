import Foundation
import CodexAppServerProtocol

/// How strictly to enforce that the running codex binary matches the version pinned to this
/// Swift package.
public enum VersionPolicy: Sendable {
    /// Require the connected codex to match ``CodexBindingMetadata/codexVersion`` exactly.
    case exact
    /// Permit any codex version. The protocol wire format may drift; use with care.
    case allowMismatch
}

#if os(macOS)
/// Options controlling a locally launched codex app-server process.
public struct LocalServerOptions: Sendable {
    /// Path to the codex executable (resolved via `$PATH` if just a name). Defaults to `"codex"`.
    public var codexExecutable: String?
    /// Working directory for the child process. Defaults to the current process directory.
    public var workingDirectory: URL?
    /// Environment variables added to or overriding the current process environment.
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
#endif

/// Options for connecting to a pre-running codex app-server over the network.
public struct RemoteServerOptions: Sendable {
    /// Websocket URL (`ws://…` or `wss://…`). Bearer auth requires `wss` or a loopback host.
    public var url: URL
    /// Optional bearer token; sent as `Authorization: Bearer <token>`.
    public var authToken: String?
    /// Version of the remote codex. Required when `versionPolicy == .exact`.
    public var codexVersion: String?

    public init(url: URL, authToken: String? = nil, codexVersion: String? = nil) {
        self.url = url
        self.authToken = authToken
        self.codexVersion = codexVersion
    }
}

/// Where to find the codex app-server this client connects to.
public enum CodexConnection: Sendable {
#if os(macOS)
    /// Launch and manage a local codex app-server subprocess (macOS only).
    case localManaged(LocalServerOptions = .init())
#endif
    /// Connect to a codex app-server already running at a remote URL.
    case remote(RemoteServerOptions)
}

/// Client-side configuration passed to ``CodexClient/connect(_:options:)``.
public struct CodexClientOptions: Sendable {
    /// Whether to advertise support for experimental app-server APIs. Defaults to `true`.
    public var experimentalAPI: Bool
    /// Whether to enforce codex version match. Defaults to ``VersionPolicy/exact``.
    public var versionPolicy: VersionPolicy
    /// Identity of this client (name, title, version) reported to the server during initialize.
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

/// High-level connection lifecycle phase reported via ``CodexEvent/connectionStateChanged(_:)``.
public enum ConnectionState: Sendable {
    /// The client is launching the local process and/or opening the websocket.
    case connecting
    /// The websocket is open; `initialize` has not yet completed.
    case connected
    /// The `initialize` handshake has finished; RPC calls may now be issued.
    case initialized
    /// The client has been disconnected (intentionally or due to error).
    case disconnected
}

/// An event observable through ``CodexClient/events(bufferSize:)``.
public enum CodexEvent: Sendable {
    /// Reports a change in the connection lifecycle.
    case connectionStateChanged(ConnectionState)
    /// A typed server-to-client notification.
    case notification(ServerNotificationEvent)
    /// A typed server-to-client request. Respond via ``CodexClient/respond(to:result:)`` or ``CodexClient/reject(_:code:message:)``.
    case serverRequest(AnyTypedServerRequest)
    /// The connection was lost with the given reason.
    case disconnected(String)
    /// A JSON frame that failed to parse as JSON-RPC.
    case invalidMessage(rawJSON: Data, errorDescription: String)
    /// A JSON-RPC message with a method string this library does not recognise (likely version skew).
    case unknownMessage(method: String, rawJSON: Data)
    /// Emitted when a slow consumer dropped events due to buffer overflow. `skipped` counts dropped events.
    case lagged(skipped: Int)
    /// A line of stderr output from the locally managed codex process.
    case processLog(line: String)
}

/// Errors surfaced by ``CodexClient``.
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
