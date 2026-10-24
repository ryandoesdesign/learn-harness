import Foundation
import LHAnthropic
import LHCore
import LHStore

/// Port of server/compaction.ts: the context-window guard. Before every turn
/// the gate awaits any running compaction and, if the projection is still
/// over threshold, compacts synchronously; at settle the kick starts one in
/// the background. One per chat at a time (the in-flight mutex).
public actor CompactionService {
	/// The summarizer's system prompt (server-owned operational framing).
	public static let summarizerSystemPrompt =
		"You are the session-compaction summarizer for a tutoring agent. You receive the transcript span to summarize and write exactly the summary the instructions demand — nothing else, no preamble, no meta-commentary."

	/// One-shot summary: prompt → (summary, usage steps). Injectable for tests.
	public typealias Summarizer = @Sendable (_ prompt: String, _ spec: EffectiveModelSpec) async throws -> (summary: String, steps: [UsageStepRecord])

	/// What one compaction needs, resolved by the caller (TurnService).
	public struct Deps: Sendable {
		public var spec: EffectiveModelSpec
		public var kind: CompactionPromptKind
		/// min(settings threshold, contextWindow − reserve).
		public var thresholdTokens: Int
		/// The composed system prompt's chars/4 — the projection starts with it.
		public var systemPromptTokens: Int
		public init(spec: EffectiveModelSpec, kind: CompactionPromptKind, thresholdTokens: Int, systemPromptTokens: Int) {
			self.spec = spec
			self.kind = kind
			self.thresholdTokens = thresholdTokens
			self.systemPromptTokens = systemPromptTokens
		}
	}

	let database: AppDatabase
	let summarize: Summarizer
	private var inFlight: [String: Task<Void, Never>] = [:]
	/// running true/false per chat (the UI's COMPACTING CONTEXT line).
	let notify: @Sendable (_ chatId: String, _ running: Bool) -> Void

	public init(database: AppDatabase, summarize: @escaping Summarizer, notify: @escaping @Sendable (String, Bool) -> Void = { _, _ in }) {
		self.database = database
		self.summarize = summarize
		self.notify = notify
	}

	/// The production summarizer: the session's own model, no tools, one call.
	public static func summarizer(client: MessagesClient) -> Summarizer {
		{ prompt, spec in
			let loop = AgentLoop(client: client, config: AgentConfig(
				model: spec.model, effort: spec.effort, system: summarizerSystemPrompt, thinkingDisplay: .omitted, cacheTTL: .fiveMinutes))
			let outcome = await loop.run(history: [], inputs: [newUserMessage(prompt)]) { _ in }
			let text = outcome.newMessages.compactMap(\.assistant).last.map { a in
				a.content.compactMap { $0.type == "text" ? $0.raw["text"]?.stringValue : nil }.joined()
			} ?? ""
			if let failed = outcome.newMessages.compactMap(\.assistant).last, failed.stopReason == "error" {
				throw CompactionError(message: failed.errorMessage ?? "summary failed")
			}
			return (text, outcome.steps)
		}
	}

	struct CompactionError: Error { var message: String }

	public func isRunning(_ chatId: String) -> Bool { inFlight[chatId] != nil }

	/// The effective trigger: unknown window → the setting alone.
	public static func effectiveThreshold(setting: Int?, contextWindow: Int?) -> Int {
		let s = setting ?? DEFAULT_COMPACTION_THRESHOLD_TOKENS
		guard let contextWindow else { return s }
		return min(s, max(contextWindow - COMPACTION_RESERVE_TOKENS, 1))
	}

	/// What the next call would carry: anchored on the last usage when one
	/// is valid, else chars/4 over the cut-honored projection plus the prompt.
	public static func projectedTokens(_ messages: [Message], systemPromptTokens: Int) -> Int {
		let est = estimateContextTokens(messages)
		if est.lastUsageIndex != nil { return est.tokens }
		var projected = messages
		if let active = activeCompactionOf(messages) {
			let kept = keptIndexFor(messages, active)
			if let marker = messages.first(where: { $0.id == active.id }) {
				projected = [marker] + messages[kept...].filter { $0.id != active.id }
			}
		}
		return estimateTokens(projected) + systemPromptTokens
	}

	/// The gate: await any running compaction, then compact now if still over.
	public func ensureCompacted(_ chatId: String, deps: Deps) async {
		if let running = inFlight[chatId] { await running.value }
		guard let record = try? ChatRepository(database).get(chatId) else { return }
		guard Self.projectedTokens(record.messages, systemPromptTokens: deps.systemPromptTokens) > deps.thresholdTokens else { return }
		if let running = inFlight[chatId] { await running.value; return }
		let run = start(chatId, deps: deps)
		await run.value
	}

	/// The settle kick (fire-and-forget).
	public func kick(_ chatId: String, deps: Deps) {
		guard inFlight[chatId] == nil, let record = try? ChatRepository(database).get(chatId) else { return }
		guard Self.projectedTokens(record.messages, systemPromptTokens: deps.systemPromptTokens) > deps.thresholdTokens else { return }
		_ = start(chatId, deps: deps)
	}

	private func start(_ chatId: String, deps: Deps) -> Task<Void, Never> {
		let task = Task { await self.compact(chatId, deps: deps) }
		inFlight[chatId] = task
		Task {
			await task.value
			self.finished(chatId)
		}
		return task
	}

	private func finished(_ chatId: String) { inFlight[chatId] = nil }

	/// One compaction: cut, summarize, append the marker + usage.
	private func compact(_ chatId: String, deps: Deps) async {
		let repo = ChatRepository(database)
		guard let record = try? repo.get(chatId) else { return }
		let messages = record.messages
		let tokensBefore = Self.projectedTokens(messages, systemPromptTokens: deps.systemPromptTokens)
		guard tokensBefore > deps.thresholdTokens else { return }
		let cut = compactionCutIndex(messages)
		guard cut < messages.count else { return }
		let previous = activeCompactionOf(messages)
		let prevKept = previous.map { p in messages.firstIndex { $0.id == p.firstKeptMessageId } ?? -1 } ?? -1
		if previous != nil, prevKept != -1, cut <= prevKept { return } // the kept tail alone exceeds the threshold

		var spanStart = 0
		var priorSummary: String?
		if let previous, prevKept > 0 {
			spanStart = prevKept
			priorSummary = previous.content
		}
		let spanText = serializeForSummary(Array(messages[spanStart..<cut]))
		let fullSpan = priorSummary.map { "[SYSTEM NOTE — prior compaction summary, still authoritative where not superseded]\n\($0)\n\n\(spanText)" } ?? spanText
		let prompt = buildCompactionPrompt(spanText: fullSpan, planTreeText: planTreeToText(record.tree, messages), kind: deps.kind)

		notify(chatId, true)
		defer { notify(chatId, false) }
		do {
			let (summary, steps) = try await summarize(prompt, deps.spec)
			let trimmed = summary.jsTrimmed
			guard !trimmed.isEmpty else { return } // a refusal artifact — leave the record honest
			let at = ISOClock.string(Date())
			let details = CompactionDetails(firstKeptMessageId: messages[cut].id, tokensBefore: tokensBefore, model: deps.spec.model, at: at)
			let marker = newCompactionMarker(summary: trimmed, details: details)
			try repo.append([marker], to: chatId)
			if !steps.isEmpty {
				try repo.appendTurnUsage(TurnUsage(id: UUID().uuidString.lowercased(), messageId: marker.id, at: at, model: deps.spec.model, steps: steps.map(\.usage)), chatId: chatId)
			}
		} catch {
			// The record stays untouched; the next gate retries.
		}
	}
}
