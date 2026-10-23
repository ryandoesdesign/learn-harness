import Testing
import LHCore
import LHResources
@testable import LearnHarness

@MainActor
@Suite struct AppHostTests {
	@Test func rootViewBuilds() {
		_ = RootView().body
	}

	@Test func bundledModelCatalogLoadsInTheHost() throws {
		let data = try LHResources.modelsJSON
		let catalog = try JSONValue.parse(data)
		#expect(catalog["models"]?.arrayValue?.count == 5)
	}
}
