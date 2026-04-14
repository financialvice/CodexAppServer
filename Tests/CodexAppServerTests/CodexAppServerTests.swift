import Foundation
import Testing
@testable import CodexAppServer
@testable import CodexAppServerClient

@Test
func parsesCodexVersions() {
    #expect(CodexVersionChecker.parseVersion(from: "codex-cli 0.120.0") == "0.120.0")
    #expect(CodexVersionChecker.parseVersion(from: "codex 1.2.3-dev") == "1.2.3")
    #expect(CodexVersionChecker.parseVersion(from: "not a version") == nil)
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
