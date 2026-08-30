import Foundation
import Security

protocol SecureValueStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ value: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum KeychainError: LocalizedError, Equatable, Sendable {
    case operationFailed(status: OSStatus, name: String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(_, let name):
            return "Keychain operation failed: \(name)."
        }
    }
}

struct KeychainSecureValueStore: SecureValueStore {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func write(_ value: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = value
        #if os(iOS)
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

private extension KeychainError {
    init(status: OSStatus) {
        let name = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        self = .operationFailed(status: status, name: name)
    }
}
