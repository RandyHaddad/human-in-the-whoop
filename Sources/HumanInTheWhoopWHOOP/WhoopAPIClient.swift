import Foundation

public protocol WhoopAPI: Sendable {
    func latestCycle() async throws -> WhoopCycleDTO
    func recovery(cycleID: Int64) async throws -> WhoopRecoveryDTO
    func sleep(cycleID: Int64) async throws -> WhoopSleepDTO?
    func workouts(start: Date, end: Date) async throws -> [WhoopWorkoutDTO]
}

private struct TokenRotation: Equatable, Sendable {
    let account: String
    let accessToken: String
    let refreshToken: String

    var accessSecret: WhoopSecret {
        WhoopSecret(account: account, value: accessToken)
    }
}

public actor WhoopAPIClient: WhoopAPI {
    public static let defaultBaseURL = URL(string: "https://api.prod.whoop.com/developer")!
    public static let defaultTokenURL = URL(string: "https://api.prod.whoop.com/oauth/oauth2/token")!

    private let httpClient: any HTTPClient
    private let credentialStore: any WhoopCredentialStore
    private let baseURL: URL
    private let tokenURL: URL
    private var refreshOperation: (
        id: UUID,
        task: Task<TokenRotation, any Error>
    )?
    private var pendingRotation: TokenRotation?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentialStore: any WhoopCredentialStore = KeychainCredentialStore(),
        baseURL: URL = WhoopAPIClient.defaultBaseURL,
        tokenURL: URL = WhoopAPIClient.defaultTokenURL
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.tokenURL = tokenURL
    }

    public func latestCycle() async throws -> WhoopCycleDTO {
        let request = try resourceRequest(
            path: "/v2/cycle",
            queryItems: [URLQueryItem(name: "limit", value: "1")]
        )
        let (data, response) = try await authorizedResponse(for: request)
        try Self.validateResourceStatus(response.statusCode)
        let collection: WhoopCycleCollectionDTO = try Self.decode(data)
        guard let latest = collection.records.first else {
            throw WhoopAPIError.notFound
        }
        return latest
    }

    public func recovery(cycleID: Int64) async throws -> WhoopRecoveryDTO {
        let request = try resourceRequest(path: "/v2/cycle/\(cycleID)/recovery")
        let (data, response) = try await authorizedResponse(for: request)
        try Self.validateResourceStatus(response.statusCode)
        return try Self.decode(data)
    }

    public func sleep(cycleID: Int64) async throws -> WhoopSleepDTO? {
        let request = try resourceRequest(path: "/v2/cycle/\(cycleID)/sleep")
        let (data, response) = try await authorizedResponse(for: request)
        if response.statusCode == 404 { return nil }
        try Self.validateResourceStatus(response.statusCode)
        return try Self.decode(data)
    }

    public func workouts(start: Date, end: Date) async throws -> [WhoopWorkoutDTO] {
        var records: [WhoopWorkoutDTO] = []
        var nextToken: String?
        var observedTokens: Set<String> = []

        repeat {
            var queryItems = [
                URLQueryItem(name: "start", value: Self.rfc3339(start)),
                URLQueryItem(name: "end", value: Self.rfc3339(end)),
                URLQueryItem(name: "limit", value: "25"),
            ]
            if let nextToken {
                queryItems.append(URLQueryItem(name: "nextToken", value: nextToken))
            }
            let request = try resourceRequest(
                path: "/v2/activity/workout",
                queryItems: queryItems
            )
            let (data, response) = try await authorizedResponse(for: request)
            try Self.validateResourceStatus(response.statusCode)
            let collection: WhoopWorkoutCollectionDTO = try Self.decode(data)
            records.append(contentsOf: collection.records)

            if let token = collection.nextToken {
                guard !token.isEmpty, observedTokens.insert(token).inserted else {
                    throw WhoopAPIError.invalidResponse
                }
            }
            nextToken = collection.nextToken
        } while nextToken != nil

        return records
    }

    private func resourceRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WhoopAPIError.invalidResponse
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw WhoopAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func authorizedResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let access = try accessTokenForRequest()
        var firstRequest = request
        firstRequest.setValue("Bearer \(access.value)", forHTTPHeaderField: "Authorization")
        let first = try await Self.perform(httpClient: httpClient, request: firstRequest)
        guard first.1.statusCode == 401 else { return first }

        let replacement = try await replacementAccessToken(rejected: access)
        var retryRequest = request
        retryRequest.setValue("Bearer \(replacement.value)", forHTTPHeaderField: "Authorization")
        let retry = try await Self.perform(httpClient: httpClient, request: retryRequest)
        guard retry.1.statusCode != 401 else {
            throw WhoopAPIError.authenticationFailed
        }
        return retry
    }

    private func accessTokenForRequest() throws -> WhoopSecret {
        if pendingRotation != nil {
            return try persistPendingRotation()
        }
        return try requiredSecret(service: WhoopKeychainService.accessToken)
    }

    private func replacementAccessToken(rejected: WhoopSecret) async throws -> WhoopSecret {
        try Task.checkCancellation()
        if pendingRotation != nil {
            return try persistPendingRotation()
        }

        let current = try requiredSecret(service: WhoopKeychainService.accessToken)
        guard current.account == rejected.account else {
            throw WhoopAPIError.authenticationFailed
        }
        if current.value != rejected.value { return current }

        let operation: (id: UUID, task: Task<TokenRotation, any Error>)
        if let activeOperation = refreshOperation {
            operation = activeOperation
        } else {
            let operationID = UUID()
            let task = Task {
                try await Self.fetchTokenRotation(
                    rejectedAccess: rejected,
                    httpClient: httpClient,
                    credentialStore: credentialStore,
                    tokenURL: tokenURL
                )
            }
            operation = (operationID, task)
            refreshOperation = operation
        }

        do {
            let rotation = try await operation.task.value
            if refreshOperation?.id == operation.id {
                refreshOperation = nil
                pendingRotation = rotation
            }
            if pendingRotation == rotation {
                try Task.checkCancellation()
                return try persistPendingRotation()
            }
            return rotation.accessSecret
        } catch {
            if refreshOperation?.id == operation.id { refreshOperation = nil }
            throw error
        }
    }

    private func persistPendingRotation() throws -> WhoopSecret {
        guard let rotation = pendingRotation else {
            throw WhoopAPIError.authenticationFailed
        }
        do {
            try credentialStore.upsert(
                service: WhoopKeychainService.refreshToken,
                account: rotation.account,
                value: rotation.refreshToken
            )
            try credentialStore.upsert(
                service: WhoopKeychainService.accessToken,
                account: rotation.account,
                value: rotation.accessToken
            )
        } catch {
            throw WhoopAPIError.authenticationFailed
        }
        pendingRotation = nil
        return rotation.accessSecret
    }

    private func requiredSecret(service: String) throws -> WhoopSecret {
        let secret: WhoopSecret
        do {
            secret = try credentialStore.read(service: service)
        } catch {
            throw WhoopAPIError.missingCredentials
        }
        guard secret.account.isEmpty == false, secret.value.isEmpty == false else {
            throw WhoopAPIError.missingCredentials
        }
        return secret
    }

    private static func fetchTokenRotation(
        rejectedAccess: WhoopSecret,
        httpClient: any HTTPClient,
        credentialStore: any WhoopCredentialStore,
        tokenURL: URL
    ) async throws -> TokenRotation {
        let refresh: WhoopSecret
        let clientSecret: WhoopSecret
        do {
            refresh = try credentialStore.read(service: WhoopKeychainService.refreshToken)
            clientSecret = try credentialStore.read(service: WhoopKeychainService.clientSecret)
        } catch {
            throw WhoopAPIError.missingCredentials
        }
        guard rejectedAccess.account.isEmpty == false,
              refresh.account.isEmpty == false,
              refresh.value.isEmpty == false,
              clientSecret.account.isEmpty == false,
              clientSecret.value.isEmpty == false
        else {
            throw WhoopAPIError.missingCredentials
        }
        guard refresh.account == rejectedAccess.account,
              clientSecret.account == rejectedAccess.account
        else {
            throw WhoopAPIError.authenticationFailed
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formData([
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh.value),
            ("client_id", rejectedAccess.account),
            ("client_secret", clientSecret.value),
            ("scope", "offline"),
        ])

        let (data, response) = try await perform(httpClient: httpClient, request: request)
        try validateTokenStatus(response.statusCode)
        let token: WhoopTokenResponseDTO = try decode(data)
        guard token.accessToken.isEmpty == false,
              token.refreshToken.isEmpty == false
        else {
            throw WhoopAPIError.authenticationFailed
        }

        return TokenRotation(
            account: rejectedAccess.account,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken
        )
    }

    private static func perform(
        httpClient: any HTTPClient,
        request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let response = try await httpClient.data(for: request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch WhoopAPIError.invalidResponse {
            if Task.isCancelled { throw CancellationError() }
            throw WhoopAPIError.invalidResponse
        } catch let error as WhoopAPIError {
            if Task.isCancelled { throw CancellationError() }
            switch error {
            case .transport:
                throw WhoopAPIError.transport(message: "request_failed")
            default:
                throw error
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WhoopAPIError.transport(message: "request_failed")
        }
    }

    private static func validateResourceStatus(_ status: Int) throws {
        switch status {
        case 200..<300:
            return
        case 401:
            throw WhoopAPIError.authenticationFailed
        case 404:
            throw WhoopAPIError.notFound
        case 429:
            throw WhoopAPIError.rateLimited
        case 500..<600:
            throw WhoopAPIError.server(status: status)
        default:
            throw WhoopAPIError.invalidResponse
        }
    }

    private static func validateTokenStatus(_ status: Int) throws {
        switch status {
        case 200..<300:
            return
        case 400, 401:
            throw WhoopAPIError.authenticationFailed
        case 429:
            throw WhoopAPIError.rateLimited
        case 500..<600:
            throw WhoopAPIError.server(status: status)
        default:
            throw WhoopAPIError.invalidResponse
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WhoopAPIError.decoding
        }
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func formData(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = fields.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedName)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
