# ``CodexAppServerClient``

A Swift client for the codex app-server JSON-RPC protocol.

## Overview

`CodexAppServerClient` speaks the codex app-server wire protocol over WebSocket. It launches a
local codex subprocess (macOS) or connects to a remote codex instance, performs the `initialize`
handshake, and exposes strongly-typed APIs for requests, responses, notifications, and
server-initiated requests.

The Swift package version is pinned 1:1 with a codex release; each codex bump yields a new
tag. See `.codex-version` in the repo root.

## Topics

### Connecting

- ``CodexClient``
- ``CodexConnection``
- ``CodexClientOptions``
- ``LocalServerOptions``
- ``RemoteServerOptions``
- ``VersionPolicy``

### Observing

- ``CodexEvent``
- ``ConnectionState``

### Errors

- ``CodexClientError``
