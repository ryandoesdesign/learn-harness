import Foundation
import Testing
@testable import LHCore

// Port of tests/graph.test.ts (the pure parts) over in-memory ports. The TS
// suite stacks every case on one shared fs ledger; here each case builds the
// state its assertions depend on.

private let fold = "2026-08-22T00:00:00.000Z"
private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000.123)

private func prop(_ id: String, _ name: String, _ statement: String, _ aliases: [String] = [], messageId: String? = nil) -> ExtractedProposition {
	ExtractedProposition(id: id, name: name, statement: statement, aliases: aliases, messageId: messageId)
}

/// The extractor's findings for the fixture chat: three propositions, one chain.
private func fixtureFindings() -> SessionFindings {
	SessionFindings(
		propositions: [
			prop("p1", "Alpha", "Alpha intuition", ["alpha feel"]),
			prop("p2", "Beta rule", "Beta rule"),
			prop("p3", "Gamma", "Gamma application"),
		],
		chains: [ExtractedChain(premises: ["p1"], conclusion: "p2")])
}

private final class World {
	let graph = MemoryGraphStore()
	let chats = MemoryChatStore()
	let ids = CountingRandom()
	var deps: GraphDeps { GraphDeps(chatStore: chats, graphStore: graph) }

	@discardableResult
	func merge(_ chatId: String, _ findings: SessionFindings, links: [IdentityLink] = [], source: MergeSource? = nil) throws -> EmissionStats {
		try mergeFindings(chatId: chatId, findings: findings, verdicts: AuditVerdicts(links: links), deps: deps,
			source: source ?? MergeSource(foldedAt: chats.getChat(chatId)?.updatedAt ?? fold), now: fixedNow, random: ids.random)
	}

	/// Everything the graph holds for a set of chats.
	func scoped(_ chatIds: [String]) -> DerivedGraph {
		let g = getGraph(graph)
		return DerivedGraph(
			nodes: g.nodes.filter { $0.provenance.contains { chatIds.contains($0.chatId) } },
			chains: g.chains.filter { $0.provenance.contains { chatIds.contains($0.chatId) } })
	}
}

@Suite("the merger (mergeFindings)")
struct GraphMergerTests {
	@Test func createsNodesFromTheVerdictsWithChatLevelProvenance() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		let stats = try w.merge("chat_1", fixtureFindings())
		#expect(stats == EmissionStats(nodes: 3, chains: 1))

		let graph = w.scoped(["chat_1"])
		#expect(graph.nodes.count == 3)
		let idByStatement = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.statement, $0.id) })
		for node in graph.nodes {
			#expect(node.id.wholeMatch(of: /n_[0-9a-f]{12}/) != nil)
			#expect(!node.name.isEmpty, "name is required")
		}
		let alpha = try #require(graph.nodes.first { $0.statement == "Alpha intuition" })
		#expect(alpha.provenance == [ProvenancePoint(chatId: "chat_1", messageId: "")])

		#expect(graph.chains.count == 1)
		let chain = graph.chains[0]
		#expect(chain.id.wholeMatch(of: /arg_[0-9a-f]{12}/) != nil, "store-minted argument id")
		#expect(chain.premises == [idByStatement["Alpha intuition"]!])
		#expect(chain.conclusion == idByStatement["Beta rule"])
		#expect(chain.provenance == [ProvenancePoint(chatId: "chat_1", messageId: "")])
		// The fold stamp: the injected clock, toISOString-shaped.
		#expect(alpha.createdAt == "2026-09-21T14:13:20.123Z")
	}

	@Test func messageIdAnchorsStampCreatesAndLinkAppendsChainsStayChatLevel() throws {
		let w = World()
		w.chats.create("chat_a", title: "Anchor fixture")
		let first = try w.merge("chat_a", SessionFindings(propositions: [prop("p1", "Anchored", "Anchored statement", messageId: "t1")], chains: []))
		#expect(first.nodes == 1)
		let created = try #require(w.scoped(["chat_a"]).nodes.first { $0.statement == "Anchored statement" })
		#expect(created.provenance == [ProvenancePoint(chatId: "chat_a", messageId: "t1")], "the created node anchors to its passage")

		let second = try w.merge("chat_a", SessionFindings(
			propositions: [
				prop("q1", "Anchored again", "Anchored statement, rephrased", messageId: "t2"),
				prop("q2", "Follows", "Follows the anchored claim", messageId: "t2"),
			],
			chains: [ExtractedChain(premises: ["q1"], conclusion: "q2")]),
			links: [IdentityLink(id: "q1", linkTo: created.id)])
		#expect(second.nodes == 1, "q1 linked (no create), q2 created")
		let linkLine = try #require(w.graph.readNodes().filter { $0.id == created.id }
			.first { $0.provenance.contains(ProvenancePoint(chatId: "chat_a", messageId: "t2")) },
			"the link-append line carries the re-encounter's passage id")
		#expect(linkLine.name == "Anchored again")
		let chains = w.graph.readChains().filter { $0.provenance.contains { $0.chatId == "chat_a" } }
		#expect(chains.count == 1)
		#expect(chains[0].provenance == [ProvenancePoint(chatId: "chat_a", messageId: "")], "chains stay chat-level — never anchored")
	}

	@Test func mergesIndependentlyPerCall() throws {
		let w = World()
		w.chats.create("chat_rep", title: "Independence fixture")
		let findings = SessionFindings(
			propositions: [prop("p1", "Rep one", "Independence one statement"), prop("p2", "Rep two", "Independence two statement")],
			chains: [ExtractedChain(premises: ["p1"], conclusion: "p2")])
		#expect(try w.merge("chat_rep", findings) == EmissionStats(nodes: 2, chains: 1))
		#expect(try w.merge("chat_rep", findings) == EmissionStats(nodes: 2, chains: 1), "nothing remembered — everything re-creates")
		let graph = w.scoped(["chat_rep"])
		#expect(graph.nodes.count == 4)
		#expect(graph.chains.count == 2)
		#expect(w.graph.checkpoints.filter { $0.chatId == "chat_rep" }.count == 2)
	}

	@Test func isIdempotentWithinOneSubmit() throws {
		let w = World()
		w.chats.create("chat_dup", title: "Duplicate-id fixture")
		let stats = try w.merge("chat_dup", SessionFindings(propositions: [prop("p1", "Dup", "Dup statement"), prop("p1", "Dup", "Dup statement")], chains: []))
		#expect(stats == EmissionStats(nodes: 1, chains: 0))
	}

	@Test func appliesALinkToVerdict() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		try w.merge("chat_1", fixtureFindings())
		let alphaId = try #require(w.scoped(["chat_1"]).nodes.first { $0.statement == "Alpha intuition" }).id
		w.chats.create("chat_2", title: "Graph fixture 2")
		let stats = try w.merge("chat_2", SessionFindings(propositions: [prop("q1", "Alpha", "Alpha feel", ["alpha intuition"])], chains: []),
			links: [IdentityLink(id: "q1", linkTo: alphaId)])
		#expect(stats == EmissionStats(nodes: 0, chains: 0))
		#expect(w.scoped(["chat_1", "chat_2"]).nodes.count == 3, "no duplicate node")
		let alpha = try #require(getGraph(w.graph).nodes.first { $0.id == alphaId })
		#expect(alpha.aliases.contains("Alpha feel"))
		#expect(alpha.aliases.contains("alpha intuition"))
		#expect(alpha.provenance.contains { $0.chatId == "chat_2" }, "provenance unions")
	}

	@Test func aRewriteVerdictRevisesTheNodeAndKeepsTheOldStatement() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		try w.merge("chat_1", fixtureFindings())
		let alphaId = try #require(w.scoped(["chat_1"]).nodes.first { $0.statement == "Alpha intuition" }).id
		w.chats.create("chat_2", title: "Graph fixture 2")
		try w.merge("chat_2", SessionFindings(propositions: [prop("q1", "Alpha principle", "Alpha, stated precisely")], chains: []),
			links: [IdentityLink(id: "q1", linkTo: alphaId, rewrite: true)])
		#expect(w.graph.nodes.last?.revises == true)
		var alpha = try #require(getGraph(w.graph).nodes.first { $0.id == alphaId })
		#expect(alpha.name == "Alpha principle" && alpha.statement == "Alpha, stated precisely")
		#expect(alpha.aliases.contains("Alpha intuition") && alpha.aliases.contains("alpha feel"))
		#expect(!alpha.aliases.contains("Alpha, stated precisely"))
		#expect(alpha.createdAt == w.graph.nodes.first { $0.id == alphaId }?.createdAt, "the identity stands")
		#expect(getGraph(w.graph).chains.count == 1, "chains are untouched")

		w.chats.create("chat_3", title: "Graph fixture 3")
		try w.merge("chat_3", SessionFindings(propositions: [prop("r1", "Alpha law", "Alpha, stated best")], chains: []),
			links: [IdentityLink(id: "r1", linkTo: alphaId, rewrite: true)])
		alpha = try #require(getGraph(w.graph).nodes.first { $0.id == alphaId })
		#expect(alpha.name == "Alpha law" && alpha.statement == "Alpha, stated best", "the last revision wins")
		#expect(alpha.aliases.contains("Alpha, stated precisely") && alpha.aliases.contains("Alpha intuition"))
	}

	@Test func aPlainLinkLineCarriesNoRevisesField() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		try w.merge("chat_1", fixtureFindings())
		let alphaId = try #require(w.scoped(["chat_1"]).nodes.first { $0.statement == "Alpha intuition" }).id
		try w.merge("chat_1", SessionFindings(propositions: [prop("q1", "Alpha", "Alpha feel")], chains: []), links: [IdentityLink(id: "q1", linkTo: alphaId)])
		let line = try #require(w.graph.nodes.last)
		#expect(line.revises == nil)
		#expect(try JSONCodec.encode(line)["revises"] == nil, "the ledger JSON is unchanged")
	}

	@Test func resolvesImportedNotesIdsToTheirFilePathsInTheSnapshot() throws {
		let w = World()
		w.graph.upsertSource(NotesSource(id: "src_snapfixture", filePath: "/vault/learn vim.md", importedAt: "2026-09-13T00:00:00.000Z"))
		try w.merge("src_snapfixture", SessionFindings(propositions: [prop("p1", "Vim registers", "Vim registers map single keys to editing commands.")], chains: []),
			source: MergeSource(foldedAt: "2026-09-13T00:00:00.000Z"))
		let snap = graphSnapshot(w.deps)
		let node = try #require(snap.nodes.first { $0.statement == "Vim registers map single keys to editing commands." })
		#expect(snap.fileSources["src_snapfixture"] == "/vault/learn vim.md")
		#expect(snap.nodeSessions[node.id] == ["src_snapfixture"])
		#expect(snap.sessions["src_snapfixture"] == nil, "a notes source is never a chat session")
	}

	@Test func derivesBirthSessionClustersLabeledWithTheSessionsName() throws {
		let w = World()
		let tri = ["Alpha.", "Beta.", "Gamma cluster."]
		w.graph.upsertSource(NotesSource(id: "src_clusterfixture", filePath: "/vault/cluster notes.md", importedAt: "2026-09-13T00:00:00.000Z"))
		let merge = try w.merge("src_clusterfixture", SessionFindings(
			propositions: tri.enumerated().map { prop("p\($0.offset + 1)", "Cluster node \($0.offset + 1)", $0.element) },
			chains: [ExtractedChain(premises: ["p1"], conclusion: "p2"), ExtractedChain(premises: ["p2"], conclusion: "p3")]),
			source: MergeSource(foldedAt: "2026-09-13T00:00:00.000Z"))
		#expect(merge.nodes == 3)
		let snap = graphSnapshot(w.deps)
		#expect(snap.clusters.allSatisfy { $0.members.count >= 3 })
		let triIds = tri.map { s in snap.nodes.first { $0.statement == s }!.id }
		let mine = try #require(snap.clusters.first { c in c.members.count == 3 && triIds.allSatisfy(c.members.contains) }, "the trio is one cluster")
		#expect(mine.id == "src_clusterfixture")
		#expect(mine.label == "/vault/cluster notes.md")

		let stored = w.graph.readChains()
		let live = Set(snap.propositions.map(\.id))
		let impChains = stored.filter { $0.premises.count >= 2 && live.contains($0.conclusion) && $0.premises.allSatisfy(live.contains) }
		#expect(snap.propositions.allSatisfy { !$0.id.hasPrefix("arg_") })
		#expect(snap.nodes.count == snap.propositions.count + impChains.count)
		let imp = snap.nodes.filter { $0.id.hasPrefix("arg_") }
		#expect(imp.count == impChains.count && imp.allSatisfy { n in snap.propositions.allSatisfy { $0.id != n.id } })
		#expect(imp.isEmpty, "this fixture's chains are single-premise — all collapsed to direct arrows")
	}

	@Test func derivesTheSessionsIndexInGraphSnapshot() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		try w.merge("chat_1", fixtureFindings())
		let alphaId = try #require(w.scoped(["chat_1"]).nodes.first { $0.statement == "Alpha intuition" }).id
		w.chats.create("chat_2", title: "Graph fixture 2")
		try w.merge("chat_2", SessionFindings(propositions: [prop("q1", "Alpha", "Alpha feel", ["alpha intuition"])], chains: []),
			links: [IdentityLink(id: "q1", linkTo: alphaId)])

		let snap = graphSnapshot(w.deps)
		let idByStatement = Dictionary(snap.nodes.map { ($0.statement, $0.id) }, uniquingKeysWith: { a, _ in a })
		#expect(snap.sessions["chat_1"] == "Graph fixture")
		#expect(snap.sessions["chat_2"] == "Graph fixture 2")
		#expect((snap.nodeSessions[idByStatement["Alpha intuition"]!] ?? []).sorted() == ["chat_1", "chat_2"])
		#expect(snap.nodeSessions[idByStatement["Gamma application"]!] == ["chat_1"])
	}

	@Test func neverStringMatchesWithoutAVerdict() throws {
		let w = World()
		w.chats.create("chat_1", title: "Graph fixture")
		try w.merge("chat_1", fixtureFindings())
		w.chats.create("chat_3", title: "Graph fixture 3")
		let stats = try w.merge("chat_3", SessionFindings(propositions: [prop("r1", "Alpha", "Alpha intuition")], chains: []))
		#expect(stats.nodes == 1, "created — the merger does not match strings")
		#expect(getGraph(w.graph).nodes.filter { $0.statement == "Alpha intuition" }.count == 2)
	}

	@Test func mergesTheNotesFrontDoor() throws {
		let w = World()
		let stats = try w.merge("src_notesfixture", SessionFindings(propositions: [prop("p1", "Vim normal mode", "Vim starts in Normal mode, where keys are commands.")], chains: []),
			source: MergeSource(foldedAt: "2026-09-13T00:00:00.000Z"))
		#expect(stats == EmissionStats(nodes: 1, chains: 0))
		let node = try #require(getGraph(w.graph).nodes.first { $0.statement.hasPrefix("Vim starts") })
		#expect(node.provenance == [ProvenancePoint(chatId: "src_notesfixture", messageId: "")])
		#expect(w.graph.checkpoints.first { $0.chatId == "src_notesfixture" }?.foldedAt == "2026-09-13T00:00:00.000Z")
	}

	// Swift-side additions: the injectable seams and the paths the TS suite
	// exercises only through the extraction pipeline.

	@Test func idMintingIsInjectable() throws {
		let w = World()
		try w.merge("c", fixtureFindings())
		#expect(w.graph.nodes.map(\.id) == ["n_000000000001", "n_000000000002", "n_000000000003"])
		#expect(w.graph.chains.map(\.id) == ["arg_000000000004"])
		let fixed = MemoryGraphStore()
		try mergeFindings(chatId: "c", findings: SessionFindings(propositions: [prop("p1", "A", "A")], chains: []), verdicts: AuditVerdicts(links: []),
			deps: GraphDeps(chatStore: MemoryChatStore(), graphStore: fixed), source: MergeSource(foldedAt: fold),
			random: GraphRandom { _ in [0xde, 0xad, 0xbe, 0xef, 0x00, 0x01] })
		#expect(fixed.nodes.map(\.id) == ["n_deadbeef0001"], "randomBytes(6).toString(\"hex\")")
	}

	@Test func coverageEntriesReplaceTheCheckpointOnTheChatPath() throws {
		let w = World()
		let entries = [CoverageEntry(chatId: "c", fp: "f1", tokens: 3, foldedAt: fold), CoverageEntry(chatId: "c", fp: "f2", tokens: 4, foldedAt: fold)]
		try w.merge("c", fixtureFindings(), source: MergeSource(foldedAt: fold, coverage: entries))
		#expect(w.graph.coverage == entries)
		#expect(w.graph.checkpoints.isEmpty)
	}

	@Test func chainsResolveVerbatimIdsDedupePremisesAndSkipUnresolvable() throws {
		let w = World()
		w.graph.nodes = [GraphNode(id: "n_old", name: "Old", statement: "Old", aliases: [], createdAt: fold, provenance: [])]
		let stats = try w.merge("c", SessionFindings(
			propositions: [prop("p1", "A", "A"), prop("p2", "B", "B")],
			chains: [
				ExtractedChain(premises: ["p1", "p1", "n_old", "ghost", "p2"], conclusion: "p2"), // dup + conclusion + unknown dropped
				ExtractedChain(premises: ["p1"], conclusion: "ghost"), // unresolvable conclusion
				ExtractedChain(premises: ["p2"], conclusion: "p2"), // nothing left
				ExtractedChain(premises: ["n_old", "p1"], conclusion: "p2"), // same key, this chat — skipped
			]))
		#expect(stats == EmissionStats(nodes: 2, chains: 1))
		let p1 = w.graph.nodes[1].id, p2 = w.graph.nodes[2].id
		#expect(w.graph.chains.map(\.premises) == [[p1, "n_old"]])
		#expect(w.graph.chains[0].conclusion == p2)
	}

	@Test func anotherChatReassertingAChainReusesItsIdAndSimplificationRewrites() throws {
		let w = World()
		w.graph.nodes = ["a", "b", "x"].map { GraphNode(id: $0, name: $0, statement: $0, aliases: [], createdAt: fold, provenance: [ProvenancePoint(chatId: "c1", messageId: "")]) }
		w.graph.chains = [GraphChain(id: "arg_ab", premises: ["a", "b"], conclusion: "x", provenance: [ProvenancePoint(chatId: "c1", messageId: "")], createdAt: fold)]
		let stats = try w.merge("c2", SessionFindings(propositions: [], chains: [
			ExtractedChain(premises: ["b", "a"], conclusion: "x"), // the known argument, re-stated
			ExtractedChain(premises: ["a"], conclusion: "x"), // leaner — makes [a,b]⟹x redundant
		]))
		#expect(stats == EmissionStats(nodes: 0, chains: 2, droppedChains: 2))
		#expect(w.graph.chains.map(\.premises) == [["a"]], "the dropped key takes every provenance line with it")
	}
}

@Suite("getGraph — raw lines merge on read")
struct GraphGetGraphTests {
	@Test func repeatedIdsAreEachTheirOwnLineGetGraphMerges() throws {
		let line = { (msgId: String) in
			GraphNode(id: "n_linktest", name: "Link test", statement: "Phrasing \(msgId)", aliases: [], createdAt: fold,
				provenance: [ProvenancePoint(chatId: "chat_c", messageId: msgId)])
		}
		let store = MemoryGraphStore(nodes: [line("m1"), line("m2")])
		#expect(store.readNodes().filter { $0.id == "n_linktest" }.count == 2)
		let merged = try #require(getGraph(store).nodes.first { $0.id == "n_linktest" })
		#expect(merged.statement == "Phrasing m1", "the FIRST line defines the node")
		#expect(merged.aliases.contains("Phrasing m2"))
		#expect(merged.provenance.map(\.messageId) == ["m1", "m2"])
	}
}

@Suite("deriveView (the argument's geometry)")
struct GraphDeriveViewTests {
	private func prop(_ id: String) -> GraphNode {
		GraphNode(id: id, name: id.uppercased(), statement: "\(id) statement", aliases: [], createdAt: "2026-09-30T00:00:00.000Z", provenance: [])
	}

	private func chain(_ id: String, _ premises: [String], _ conclusion: String) -> GraphChain {
		GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [], createdAt: "2026-09-30T00:00:00.000Z")
	}

	private func sortedEdges(_ edges: [GraphEdge]) -> [GraphEdge] {
		edges.sorted { $0.from != $1.from ? $0.from < $1.from : $0.to < $1.to }
	}

	@Test func aSinglePremiseChainCollapsesToOneDirectArrow() {
		let view = deriveView(DerivedGraph(nodes: [prop("a"), prop("b")], chains: [chain("arg_ab", ["a"], "b")]))
		#expect(view.nodes.map(\.id) == ["a", "b"])
		#expect(view.edges == [GraphEdge(from: "a", to: "b")])
	}

	@Test func aMultiPremiseChainKeepsTheImpNodeAndFan() throws {
		let view = deriveView(DerivedGraph(nodes: [prop("a"), prop("b"), prop("c")], chains: [chain("arg_ab", ["a", "b"], "c")]))
		#expect(view.nodes.map(\.id).sorted() == ["a", "arg_ab", "b", "c"])
		#expect(sortedEdges(view.edges) == [GraphEdge(from: "a", to: "arg_ab"), GraphEdge(from: "arg_ab", to: "c"), GraphEdge(from: "b", to: "arg_ab")])
		let imp = try #require(view.nodes.first { $0.id == "arg_ab" })
		#expect(imp.name == "\u{27f9}")
		#expect(imp.statement == "A, B → C")
	}

	@Test func twoChainsSharingAConclusionStayDistinct() {
		let view = deriveView(DerivedGraph(
			nodes: [prop("a"), prop("b"), prop("c"), prop("d"), prop("e")],
			chains: [chain("arg_e1", ["a", "b"], "e"), chain("arg_e2", ["c", "d"], "e")]))
		#expect(view.nodes.map(\.id).sorted() == ["a", "arg_e1", "arg_e2", "b", "c", "d", "e"])
		#expect(view.edges.contains(GraphEdge(from: "arg_e1", to: "e")))
		#expect(view.edges.contains(GraphEdge(from: "arg_e2", to: "e")))
	}

	@Test func danglingChainsDrop() {
		let view = deriveView(DerivedGraph(nodes: [prop("a")], chains: [chain("arg_ghost", ["a"], "gone"), chain("arg_gone", ["ghost"], "a")]))
		#expect(view.nodes.map(\.id) == ["a"])
		#expect(view.edges.isEmpty)
	}

	@Test func logicalEdgesContractEveryChainDeduped() {
		let view = deriveView(DerivedGraph(nodes: [prop("a"), prop("b"), prop("c")], chains: [chain("arg_ab", ["a", "b"], "c"), chain("arg_ac", ["a"], "c")]))
		#expect(sortedEdges(view.logicalEdges) == [GraphEdge(from: "a", to: "c"), GraphEdge(from: "b", to: "c")])
		#expect(view.logicalEdges.allSatisfy { !$0.from.hasPrefix("arg_") && !$0.to.hasPrefix("arg_") })
	}

	@Test func impLinksOnePerMultiPremiseChain() {
		let view = deriveView(DerivedGraph(nodes: [prop("a"), prop("b"), prop("c")], chains: [chain("arg_ab", ["a", "b"], "c"), chain("arg_ac", ["a"], "c")]))
		#expect(view.impLinks == [ImpLink(id: "arg_ab", premises: ["a", "b"], conclusion: "c")])
	}
}
