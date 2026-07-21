import Foundation
import Security
@testable import HumanInTheWhoopWHOOP

private enum KeychainStoreTestFailure: Error {
    case failed(String)
}

private func keychainRequire(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw KeychainStoreTestFailure.failed(message)
    }
}

private final class ScriptedKeychain: @unchecked Sendable {
    struct Step {
        var status: OSStatus
        var result: CFTypeRef?
    }

    private(set) var queries: [[String: Any]] = []
    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        queries.append(query as NSDictionary as! [String: Any])
        guard steps.isEmpty == false else {
            return errSecInternalError
        }
        let step = steps.removeFirst()
        result?.pointee = step.result
        return step.status
    }
}

private enum KeychainCredentialStoreTestScenarios {
    private static let service = "test.human-in-the-whoop.credential"
    private static let account = "synthetic-client-id"

    private static func attributes(account: String = account) -> NSDictionary {
        [kSecAttrAccount as String: account]
    }

    private static func valueItem(account: String = account) -> NSDictionary {
        [
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("synthetic-value".utf8),
        ]
    }

    static func stagedQueriesAvoidInvalidMatchAllCombination() throws {
        let keychain = ScriptedKeychain(steps: [
            .init(status: errSecSuccess, result: attributes()),
            .init(status: errSecSuccess, result: valueItem()),
        ])

        let secrets = try KeychainCredentialStore.readAll(
            service: service,
            copyMatching: keychain.copyMatching
        )

        try keychainRequire(secrets.count == 1, "Expected one decoded credential")
        try keychainRequire(secrets[0].account == account, "Decoded the wrong account")
        try keychainRequire(keychain.queries.count == 2, "Expected staged Keychain queries")

        let attributesQuery = keychain.queries[0]
        try keychainRequire(attributesQuery[kSecReturnAttributes as String] as? Bool == true, "Enumeration did not request attributes")
        try keychainRequire(attributesQuery[kSecReturnData as String] == nil, "Enumeration requested data with MatchLimitAll")
        try keychainRequire(attributesQuery[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String, "Enumeration did not use MatchLimitAll")

        let valueQuery = keychain.queries[1]
        try keychainRequire(valueQuery[kSecAttrAccount as String] as? String == account, "Value lookup was not account-specific")
        try keychainRequire(valueQuery[kSecReturnAttributes as String] as? Bool == true, "Value lookup did not request attributes")
        try keychainRequire(valueQuery[kSecReturnData as String] as? Bool == true, "Value lookup did not request data")
        try keychainRequire(valueQuery[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String, "Value lookup did not use MatchLimitOne")
    }

    static func ambiguousEnumerationFailsBeforeReadingData() throws {
        let keychain = ScriptedKeychain(steps: [
            .init(
                status: errSecSuccess,
                result: [attributes(), attributes(account: "other-synthetic-client")] as NSArray
            ),
        ])

        do {
            _ = try KeychainCredentialStore.readAll(
                service: service,
                copyMatching: keychain.copyMatching
            )
            throw KeychainStoreTestFailure.failed("Expected ambiguous credentials to fail")
        } catch KeychainCredentialStoreError.invalidSecret {
            try keychainRequire(keychain.queries.count == 1, "Ambiguous credentials triggered a data read")
        }
    }

    static func accountMismatchFailsClosed() throws {
        let keychain = ScriptedKeychain(steps: [
            .init(status: errSecSuccess, result: attributes()),
            .init(status: errSecSuccess, result: valueItem(account: "different-client")),
        ])

        do {
            _ = try KeychainCredentialStore.readAll(
                service: service,
                copyMatching: keychain.copyMatching
            )
            throw KeychainStoreTestFailure.failed("Expected account mismatch to fail")
        } catch KeychainCredentialStoreError.invalidSecret {
            try keychainRequire(keychain.queries.count == 2, "Account mismatch did not use staged reads")
        }
    }
}

#if canImport(XCTest)
import XCTest

final class KeychainCredentialStoreTests: XCTestCase {
    func testStagedQueriesAvoidInvalidMatchAllAttributesAndDataCombination() throws {
        try KeychainCredentialStoreTestScenarios.stagedQueriesAvoidInvalidMatchAllCombination()
    }

    func testAmbiguousEnumerationFailsBeforeReadingCredentialData() throws {
        try KeychainCredentialStoreTestScenarios.ambiguousEnumerationFailsBeforeReadingData()
    }

    func testAccountMismatchFailsClosed() throws {
        try KeychainCredentialStoreTestScenarios.accountMismatchFailsClosed()
    }
}
#else
import Testing

@Suite struct KeychainCredentialStoreTests {
    @Test func stagedQueriesAvoidInvalidMatchAllAttributesAndDataCombination() throws {
        try KeychainCredentialStoreTestScenarios.stagedQueriesAvoidInvalidMatchAllCombination()
    }

    @Test func ambiguousEnumerationFailsBeforeReadingCredentialData() throws {
        try KeychainCredentialStoreTestScenarios.ambiguousEnumerationFailsBeforeReadingData()
    }

    @Test func accountMismatchFailsClosed() throws {
        try KeychainCredentialStoreTestScenarios.accountMismatchFailsClosed()
    }
}
#endif
