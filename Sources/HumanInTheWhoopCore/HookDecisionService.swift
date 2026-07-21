import Foundation

public struct CodexHookOutput: Codable, Equatable, Sendable {
    public var `continue`: Bool
    public var systemMessage: String?
    public var hookSpecificOutput: HookSpecificOutput?

    public init(
        continue: Bool,
        systemMessage: String?,
        hookSpecificOutput: HookSpecificOutput?
    ) {
        self.continue = `continue`
        self.systemMessage = systemMessage
        self.hookSpecificOutput = hookSpecificOutput
    }
}

public struct HookSpecificOutput: Codable, Equatable, Sendable {
    public var hookEventName: String
    public var additionalContext: String

    public init(hookEventName: String, additionalContext: String) {
        self.hookEventName = hookEventName
        self.additionalContext = additionalContext
    }
}

public struct HookDecisionService: Sendable {
    private static let hookEventName = "UserPromptSubmit"

    public init() {}

    public func render(
        _ decision: ChargeDecision,
        now: Date,
        calendar: Calendar = .current
    ) throws -> Data? {
        let output: CodexHookOutput

        switch decision {
        case .passThrough:
            return nil

        case let .redirect(recovery):
            output = redirectOutput(
                recovery: recovery,
                now: now,
                calendar: calendar,
                mentionOverride: false
            )

        case let .repeatedRedirect(recovery):
            output = redirectOutput(
                recovery: recovery,
                now: now,
                calendar: calendar,
                mentionOverride: true
            )

        case .continueOnce:
            let context = "Human in the Whoop granted this one-turn override. Perform the immediately preceding redirected request normally for this turn only. Do not redirect again this turn. Charge remains 0/100. The override itself does not refill Charge; a newly scored WHOOP workout can replenish Charge after Human in the Whoop refreshes. The next submitted prompt is subject to redirect again unless Charge has been replenished."
            output = CodexHookOutput(
                continue: true,
                systemMessage: nil,
                hookSpecificOutput: HookSpecificOutput(
                    hookEventName: Self.hookEventName,
                    additionalContext: context
                )
            )

        case let .degradedWarning(message),
             let .nothingToContinue(message):
            output = CodexHookOutput(
                continue: true,
                systemMessage: message,
                hookSpecificOutput: nil
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(output)
    }

    private func redirectOutput(
        recovery: RecoverySnapshot,
        now: Date,
        calendar: Calendar,
        mentionOverride: Bool
    ) -> CodexHookOutput {
        let plan = RedirectMessagePolicy.make(
            recovery: recovery,
            now: now,
            calendar: calendar,
            mentionOverride: mentionOverride
        )
        return CodexHookOutput(
            continue: true,
            systemMessage: plan.systemMessage,
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: Self.hookEventName,
                additionalContext: plan.additionalContext
            )
        )
    }
}
