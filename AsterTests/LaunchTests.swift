import Foundation
import Testing
import LHCore
import LHResources
import LHStore
@testable import Aster

@MainActor
@Suite struct AppHostTests {
	private func tempModel() -> AppModel {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhapp-\(UUID().uuidString)", directoryHint: .isDirectory)
		return AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
	}

	@Test func rootViewBuilds() {
		_ = RootView(model: tempModel()).body
	}

	@Test func bundledModelCatalogLoadsInTheHost() throws {
		let catalog = try JSONValue.parse(try LHResources.modelsJSON)
		#expect(catalog["models"]?.arrayValue?.count == 5)
	}

	@Test func databaseOpensInsideTheContainer() {
		let model = tempModel()
		#expect(model.startupError == nil)
	}

	/// The real Keychain, under a throwaway account (never the app's key).
	@Test func systemKeychainRoundTrip() throws {
		let keychain = SystemKeychain(account: "test-\(UUID().uuidString)")
		#expect(try keychain.anthropicKey() == nil)
		try keychain.setAnthropicKey("sk-ant-test-1")
		try keychain.setAnthropicKey("sk-ant-test-2")
		#expect(try keychain.anthropicKey() == "sk-ant-test-2")
		try keychain.deleteAnthropicKey()
		#expect(try keychain.anthropicKey() == nil)
	}
}
