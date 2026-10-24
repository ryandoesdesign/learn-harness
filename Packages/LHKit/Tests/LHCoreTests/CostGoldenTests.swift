import Foundation
import Testing
@testable import LHCore

// Golden parity for the usage folds (Golden/cost.usage.json,
// Golden/cost.graphCostSummary.json, written by scripts/core-golden/cost.ts).
// Every golden usage row names a foreign (OpenRouter) model, unpriced in the
// native catalog by design; to check the FOLDS the test builds a catalog from
// the TS prices the dump recorded (no tiers, so the math is identical).

private func goldenCatalog(_ usage: JSONValue) throws -> ModelCatalog {
	let window = try #require(usage["contextWindow"]?.intValue)
	let prices = try #require(usage["prices"]?.objectValue)
	return ModelCatalog(models: try prices.map { id, price in
		CatalogModel(id: id, name: id, contextWindow: window, maxTokens: 1, input: ["text"], efforts: Effort.allCases, price: try JSONCodec.decode(ModelPrice.self, from: price))
	})
}

private func goldenSources() throws -> [NotesSource] {
	let raw = try #require(try Fixtures.json("graph/sources.json").objectValue)
	return try raw.map { try JSONCodec.decode(NotesSource.self, from: $0.value) }
}

private func goldenJobs() throws -> [(id: String, usage: JobUsage?)] {
	let dir = Fixtures.goldenData.appending(path: "jobs")
	let files = try FileManager.default.contentsOfDirectory(atPath: dir.path()).filter { $0.hasSuffix(".json") }.sorted()
	return try files.map { f in
		let raw = try Fixtures.json("jobs/\(f)")
		return (raw["id"]!.stringValue!, try raw["usage"].map { try JSONCodec.decode(JobUsage.self, from: $0) })
	}
}

private func readingJSON(_ r: ContextWindowReading?) -> JSONValue {
	guard let r else { return .null }
	return ["model": .string(r.model), "usedTokens": .number(r.usedTokens), "limit": r.limit.map { .number($0) } ?? .null]
}

private func stageJSON(_ s: StageCost) -> JSONValue {
	["dollars": .number(s.dollars), "unpricedRuns": .number(s.unpricedRuns), "runs": .number(s.runs), "tokens": s.tokens.json]
}

/// `raw` with every dollar-valued field taken from `priced`.
private func withDollars(_ raw: JSONValue, from priced: JSONValue) -> JSONValue {
	switch (raw, priced) {
	case (.object(var r), .object(let p)):
		for key in r.keys {
			if ["dollars", "totalDollars", "unpricedRuns", "unpriced"].contains(key) { r[key] = p[key] }
			else if let rv = r[key], let pv = p[key] { r[key] = withDollars(rv, from: pv) }
		}
		return .object(r)
	case (.array(let r), .array(let p)) where r.count == p.count:
		return .array(zip(r, p).map(withDollars))
	default:
		return raw
	}
}

private func summaryJSON(_ s: GraphCostSummary) -> JSONValue {
	[
		"totalDollars": .number(s.totalDollars),
		"unpricedRuns": .number(s.unpricedRuns),
		"stages": ["extraction": stageJSON(s.stages.extraction), "audit": stageJSON(s.stages.audit)],
		"runs": .array(s.runs.map { r in
			var o: JSONObject = JSONObject(pairs: [
				("startedAt", .number(r.startedAt)), ("at", .string(r.at)), ("durationMs", .number(r.durationMs)),
				("kind", .string(r.kind)), ("title", .string(r.title)), ("dollars", r.dollars.json), ("tokens", r.tokens.json),
			])
			if let m = r.merged { o["merged"] = try! JSONCodec.encode(m) }
			return .object(o)
		}),
	]
}

/// The golden usage is TS-era (OpenRouter: input INCLUDES the cached
/// portion). The native folds take Anthropic-native classes, so the dollar
/// comparisons convert each step first: native input = input − cacheRead.
/// Under that conversion the native formula equals the TS one exactly.
private func native(_ s: CallUsage) -> CallUsage {
	var n = s
	if let input = s.inputTokens { n.inputTokens = max(0, input - (s.cacheReadTokens ?? 0)) }
	return n
}

private func native(_ t: TurnUsage) -> TurnUsage {
	var n = t
	n.steps = t.steps.map(native)
	return n
}

private func native(_ r: ExtractionRunUsage) -> ExtractionRunUsage {
	var n = r
	n.stages.extractor.steps = r.stages.extractor.steps.map(native)
	n.stages.auditor.steps = r.stages.auditor.steps.map(native)
	return n
}

@Suite struct CostGoldenTests {
	@Test func usageFoldsMatchTS() throws {
		let golden = try Golden.load("cost.usage")
		let catalog = try goldenCatalog(golden)
		let chats = try [Fixtures.teachChat, Fixtures.practiceChat]
		let rows = try #require(golden["chats"]?.arrayValue)
		#expect(rows.count == chats.count)
		for (chat, row) in zip(chats, rows) {
			#expect(row["id"]?.stringValue == chat.id)
			let turns = chat.turns ?? []
			let actualTurns = JSONValue.array(turns.map { t in
				["id": .string(t.id), "cost": turnCost(native(t), catalog: catalog).json, "sum": sumSteps(t.steps).json]
			})
			expectJSONEqual(actualTurns, row["turns"]!, tolerance: 1e-12)
			var nativeChat = chat
			nativeChat.turns = chat.turns?.map(native)
			let sc = sessionCost(nativeChat, catalog: catalog)
			expectJSONEqual(["cost": .number(sc.cost), "unpriced": .number(sc.unpriced)], row["sessionCost"]!, tolerance: 1e-12)
			expectJSONEqual(readingJSON(contextWindow(chat, catalog: catalog)), row["contextWindow"]!)
			var zeroed = turns
			if !zeroed.isEmpty {
				zeroed[zeroed.count - 1].steps.append(CallUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0))
			}
			expectJSONEqual(readingJSON(contextWindow(zeroed, catalog: catalog)), row["contextWindowZeroedTail"]!)
			expectJSONEqual(sumSteps(turns.flatMap(\.steps)).json, row["allSteps"]!)
		}

		let jobs = try goldenJobs()
		let actualJobs = JSONValue.array(jobs.map { job -> JSONValue in
			var usage = job.usage
			if let u = usage, let input = u.inputTokens { usage?.inputTokens = max(0, input - (u.cacheReadTokens ?? 0)) }
			return ["id": .string(job.id), "cost": jobCost(usage, catalog: catalog).json]
		})
		expectJSONEqual(actualJobs, golden["jobs"]!, tolerance: 1e-12)

		let stageSums = JSONValue.array(try goldenSources().flatMap { s in
			(s.extractions ?? []).map { r -> JSONValue in
				["startedAt": .number(r.startedAt), "extractor": sumSteps(r.stages.extractor.steps).json, "auditor": sumSteps(r.stages.auditor.steps).json]
			}
		})
		expectJSONEqual(stageSums, golden["stageSums"]!)
	}

	@Test func graphCostSummaryMatchesTS() throws {
		let catalog = try goldenCatalog(try Golden.load("cost.usage"))
		let golden = try Golden.load("cost.graphCostSummary")
		// Token totals compare on the raw (TS-era) usage; dollars on the
		// native-converted usage (see `native` above).
		func inputs(_ convert: Bool) throws -> ([CostSummaryInput.ChatRuns], [CostSummaryInput.SourceRuns]) {
			let chats = try [Fixtures.teachChat, Fixtures.practiceChat].map {
				CostSummaryInput.ChatRuns(title: $0.title, extractions: ($0.extractions ?? []).map { convert ? native($0) : $0 })
			}
			let sources = try goldenSources().map {
				CostSummaryInput.SourceRuns(filePath: $0.filePath, extractions: ($0.extractions ?? []).map { convert ? native($0) : $0 })
			}
			return (chats, sources)
		}
		let (chats, sources) = try inputs(false)
		let (nativeChats, nativeSources) = try inputs(true)
		#expect(sources.contains { !$0.extractions.isEmpty }, "the golden notes source carries runs")
		for (cap, key) in [(10, "default"), (1, "capped")] {
			let raw = summaryJSON(graphCostSummary(CostSummaryInput(chats: chats, sources: sources, recentCap: cap), catalog: catalog))
			let priced = summaryJSON(graphCostSummary(CostSummaryInput(chats: nativeChats, sources: nativeSources, recentCap: cap), catalog: catalog))
			expectJSONEqual(withDollars(raw, from: priced), golden[key]!, tolerance: 1e-12)
		}
		let full = graphCostSummary(CostSummaryInput(chats: chats, sources: sources), catalog: catalog)
		// In the native catalog the same data is honestly unpriced.
		let inNativeCatalog = graphCostSummary(CostSummaryInput(chats: chats, sources: sources), catalog: TestCatalog.shared)
		#expect(inNativeCatalog.totalDollars == 0)
		#expect(inNativeCatalog.unpricedRuns == full.stages.extraction.runs)
		#expect(inNativeCatalog.stages.extraction.tokens == full.stages.extraction.tokens)
	}
}
