import Foundation

public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum WhoopAPIError: Error, Equatable, Sendable {
    case missingCredentials
    case authenticationFailed
    case rateLimited
    case server(status: Int)
    case notFound
    case invalidResponse
    case decoding
    case transport(message: String)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WhoopAPIError.invalidResponse
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WhoopAPIError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw WhoopAPIError.transport(message: "url_error_\(error.errorCode)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WhoopAPIError.transport(message: "network_request_failed")
        }
    }
}
