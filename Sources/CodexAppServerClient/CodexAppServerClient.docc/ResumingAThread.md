# Resuming a Persisted Thread

Create a thread with `ephemeral: false`, save its ID, and call `RPC.ThreadResume` on relaunch to restore context.

## Overview

By default, ephemeral threads exist only for the lifetime of the session and are not written to disk. To resume a conversation across app launches, create the thread with `ephemeral: false` and persist the returned thread ID. On relaunch, pass that ID to `RPC.ThreadResume`.

## Creating a persistent thread

```swift
let thread = try await client.call(
    RPC.ThreadStart.self,
    params: ThreadStartParams(ephemeral: false)
)
let savedThreadId = thread.thread.id
// Persist savedThreadId — UserDefaults, a database, wherever makes sense for your app.
UserDefaults.standard.set(savedThreadId, forKey: "lastThreadId")
```

## Resuming on relaunch

```swift
if let savedId = UserDefaults.standard.string(forKey: "lastThreadId") {
    do {
        let resumed = try await client.call(
            RPC.ThreadResume.self,
            params: ThreadResumeParams(threadId: savedId)
        )
        print("Resumed thread: \(resumed.thread.id)")
        // Use resumed.thread.id as your threadId going forward.
    } catch let error as CodexClientError where error.isThreadNotFound {
        // The thread was pruned or the server was wiped. Start fresh.
        UserDefaults.standard.removeObject(forKey: "lastThreadId")
        let fresh = try await client.call(
            RPC.ThreadStart.self,
            params: ThreadStartParams(ephemeral: false)
        )
        UserDefaults.standard.set(fresh.thread.id, forKey: "lastThreadId")
    }
}
```

## `isThreadNotFound`

``CodexClientError/isThreadNotFound`` is a computed property that returns `true` for both the dedicated ``CodexClientError/threadNotFound(_:)`` case and ``CodexClientError/rpcError(code:message:)`` responses whose message matches the server's thread-not-found wording. This covers server version differences without requiring exhaustive string matching on your end.

## What `ThreadResume` gives you back

`RPC.ThreadResume` returns a `ThreadResumeResponse`, which has the same shape as `ThreadStartResponse`:

- `response.thread.id` — the thread ID (same as the one you passed in)
- `response.thread.preview` — usually the first user message, useful for confirming you got the right thread
- `response.model`, `response.cwd`, etc.

After a successful resume, send turns to the thread exactly as you would to a new thread.

## Gotcha: ephemeral threads cannot be resumed

If you call `RPC.ThreadResume` with the ID of an ephemeral thread (one created with `ephemeral: true`), the server returns a thread-not-found error. Ephemeral threads are never written to disk. If you intend to resume, set `ephemeral: false` at creation time — there is no way to upgrade a thread from ephemeral to persistent later.
