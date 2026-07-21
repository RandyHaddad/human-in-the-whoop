import Foundation

public enum WhoopScoreState: Codable, Equatable, RawRepresentable, Sendable {
    case scored
    case pendingScore
    case unscorable
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "SCORED":
            self = .scored
        case "PENDING_SCORE":
            self = .pendingScore
        case "UNSCORABLE":
            self = .unscorable
        default:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scored: "SCORED"
        case .pendingScore: "PENDING_SCORE"
        case .unscorable: "UNSCORABLE"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self))!
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WhoopCycleScoreDTO: Codable, Equatable, Sendable {
    public let strain: Double

    public init(strain: Double) {
        self.strain = strain
    }
}

public struct WhoopCycleDTO: Codable, Equatable, Sendable {
    public let id: Int64
    public let start: Date
    public let end: Date?
    public let scoreState: WhoopScoreState
    public let score: WhoopCycleScoreDTO?

    public init(
        id: Int64,
        start: Date,
        end: Date?,
        scoreState: WhoopScoreState,
        score: WhoopCycleScoreDTO?
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.scoreState = scoreState
        self.score = score
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case scoreState = "score_state"
        case score
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        start = try container.decodeWhoopDate(forKey: .start)
        end = try container.decodeWhoopDateIfPresent(forKey: .end)
        scoreState = try container.decode(WhoopScoreState.self, forKey: .scoreState)
        score = try container.decodeIfPresent(WhoopCycleScoreDTO.self, forKey: .score)
    }
}

public struct WhoopCycleCollectionDTO: Codable, Equatable, Sendable {
    public let records: [WhoopCycleDTO]
    public let nextToken: String?

    public init(records: [WhoopCycleDTO], nextToken: String?) {
        self.records = records
        self.nextToken = nextToken
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case nextToken = "next_token"
    }
}

public struct WhoopRecoveryScoreDTO: Codable, Equatable, Sendable {
    public let recoveryScore: Int

    public init(recoveryScore: Int) {
        self.recoveryScore = recoveryScore
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryScore = "recovery_score"
    }
}

public struct WhoopRecoveryDTO: Codable, Equatable, Sendable {
    public let cycleID: Int64
    public let sleepID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let scoreState: WhoopScoreState
    public let score: WhoopRecoveryScoreDTO?

    public init(
        cycleID: Int64,
        sleepID: UUID,
        createdAt: Date,
        updatedAt: Date,
        scoreState: WhoopScoreState,
        score: WhoopRecoveryScoreDTO?
    ) {
        self.cycleID = cycleID
        self.sleepID = sleepID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scoreState = scoreState
        self.score = score
    }

    private enum CodingKeys: String, CodingKey {
        case cycleID = "cycle_id"
        case sleepID = "sleep_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case scoreState = "score_state"
        case score
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try container.decode(Int64.self, forKey: .cycleID)
        sleepID = try container.decode(UUID.self, forKey: .sleepID)
        createdAt = try container.decodeWhoopDate(forKey: .createdAt)
        updatedAt = try container.decodeWhoopDate(forKey: .updatedAt)
        scoreState = try container.decode(WhoopScoreState.self, forKey: .scoreState)
        score = try container.decodeIfPresent(WhoopRecoveryScoreDTO.self, forKey: .score)
    }
}

public struct WhoopSleepScoreDTO: Codable, Equatable, Sendable {
    public let sleepPerformancePercentage: Double

    public init(sleepPerformancePercentage: Double) {
        self.sleepPerformancePercentage = sleepPerformancePercentage
    }

    private enum CodingKeys: String, CodingKey {
        case sleepPerformancePercentage = "sleep_performance_percentage"
    }
}

public struct WhoopSleepDTO: Codable, Equatable, Sendable {
    public let id: UUID
    public let cycleID: Int64
    public let scoreState: WhoopScoreState
    public let score: WhoopSleepScoreDTO?

    public init(
        id: UUID,
        cycleID: Int64,
        scoreState: WhoopScoreState,
        score: WhoopSleepScoreDTO?
    ) {
        self.id = id
        self.cycleID = cycleID
        self.scoreState = scoreState
        self.score = score
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cycleID = "cycle_id"
        case scoreState = "score_state"
        case score
    }
}

public struct WhoopWorkoutScoreDTO: Codable, Equatable, Sendable {
    public let strain: Double

    public init(strain: Double) {
        self.strain = strain
    }
}

public struct WhoopWorkoutDTO: Codable, Equatable, Sendable {
    public let id: UUID
    public let end: Date
    public let scoreState: WhoopScoreState
    public let score: WhoopWorkoutScoreDTO?

    public init(
        id: UUID,
        end: Date,
        scoreState: WhoopScoreState,
        score: WhoopWorkoutScoreDTO?
    ) {
        self.id = id
        self.end = end
        self.scoreState = scoreState
        self.score = score
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case end
        case scoreState = "score_state"
        case score
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        end = try container.decodeWhoopDate(forKey: .end)
        scoreState = try container.decode(WhoopScoreState.self, forKey: .scoreState)
        score = try container.decodeIfPresent(WhoopWorkoutScoreDTO.self, forKey: .score)
    }
}

public struct WhoopWorkoutCollectionDTO: Codable, Equatable, Sendable {
    public let records: [WhoopWorkoutDTO]
    public let nextToken: String?

    public init(records: [WhoopWorkoutDTO], nextToken: String?) {
        self.records = records
        self.nextToken = nextToken
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case nextToken = "next_token"
    }
}

public struct WhoopTokenResponseDTO: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let tokenType: String
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        tokenType: String,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

private extension KeyedDecodingContainer {
    func decodeWhoopDate(forKey key: Key) throws -> Date {
        let value = try decode(String.self, forKey: key)
        guard let date = parseWhoopDate(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected an RFC3339 timestamp"
            )
        }
        return date
    }

    func decodeWhoopDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        return try decodeWhoopDate(forKey: key)
    }
}

private func parseWhoopDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }

    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: value)
}
