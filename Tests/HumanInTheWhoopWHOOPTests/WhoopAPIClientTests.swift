import Foundation
@testable import HumanInTheWhoopWHOOP

private enum WHOOPTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): message }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WHOOPTestFailure.failed(message) }
}

private enum FakeCredentialError: Error { case unavailable }

private final class LockedCredentialStore: WhoopCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: WhoopSecret]
    private var recordedWrites: [(service: String, account: String, value: String)] = []
    private var writeFailuresRemaining: [String: Int]

    init(_ secrets: [String: WhoopSecret], writeFailuresRemaining: [String: Int] = [:]) {
        self.secrets = secrets
        self.writeFailuresRemaining = writeFailuresRemaining
    }

    func read(service: String) throws -> WhoopSecret {
        try lock.withLock {
            guard let secret = secrets[service] else { throw FakeCredentialError.unavailable }
            return secret
        }
    }

    func upsert(service: String, account: String, value: String) throws {
        try lock.withLock {
            recordedWrites.append((service, account, value))
            if let remaining = writeFailuresRemaining[service], remaining > 0 {
                writeFailuresRemaining[service] = remaining - 1
                throw FakeCredentialError.unavailable
            }
            secrets[service] = WhoopSecret(account: account, value: value)
        }
    }

    func writes() -> [(service: String, account: String, value: String)] {
        lock.withLock { recordedWrites }
    }

    func storedSecret(service: String) -> WhoopSecret? {
        lock.withLock { secrets[service] }
    }
}

private enum ScriptedHTTPResult: Sendable {
    case response(status: Int, data: Data)
    case failure(UnsafeTransportFailure)
    case cancellation
    case urlCancelled
}

private struct UnsafeTransportFailure: Error, Sendable {
    let detail: String
}

private actor ScriptedHTTPClient: HTTPClient {
    private var results: [ScriptedHTTPResult]
    private var captured: [URLRequest] = []

    init(_ results: [ScriptedHTTPResult]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard results.isEmpty == false else { throw WHOOPTestFailure.failed("Unexpected HTTP request") }
        let result = results.removeFirst()
        switch result {
        case .failure(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        case .response(let status, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                  )
            else { throw WHOOPTestFailure.failed("Could not construct fake response") }
            return (data, response)
        }
    }

    func requests() -> [URLRequest] { captured }
}

private actor ConcurrentRefreshHTTPClient: HTTPClient {
    private var oldResourceCount = 0
    private var tokenRequestCount = 0
    private var resourceRequestCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw WHOOPTestFailure.failed("Missing URL") }
        let status: Int
        let data: Data

        if url.path == "/oauth/oauth2/token" {
            tokenRequestCount += 1
            status = 200
            data = APIClientTestScenarios.tokenData
        } else if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
            resourceRequestCount += 1
            oldResourceCount += 1
            if oldResourceCount < 2 {
                await withCheckedContinuation { waiters.append($0) }
            } else {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }
            status = 401
            data = Data()
        } else {
            resourceRequestCount += 1
            status = 200
            data = APIClientTestScenarios.cycleData
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ) else { throw WHOOPTestFailure.failed("Could not construct fake response") }
        return (data, response)
    }

    func refreshCount() -> Int { tokenRequestCount }
    func totalRequestCount() -> Int { tokenRequestCount + resourceRequestCount }
}

private enum APIClientTestScenarios {
    static let account = "client+id&="
    static let cycleData = Data(#"{"records":[{"id":42,"start":"2026-07-18T07:11:44.774Z","end":null,"score_state":"SCORED","score":{"strain":8.5}}],"next_token":null}"#.utf8)
    static let emptyCycleData = Data(#"{"records":[],"next_token":null}"#.utf8)
    static let recoveryData = Data(#"{"cycle_id":42,"sleep_id":"550E8400-E29B-41D4-A716-446655440000","created_at":"2026-07-18T08:00:00Z","updated_at":"2026-07-18T08:01:00.123Z","score_state":"SCORED","score":{"recovery_score":72}}"#.utf8)
    static let workoutData = Data(#"{"records":[{"id":"650E8400-E29B-41D4-A716-446655440000","end":"2026-07-18T15:30:45Z","score_state":"SCORED","score":{"strain":14.2}}],"next_token":null}"#.utf8)
    static let tokenData = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"bearer"}"#.utf8)

    static func credentials(
        accessAccount: String = account,
        refreshAccount: String = account,
        clientSecretAccount: String = account,
        writeFailuresRemaining: [String: Int] = [:]
    ) -> LockedCredentialStore {
        LockedCredentialStore([
            WhoopKeychainService.accessToken: WhoopSecret(account: accessAccount, value: "old-access"),
            WhoopKeychainService.refreshToken: WhoopSecret(account: refreshAccount, value: "refresh+&="),
            WhoopKeychainService.clientSecret: WhoopSecret(account: clientSecretAccount, value: "secret+&="),
        ], writeFailuresRemaining: writeFailuresRemaining)
    }

    static func error<T>(from operation: () async throws -> T) async throws -> WhoopAPIError {
        do {
            _ = try await operation()
            throw WHOOPTestFailure.failed("Expected WHOOP API error")
        } catch let error as WhoopAPIError {
            return error
        }
    }

    static func authorizedRequestUsesBearerAndExactCycleURL() async throws {
        let http = ScriptedHTTPClient([.response(status: 200, data: cycleData)])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())

        let cycle = try await client.latestCycle()
        let requests = await http.requests()
        try require(cycle.id == 42, "Wrong cycle decoded")
        try require(requests.count == 1, "Expected one resource request")
        try require(requests[0].url?.absoluteString == "https://api.prod.whoop.com/developer/v2/cycle?limit=1", "Wrong latest-cycle URL")
        try require(requests[0].httpMethod == "GET", "Latest-cycle request was not GET")
        try require(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-access", "Missing bearer access token")
        try require(requests[0].value(forHTTPHeaderField: "Accept") == "application/json", "Missing JSON Accept header")
    }

    static func recoveryAndWorkoutURLsAreExact() async throws {
        let http = ScriptedHTTPClient([
            .response(status: 200, data: recoveryData),
            .response(status: 200, data: workoutData),
        ])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
        _ = try await client.recovery(cycleID: 42)
        let start = Date(timeIntervalSince1970: 1_752_643_200.123)
        let end = Date(timeIntervalSince1970: 1_752_646_800.987)
        _ = try await client.workouts(start: start, end: end)

        let requests = await http.requests()
        try require(requests[0].url?.absoluteString == "https://api.prod.whoop.com/developer/v2/cycle/42/recovery", "Wrong recovery URL")
        guard let components = requests[1].url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw WHOOPTestFailure.failed("Missing workout URL components")
        }
        try require(components.path == "/developer/v2/activity/workout", "Wrong workout path")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try require(query["start"] == "2025-07-16T05:20:00.123Z", "Workout start lost fractional precision")
        try require(query["end"] == "2025-07-16T06:20:00.987Z", "Exclusive workout end lost fractional precision")
        try require(query["limit"] == "25", "Wrong workout limit")
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try require(query["start"].flatMap(parser.date(from:)) == start, "Encoded workout start changed the lower bound")
        try require(query["end"].flatMap(parser.date(from:)) == end, "Encoded workout end changed the exclusive upper bound")
    }

    static func workoutPaginationFollowsNextToken() async throws {
        let firstPage = Data(
            #"{"records":[{"id":"650E8400-E29B-41D4-A716-446655440000","end":"2026-07-18T15:30:45Z","score_state":"SCORED","score":{"strain":14.2}}],"next_token":"page-2"}"#.utf8
        )
        let secondPage = Data(
            #"{"records":[{"id":"750E8400-E29B-41D4-A716-446655440000","end":"2026-07-18T16:30:45Z","score_state":"SCORED","score":{"strain":10.0}}],"next_token":null}"#.utf8
        )
        let http = ScriptedHTTPClient([
            .response(status: 200, data: firstPage),
            .response(status: 200, data: secondPage),
        ])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
        let start = Date(timeIntervalSince1970: 1_752_643_200.123)
        let end = Date(timeIntervalSince1970: 1_752_646_800.987)

        let workouts = try await client.workouts(start: start, end: end)
        try require(workouts.count == 2, "pagination omitted a workout page")
        let requests = await http.requests()
        try require(requests.count == 2, "pagination made the wrong request count")
        let secondQuery = requests[1].url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: secondQuery.map { ($0.name, $0.value ?? "") })
        try require(values["nextToken"] == "page-2", "next workout page omitted its token")
        try require(values["start"] == "2025-07-16T05:20:00.123Z", "pagination changed the start bound")
        try require(values["end"] == "2025-07-16T06:20:00.987Z", "pagination changed the end bound")
    }

    static func unauthorizedRefreshesOnceAndWritesRefreshFirst() async throws {
        let http = ScriptedHTTPClient([
            .response(status: 401, data: Data()),
            .response(status: 200, data: tokenData),
            .response(status: 200, data: cycleData),
        ])
        let store = credentials()
        let client = WhoopAPIClient(httpClient: http, credentialStore: store)
        _ = try await client.latestCycle()

        let requests = await http.requests()
        try require(requests.count == 3, "Expected resource, refresh, and one retry")
        try require(requests[1].url?.absoluteString == "https://api.prod.whoop.com/oauth/oauth2/token", "Wrong token URL")
        try require(requests[1].httpMethod == "POST", "Refresh was not POST")
        try require(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "Wrong refresh content type")
        let body = String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self)
        try require(body == "grant_type=refresh_token&refresh_token=refresh%2B%26%3D&client_id=client%2Bid%26%3D&client_secret=secret%2B%26%3D&scope=offline", "Refresh form was not safely and deterministically encoded")
        try require(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-access", "Retry did not use replacement access token")
        let writes = store.writes()
        try require(writes.map(\.service) == [WhoopKeychainService.refreshToken, WhoopKeychainService.accessToken], "Tokens were not saved refresh-first")
        try require(writes.map(\.value) == ["new-refresh", "new-access"], "Wrong replacement tokens saved")
    }

    static func secondUnauthorizedFailsWithoutAnotherRetry() async throws {
        let http = ScriptedHTTPClient([
            .response(status: 401, data: Data()),
            .response(status: 200, data: tokenData),
            .response(status: 401, data: Data()),
        ])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
        let error = try await error { try await client.latestCycle() }
        try require(error == .authenticationFailed, "Second 401 was not authentication failure")
        let requestCount = await http.requests().count
        try require(requestCount == 3, "Second 401 triggered another retry")
    }

    static func refreshEndpointFailureDoesNotRetryRecursively() async throws {
        for tokenStatus in [400, 401] {
            let http = ScriptedHTTPClient([
                .response(status: 401, data: Data()),
                .response(status: tokenStatus, data: Data(#"{"error":"invalid_grant"}"#.utf8)),
            ])
            let store = credentials()
            let client = WhoopAPIClient(httpClient: http, credentialStore: store)
            let capturedError = try await error { try await client.latestCycle() }
            try require(capturedError == .authenticationFailed, "Refresh \(tokenStatus) was not authentication failure")
            let requests = await http.requests()
            try require(requests.count == 2, "Refresh endpoint failure retried recursively")
            try require(store.writes().isEmpty, "Failed refresh endpoint changed credentials")
        }

        let resourceHTTP = ScriptedHTTPClient([.response(status: 400, data: Data())])
        let resourceClient = WhoopAPIClient(httpClient: resourceHTTP, credentialStore: credentials())
        let resourceError = try await error { try await resourceClient.latestCycle() }
        try require(resourceError == .invalidResponse, "Resource 400 did not remain invalidResponse")
    }

    static func failedRefreshWriteRecoversPendingRotationWithoutAnotherRefresh() async throws {
        let http = ScriptedHTTPClient([
            .response(status: 401, data: Data()),
            .response(status: 200, data: tokenData),
            .response(status: 200, data: cycleData),
        ])
        let store = credentials(writeFailuresRemaining: [WhoopKeychainService.refreshToken: 1])
        let client = WhoopAPIClient(httpClient: http, credentialStore: store)
        let capturedError = try await error { try await client.latestCycle() }
        try require(capturedError == .authenticationFailed, "First refresh-token write failure mapped incorrectly")
        let cycle = try await client.latestCycle()
        try require(cycle.id == 42, "Pending rotation recovery did not complete the next request")
        let requests = await http.requests()
        try require(requests.count == 3, "Pending rotation recovery made another token request")
        try require(requests.filter { $0.url?.path == "/oauth/oauth2/token" }.count == 1, "Rotating refresh token was consumed twice")
        try require(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-access", "Recovered call did not use pending access token")
        try require(store.writes().map(\.service) == [
            WhoopKeychainService.refreshToken,
            WhoopKeychainService.refreshToken,
            WhoopKeychainService.accessToken,
        ], "First-write recovery order changed")
    }

    static func failedAccessWriteRecoversPendingRotationIdempotently() async throws {
        let http = ScriptedHTTPClient([
            .response(status: 401, data: Data()),
            .response(status: 200, data: tokenData),
            .response(status: 200, data: cycleData),
        ])
        let store = credentials(writeFailuresRemaining: [WhoopKeychainService.accessToken: 1])
        let client = WhoopAPIClient(httpClient: http, credentialStore: store)
        let capturedError = try await error { try await client.latestCycle() }
        try require(capturedError == .authenticationFailed, "Access-token write failure mapped incorrectly")
        try require(store.storedSecret(service: WhoopKeychainService.refreshToken)?.value == "new-refresh", "Replacement refresh token was not retained")
        try require(store.storedSecret(service: WhoopKeychainService.accessToken)?.value == "old-access", "Failed access write unexpectedly replaced access token")
        let cycle = try await client.latestCycle()
        try require(cycle.id == 42, "Pending second-write rotation did not recover")
        let requests = await http.requests()
        try require(requests.count == 3, "Second-write recovery made another token request")
        try require(requests.filter { $0.url?.path == "/oauth/oauth2/token" }.count == 1, "Second-write recovery refreshed again")
        try require(store.writes().map(\.service) == [
            WhoopKeychainService.refreshToken,
            WhoopKeychainService.accessToken,
            WhoopKeychainService.refreshToken,
            WhoopKeychainService.accessToken,
        ], "Second-write recovery was not refresh-first and idempotent")
    }

    static func sleepNotFoundReturnsNilAndUsesExactURL() async throws {
        let http = ScriptedHTTPClient([.response(status: 404, data: Data())])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
        let sleep = try await client.sleep(cycleID: 42)
        try require(sleep == nil, "Sleep 404 was not nil")
        let requests = await http.requests()
        try require(requests[0].url?.absoluteString == "https://api.prod.whoop.com/developer/v2/cycle/42/sleep", "Wrong sleep URL")
    }

    static func emptyLatestCycleIsNotFound() async throws {
        let http = ScriptedHTTPClient([.response(status: 200, data: emptyCycleData)])
        let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
        let capturedError = try await error { try await client.latestCycle() }
        try require(capturedError == .notFound, "Empty collection was not notFound")
    }

    static func statusDecodingAndTransportErrorsStayDistinctAndSafe() async throws {
        let rateHTTP = ScriptedHTTPClient([.response(status: 429, data: Data())])
        let serverHTTP = ScriptedHTTPClient([.response(status: 503, data: Data())])
        let decodeHTTP = ScriptedHTTPClient([.response(status: 200, data: Data("not-json".utf8))])
        let unsafeSecret = "do-not-leak-token"
        let transportHTTP = ScriptedHTTPClient([.failure(UnsafeTransportFailure(detail: unsafeSecret))])

        let rate = try await error { try await WhoopAPIClient(httpClient: rateHTTP, credentialStore: credentials()).latestCycle() }
        let server = try await error { try await WhoopAPIClient(httpClient: serverHTTP, credentialStore: credentials()).latestCycle() }
        let decoding = try await error { try await WhoopAPIClient(httpClient: decodeHTTP, credentialStore: credentials()).latestCycle() }
        let transport = try await error { try await WhoopAPIClient(httpClient: transportHTTP, credentialStore: credentials()).latestCycle() }
        try require(rate == .rateLimited, "429 mapping changed")
        try require(server == .server(status: 503), "5xx mapping changed")
        try require(decoding == .decoding, "Decoding mapping changed")
        guard case .transport = transport else { throw WHOOPTestFailure.failed("Transport error mapping changed") }
        try require(String(reflecting: transport).contains(unsafeSecret) == false, "Transport error leaked source detail")
    }

    static func cancellationIsNeverConvertedToTransportFailure() async throws {
        for result in [ScriptedHTTPResult.cancellation, .urlCancelled] {
            let http = ScriptedHTTPClient([result])
            let client = WhoopAPIClient(httpClient: http, credentialStore: credentials())
            do {
                _ = try await client.latestCycle()
                throw WHOOPTestFailure.failed("Expected cancellation")
            } catch is CancellationError {
                continue
            } catch {
                throw WHOOPTestFailure.failed("Cancellation became \(String(reflecting: error))")
            }
        }
    }

    static func credentialMissingAndAccountMismatchFailSafely() async throws {
        let missing = LockedCredentialStore([:])
        let missingHTTP = ScriptedHTTPClient([])
        let missingError = try await error {
            try await WhoopAPIClient(httpClient: missingHTTP, credentialStore: missing).latestCycle()
        }
        try require(missingError == .missingCredentials, "Missing credentials mapped incorrectly")
        let missingRequests = await missingHTTP.requests()
        try require(missingRequests.isEmpty, "Missing credentials still made a request")

        let mismatchHTTP = ScriptedHTTPClient([
            .response(status: 401, data: Data()),
        ])
        let mismatchError = try await error {
            try await WhoopAPIClient(
                httpClient: mismatchHTTP,
                credentialStore: credentials(refreshAccount: "different-account")
            ).latestCycle()
        }
        try require(mismatchError == .authenticationFailed, "Account mismatch mapped incorrectly")
        let reflected = String(reflecting: mismatchError)
        try require(reflected.contains("refresh+&=") == false && reflected.contains("secret+&=") == false, "Credential error exposed a secret")
    }

    static func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let http = ConcurrentRefreshHTTPClient()
        let store = credentials()
        let client = WhoopAPIClient(httpClient: http, credentialStore: store)
        async let first = client.latestCycle()
        async let second = client.latestCycle()
        let cycles = try await [first, second]
        try require(cycles.map(\.id) == [42, 42], "Concurrent retries returned wrong data")
        let refreshCount = await http.refreshCount()
        try require(refreshCount == 1, "Concurrent 401 responses rotated refresh token more than once")
        let requestCount = await http.totalRequestCount()
        try require(requestCount == 5, "Concurrent retry request count changed")
        let writes = store.writes()
        try require(writes.map(\.service) == [WhoopKeychainService.refreshToken, WhoopKeychainService.accessToken], "Concurrent waiters persisted the same rotation more than once")
    }

    static func defaultClientCanBeConstructedWithoutTouchingCredentials() {
        _ = WhoopAPIClient()
    }
}

#if canImport(XCTest)
import XCTest

final class WhoopAPIClientTests: XCTestCase {
    func testAuthorizedRequestUsesBearerAccessTokenAndExactURL() async throws { try await APIClientTestScenarios.authorizedRequestUsesBearerAndExactCycleURL() }
    func testRecoveryAndWorkoutURLsAreExact() async throws { try await APIClientTestScenarios.recoveryAndWorkoutURLsAreExact() }
    func testWorkoutPaginationFollowsNextToken() async throws { try await APIClientTestScenarios.workoutPaginationFollowsNextToken() }
    func testUnauthorizedRequestRefreshesExactlyOnceAndWritesRefreshFirst() async throws { try await APIClientTestScenarios.unauthorizedRefreshesOnceAndWritesRefreshFirst() }
    func testSecondUnauthorizedResponseIsAuthenticationFailure() async throws { try await APIClientTestScenarios.secondUnauthorizedFailsWithoutAnotherRetry() }
    func testRefreshEndpointFailureDoesNotRetryRecursively() async throws { try await APIClientTestScenarios.refreshEndpointFailureDoesNotRetryRecursively() }
    func testFailedRefreshWriteRecoversPendingRotationWithoutAnotherRefresh() async throws { try await APIClientTestScenarios.failedRefreshWriteRecoversPendingRotationWithoutAnotherRefresh() }
    func testFailedAccessWriteRecoversPendingRotationIdempotently() async throws { try await APIClientTestScenarios.failedAccessWriteRecoversPendingRotationIdempotently() }
    func testSleepNotFoundReturnsNilAndUsesExactURL() async throws { try await APIClientTestScenarios.sleepNotFoundReturnsNilAndUsesExactURL() }
    func testEmptyLatestCycleIsNotFound() async throws { try await APIClientTestScenarios.emptyLatestCycleIsNotFound() }
    func testStatusDecodingAndTransportErrorsRemainDistinctAndSafe() async throws { try await APIClientTestScenarios.statusDecodingAndTransportErrorsStayDistinctAndSafe() }
    func testCancellationIsNeverConvertedToTransportFailure() async throws { try await APIClientTestScenarios.cancellationIsNeverConvertedToTransportFailure() }
    func testCredentialMissingAndAccountMismatchFailSafely() async throws { try await APIClientTestScenarios.credentialMissingAndAccountMismatchFailSafely() }
    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws { try await APIClientTestScenarios.concurrentUnauthorizedRequestsShareOneRefresh() }
    func testDefaultClientCanBeConstructedWithoutTouchingCredentials() { APIClientTestScenarios.defaultClientCanBeConstructedWithoutTouchingCredentials() }
}
#else
import Testing

@Suite struct WhoopAPIClientTests {
    @Test func authorizedRequestUsesBearerAccessTokenAndExactURL() async throws { try await APIClientTestScenarios.authorizedRequestUsesBearerAndExactCycleURL() }
    @Test func recoveryAndWorkoutURLsAreExact() async throws { try await APIClientTestScenarios.recoveryAndWorkoutURLsAreExact() }
    @Test func workoutPaginationFollowsNextToken() async throws { try await APIClientTestScenarios.workoutPaginationFollowsNextToken() }
    @Test func unauthorizedRequestRefreshesExactlyOnceAndWritesRefreshFirst() async throws { try await APIClientTestScenarios.unauthorizedRefreshesOnceAndWritesRefreshFirst() }
    @Test func secondUnauthorizedResponseIsAuthenticationFailure() async throws { try await APIClientTestScenarios.secondUnauthorizedFailsWithoutAnotherRetry() }
    @Test func refreshEndpointFailureDoesNotRetryRecursively() async throws { try await APIClientTestScenarios.refreshEndpointFailureDoesNotRetryRecursively() }
    @Test func failedRefreshWriteRecoversPendingRotationWithoutAnotherRefresh() async throws { try await APIClientTestScenarios.failedRefreshWriteRecoversPendingRotationWithoutAnotherRefresh() }
    @Test func failedAccessWriteRecoversPendingRotationIdempotently() async throws { try await APIClientTestScenarios.failedAccessWriteRecoversPendingRotationIdempotently() }
    @Test func sleepNotFoundReturnsNilAndUsesExactURL() async throws { try await APIClientTestScenarios.sleepNotFoundReturnsNilAndUsesExactURL() }
    @Test func emptyLatestCycleIsNotFound() async throws { try await APIClientTestScenarios.emptyLatestCycleIsNotFound() }
    @Test func statusDecodingAndTransportErrorsRemainDistinctAndSafe() async throws { try await APIClientTestScenarios.statusDecodingAndTransportErrorsStayDistinctAndSafe() }
    @Test func cancellationIsNeverConvertedToTransportFailure() async throws { try await APIClientTestScenarios.cancellationIsNeverConvertedToTransportFailure() }
    @Test func credentialMissingAndAccountMismatchFailSafely() async throws { try await APIClientTestScenarios.credentialMissingAndAccountMismatchFailSafely() }
    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws { try await APIClientTestScenarios.concurrentUnauthorizedRequestsShareOneRefresh() }
    @Test func defaultClientCanBeConstructedWithoutTouchingCredentials() { APIClientTestScenarios.defaultClientCanBeConstructedWithoutTouchingCredentials() }
}
#endif
