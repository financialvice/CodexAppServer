# Handling Approval Requests

Use `ApprovalIntent` and the unified `init(intent:)` to respond to any of the four approval request types with the same UI code.

## Overview

The codex agent pauses and asks your client for permission before applying patches, running commands, or changing files. These arrive as ``CodexEvent/serverRequest(_:)`` events carrying one of four `AnyTypedServerRequest` cases. Each case has its own wire response type, but they all conform to `ApprovalResponse`, which exposes `init(intent:)`. This means your approval UI only needs to produce an `ApprovalIntent` — the response type does the rest.

## The four approval cases

| `AnyTypedServerRequest` case | Response type |
|---|---|
| `.applyPatchApproval` | `ApplyPatchApprovalResponse` |
| `.execCommandApproval` | `ExecCommandApprovalResponse` |
| `.itemCommandExecutionRequestApproval` | `CommandExecutionRequestApprovalResponse` |
| `.itemFileChangeRequestApproval` | `FileChangeRequestApprovalResponse` |

## Handling all four with `ApprovalIntent`

```swift
for await event in await client.events() {
    guard case .serverRequest(let request) = event else { continue }

    // Ask the user — returns .allowOnce, .allowForSession, .deny, or .abort
    let intent: ApprovalIntent = await askUser(for: request)

    switch request {
    case .applyPatchApproval(let r):
        try await client.respond(to: r, result: ApplyPatchApprovalResponse(intent: intent))
    case .execCommandApproval(let r):
        try await client.respond(to: r, result: ExecCommandApprovalResponse(intent: intent))
    case .itemCommandExecutionRequestApproval(let r):
        try await client.respond(to: r, result: CommandExecutionRequestApprovalResponse(intent: intent))
    case .itemFileChangeRequestApproval(let r):
        try await client.respond(to: r, result: FileChangeRequestApprovalResponse(intent: intent))
    default:
        try await client.reject(request, code: -32601, message: "not implemented")
    }
}
```

Each `init(intent:)` maps the canonical intent to the correct underlying wire enum automatically.

## Intent semantics

- **`.allowOnce`** — approve this specific action. The agent may ask again for the next equivalent action.
- **`.allowForSession`** — approve this action and suppress re-prompting for equivalent actions for the rest of the session.
- **`.deny`** — decline the action but let the turn continue. The agent may try an alternate approach.
- **`.abort`** — decline and immediately end the turn. Use this when the user wants the agent to stop entirely, not just skip one step.

`.deny` is a soft decline; `.abort` is a hard stop. If you present a single "Deny" button, decide up front which semantic you want. Most UI patterns map "Deny" to `.deny` and a separate "Stop Turn" button to `.abort`.

## Responding to unrecognised requests

The server may send request types this library knows about but your app does not handle (e.g. `itemPermissionsRequestApproval`). Reject them explicitly rather than leaving them unanswered — an unanswered server request stalls the turn indefinitely:

```swift
default:
    try await client.reject(request, code: -32601, message: "not implemented")
```

JSON-RPC code `-32601` ("method not found") is the conventional signal that the client does not support the method.

## Inspecting request params

Each typed case carries a `params` value with the request details. For example:

```swift
case .applyPatchApproval(let r):
    print("Patch to apply:\n\(r.params.patch)")
    let intent = await askUser(description: r.params.patch)
    try await client.respond(to: r, result: ApplyPatchApprovalResponse(intent: intent))
```

The exact shape of each params type is visible in the generated protocol types.
