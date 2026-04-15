# Getting Started

Connect to a codex app-server, start a thread, observe the turn.

## Add the dependency

```swift
.package(url: "https://github.com/…/codex-app-server-client", from: "0.120.0")
```

Target dependency: `"CodexAppServerClient"`.

## Launch a local codex app-server

```swift
import CodexAppServerClient

let client = try await CodexClient.connect(
    .localManaged(),
    options: CodexClientOptions(
        clientInfo: ClientInfo(name: "my_app", title: "My App", version: "1.0.0")
    )
)
defer { Task { await client.disconnect() } }
```

`LocalServerOptions` lets you override the codex executable, working directory, or environment.

## Connect to a remote codex

```swift
let client = try await CodexClient.connect(
    .remote(RemoteServerOptions(
        url: URL(string: "wss://codex.example.com")!,
        authToken: "…",
        codexVersion: CodexBindingMetadata.codexVersion
    )),
    options: CodexClientOptions(clientInfo: clientInfo)
)
```

Bearer auth requires `wss://` or a loopback `ws://` URL.

## Make a typed request

```swift
let thread = try await client.call(
    RPC.ThreadStart.self,
    params: ThreadStartParams(ephemeral: true)
)
```

## Observe notifications

```swift
for await event in await client.events() {
    switch event {
    case .notification(let note):
        print("notification:", note.method.rawValue)
    case .serverRequest(let request):
        try? await client.reject(request, message: "not supported")
    case .connectionStateChanged(.disconnected(let reason)):
        print("disconnected:", reason.description)
    default:
        break
    }
}
```

Or filter for a single method:

```swift
for await delta in await client.notifications(of: ServerNotifications.ItemAgentMessageDelta.self) {
    print(delta.delta)
}
```
