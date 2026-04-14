import Foundation
import Testing
@testable import CodexAppServer
@testable import CodexAppServerClient

@Test
func parsesCodexVersions() {
    #expect(CodexVersionChecker.parseVersion(from: "codex-cli 0.120.0") == "0.120.0")
    #expect(CodexVersionChecker.parseVersion(from: "Codex/0.120.0 (macOS 15.0; arm64) my_app; 0.1.0") == "0.120.0")
    #expect(CodexVersionChecker.parseVersion(from: "codex 1.2.3-dev") == "1.2.3")
    #expect(CodexVersionChecker.parseVersion(from: "not a version") == nil)
}

@Test
func malformedIncomingFramesBecomeEvents() {
    let disposition = routeIncomingData(Data("{".utf8), decoder: newJSONDecoder())

    guard case .event(.invalidMessage(let rawJSON, let errorDescription)) = disposition else {
        Issue.record("expected malformed frame to surface as invalidMessage event")
        return
    }

    #expect(rawJSON == Data("{".utf8))
    #expect(!errorDescription.isEmpty)
}

@Test
func connectsToLocalManagedAppServer() async throws {
    let client = try await CodexClient.connect(
        .localManaged(
            LocalServerOptions(
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        ),
        options: CodexClientOptions(
            versionPolicy: .exact,
            clientInfo: ClientInfo(
                name: "codex_app_server_tests",
                title: "Codex App Server Tests",
                version: "0.1.0"
            )
        )
    )

    var iterator = client.events.makeAsyncIterator()
    var sawInitialized = false
    for _ in 0..<4 {
        guard let event = await iterator.next() else { break }
        if case .connectionStateChanged(.initialized) = event {
            sawInitialized = true
            break
        }
    }

    #expect(sawInitialized)
    await client.disconnect()
}

@Test
func disconnectFinishesEventStream() async throws {
    let client = try await CodexClient.connect(
        .localManaged(
            LocalServerOptions(
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        ),
        options: CodexClientOptions(
            versionPolicy: .exact,
            clientInfo: ClientInfo(
                name: "codex_app_server_tests",
                title: "Codex App Server Tests",
                version: "0.1.0"
            )
        )
    )

    var iterator = client.events.makeAsyncIterator()
    var sawInitialized = false
    while let event = await iterator.next() {
        if case .connectionStateChanged(.initialized) = event {
            sawInitialized = true
            break
        }
    }
    #expect(sawInitialized)

    await client.disconnect()

    let disconnectedEvent = await iterator.next()
    #expect(disconnectedEvent != nil)

    let terminalEvent = await iterator.next()
    #expect(terminalEvent == nil)
}
