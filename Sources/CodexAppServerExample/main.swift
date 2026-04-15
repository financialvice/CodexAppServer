import CodexAppServerClient
import Foundation

@main
struct CodexAppServerExample {
    static func main() async throws {
        let client = try await CodexClient.connect(
            .localManaged(),
            options: CodexClientOptions(
                clientInfo: ClientInfo(
                    name: "codex_app_server_example",
                    title: "Codex App Server Example",
                    version: "0.1.0"
                )
            )
        )

        let userInput = UserInput(
            text: "Say hello in one short sentence.",
            textElements: nil,
            type: .text,
            url: nil,
            path: nil,
            name: nil
        )

        let thread = try await client.call(
            RPC.ThreadStart.self,
            params: ThreadStartParams(ephemeral: true)
        )
        print("Started thread: \(thread.thread.id)")

        let turn = try await client.call(
            RPC.TurnStart.self,
            params: TurnStartParams(
                input: [userInput],
                threadId: thread.thread.id
            )
        )
        print("Started turn: \(turn.turn.id)")

        var iterator = await client.events().makeAsyncIterator()
        eventLoop: while let event = await iterator.next() {
            switch event {
            case .notification(let notification):
                print("notification:", notification.method.rawValue)
                if case .turnCompleted(let payload) = notification, payload.turn.id == turn.turn.id {
                    break eventLoop
                }
            case .serverRequest(let request):
                print("server request:", request.method.rawValue)
                try? await client.reject(request, message: "Example client does not handle server requests")
            case .connectionStateChanged(.disconnected(let reason)):
                print("disconnected:", reason.description)
                break eventLoop
            case .unknownMessage(let method, _):
                print("unknown message:", method)
            case .invalidMessage:
                break
            case .lagged(let skipped):
                print("lagged:", skipped)
            case .processLog(let line):
                print("[codex]", line)
            case .connectionStateChanged:
                break
            }
        }

        await client.disconnect()
    }
}
