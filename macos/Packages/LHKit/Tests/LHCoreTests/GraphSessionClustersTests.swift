import Foundation
import Testing
@testable import LHCore

// Port of tests/session-clusters.test.ts + tests/clusters.test.ts (the
// MIN_CLUSTER_SIZE pin) — birth-session clustering and the prober's data
// seam, all over in-memory fakes.

private func pt(_ chatId: String, _ messageId: String = "m1") -> ProvenancePoint { ProvenancePoint(chatId: chatId, messageId: messageId) }

private func node(_ id: String, _ name: String, _ provenance: [ProvenancePoint]) -> GraphNode {
	GraphNode(id: id, name: name, statement: "\(name) statement", aliases: [], createdAt: "2026-09-23T00:00:00.000Z", provenance: provenance)
}

private struct ChatRow {
	var id: String, title: String, createdAt: String, updatedAt: String
}

private func fakeStores(_ nodes: [GraphNode], chats: [ChatRow] = [], sources: [NotesSource] = [], chains: [GraphChain] = []) -> GraphDeps {
	let store = MemoryGraphStore(nodes: nodes, chains: chains, sources: sources)
	let chatStore = MemoryChatStore()
	for c in chats { chatStore.create(c.id, title: c.title, createdAt: c.createdAt, updatedAt: c.updatedAt) }
	return GraphDeps(chatStore: chatStore, graphStore: store)
}

private func source(_ id: String, _ path: String, _ at: String) -> NotesSource { NotesSource(id: id, filePath: path, importedAt: at, extractions: []) }

@Suite("MIN_CLUSTER_SIZE")
struct GraphClustersTests {
	@Test func isThree() { #expect(MIN_CLUSTER_SIZE == 3) }
}

@Suite("birthSessionPartition")
struct GraphBirthPartitionTests {
	@Test func groupsByFirstProvenancePointDedupesSorts() {
		let nodes = [
			node("a", "A", [pt("chat1")]),
			node("b", "B", [pt("chat1")]),
			node("c", "C", [pt("chat2")]),
			node("a", "A-linked", [pt("chat2")]),
			node("d", "D", [pt("chat1")]),
		]
		#expect(birthSessionPartition(nodes) == [BirthSessionCluster(id: "chat1", members: ["a", "b", "d"]), BirthSessionCluster(id: "chat2", members: ["c"])])
	}

	@Test func aSharedNodeBelongsToItsBirthSessionOnly() {
		let nodes = [node("born-1", "X", [pt("chat1")]), node("born-1", "X-linked", [pt("chat2")]), node("born-2", "Y", [pt("chat2")])]
		#expect(birthSessionPartition(nodes) == [BirthSessionCluster(id: "chat1", members: ["born-1"]), BirthSessionCluster(id: "chat2", members: ["born-2"])])
	}

	@Test func deletionReattributionAndNakedNodes() {
		let reattributed = node("survivor", "S", [pt("chat2"), pt("chat3")])
		#expect(birthSessionOf(reattributed) == "chat2")
		let naked = node("naked", "N", [])
		#expect(birthSessionOf(naked) == nil)
		#expect(birthSessionPartition([reattributed, naked]) == [BirthSessionCluster(id: "chat2", members: ["survivor"])])
	}
}

@Suite("notes files as birth sessions")
struct GraphNotesBirthTests {
	@Test func sessionIndexListsImportedFilesAsKindFile() {
		let nodes = [node("a", "Alpha", [pt("src_abc")]), node("b", "Beta", [pt("src_abc")]), node("c", "Gamma", [pt("src_abc")])]
		let deps = fakeStores(nodes, sources: [source("src_abc", "/vault/learn vim.md", "2026-09-22T00:00:00.000Z")])
		#expect(graphSessionIndex(deps) == [GraphSessionEntry(id: "src_abc", name: "/vault/learn vim.md", kind: .file,
			createdAt: "2026-09-22T00:00:00.000Z", updatedAt: "2026-09-22T00:00:00.000Z", propositions: 3)])
	}

	@Test func sessionPropositionsListTheFilesBirths() {
		let deps = fakeStores([node("a", "Alpha", [pt("src_abc")]), node("b", "Beta", [pt("src_abc")])],
			sources: [source("src_abc", "/vault/learn vim.md", "2026-09-22T00:00:00.000Z")])
		#expect(graphSessionPropositions(deps, sessionId: "src_abc") == [GraphSessionProposition(nodeId: "a", name: "Alpha"), GraphSessionProposition(nodeId: "b", name: "Beta")])
	}
}

@Suite("graphSnapshot birth-session clusters")
struct GraphSnapshotClusterTests {
	@Test func labelsClustersWithSessionNamesKeepsTheHullRule() {
		let nodes = [
			node("a", "A", [pt("chat1")]), node("b", "B", [pt("chat1")]), node("c", "C", [pt("chat1")]),
			node("d", "D", [pt("src_notes")]), node("e", "E", [pt("src_notes")]), node("f", "F", [pt("src_notes")]),
		]
		let deps = fakeStores(nodes,
			chats: [ChatRow(id: "chat1", title: "Learning session", createdAt: "2026-09-20T00:00:00.000Z", updatedAt: "2026-09-21T00:00:00.000Z")],
			sources: [source("src_notes", "/vault/notes.md", "2026-09-22T00:00:00.000Z")])
		let snap = graphSnapshot(deps)
		#expect(snap.clusters.count == 2)
		let byLabel = Dictionary(uniqueKeysWithValues: snap.clusters.map { ($0.label, $0) })
		#expect(byLabel["Learning session"] == Cluster(id: "chat1", label: "Learning session", members: ["a", "b", "c"]))
		#expect(byLabel["/vault/notes.md"] == Cluster(id: "src_notes", label: "/vault/notes.md", members: ["d", "e", "f"]))
		let two = fakeStores([node("x", "X", [pt("chat1")]), node("y", "Y", [pt("chat1")])], chats: [ChatRow(id: "chat1", title: "tiny", createdAt: "", updatedAt: "")])
		#expect(graphSnapshot(two).clusters.isEmpty)
	}

	@Test func aGoneBirthSessionRendersUnlabeled() {
		let snap = graphSnapshot(fakeStores([node("a", "A", [pt("gone")]), node("b", "B", [pt("gone")]), node("c", "C", [pt("gone")])]))
		#expect(snap.clusters.count == 1)
		#expect(snap.clusters[0].label == nil)
		#expect(snap.clusters[0].id == "gone")
	}
}

@Suite("graphSessionIndex (the prober's session list)")
struct GraphSessionIndexTests {
	@Test func birthCountsKindsRecencyOrderAndHonestFallbacks() {
		let nodes = [
			node("a", "A", [pt("chat1")]), node("b", "B", [pt("chat1")]), node("c", "C", [pt("chat1")]),
			node("d", "D", [pt("src_notes")]),
			node("e", "E", [pt("gone")]),
		]
		let deps = fakeStores(nodes,
			chats: [ChatRow(id: "chat1", title: "Older session", createdAt: "2026-09-20T00:00:00.000Z", updatedAt: "2026-09-21T00:00:00.000Z")],
			sources: [source("src_notes", "/vault/notes.md", "2026-09-22T00:00:00.000Z")])
		#expect(graphSessionIndex(deps) == [
			GraphSessionEntry(id: "src_notes", name: "/vault/notes.md", kind: .file, createdAt: "2026-09-22T00:00:00.000Z", updatedAt: "2026-09-22T00:00:00.000Z", propositions: 1),
			GraphSessionEntry(id: "chat1", name: "Older session", kind: .chat, createdAt: "2026-09-20T00:00:00.000Z", updatedAt: "2026-09-21T00:00:00.000Z", propositions: 3),
			GraphSessionEntry(id: "gone", name: "gone", kind: .file, createdAt: nil, updatedAt: nil, propositions: 1),
		])
	}
}

@Suite("graphSessionPropositions (the per-session view)")
struct GraphSessionPropositionsTests {
	@Test func birthPropositionsOnly() {
		let deps = fakeStores([node("a", "Alpha", [pt("chat1")]), node("b", "Beta", [pt("chat1")]), node("c", "Gamma", [pt("chat2")])])
		#expect(graphSessionPropositions(deps, sessionId: "chat1") == [GraphSessionProposition(nodeId: "a", name: "Alpha"), GraphSessionProposition(nodeId: "b", name: "Beta")])
	}
}

@Suite("impClusterKey (majority among PREMISES' births)")
struct GraphImpClusterKeyTests {
	private func chainOf(_ premises: [String], _ provenance: [ProvenancePoint] = []) -> GraphChain {
		GraphChain(id: "arg_t", premises: premises, conclusion: "c", provenance: provenance, createdAt: "2026-09-30T00:00:00.000Z")
	}

	@Test func unanimous() { #expect(impClusterKey(chainOf(["p1", "p2", "p3"])) { _ in "chatA" } == "chatA") }

	@Test func crossSessionMajorityWins() {
		let births = ["p1": "chatA", "p2": "chatA", "p3": "chatB"]
		#expect(impClusterKey(chainOf(["p1", "p2", "p3"])) { births[$0] } == "chatA")
	}

	@Test func tieGoesToTheChainsOwnBirth() {
		let births = ["p1": "chatA", "p2": "chatB", "c": "chatC"]
		#expect(impClusterKey(chainOf(["p1", "p2"], [pt("chatT")])) { births[$0] } == "chatT")
	}

	@Test func noBirthInfoIsNil() { #expect(impClusterKey(chainOf(["p1", "p2"])) { _ in nil } == nil) }

	@Test func tieWithoutOwnBirthFallsToTheFirstWinnerAlphabetically() {
		let births = ["p1": "chatB", "p2": "chatA"]
		#expect(impClusterKey(chainOf(["p1", "p2"])) { births[$0] } == "chatA")
	}
}

@Suite("attachImpToCommunities (the shared seam for pull + hulls)")
struct GraphAttachImpTests {
	private func chain(_ id: String, _ premises: [String], _ conclusion: String) -> GraphChain {
		GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [pt("chatA")], createdAt: "2026-09-30T00:00:00.000Z")
	}

	@Test func aMultiPremiseLiveChainJoinsItsHomeCommunity() {
		let props = [node("p1", "P1", [pt("chatA")]), node("p2", "P2", [pt("chatA")]), node("p3", "P3", [pt("chatA")])]
		var communities = birthSessionPartition(props)
		attachImpToCommunities(&communities, propositions: props, chains: [chain("arg_t", ["p1", "p2"], "p3")])
		#expect(communities[0].members == ["arg_t", "p1", "p2", "p3"])
	}

	@Test func singlePremiseChainsAttachNothing() {
		let props = [node("p1", "P1", [pt("chatA")]), node("p2", "P2", [pt("chatA")])]
		var communities = birthSessionPartition(props)
		attachImpToCommunities(&communities, propositions: props, chains: [chain("arg_t", ["p1"], "p2")])
		#expect(communities[0].members == ["p1", "p2"])
	}

	@Test func danglingChainsMintNothingAndAbsentHomesStayUnattached() {
		let props = [node("p1", "P1", [pt("chatA")]), node("p1b", "P1b", [pt("chatA")]), node("p1c", "P1c", [pt("chatA")])]
		var elsewhere = [BirthSessionCluster(id: "chatB", members: ["q1"])]
		attachImpToCommunities(&elsewhere, propositions: props, chains: [
			chain("arg_gone", ["p1", "p1b"], "ghost"),
			chain("arg_home", ["p1", "p1b"], "p1c"),
		])
		#expect(elsewhere[0].members == ["q1"])
	}
}

@Suite("graphSnapshot imp-node cluster assignment")
struct GraphSnapshotImpTests {
	private let chats = [ChatRow(id: "chatA", title: "Session A", createdAt: "2026-09-30T00:00:00.000Z", updatedAt: "2026-09-30T00:00:00.000Z")]
	private func multi(_ id: String, _ premises: [String], _ conclusion: String) -> GraphChain {
		GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [pt("chatA")], createdAt: "2026-09-30T00:00:00.000Z")
	}

	@Test func aLiveMultiPremiseChainsImpIdJoinsTheClusterMembers() {
		let snap = graphSnapshot(fakeStores([node("p1", "P1", [pt("chatA")]), node("p2", "P2", [pt("chatA")]), node("p3", "P3", [pt("chatA")])],
			chats: chats, chains: [multi("arg_t", ["p1", "p2"], "p3")]))
		#expect(snap.clusters.count == 1)
		#expect(snap.clusters[0].members.contains("arg_t"))
	}

	@Test func theHullFilterCountsPropositions() {
		let snap = graphSnapshot(fakeStores([node("p1", "P1", [pt("chatA")]), node("p2", "P2", [pt("chatA")]), node("p3b", "P3b", [pt("chatB")])],
			chats: chats, chains: [multi("arg_t", ["p1", "p2"], "p3b")]))
		#expect(snap.clusters.isEmpty, "two propositions + a bundle is still not a hull")
	}
}
