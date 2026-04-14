import Foundation
import CodexAppServerProtocol

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

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--listen", "ws://127.0.0.1:0"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "app-server", "--listen", "ws://127.0.0.1:0"]
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

        let resolver = BoundURLResolver()
        let stderrTask = Task.detached { [handle = stderrPipe.fileHandleForReading] in
            do {
                for try await line in handle.bytes.lines {
                    if let websocketURL = extractWebSocketURL(from: String(line)) {
                        await resolver.resolve(with: websocketURL)
                    }
                }
                await resolver.failIfUnresolved(
                    with: CodexClientError.processLaunchFailed(
                        "codex app-server exited before reporting a websocket URL"
                    )
                )
            } catch {
                await resolver.failIfUnresolved(
                    with: CodexClientError.processLaunchFailed(error.localizedDescription)
                )
            }
        }

        do {
            try process.run()
        } catch {
            stderrTask.cancel()
            throw CodexClientError.processLaunchFailed(error.localizedDescription)
        }

        let websocketURL = try await withTimeout(seconds: 10) {
            try await resolver.value()
        }

        return LocalCodexAppServerProcess(
            process: process,
            websocketURL: websocketURL,
            stderrDrainTask: stderrTask
        )
    }

    func stop() async {
        stderrDrainTask.cancel()
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: .seconds(3))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

internal enum CodexVersionChecker {
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

private actor BoundURLResolver {
    private var result: Result<URL, Error>?
    private var continuations: [CheckedContinuation<URL, Error>] = []

    func value() async throws -> URL {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(with url: URL) {
        guard result == nil else { return }
        result = .success(url)
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: url)
        }
    }

    func failIfUnresolved(with error: Error) {
        guard result == nil else { return }
        result = .failure(error)
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
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

private func extractWebSocketURL(from rawLine: String) -> URL? {
    let line = stripANSIEscapeSequences(from: rawLine)
    for token in line.split(whereSeparator: \.isWhitespace) {
        guard let suffix = token.split(separator: "ws://", maxSplits: 1, omittingEmptySubsequences: false).last,
              token.hasPrefix("ws://") else {
            continue
        }
        if let url = URL(string: "ws://\(suffix)") {
            return url
        }
    }
    return nil
}

private func stripANSIEscapeSequences(from line: String) -> String {
    var stripped = ""
    var iterator = line.makeIterator()
    while let character = iterator.next() {
        if character == "\u{001B}" {
            if iterator.next() == "[" {
                while let next = iterator.next() {
                    if ("@"..."~").contains(String(next)) {
                        break
                    }
                }
                continue
            }
        }
        stripped.append(character)
    }
    return stripped
}
