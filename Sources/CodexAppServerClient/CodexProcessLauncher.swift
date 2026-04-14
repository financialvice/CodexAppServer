import Foundation
import CodexAppServerProtocol

#if os(macOS)
import Darwin
#endif

#if os(macOS)
internal final class LocalCodexAppServerProcess: @unchecked Sendable {
    let websocketURL: URL

    private let process: Process
    private let stderrDrainTask: Task<Void, Never>

    private init(process: Process, websocketURL: URL, stderrDrainTask: Task<Void, Never>) {
        self.process = process
        self.websocketURL = websocketURL
        self.stderrDrainTask = stderrDrainTask
    }

    static func launch(
        options: LocalServerOptions,
        versionPolicy: VersionPolicy
    ) async throws -> LocalCodexAppServerProcess {
        let executable = options.codexExecutable ?? "codex"
        let installedVersion = try CodexVersionChecker.codexVersion(for: executable)
        try CodexVersionChecker.validate(
            actual: installedVersion,
            expected: CodexBindingMetadata.codexVersion,
            policy: versionPolicy
        )

        let port = findAvailableLoopbackPort()
        let websocketURL = URL(string: "ws://127.0.0.1:\(port)")!
        let readyURL = URL(string: "http://127.0.0.1:\(port)/readyz")!

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--listen", websocketURL.absoluteString]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "app-server", "--listen", websocketURL.absoluteString]
        }
        process.currentDirectoryURL = options.workingDirectory

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in options.environment {
            environment[key] = value
        }
        if environment["RUST_LOG"] == nil {
            environment["RUST_LOG"] = "warn"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let stderrBuffer = LaunchLogBuffer()
        let stderrTask = Task.detached { [handle = stderrPipe.fileHandleForReading] in
            do {
                for try await line in handle.bytes.lines {
                    await stderrBuffer.append(String(line))
                }
            } catch {
                await stderrBuffer.append(error.localizedDescription)
            }
        }

        do {
            try process.run()
        } catch {
            stderrTask.cancel()
            throw CodexClientError.processLaunchFailed(error.localizedDescription)
        }

        do {
            try await waitUntilReady(
                process: process,
                readyURL: readyURL,
                stderrBuffer: stderrBuffer,
                timeoutSeconds: 10
            )
        } catch {
            stderrTask.cancel()
            terminate(process)
            throw error
        }

        return LocalCodexAppServerProcess(
            process: process,
            websocketURL: websocketURL,
            stderrDrainTask: stderrTask
        )
    }

    func stop() async {
        stderrDrainTask.cancel()
        terminate(process)
    }
}
#endif

internal enum CodexVersionChecker {
#if os(macOS)
    static func codexVersion(for executable: String) throws -> String {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--version"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "--version"]
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexClientError.executableLookupFailed(executable)
        }

        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard let version = parseVersion(from: output) else {
            throw CodexClientError.invalidResponse("unable to parse codex version from: \(output)")
        }
        return version
    }
#endif

    static func parseVersion(from string: String) -> String? {
        let pattern = #"\b\d+\.\d+\.\d+\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let matchRange = Range(match.range, in: string) else {
            return nil
        }
        return String(string[matchRange])
    }

    static func validate(actual: String, expected: String, policy: VersionPolicy) throws {
        guard policy == .exact, actual != expected else { return }
        throw CodexClientError.versionMismatch(expected: expected, actual: actual)
    }
}

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CodexClientError.processLaunchFailed("timed out waiting for codex app-server readiness")
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

#if os(macOS)
private actor LaunchLogBuffer {
    private let maxLines = 20
    private var lines: [String] = []

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func failureDescription(fallback: String) -> String {
        guard !lines.isEmpty else { return fallback }
        return "\(fallback)\n\(lines.joined(separator: "\n"))"
    }
}

private func waitUntilReady(
    process: Process,
    readyURL: URL,
    stderrBuffer: LaunchLogBuffer,
    timeoutSeconds: Double
) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
    }

    do {
        try await withTimeout(seconds: timeoutSeconds) {
            while true {
                if !process.isRunning {
                    let message = await stderrBuffer.failureDescription(
                        fallback: "codex app-server exited before becoming ready"
                    )
                    throw CodexClientError.processLaunchFailed(message)
                }

                var request = URLRequest(url: readyURL)
                request.timeoutInterval = 1
                if let (_, response) = try? await session.data(for: request),
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    return
                }

                try await Task.sleep(for: .milliseconds(100))
            }
        }
    } catch let error as CodexClientError {
        throw error
    } catch {
        let message = await stderrBuffer.failureDescription(
            fallback: "timed out waiting for codex app-server readiness"
        )
        throw CodexClientError.processLaunchFailed(message)
    }
}

private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    for _ in 0..<30 where process.isRunning {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

private func findAvailableLoopbackPort() -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return 4500 }
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    var addrCopy = addr
    let bindResult = withUnsafePointer(to: &addrCopy) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { return 4500 }

    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getResult = withUnsafeMutablePointer(to: &addrCopy) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            getsockname(sock, sockPtr, &len)
        }
    }
    guard getResult == 0 else { return 4500 }

    return Int(UInt16(bigEndian: addrCopy.sin_port))
}
#endif
