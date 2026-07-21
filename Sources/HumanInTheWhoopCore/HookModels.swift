import Foundation

public struct HookInput: Codable, Equatable, Sendable {
    public var sessionID: String
    public var turnID: String
    public var hookEventName: String
    public var prompt: String

    public init(
        sessionID: String,
        turnID: String,
        hookEventName: String,
        prompt: String
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.hookEventName = hookEventName
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case hookEventName = "hook_event_name"
        case prompt
    }
}

public enum ChargeDecision: Equatable, Sendable {
    case passThrough
    case degradedWarning(message: String)
    case redirect(recovery: RecoverySnapshot)
    case repeatedRedirect(recovery: RecoverySnapshot)
    case continueOnce
    case nothingToContinue(message: String)
}
