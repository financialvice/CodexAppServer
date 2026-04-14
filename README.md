# CodexAppServer

Minimal Swift Package Manager client for `codex app-server`.

This package is intentionally opinionated:

- generated from a pinned Codex version
- includes experimental API surface in generated bindings
- enables `experimentalApi` by default at runtime
- uses WebSocket transport for local managed launch
- enforces exact Codex version matching by default

The goal is to make native app integration as small as possible while keeping the protocol strongly typed.

## What It Includes

- generated Swift protocol models from `codex app-server generate-json-schema --experimental`
- generated typed RPC method bindings from `codex app-server generate-ts --experimental`
- typed server notification and server request decoding
- local managed launcher for `codex app-server --listen ws://127.0.0.1:0`
- remote WebSocket connection support

## What It Does Not Include

- stdio transport
- reconnect logic
- UI/session abstractions
- version compatibility shims across Codex releases

Those are omitted on purpose to keep the package small and predictable.

## Requirements

- Swift 6.3+
- macOS
- `codex` installed locally for managed local launch
- exact match between local `codex` version and the generated binding version

Current pinned Codex version: `0.120.0`

## Install

```swift
.package(
    url: "https://github.com/financialvice/CodexAppServer.git",
    exact: "0.120.0"
)
```

## Local Managed Example

```swift
import CodexAppServer

let client = try await CodexClient.connect(
    .localManaged(),
    options: CodexClientOptions(
        clientInfo: ClientInfo(
            name: "my_native_app",
            title: "My Native App",
            version: "0.1.0"
        )
    )
)

let thread = try await client.call(
    RPC.ThreadStart.self,
    params: ThreadStartParams(ephemeral: true)
)

for await event in client.events {
    switch event {
    case .notification(let notification):
        print(notification.method)
    case .serverRequest(let request):
        print(request.method)
    default:
        break
    }
}
```

## Remote Example

For remote connections, exact version policy requires the caller to declare the remote Codex version explicitly:

```swift
let client = try await CodexClient.connect(
    .remote(
        RemoteServerOptions(
            url: URL(string: "ws://127.0.0.1:4500")!,
            codexVersion: "0.120.0"
        )
    ),
    options: CodexClientOptions(
        clientInfo: ClientInfo(
            name: "my_native_app",
            title: "My Native App",
            version: "0.1.0"
        )
    )
)
```

## Regenerating Bindings

The package is generated from the local `codex` binary and requires that the installed version match `.codex-version`.

```bash
./Scripts/generate-protocol.sh
```

## Release Model

Package versions are intended to match Codex versions exactly.

Example:

- package `0.120.0`
- generated from `codex 0.120.0`

## CI And Release

Two GitHub Actions workflows are included:

- `CI`
  - installs the pinned Codex version
  - regenerates bindings
  - verifies generated files are committed
  - runs `swift build` and `swift test`

- `Release`
  - manual workflow
  - requires the input version to match `.codex-version`
  - reruns generation, build, and tests
  - creates and pushes a Git tag
  - creates a GitHub Release

The release workflow assumes the repository state is already committed and ready. It does not auto-commit regenerated files.
