import Foundation
import Testing
@testable import LHCore

// M7's pure ports (docs/native-macos-m7.md): graph deletion (tests/graph.test.ts
// deletion cases + the no-provenance fix), commitPositions, render settings,
// the canvas math, and the extraction inputs.

private func node(_ id: String, _ name: String, aliases: [String] = [], _ prov: [(String, String)]) -> GraphNode {
	GraphNode(id: id, name: name, statement: "\(name) statement", aliases: aliases, createdAt: "2026-09-23T00:00:00.000Z",
		provenance: prov.map { ProvenancePoint(chatId: $0.0, messageId: $0.1) })
}

private func chain(_ id: String, _ premises: [String], _ conclusion: String, _ chat: String) -> GraphChain {
	GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [ProvenancePoint(chatId: chat, messageId: "")], createdAt: "2026-09-23T00:00:00.000Z")
}

/// dA creates X and the orphan Y and argues X⇒Y; dB links X, creates Z, argues X⇒Z.
private func twoSessions() -> MemoryGraphStore {
	let s = MemoryGraphStore(
		nodes: [
			node("n_x", "Shared core", aliases: ["shared feel"], [("chat_a", "")]),
			node("n_y", "Solo fact", [("chat_a", "")]),
			node("n_x", "Shared core", aliases: ["B phrasing"], [("chat_b", "")]),
			node("n_z", "B extra", [("chat_b", "")]),
		],
		chains: [chain("arg_xy", ["n_x"], "n_y", "chat_a"), chain("arg_xz", ["n_x"], "n_z", "chat_b")],
		positions: ["n_x": Position(x: 1, y: 1), "n_y": Position(x: 2, y: 2), "n_z": Position(x: 3, y: 3), "arg_xy": Position(x: 4, y: 4)])
	for chat in ["chat_a", "chat_b"] {
		for i in 0..<2 { s.coverage.append(CoverageEntry(chatId: chat, fp: "\(chat)-\(i)", tokens: 10, foldedAt: "2026-09-23T00:02:00.000Z")) }
	}
	s.checkpoints = [SessionCheckpoint(chatId: "chat_a", foldedAt: "2026-09-23T00:02:00.000Z")]
	return s
}

@Suite struct GraphDeletionTests {
	@Test func deleteNodesKeepsTheSharedNodeAndKillsTheOrphan() throws {
		let s = twoSessions()
		let zBefore = s.nodes.first { $0.id == "n_z" }
		let stats = try deleteChatTraces(s, chatId: "chat_a", mode: .deleteNodes)
		#expect(stats == ChatDeletionStats(nodesRemoved: 1, chainsRemoved: 1, coverageRemoved: 2, checkpointsRemoved: 1))
		let x = try #require(getGraph(s).nodes.first { $0.id == "n_x" })
		#expect(x.name == "Shared core" && x.statement == "Shared core statement", "the identity survives")
		#expect(!x.aliases.contains("shared feel") && x.aliases.contains("B phrasing"))
		#expect(x.provenance == [ProvenancePoint(chatId: "chat_b", messageId: "")])
		#expect(!s.nodes.contains { $0.id == "n_y" })
		#expect(s.nodes.first { $0.id == "n_z" } == zBefore)
		#expect(s.chains.map(\.id) == ["arg_xz"])
		#expect(s.positions["n_y"] == nil && s.positions["arg_xy"] == nil && s.positions["n_x"] == Position(x: 1, y: 1))
		#expect(try deleteChatTraces(s, chatId: "chat_a", mode: .deleteNodes) == ChatDeletionStats(), "idempotent")
	}

	@Test func deletingTheRevisingSessionRevertsTheNode() throws {
		let s = twoSessions()
		s.nodes.append(GraphNode(id: "n_x", name: "Core, precisely", statement: "The core, stated precisely", aliases: [], createdAt: "2026-09-24T00:00:00.000Z",
			provenance: [ProvenancePoint(chatId: "chat_c", messageId: "")], revises: true))
		#expect(getGraph(s).nodes.first { $0.id == "n_x" }?.statement == "The core, stated precisely")
		try deleteChatTraces(s, chatId: "chat_c", mode: .deleteNodes)
		let x = try #require(getGraph(s).nodes.first { $0.id == "n_x" })
		#expect(x.name == "Shared core" && x.statement == "Shared core statement")
	}

	@Test func preserveGraphDropsOnlyTheBookkeeping() throws {
		let s = twoSessions()
		let (nodes, chains, positions) = (s.nodes, s.chains, s.positions)
		#expect(try deleteChatTraces(s, chatId: "chat_a", mode: .preserveGraph) == ChatDeletionStats(coverageRemoved: 2, checkpointsRemoved: 1))
		#expect(s.nodes == nodes && s.chains == chains && s.positions == positions)
		#expect(!s.coverage.contains { $0.chatId == "chat_a" } && s.coverage.contains { $0.chatId == "chat_b" })
	}

	/// The fix (your answer): TS's delete-nodes killed every provenance-less
	/// (legacy) node, even ones the session never touched.
	@Test func legacyNodesSurviveASessionDelete() throws {
		let s = MemoryGraphStore(
			nodes: [
				node("n_legacy", "Legacy", []),
				node("n_legacy2", "Legacy linked", []),
				node("n_legacy2", "Legacy linked", aliases: ["a's phrasing"], [("chat_a", "m1")]),
				node("n_a", "A only", [("chat_a", "m2")]),
			],
			chains: [GraphChain(id: "arg_old", premises: ["n_legacy"], conclusion: "n_legacy2", provenance: [], createdAt: "")])
		let stats = try deleteChatTraces(s, chatId: "chat_a", mode: .deleteNodes)
		#expect(stats.nodesRemoved == 1)
		#expect(Set(getGraph(s).nodes.map(\.id)) == ["n_legacy", "n_legacy2"])
		#expect(getGraph(s).nodes.first { $0.id == "n_legacy2" }?.aliases.contains("a's phrasing") == false, "the chat's link line is gone")
		#expect(s.chains.map(\.id) == ["arg_old"])
	}

	@Test func deleteNodeIsFullDeathWithItsChains() throws {
		let s = MemoryGraphStore(
			nodes: [node("n_dead", "Doomed", []), node("n_dead", "Doomed", aliases: ["again"], [("chat_a", "m1")]), node("n_keep", "Keeper", [("chat_a", "m2")])],
			chains: [chain("arg_dk", ["n_dead"], "n_keep", "chat_a"), chain("arg_kd", ["n_keep"], "n_dead", "chat_b"), chain("arg_ko", ["n_keep"], "n_other", "chat_b")],
			positions: ["n_dead": Position(x: 1, y: 1), "n_keep": Position(x: 2, y: 2), "arg_dk": Position(x: 3, y: 3), "arg_kd": Position(x: 4, y: 4)])
		#expect(try deleteNodeTraces(s, nodeId: "n_dead") == 2)
		#expect(!s.nodes.contains { $0.id == "n_dead" })
		#expect(s.chains.map(\.id) == ["arg_ko"])
		#expect(Set(s.positions.keys) == ["n_keep"])
		#expect(try deleteNodeTraces(s, nodeId: "n_dead") == nil)
	}

	@Test func deleteChainRemovesOnlyTheArgument() throws {
		let s = twoSessions()
		#expect(try deleteNodeTraces(s, nodeId: "arg_xy") == 1)
		#expect(s.chains.map(\.id) == ["arg_xz"])
		#expect(Set(getGraph(s).nodes.map(\.id)) == ["n_x", "n_y", "n_z"], "its propositions stay")
		#expect(s.positions["arg_xy"] == nil)
		#expect(try deleteNodeTraces(s, nodeId: "arg_nope") == nil)
	}
}

@Suite struct CommitPositionsTests {
	@Test func keepsKnownFiniteClampedAndSettlesTheMissing() throws {
		let s = twoSessions()
		s.positions = [:]
		let out = try commitPositions(["n_x": Position(x: 5, y: 2e7), "n_ghost": Position(x: 1, y: 1), "n_y": Position(x: .nan, y: 0)], store: s)
		#expect(out == ["n_x": Position(x: 5, y: 1e6)])
		#expect(s.positions["n_ghost"] == nil)
		#expect(s.positions["n_y"] != nil && s.positions["n_z"] != nil, "the view had ids the client didn't send: re-settled")
		#expect(try commitPositions(["n_ghost": Position(x: 0, y: 0)], store: s).isEmpty)
	}
}

@Suite struct RenderSettingsTests {
	@Test func defaultsAndLegacyResets() {
		#expect(sanitizeRenderSettings(nil) == DEFAULT_RENDER_SETTINGS)
		let legacy = sanitizeRenderSettings(["nodeSize": 8, "edgeWidth": 3, "labelSize": 12, "regions": ["dilation": 80]])
		#expect(legacy.nodeSize == 2 && legacy.labelSize == 3 && legacy.regions.dilation == 20, "no sizeUnits: the world sizes reset")
		#expect(legacy.edgeWidth == 3)
		let world = sanitizeRenderSettings(["sizeUnits": "world", "nodeSize": 7, "regions": ["dilation": 80, "bitmap": 300], "physics": ["chargeStrength": -9999, "depthMode": "radial", "clusterPull": -1]])
		#expect(world.nodeSize == 6, "snapped to the ladder")
		#expect(world.regions.dilation == 80 && world.regions.bitmap == 256)
		#expect(world.physics.chargeStrength == -480 && world.physics.depthMode == .radial && world.physics.clusterPull == 0)
		#expect(sanitizeRenderSettings(world.json) == world, "the stored shape round-trips")
	}

	@Test func laddersAndLogSliders() {
		#expect(toLadderPosition(2, NODE_SIZE_LADDER) == 50 && fromLadderPosition(50, NODE_SIZE_LADDER) == 2)
		#expect(fromLadderPosition(999, NODE_SIZE_LADDER) == 12)
		#expect(abs(fromSliderPosition(toSliderPosition(-240, CHARGE_RANGE), CHARGE_RANGE) - -240) < 1e-9)
		#expect(abs(toSliderPosition(1, LINK_STRENGTH_RANGE) - 50) < 1e-9, "the default sits dead centre")
		#expect(toOffSliderPosition(0, CLUSTER_PULL_RANGE) == 0 && fromOffSliderPosition(0, CLUSTER_PULL_RANGE) == 0)
		#expect(labelZoomDisplay(0.5) == "1×" && labelZoomDisplay(0.175) == "0.35×")
	}
}

@Suite struct GraphCanvasMathTests {
	@Test func zoomLabelsFitArrowsPicking() {
		#expect(zoomRatioOf(kFit: 2, k: 4) == 0.5)
		#expect(labelAlpha(ratio: 0.5, labelZoom: 0.5) == 1 && labelAlpha(ratio: 0.75, labelZoom: 0.5) == 0)
		let fit = fitTransform(GraphBBox(minX: 0, maxX: 100, minY: 0, maxY: 50), width: 300, height: 300, padding: 50)
		#expect(fit.k == 2 && fit.x == 50 && fit.y == 100)
		let a = arrowGeometry(GraphPoint(x: 0, y: 0), GraphPoint(x: 10, y: 0), fromRadius: 1, toRadius: 2, headLength: 3)
		#expect(a?.tip == GraphPoint(x: 8, y: 0) && a?.shaftTo == GraphPoint(x: 5, y: 0) && a?.shaftFrom == GraphPoint(x: 1, y: 0))
		#expect(arrowGeometry(GraphPoint(x: 1, y: 1), GraphPoint(x: 1, y: 1), fromRadius: 0, toRadius: 0, headLength: 1) == nil)
		let pts = [GraphPoint(x: 0, y: 0), GraphPoint(x: 5, y: 0)]
		#expect(pickNearest(pts, at: GraphPoint(x: 4, y: 0), maxDistance: 2, position: { $0 }) == GraphPoint(x: 5, y: 0))
		#expect(pickNearest(pts, at: GraphPoint(x: 20, y: 0), maxDistance: 2, position: { $0 }) == nil)
	}

	@Test func wrapping() {
		let measure: (String) -> Double = { Double($0.count) }
		#expect(wrapLabel("aa bb cc", maxWidth: 5, measure: measure) == ["aa bb", "cc"])
		#expect(wrapLabel("abcdefgh", maxWidth: 3, measure: measure) == ["abc", "def", "gh"], "never truncates")
		#expect(wrapRegionLabel("short", maxWidth: 10, maxLines: 3, measure: measure) == ["short"])
		#expect(wrapRegionLabel("one two three four five six seven", maxWidth: 9, maxLines: 2, measure: measure) == ["one two", "three fo…"])
	}

	@Test func visibilitySeedingAndHue() {
		#expect(isNodeVisible(name: "Inner join", statement: "keeps matches", query: " JOIN ") && !isNodeVisible(name: "a", statement: "b", query: "z"))
		let seeded = seedMissingNodePositions(["a", "b", "c"], ["a": Position(x: 0, y: 0), "b": Position(x: 100, y: 0)])
		#expect(seeded.count == 3 && seeded == seedMissingNodePositions(["a", "b", "c"], ["a": Position(x: 0, y: 0), "b": Position(x: 100, y: 0)]), "deterministic")
		#expect(seedMissingNodePositions(["a"], [:]).isEmpty, "no ledger: nothing to seed around")
		#expect(clusterHue("chat_x") == clusterHue("chat_x") && (0..<360).contains(clusterHue("chat_x")))
		#expect(clusterHue("ab") == Double((97 * 31 + 98) % 360))
	}
}

@Suite struct ExtractionInputsTests {
	private func teacher(_ id: String, _ text: String) -> Message {
		Message(id: id, timestamp: 0, body: .assistant(AssistantBody(content: [.text(text)], model: "m", stopReason: "end_turn")))
	}

	@Test func proseViewAndAnchors() {
		let msgs = [newUserMessage("hi", now: 0), teacher("t1", " First. "), teacher("t2", "Second.")]
		#expect(proseView(msgs, title: "Joins") == "# Joins\n\nTEACHER [t1] First.\n\nTEACHER [t2] Second.")
		#expect(batchAnchorIds(msgs) == ["t1", "t2"])
	}

	@Test func digestListsOnlyThisSource() {
		let g = DerivedGraph(nodes: [node("n_a", "A", [("src", "")]), node("n_b", "B", [("other", "")])], chains: [chain("arg_1", ["n_a"], "n_b", "src")])
		#expect(sourceDigest(g, sourceId: "src") == """
			THE GRAPH SO FAR — everything already extracted from this source (reference these ids verbatim):
			  n_a | A | A statement
			DERIVATIONS ALREADY RECORDED (build on these; do not re-derive them):
			  [n_a ⇒ n_b]  A ⇒ B
			""")
		#expect(sourceDigest(g, sourceId: "none") == "")
	}

	@Test func chunksNotesByLine() {
		#expect(chunkNotes("  ", budget: 10).isEmpty)
		#expect(chunkNotes("aaaa\nbbbb\ncccc", budget: 3) == ["aaaa\nbbbb", "cccc"])
		#expect(notesView(filePath: "/n.md", text: "x", part: (2, 3)) == "SOURCE (the author's personal notes): /n.md (part 2/3)\n\nx")
	}

	@Test func theSubmitSeam() {
		let raw: JSONValue = ["propositions": [["id": "p1", "name": "N", "statement": "S", "messageId": "t1"]], "chains": [["premises": ["p1"], "conclusion": "n_x"]]]
		let f = decodeFindings(raw, notes: false)!
		#expect(f.propositions[0].aliases == [] && f.propositions[0].messageId == "t1")
		#expect(decodeFindings(raw, notes: true)!.propositions[0].messageId == nil, "the notes door strips anchors")
		#expect(validateFindingsChains(f, existingIds: ["n_x"]) == nil)
		#expect(validateFindingsChains(f, existingIds: [])?.contains("\"n_x\" is neither") == true)
		#expect(validateSessionAnchors(f, batchIds: ["t1"]) == nil)
		#expect(validateSessionAnchors(f, batchIds: ["t2"])?.contains("not a passage of THIS stretch") == true)
		#expect(decodeVerdicts(["links": [["id": "p1", "linkTo": "n_x"]]]) == AuditVerdicts(links: [IdentityLink(id: "p1", linkTo: "n_x")]))
		#expect(decodeVerdicts(["links": [["id": "p1", "linkTo": "n_x", "rewrite": true]]]) == AuditVerdicts(links: [IdentityLink(id: "p1", linkTo: "n_x", rewrite: true)]))
		#expect(notesSourceId(path: "/a/notes.md") != notesSourceId(path: "/b/notes.md"))
		#expect(notesSourceId(path: "/a/notes.md").hasPrefix("src_") && notesSourceId(path: "/a/notes.md").count == 16)
	}
}
