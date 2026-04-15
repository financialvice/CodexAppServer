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
/// decision enum. Use this protocol to write approval UI that doesn't care
/// which specific request arrived.
///
/// ```swift
/// func handle<Response: ApprovalResponse>(_: Response.Type) async throws {
///     try await client.respond(to: request, result: Response(intent: userChoice))
/// }
/// ```
public protocol ApprovalResponse: Sendable {
    /// Build a response for the given user intent.
    init(intent: ApprovalIntent)
}

// MARK: - ReviewDecision-shaped responses

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

extension ApplyPatchApprovalResponse: ApprovalResponse {
    public init(intent: ApprovalIntent) {
        self.init(decision: ReviewDecision(intent: intent))
    }
}

extension ExecCommandApprovalResponse: ApprovalResponse {
    public init(intent: ApprovalIntent) {
        self.init(decision: ReviewDecision(intent: intent))
    }
}

// MARK: - FileChangeApprovalDecision-shaped responses

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

extension CommandExecutionRequestApprovalResponse: ApprovalResponse {
    public init(intent: ApprovalIntent) {
        self.init(decision: CommandExecutionApprovalDecision(intent: intent))
    }
}

extension FileChangeRequestApprovalResponse: ApprovalResponse {
    public init(intent: ApprovalIntent) {
        self.init(decision: FileChangeApprovalDecision(intent: intent))
    }
}
