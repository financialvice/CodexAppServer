import Foundation

/// A user's intent when responding to any codex approval request.
///
/// Codex's wire protocol has **three** different decision enums for
/// semantically-identical user choices:
///
/// | Intent           | ``ReviewDecisionEnum`` | ``FileChangeApprovalDecision`` |
/// | ---------------- | ---------------------- | ------------------------------ |
/// | ``allowOnce``    | `.approved`            | `.accept`                      |
/// | ``allowForSession``| `.approvedForSession`| `.acceptForSession`            |
/// | ``deny``         | `.denied`              | `.decline`                     |
/// | ``abort``        | `.abort`               | `.cancel`                      |
///
/// ``ApprovalIntent`` lets UI code use one vocabulary ("allow once",
/// "deny", etc.) across every server approval request, and each approval
/// response type exposes an `init(intent:)` convenience that picks the
/// correct underlying decision enum automatically.
///
/// ```swift
/// case .execCommandApproval(let request):
///     try await client.respond(to: request.request, result: .init(intent: .allowOnce))
/// case .itemFileChangeRequestApproval(let request):
///     try await client.respond(to: request.request, result: .init(intent: .deny))
/// ```
///
/// See ``ApprovalResponse`` for the protocol all four approval responses
/// conform to.
public enum ApprovalIntent: Sendable, Equatable, CaseIterable {
    /// Allow this action for this invocation only.
    case allowOnce
    /// Allow this action and any equivalent follow-up actions for the rest of
    /// the current session without re-prompting.
    case allowForSession
    /// Decline this action but let the turn continue. The agent may try an
    /// alternate approach.
    case deny
    /// Decline this action and immediately end the turn.
    case abort
}

/// A unified response type across codex's four decision-style approval requests.
///
/// Every conforming response type provides an ``init(intent:)`` convenience
/// that maps the canonical ``ApprovalIntent`` into the correct underlying
/// decision enum.
///
/// For generic dispatch across all four approval requests in one call site, prefer
/// ``AnyApprovalRequest`` combined with the client's
/// `respond(to:intent:)` helper — it avoids writing one branch per approval method
/// in UI code.
public protocol ApprovalResponse: Sendable {
    /// Build a response for the given user intent.
    init(intent: ApprovalIntent)
}

/// Compile-time-safe subset of ``AnyTypedServerRequest`` containing only the
/// approval-shaped requests (those answered with an ``ApprovalIntent``).
///
/// Obtain one from ``AnyTypedServerRequest/asApprovalRequest`` and answer it
/// with the client's `respond(to:intent:)` helper. UI code that treats every
/// approval uniformly needs a single call site instead of one branch per
/// approval method.
public enum AnyApprovalRequest: Sendable {
    case applyPatchApproval(TypedServerRequest<ServerRequests.ApplyPatchApproval>)
    case execCommandApproval(TypedServerRequest<ServerRequests.ExecCommandApproval>)
    case itemCommandExecutionRequestApproval(TypedServerRequest<ServerRequests.ItemCommandExecutionRequestApproval>)
    case itemFileChangeRequestApproval(TypedServerRequest<ServerRequests.ItemFileChangeRequestApproval>)

    /// JSON-RPC request identifier this approval is answering.
    public var id: RequestId {
        switch self {
        case .applyPatchApproval(let request): return request.id
        case .execCommandApproval(let request): return request.id
        case .itemCommandExecutionRequestApproval(let request): return request.id
        case .itemFileChangeRequestApproval(let request): return request.id
        }
    }

    /// Wire method that originated this approval.
    public var method: ServerRequestMethod {
        switch self {
        case .applyPatchApproval: return .applyPatchApproval
        case .execCommandApproval: return .execCommandApproval
        case .itemCommandExecutionRequestApproval: return .itemCommandExecutionRequestApproval
        case .itemFileChangeRequestApproval: return .itemFileChangeRequestApproval
        }
    }
}

extension AnyTypedServerRequest {
    /// Narrow to an ``AnyApprovalRequest`` if this is one of the four approval-shaped
    /// server requests. Returns `nil` for non-approval requests
    /// (`ItemToolCall`, `ItemToolRequestUserInput`, `PermissionsRequestApproval`,
    /// `McpServerElicitationRequest`, `AccountChatgptAuthTokensRefresh`).
    public var asApprovalRequest: AnyApprovalRequest? {
        switch self {
        case .applyPatchApproval(let request): return .applyPatchApproval(request)
        case .execCommandApproval(let request): return .execCommandApproval(request)
        case .itemCommandExecutionRequestApproval(let request): return .itemCommandExecutionRequestApproval(request)
        case .itemFileChangeRequestApproval(let request): return .itemFileChangeRequestApproval(request)
        case .accountChatgptAuthTokensRefresh,
             .itemPermissionsRequestApproval,
             .itemToolCall,
             .itemToolRequestUserInput,
             .mcpServerElicitationRequest:
            return nil
        }
    }
}

// MARK: - Decision-enum mappings (curated vocabulary, hand-maintained)

// These map the canonical ``ApprovalIntent`` onto the wire-format decision
// enums. They live here (not in the generated output) because they encode
// the intent→wire-value mapping that is semantic, not mechanical — a change
// in codex's wire vocabulary would require an informed update, not a
// pure regeneration.
//
// The per-response-type `init(intent:)` extensions that consume these
// decision enums are generated from the schema in
// `Generated/ApprovalMappingsGenerated.swift` so new approval-shaped response
// types introduced by upstream codex are covered automatically.

extension ReviewDecision {
    /// Construct a ``ReviewDecision`` for the given canonical ``ApprovalIntent``.
    public init(intent: ApprovalIntent) {
        switch intent {
        case .allowOnce:
            self = .enumeration(.approved)
        case .allowForSession:
            self = .enumeration(.approvedForSession)
        case .deny:
            self = .enumeration(.denied)
        case .abort:
            self = .enumeration(.abort)
        }
    }
}

extension FileChangeApprovalDecision {
    /// Construct a ``FileChangeApprovalDecision`` for the given canonical ``ApprovalIntent``.
    public init(intent: ApprovalIntent) {
        switch intent {
        case .allowOnce:
            self = .accept
        case .allowForSession:
            self = .acceptForSession
        case .deny:
            self = .decline
        case .abort:
            self = .cancel
        }
    }
}

extension CommandExecutionApprovalDecision {
    /// Construct a ``CommandExecutionApprovalDecision`` for the given canonical ``ApprovalIntent``.
    public init(intent: ApprovalIntent) {
        self = .enumeration(FileChangeApprovalDecision(intent: intent))
    }
}
