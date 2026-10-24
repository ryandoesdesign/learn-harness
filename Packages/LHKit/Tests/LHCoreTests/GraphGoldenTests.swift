import Foundation
import Testing
@testable import LHCore

/// Golden parity with the TS graph core (scripts/core-golden/graph.ts): the
/// snapshot, session index, propositions and simplification over the real
/// ledgers, and coverage over both golden chats — the converted native
/// messages must yield the TS view lines and fingerprints byte-for-byte.
@Suite struct GraphGoldenTests {
	private func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONCodec.encode(value) }

	private func clusterJSON(_ c: Cluster) -> JSONValue {
		["id": .string(c.id), "label": c.label.map(JSONValue.string) ?? .null, "members": .array(c.members.map(JSONValue.string))]
	}

	private func entryJSON(_ e: GraphSessionEntry) -> JSONValue {
		[
			"id": .string(e.id), "name": .string(e.name), "kind": .string(e.kind.rawValue),
			"createdAt": e.createdAt.map(JSONValue.string) ?? .null, "updatedAt": e.updatedAt.map(JSONValue.string) ?? .null,
			"propositions": .number(e.propositions),
		]
	}

	@Test func snapshotMatchesTS() throws {
		let (deps, _) = try GoldenGraph.deps()
		let snap = graphSnapshot(deps)
		var o = JSONObject()
		o["nodes"] = try encode(snap.nodes)
		o["propositions"] = try encode(snap.propositions)
		o["edges"] = try encode(snap.edges)
		o["logicalEdges"] = try encode(snap.logicalEdges)
		o["impLinks"] = try encode(snap.impLinks)
		o["chains"] = try encode(snap.chains)
		o["sessions"] = try encode(snap.sessions)
		o["fileSources"] = try encode(snap.fileSources)
		o["nodeSessions"] = try encode(snap.nodeSessions)
		o["clusters"] = .array(snap.clusters.map(clusterJSON))
		if let positions = snap.positions { o["positions"] = try encode(positions) }
		expectJSONEqual(.object(o), try Golden.load("graph.snapshot"))
	}

	@Test func derivedGraphIndexAndPropositionsMatchTS() throws {
		let (deps, store) = try GoldenGraph.deps()
		let golden = try Golden.load("graph.derived")
		let graph = getGraph(store)
		let simplified = simplifyChains(store.readChains())
		let index = graphSessionIndex(deps)
		var props = JSONObject()
		for entry in index { props[entry.id] = try encode(graphSessionPropositions(deps, sessionId: entry.id)) }
		let actual: JSONValue = [
			"counts": [
				"nodeLines": .number(store.readNodes().count),
				"chainLines": .number(store.readChains().count),
				"nodes": .number(graph.nodes.count),
				"chains": .number(graph.chains.count),
				"simplifiedChains": .number(simplified.count),
			],
			"graph": ["nodes": try encode(graph.nodes), "chains": try encode(graph.chains)],
			"partition": try encode(birthSessionPartition(graph.nodes)),
			"simplifiedChainIds": .array(simplified.map { .string($0.id) }),
			"sessionIndex": .array(index.map(entryJSON)),
			"sessionPropositions": .object(props),
		]
		expectJSONEqual(actual, golden)
		// The derived counts the TS side reports for tests/fixtures/golden-data.
		#expect(golden["counts"] == ["nodeLines": 298, "chainLines": 173, "nodes": 278, "chains": 173, "simplifiedChains": 173])
	}

	@Test func simplifyChainsMatchesTS() throws {
		for (i, row) in (try Golden.load("graph.simplify").arrayValue ?? []).enumerated() {
			let input = try JSONCodec.decode([GraphChain].self, from: row["input"]!)
			let output = simplifyChains(input)
			let d = jsonDiff(try encode(output), row["output"]!)
			#expect(d == nil, "case \(i): \(d ?? "")")
		}
	}

	@Test func coveredSetsMatchTS() throws {
		let ledger = try Fixtures.jsonl("graph/coverage.jsonl").map { try JSONCodec.decode(CoverageEntry.self, from: $0) }
		guard case .object(let golden) = try Golden.load("graph.coveredSets") else { Issue.record("shape"); return }
		#expect(golden.count == Set(ledger.map(\.chatId)).count)
		for (chatId, fps) in golden {
			let actual = GraphJS.sorted(Array(coveredSet(ledger, chatId: chatId)))
			#expect(JSONValue.array(actual.map(JSONValue.string)) == fps)
		}
	}

	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func coverageMatchesTS(chatId: String) throws {
		let golden = try Golden.load("graph.coverage.\(chatId)")
		let messages = try Fixtures.chat(chatId).messages
		let slots = coverageSlots(messages)

		// Slots: per-message view lines + persisted fingerprints, positionally.
		let goldenSlots = golden["slots"]?.arrayValue ?? []
		#expect(slots.count == goldenSlots.count)
		for (slot, row) in zip(slots, goldenSlots) {
			let actual: JSONValue = [
				"id": .string(slot.message.id),
				"role": .string(slot.message.role == .marker ? "custom" : slot.message.role.rawValue),
				"lines": .array(messageViewLines(slot.message, mid: slot.message.id).map(JSONValue.string)),
				"fp": .string(slot.fp),
				"tokens": .number(slot.tokens),
			]
			expectJSONEqual(actual, row)
		}
		expectJSONEqual(.array(teacherProseBlocks(messages).map(JSONValue.string)), golden["teacherProseBlocks"]!)

		func stateJSON(_ s: CoverageState) -> JSONValue {
			[
				"uncovered": .array(s.uncovered.map { .number($0) }),
				"coveredTokens": .number(s.coveredTokens), "uncoveredTokens": .number(s.uncoveredTokens),
				"coveredCount": .number(s.coveredCount), "uncoveredCount": .number(s.uncoveredCount),
			]
		}
		func runsJSON(_ runs: [[CoverageSlot]]) -> JSONValue {
			.array(runs.map { run in ["ids": .array(run.map { .string($0.message.id) }), "tag": .string(batchTag(run))] })
		}

		let ledger = try Fixtures.jsonl("graph/coverage.jsonl").map { try JSONCodec.decode(CoverageEntry.self, from: $0) }
		expectJSONEqual(stateJSON(coverageOf(messages, entries: ledger, chatId: chatId)), golden["ledgerCoverage"]!)
		expectJSONEqual(stateJSON(coverageOf(messages, entries: [], chatId: chatId)), golden["emptyCoverage"]!)

		let visible = slots.filter { !messageViewLines($0.message, mid: $0.message.id).isEmpty }
		let synthetic = visible.enumerated().filter { $0.offset % 2 == 0 }
			.map { CoverageEntry(chatId: chatId, fp: $0.element.fp, tokens: $0.element.tokens, foldedAt: "2026-10-24T00:00:00.000Z") }
		let synth = coverageOf(messages, entries: synthetic, chatId: chatId)
		expectJSONEqual(stateJSON(synth), golden["syntheticCoverage"]!)
		for budget in [0, 50, 500, 4096] {
			expectJSONEqual(runsJSON(batchRuns(synth.slots, uncovered: synth.uncovered, budget: budget)), golden["syntheticRuns"]![String(budget)]!)
		}
		let all = coverageOf(messages, entries: [], chatId: chatId)
		expectJSONEqual(runsJSON(batchRuns(all.slots, uncovered: all.uncovered, budget: 4096)), golden["allUncoveredRuns4096"]!)
	}
}
