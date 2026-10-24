import Foundation

// Port of src/core/cost-summary.ts — the graph cost pill's pure fold. Two
// usage channels in: chat extraction runs (ChatRecord.extractions) and
// notes-source runs (NotesSource.extractions). Out: per-stage totals
// (extraction / audit) plus a capped recent-runs list.
//
// Dollars are inferred at read time from the catalog. An unpriced model
// contributes ZERO dollars but is counted in `unpricedRuns`, so the UI can
// render "— unpriced" honestly. Tokens always sum.

/// One pipeline stage's cumulative cost across every run.
public struct StageCost: Sendable, Hashable {
	/// Inferred USD over PRICED runs (partial when unpricedRuns > 0).
	public var dollars: Double
	/// Stage-runs whose model is unpriced.
	public var unpricedRuns: Int
	/// Runs that billed this stage.
	public var runs: Int
	/// Token totals across every run (nil until the first run folds in).
	public var tokens: CallUsage
	public init(dollars: Double = 0, unpricedRuns: Int = 0, runs: Int = 0, tokens: CallUsage = CallUsage()) {
		self.dollars = dollars
		self.unpricedRuns = unpricedRuns
		self.runs = runs
		self.tokens = tokens
	}
}

/// One run in the recent-runs list.
public struct RecentRun: Sendable, Hashable {
	public var startedAt: Int
	/// ISO wall-clock.
	public var at: String
	public var durationMs: Int
	/// Always "extraction" (covers both front doors).
	public var kind: String
	/// Chat title or source file path.
	public var title: String
	/// Whole-run USD; nil only when EVERY stage is unpriced.
	public var dollars: Double?
	public var tokens: CallUsage
	/// What the run merged into the graph; nil on failed runs.
	public var merged: EmissionStats?
	public init(startedAt: Int, at: String, durationMs: Int, kind: String = "extraction", title: String, dollars: Double?, tokens: CallUsage, merged: EmissionStats?) {
		self.startedAt = startedAt
		self.at = at
		self.durationMs = durationMs
		self.kind = kind
		self.title = title
		self.dollars = dollars
		self.tokens = tokens
		self.merged = merged
	}
}

/// The cost pill's whole payload.
public struct GraphCostSummary: Sendable, Hashable {
	public struct Stages: Sendable, Hashable {
		public var extraction: StageCost
		public var audit: StageCost
	}

	/// Inferred USD across all priced stages of all runs.
	public var totalDollars: Double
	/// Runs where EVERY stage was unpriced.
	public var unpricedRuns: Int
	/// The billable pipeline stages.
	public var stages: Stages
	/// Newest first, capped at `recentCap`.
	public var runs: [RecentRun]
}

/// What the fold reads: already-collected run records, front-door-tagged.
public struct CostSummaryInput: Sendable, Hashable {
	public struct ChatRuns: Sendable, Hashable {
		public var title: String
		public var extractions: [ExtractionRunUsage]
		public init(title: String, extractions: [ExtractionRunUsage]) {
			self.title = title
			self.extractions = extractions
		}
	}

	public struct SourceRuns: Sendable, Hashable {
		public var filePath: String
		public var extractions: [ExtractionRunUsage]
		public init(filePath: String, extractions: [ExtractionRunUsage]) {
			self.filePath = filePath
			self.extractions = extractions
		}
	}

	public var chats: [ChatRuns]
	public var sources: [SourceRuns]
	public var recentCap: Int
	public init(chats: [ChatRuns], sources: [SourceRuns], recentCap: Int = 10) {
		self.chats = chats
		self.sources = sources
		self.recentCap = recentCap
	}
}

/// One stage's dollars over its steps; nil when the model is unpriced
/// (all-or-nothing: a stage runs one model).
private func stageDollars(_ model: String, _ steps: [CallUsage], _ catalog: ModelCatalog) -> Double? {
	var total = 0.0
	for step in steps {
		guard let c = callCost(step, model: model, catalog: catalog) else { return nil }
		total += c
	}
	return total
}

private func mergeTokens(_ into: inout CallUsage, _ steps: [CallUsage]) {
	let s = sumSteps(steps)
	into.inputTokens = (into.inputTokens ?? 0) + (s.inputTokens ?? 0)
	into.outputTokens = (into.outputTokens ?? 0) + (s.outputTokens ?? 0)
	into.cacheReadTokens = (into.cacheReadTokens ?? 0) + (s.cacheReadTokens ?? 0)
	into.cacheWriteTokens = (into.cacheWriteTokens ?? 0) + (s.cacheWriteTokens ?? 0)
	into.reasoningTokens = (into.reasoningTokens ?? 0) + (s.reasoningTokens ?? 0)
}

/// Fold every usage channel into the pill's payload. Pure.
public func graphCostSummary(_ input: CostSummaryInput, catalog: ModelCatalog) -> GraphCostSummary {
	var extraction = StageCost()
	var audit = StageCost()
	var runs: [RecentRun] = []

	func fold(_ run: ExtractionRunUsage, title: String) {
		let stages = run.stages
		extraction.runs += 1
		mergeTokens(&extraction.tokens, stages.extractor.steps)
		let ext = stageDollars(stages.extractor.model, stages.extractor.steps, catalog)
		if let ext { extraction.dollars += ext } else { extraction.unpricedRuns += 1 }

		audit.runs += 1
		mergeTokens(&audit.tokens, stages.auditor.steps)
		let aud = stageDollars(stages.auditor.model, stages.auditor.steps, catalog)
		if let aud { audit.dollars += aud } else { audit.unpricedRuns += 1 }

		let all = [ext, aud]
		let runDollars: Double? = all.allSatisfy { $0 == nil } ? nil : all.reduce(0) { $0 + ($1 ?? 0) }
		runs.append(RecentRun(
			startedAt: run.startedAt,
			at: run.at,
			durationMs: run.durationMs,
			title: title,
			dollars: runDollars,
			tokens: sumSteps(stages.extractor.steps + stages.auditor.steps),
			merged: run.stats))
	}

	for chat in input.chats {
		for run in chat.extractions { fold(run, title: chat.title) }
	}
	for source in input.sources {
		for run in source.extractions { fold(run, title: source.filePath) }
	}

	// Newest first; stable on ties (JS Array.prototype.sort is stable).
	let sorted = runs.enumerated()
		.sorted { a, b in a.element.startedAt != b.element.startedAt ? a.element.startedAt > b.element.startedAt : a.offset < b.offset }
		.map(\.element)
	return GraphCostSummary(
		totalDollars: extraction.dollars + audit.dollars,
		unpricedRuns: sorted.filter { $0.dollars == nil }.count,
		stages: GraphCostSummary.Stages(extraction: extraction, audit: audit),
		runs: Array(sorted.prefix(Swift.max(0, input.recentCap))))
}
