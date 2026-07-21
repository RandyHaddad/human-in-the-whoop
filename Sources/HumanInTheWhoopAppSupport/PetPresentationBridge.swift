import Foundation
import Network

public final class PetPresentationSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PetPresentationSnapshot

    public init(snapshot: PetPresentationSnapshot = .unavailable) {
        self.snapshot = snapshot
    }

    public func read() -> PetPresentationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func publish(_ snapshot: PetPresentationSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
    }
}

public protocol PetPresentationServing: AnyObject, Sendable {
    func start() throws
    func stop()
}

public enum PetPresentationHTTP {
    public static func response(
        for request: Data,
        snapshot: PetPresentationSnapshot
    ) -> Data {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.split(separator: "\n", maxSplits: 1).first
        else {
            return response(status: "400 Bad Request", body: Data())
        }
        let components = requestLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard components.count >= 2 else {
            return response(status: "400 Bad Request", body: Data())
        }
        guard components[0] == "GET" else {
            return response(status: "405 Method Not Allowed", body: Data())
        }
        guard components[1] == "/v1/pet" else {
            return response(status: "404 Not Found", body: Data())
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(snapshot)) ?? Data()
        return response(status: "200 OK", body: body)
    }

    private static func response(status: String, body: Data) -> Data {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Access-Control-Allow-Origin: app://-",
            "Vary: Origin",
            "Cache-Control: no-store",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(headers.utf8)
        data.append(body)
        return data
    }
}

public final class PetPresentationBridgeServer: PetPresentationServing, @unchecked Sendable {
    public static let defaultPort: NWEndpoint.Port = 49_797

    private let snapshotStore: PetPresentationSnapshotStore
    private let queue: DispatchQueue
    private let port: NWEndpoint.Port
    private let availabilityChanged: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var listener: NWListener?

    public init(
        snapshotStore: PetPresentationSnapshotStore,
        port: NWEndpoint.Port = PetPresentationBridgeServer.defaultPort,
        queue: DispatchQueue = DispatchQueue(label: "HumanInTheWhoop.PetBridge"),
        availabilityChanged: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.snapshotStore = snapshotStore
        self.port = port
        self.queue = queue
        self.availabilityChanged = availabilityChanged
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.availabilityChanged(true)
            case .failed:
                self.availabilityChanged(false)
                self.stop()
            case .cancelled:
                self.availabilityChanged(false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let response = PetPresentationHTTP.response(
                for: data ?? Data(),
                snapshot: self.snapshotStore.read()
            )
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
