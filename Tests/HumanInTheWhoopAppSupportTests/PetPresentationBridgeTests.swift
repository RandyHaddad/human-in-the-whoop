import Foundation
import Network
import Testing
@testable import HumanInTheWhoopAppSupport

@Suite struct PetPresentationBridgeTests {
    @Test func snapshotStorePublishesAtomically() {
        let store = PetPresentationSnapshotStore()
        #expect(store.read() == .unavailable)

        let selected = PetPresentationSnapshot(
            available: true,
            enabled: true,
            petEnabled: true,
            petIdentity: PetSelection.battery.rawValue,
            charge: 72,
            awardSequence: "100:workout:1",
            appliedCharge: 9
        )
        store.publish(selected)
        #expect(store.read() == selected)
    }

    @Test func endpointReturnsOnlyThePresentationSnapshot() throws {
        let snapshot = PetPresentationSnapshot(
            available: true,
            enabled: true,
            petEnabled: true,
            petIdentity: PetSelection.whoopSensorB.rawValue,
            charge: 33,
            awardSequence: nil,
            appliedCharge: 0
        )
        let response = PetPresentationHTTP.response(
            for: Data("GET /v1/pet HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8),
            snapshot: snapshot
        )
        let separator = Data("\r\n\r\n".utf8)
        let range = try #require(response.range(of: separator))
        let headers = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        let body = response[range.upperBound...]

        #expect(headers.contains("200 OK"))
        #expect(headers.contains("Access-Control-Allow-Origin: app://-"))
        #expect(headers.contains("Vary: Origin"))
        #expect(headers.contains("Cache-Control: no-store"))
        #expect(try JSONDecoder().decode(PetPresentationSnapshot.self, from: body) == snapshot)
        #expect(!String(decoding: body, as: UTF8.self).contains("recovery"))
        #expect(!String(decoding: body, as: UTF8.self).contains("token"))
    }

    @Test func endpointRejectsWritesAndUnknownPaths() {
        let post = PetPresentationHTTP.response(
            for: Data("POST /v1/pet HTTP/1.1\r\n\r\n".utf8),
            snapshot: .unavailable
        )
        let unknown = PetPresentationHTTP.response(
            for: Data("GET /other HTTP/1.1\r\n\r\n".utf8),
            snapshot: .unavailable
        )
        #expect(String(decoding: post, as: UTF8.self).contains("405 Method Not Allowed"))
        #expect(String(decoding: unknown, as: UTF8.self).contains("404 Not Found"))
    }

    @Test func liveServerBindsOnlyTheConfiguredLoopbackEndpoint() async throws {
        let portNumber = UInt16.random(in: 51_000...59_000)
        let port = try #require(NWEndpoint.Port(rawValue: portNumber))
        let expected = PetPresentationSnapshot(
            available: true,
            enabled: true,
            petEnabled: true,
            petIdentity: PetSelection.battery.rawValue,
            charge: 67,
            awardSequence: nil,
            appliedCharge: 0
        )
        let store = PetPresentationSnapshotStore(snapshot: expected)
        let server = PetPresentationBridgeServer(snapshotStore: store, port: port)
        try server.start()
        defer { server.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(portNumber)/v1/pet"))
        for _ in 0..<50 {
            if let result = try? await URLSession.shared.data(from: url),
               result.1 is HTTPURLResponse,
               let response = result.1 as? HTTPURLResponse,
               response.statusCode == 200
            {
                #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "app://-")
                #expect(try JSONDecoder().decode(PetPresentationSnapshot.self, from: result.0) == expected)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Loopback presentation endpoint did not become ready")
    }
}
