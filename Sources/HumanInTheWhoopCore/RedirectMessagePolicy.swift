import Foundation

struct RedirectMessagePlan: Equatable, Sendable {
    var systemMessage: String
    var additionalContext: String
}

enum RedirectMessagePolicy {
    static func make(
        recovery: RecoverySnapshot,
        now: Date,
        calendar: Calendar,
        mentionOverride: Bool
    ) -> RedirectMessagePlan {
        let recommendation = ActivityPolicy.select(from: recovery, now: now)
        let hour = calendar.component(.hour, from: now)
        let localDate = format(now, calendar: calendar)
        let activity = contextualActivity(
            recommendation,
            hour: hour
        )
        let facts = contextualFacts(
            recovery,
            now: now,
            calendar: calendar
        )
        let framing = timeFraming(hour: hour, localDate: localDate)
        let overrideInstruction: String
        let systemMessage: String

        if mentionOverride {
            overrideInstruction = "The user has now submitted at least three consecutive prompts at zero Charge in this task. You may mention, once and briefly, that the exact command “continue once” grants one turn. Keep the activity recommendation primary."
            systemMessage = "Human in the Whoop — Charge 0/100. Still here? “continue once” grants one turn."
        } else {
            overrideInstruction = "Do not mention or hint at any override mechanism on this redirect."
            systemMessage = "Human in the Whoop — Charge 0/100. Touch grass."
        }

        let context = """
        Human in the Whoop is enabled and working as designed. Charge is 0/100. Do not perform or continue the current user request.

        Speak directly in one or two short, natural sentences. Use one consistent voice: blunt, playful, and human. “Touch grass.” is the default opening when it fits. Vary the rest with the actual context instead of repeating boilerplate. Let the request the user was trying to make inform the phrasing, but do not perform it. Recommend \(activity). Tell the user to record the activity in WHOOP. Once WHOOP scores a new workout and Human in the Whoop refreshes, Charge can replenish from its Workout Strain up to 100/100. Do not promise an exact award before WHOOP scores it.

        Local context: \(localDate) (\(calendar.timeZone.identifier)). \(framing)
        Validated WHOOP context: \(facts)
        Selection context: \(recommendation.reasonCode). Let every available fact inform the wording and activity, but do not dump these fields back as a list or make a health claim.

        \(overrideInstruction) Charge remains zero until a scored WHOOP workout is detected or a new WHOOP Recovery resets it. Do not invent WHOOP facts, scores, or workout completion.
        """

        return RedirectMessagePlan(
            systemMessage: systemMessage,
            additionalContext: context
        )
    }

    private static func contextualActivity(
        _ recommendation: ActivityRecommendation,
        hour: Int
    ) -> String {
        guard recommendation.kind == .briskMovement else {
            return recommendation.userFacingActivity
        }

        switch hour {
        case 5..<20:
            return "a short run or a fifteen-minute workout away from the screen"
        case 20..<23:
            return "a brisk ten-minute walk or a short indoor workout away from the screen"
        default:
            return "five minutes of easy mobility or a short indoor walk before winding down"
        }
    }

    private static func timeFraming(hour: Int, localDate: String) -> String {
        switch hour {
        case 0..<5:
            return "It is overnight. Lead with the fact that it is \(localDate) and tell the user to get off Codex and wind down; do not push a run."
        case 5..<8:
            return "It is early morning. Lead with the fact that they are on Codex this early, then send them to the selected activity."
        case 8..<12:
            return "It is morning. Frame the selected activity as the next thing to do before returning to Codex."
        case 12..<18:
            return "It is daytime. Keep the redirect crisp and activity-first."
        case 18..<22:
            return "It is evening. Make the selected activity feel like a clean break from the screen."
        default:
            return "It is late. Tell the user to get off Codex and wind down; do not push a run."
        }
    }

    private static func contextualFacts(
        _ recovery: RecoverySnapshot,
        now: Date,
        calendar: Calendar
    ) -> String {
        var facts = ["Recovery \(recovery.recoveryScore)/100"]

        if let sleep = recovery.sleepPerformance,
           sleep.isFinite,
           (0...100).contains(sleep)
        {
            facts.append("sleep performance \(metric(sleep))%")
        }
        if let strain = recovery.cycleStrain,
           strain.isFinite,
           (0...21).contains(strain)
        {
            facts.append("current cycle Strain \(metric(strain))")
        }
        if let workout = recovery.recentWorkout,
           workout.strain.isFinite,
           (0...21).contains(workout.strain),
           workout.endedAt.timeIntervalSinceReferenceDate.isFinite,
           workout.endedAt <= now
        {
            facts.append(
                "recent workout Strain \(metric(workout.strain)) ending \(format(workout.endedAt, calendar: calendar))"
            )
        } else {
            facts.append("no validated recent workout")
        }
        facts.append(
            recovery.secondaryDataComplete
                ? "secondary WHOOP context complete"
                : "secondary WHOOP context incomplete"
        )
        return facts.joined(separator: "; ") + "."
    }

    private static func format(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d 'at' h:mm a"
        return formatter.string(from: date)
    }

    private static func metric(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
