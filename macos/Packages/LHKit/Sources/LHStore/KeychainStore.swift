import Foundation
import Security

/// The Anthropic API key's home (replaces auth.json). The only secret the
/// app keeps; never logged, never written to the database.
public protocol KeychainStore: Sendable {
	func anthropicKey() throws -> String?
	func setAnthropicKey(_ key: String) throws
	func deleteAnthropicKey() throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
	public let status: OSStatus
	public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")" }
}

/// SecItem generic password: service com.ryandoesdesign.LearnHarness,
/// account anthropic-api-key.
public struct SystemKeychain: KeychainStore {
	public let service: String
	public let account: String

	public init(service: String = "com.ryandoesdesign.LearnHarness", account: String = "anthropic-api-key") {
		self.service = service
		self.account = account
	}

	private var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
	}

	public func anthropicKey() throws -> String? {
		var q = query
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		let status = SecItemCopyMatching(q as CFDictionary, &out)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
		return String(decoding: data, as: UTF8.self)
	}

	public func setAnthropicKey(_ key: String) throws {
		let data = Data(key.utf8)
		let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecItemNotFound {
			var add = query
			add[kSecValueData as String] = data
			add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
			let s = SecItemAdd(add as CFDictionary, nil)
			guard s == errSecSuccess else { throw KeychainError(status: s) }
			return
		}
		guard status == errSecSuccess else { throw KeychainError(status: status) }
	}

	public func deleteAnthropicKey() throws {
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
	}
}

/// Test double.
public final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
	private let lock = NSLock()
	private var key: String?
	public init(key: String? = nil) { self.key = key }
	public func anthropicKey() throws -> String? { lock.withLock { key } }
	public func setAnthropicKey(_ key: String) throws { lock.withLock { self.key = key } }
	public func deleteAnthropicKey() throws { lock.withLock { key = nil } }
}
