import Foundation
import Security

public enum WhoopKeychainService {
    public static let clientSecret = "human-in-the-whoop.whoop-client-secret"
    public static let accessToken = "human-in-the-whoop.whoop-access-token"
    public static let refreshToken = "human-in-the-whoop.whoop-refresh-token"
}

public struct WhoopSecret: Equatable, Sendable {
    public var account: String
    public var value: String

    public init(account: String, value: String) {
        self.account = account
        self.value = value
    }
}

public protocol WhoopCredentialStore: Sendable {
    func read(service: String) throws -> WhoopSecret
    func upsert(service: String, account: String, value: String) throws
}

public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case missingSecret
    case invalidSecret
    case unexpectedStatus(Int32)
}

public struct KeychainCredentialStore: WhoopCredentialStore {
    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    private static let processLock = NSLock()

    public init() {}

    public func read(service: String) throws -> WhoopSecret {
        guard service.isEmpty == false else {
            throw KeychainCredentialStoreError.invalidSecret
        }

        return try Self.processLock.withLock {
            let secrets = try Self.readAll(service: service)
            guard secrets.isEmpty == false else {
                throw KeychainCredentialStoreError.missingSecret
            }
            guard secrets.count == 1, let secret = secrets.first else {
                throw KeychainCredentialStoreError.invalidSecret
            }
            return secret
        }
    }

    public func upsert(service: String, account: String, value: String) throws {
        guard service.isEmpty == false,
              account.isEmpty == false,
              value.isEmpty == false,
              let data = value.data(using: .utf8)
        else {
            throw KeychainCredentialStoreError.invalidSecret
        }

        try Self.processLock.withLock {
            let existing = try Self.readAll(service: service)
            guard existing.count <= 1 else {
                throw KeychainCredentialStoreError.invalidSecret
            }
            if let secret = existing.first {
                guard secret.account == account else {
                    throw KeychainCredentialStoreError.invalidSecret
                }
                let updateStatus = Self.updateExact(
                    service: service,
                    account: account,
                    data: data
                )
                if updateStatus == errSecSuccess {
                    try Self.validateSingleAccount(service: service, account: account)
                    return
                }
                guard updateStatus == errSecItemNotFound else {
                    throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
                }
            }

            try Self.addOrRecoverDuplicate(
                service: service,
                account: account,
                data: data
            )
        }
    }

    private static func readAll(service: String) throws -> [WhoopSecret] {
        try readAll(service: service, copyMatching: SecItemCopyMatching)
    }

    static func readAll(
        service: String,
        copyMatching: CopyMatching
    ) throws -> [WhoopSecret] {
        let attributesQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var attributesResult: CFTypeRef?
        let attributesStatus = copyMatching(
            attributesQuery as CFDictionary,
            &attributesResult
        )
        if attributesStatus == errSecItemNotFound { return [] }
        guard attributesStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(attributesStatus)
        }

        let attributeItems = try decodeItems(attributesResult)
        guard attributeItems.count == 1,
              let account = attributeItems[0][kSecAttrAccount as String] as? String,
              account.isEmpty == false
        else {
            throw KeychainCredentialStoreError.invalidSecret
        }

        var valueQuery = exactQuery(service: service, account: account)
        valueQuery[kSecReturnAttributes as String] = true
        valueQuery[kSecReturnData as String] = true
        valueQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var valueResult: CFTypeRef?
        let valueStatus = copyMatching(valueQuery as CFDictionary, &valueResult)
        guard valueStatus == errSecSuccess else {
            if valueStatus == errSecItemNotFound {
                throw KeychainCredentialStoreError.invalidSecret
            }
            throw KeychainCredentialStoreError.unexpectedStatus(valueStatus)
        }
        guard let valueItem = valueResult as? NSDictionary else {
            throw KeychainCredentialStoreError.invalidSecret
        }
        let secret = try decodeSecret(valueItem)
        guard secret.account == account else {
            throw KeychainCredentialStoreError.invalidSecret
        }
        return [secret]
    }

    private static func decodeItems(_ result: CFTypeRef?) throws -> [NSDictionary] {
        if let collection = result as? [NSDictionary] {
            return collection
        }
        if let item = result as? NSDictionary {
            return [item]
        }
        throw KeychainCredentialStoreError.invalidSecret
    }

    private static func decodeSecret(_ item: NSDictionary) throws -> WhoopSecret {
        guard let account = item[kSecAttrAccount as String] as? String,
              account.isEmpty == false,
              let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8),
              value.isEmpty == false
        else {
            throw KeychainCredentialStoreError.invalidSecret
        }
        return WhoopSecret(account: account, value: value)
    }

    private static func validateSingleAccount(service: String, account: String) throws {
        let secrets = try readAll(service: service)
        guard secrets.count == 1, secrets[0].account == account else {
            throw KeychainCredentialStoreError.invalidSecret
        }
    }

    private static func updateExact(service: String, account: String, data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemUpdate(
            exactQuery(service: service, account: account) as CFDictionary,
            attributes as CFDictionary
        )
    }

    private static func exactQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func deleteExact(service: String, account: String) {
        _ = SecItemDelete(exactQuery(service: service, account: account) as CFDictionary)
    }

    private static func addOrRecoverDuplicate(
        service: String,
        account: String,
        data: Data
    ) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess {
            do {
                try validateSingleAccount(service: service, account: account)
            } catch {
                deleteExact(service: service, account: account)
                throw error
            }
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainCredentialStoreError.unexpectedStatus(addStatus)
        }

        let racedItems = try readAll(service: service)
        guard racedItems.count == 1,
              racedItems[0].account == account
        else {
            throw KeychainCredentialStoreError.invalidSecret
        }
        let updateStatus = updateExact(service: service, account: account, data: data)
        guard updateStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
        }
        try validateSingleAccount(service: service, account: account)
    }
}
