import Foundation
import LHCore
import LHStore
import Testing
@testable import LearnHarness

// The graph window's model in the sandboxed host (docs/native-macos-m7.md):
// the snapshot load (stored or seeded positions), search visibility, a
// drag's commit through commitPositions, deletion (one transaction), and
// New Session from Selection… seeding the draft and the Graph context card.

@MainActor
@Suite(.serialized) struct GraphWindowTests {
	private func appWithGraph() throws -> AppModel {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhgraph-\(UUID().uuidString)", directoryHint: .isDirectory)
		let app = AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
		let chat = try ChatRepository(app.database).createChat(title: "Joins")
		let g = GraphRepository(app.database)
		for (id, name) in [("n_a", "Inner join"), ("n_b", "Outer join"), ("n_c", "Null")] {
			try g.appendNode(GraphNode(id: id, name: name, statement: "\(name) statement", aliases: [], createdAt: "2026-10-24T00:00:00.000Z",
				provenance: [ProvenancePoint(chatId: chat.id, messageId: "m_\(id)")]))
		}
		try g.appendChain(GraphChain(id: "arg_ab", premises: ["n_a"], conclusion: "n_b", provenance: [ProvenancePoint(chatId: chat.id, messageId: "")], createdAt: ""))
		return app
	}

	@Test func loadsSeedsAndFilters() throws {
		let model = GraphWindowModel(app: try appWithGraph())
		model.reload()
		#expect(Set(model.ids) == ["n_a", "n_b", "n_c"])
		#expect(model.positions.count == 3 && model.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
		#expect(model.sessions(of: "n_a").map(\.title) == ["Joins"])
		model.query = "outer"
		#expect(model.isVisible("n_b") && !model.isVisible("n_a"))
		model.query = "zzz"
		#expect(model.noMatches)
	}

	@Test func aDragCommitsThroughCommitPositions() async throws {
		let app = try appWithGraph()
		let model = GraphWindowModel(app: app)
		let observe = Task { await model.observe() }
		defer { observe.cancel() }
		model.reload()
		let before = try #require(model.position("n_a"))
		model.drag("n_a", to: SIMD2(500, 500))
		model.endDrag("n_a")
		// The anneal runs, settles, and 250 ms later commits every position.
		let deadline = ContinuousClock.now + .seconds(10)
		var stored: [String: Position] = [:]
		while ContinuousClock.now < deadline {
			stored = GraphRepository(app.database).readPositions()
			if stored.count == 3 { break }
			try await Task.sleep(for: .milliseconds(50))
		}
		#expect(Set(stored.keys) == ["n_a", "n_b", "n_c"])
		let after = try #require(stored["n_a"])
		#expect(after.x != before.x || after.y != before.y, "the drag moved the node and the commit stored it")
		#expect(model.simActive == false)
	}

	@Test func deletesAreOneTransactionAndGatedOnExtraction() async throws {
		let app = try appWithGraph()
		#expect(await app.deleteGraphNodes(["arg_ab"]) == nil)
		#expect(GraphRepository(app.database).readChains().isEmpty, "Delete chain: the argument alone")
		#expect(getGraph(GraphRepository(app.database)).nodes.count == 3)
		#expect(await app.deleteGraphNodes(["n_a", "n_c"]) == nil)
		#expect(getGraph(GraphRepository(app.database)).nodes.map(\.id) == ["n_b"])
	}

	@Test func aSessionFromSelectionStartsWithItsGraphContext() throws {
		let app = try appWithGraph()
		let model = GraphWindowModel(app: app)
		model.reload()
		model.startSession(from: ["n_b", "n_a"])
		#expect(app.drafting && app.draftPicks.map(\.id) == ["n_a", "n_b"])
		app.startSession(prompt: "Teach me joins")
		let chatId = try #require(app.selection)
		let record = try #require(try ChatRepository(app.database).get(chatId))
		guard case .marker(let m) = try #require(record.messages.first).body else { Issue.record("no marker first"); return }
		#expect(m.kind == .graphContext)
		#expect(m.content.contains("Inner join") && m.content.contains("Outer join"))
		#expect(m.details["chains"]?.arrayValue?.count == 1, "the picked chain rides along")
		#expect(app.draftPicks.isEmpty)
	}
}
