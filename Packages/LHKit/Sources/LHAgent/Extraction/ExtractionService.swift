import Foundation
import LHAnthropic
import LHCore
import LHResources
import LHStore

/// The extraction pipeline (docs/native-macos-m7.md) — the port of
/// extraction.ts orchestration and its triggers. A source (a chat, or an
/// imported notes file) is single-flight; its batches run in order, each
/// seeing the previous merge. Extract calls share a FIFO limit of 3; audit
/// and merge are serialized app-wide. A batch merges in one transaction, so
/// its nodes, chains and coverage land together or not at all.
public actor ExtractionService {
	public enum Phase: String, Sendable, Hashable { case queued, extracting, waiting, auditing, merging }
	public enum SourceKind: String, Sendable, Hashable { case chat, notes }

	/// One running batch job (the Background agents row).
	public struct Row: Sendable, Hashable, Identifiable {
		public var id: String
		public var sourceId: String
		public var kind: SourceKind
		/// The file path for notes; chats are titled by the UI.
		public var label: String?
		public var part: Part?
		public var phase: Phase
		/// Registry ms, strictly increasing (the usage idempotency key).
		public var startedAt: Int
		public var extractor: ExtractionStageUsage?
		public var auditor: ExtractionStageUsage?
	}

	public struct Part: Sendable, Hashable { public var i: Int, n: Int }

	public enum StartResult: Sendable, Equatable { case started, alreadyRunning, nothingToDo, refused(String) }

	public struct NotesFile: Sendable { public var path: String; public var text: String
		public init(path: String, text: String) { self.path = path; self.text = text }
	}

	public struct NotesResult: Sendable, Hashable {
		public enum Outcome: String, Sendable { case completed, failed, partial, aborted, busy }
		public var path: String
		public var outcome: Outcome
		public var stats: EmissionStats
		public var error: String?
		public init(path: String, outcome: Outcome, stats: EmissionStats, error: String?) {
			self.path = path
			self.outcome = outcome
			self.stats = stats
			self.error = error
		}
	}

	/// Per-session coverage (chats.ts sessionCoverage): the ring and the menu.
	public struct SessionCoverage: Sendable, Hashable {
		public var totalMessages: Int
		public var coveredCount: Int
		public var uncoveredCount: Int
		public var coveredTokens: Int
		public var uncoveredTokens: Int
		public var running: Bool
		public var lastFoldedAt: String?
	}

	let database: AppDatabase
	let keychain: any KeychainStore
	let catalog: ModelCatalog
	let makeTransport: @Sendable () -> any AnthropicTransport

	private var rows: [String: Row] = [:]
	private var inFlight: Set<String> = []
	private var sourceTasks: [String: Task<Void, Never>] = [:]
	private var lastStartedAt = 0
	private var subscribers: [UUID: AsyncStream<[Row]>.Continuation] = [:]
	private let extractSlots = AsyncLimiter(3)
	private let auditLock = AsyncLimiter(1)

	public init(database: AppDatabase, keychain: any KeychainStore, catalog: ModelCatalog,
		makeTransport: @escaping @Sendable () -> any AnthropicTransport = { URLSessionTransport() })
	{
		self.database = database
		self.keychain = keychain
		self.catalog = catalog
		self.makeTransport = makeTransport
	}

	var graph: GraphRepository { GraphRepository(database) }
	var chats: ChatRepository { ChatRepository(database) }

	// MARK: Observation

	/// The running jobs, oldest first, now and after every change.
	public func observe() -> AsyncStream<[Row]> {
		let id = UUID()
		let (stream, c) = AsyncStream<[Row]>.makeStream(bufferingPolicy: .bufferingNewest(1))
		subscribers[id] = c
		c.yield(current)
		c.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
		return stream
	}

	private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
	private var current: [Row] { rows.values.sorted { $0.startedAt < $1.startedAt } }
	private func publish() { for c in subscribers.values { c.yield(current) } }

	public func isRunning(_ sourceId: String) -> Bool { inFlight.contains(sourceId) }
	public var anyRunning: Bool { !inFlight.isEmpty }

	public func coverage(_ chatId: String) -> SessionCoverage? {
		Self.coverage(database: database, chatId: chatId, running: inFlight.contains(chatId))
	}

	/// The coverage read without the actor (the UI, synchronously); the caller says whether it runs.
	public nonisolated static func coverage(database: AppDatabase, chatId: String, running: Bool) -> SessionCoverage? {
		guard let record = (try? ChatRepository(database).get(chatId)) ?? nil else { return nil }
		let entries = GraphRepository(database).readCoverage()
		let cov = coverageOf(record.messages, entries: entries, chatId: chatId)
		let last = entries.filter { $0.chatId == chatId }.map(\.foldedAt).max { $0.utf16.lexicographicallyPrecedes($1.utf16) }
		return SessionCoverage(totalMessages: cov.slots.count, coveredCount: cov.coveredCount, uncoveredCount: cov.uncoveredCount,
			coveredTokens: cov.coveredTokens, uncoveredTokens: cov.uncoveredTokens, running: running, lastFoldedAt: last)
	}

	// MARK: Triggers

	private var settings: UserSettings? { (try? SettingsRepository(database).read()) ?? nil }
	private var effective: EffectiveSettings { resolveSettings(settings, catalog: catalog) }

	/// After every settled turn (chat-handler onFinish): non-practice, Extraction
	/// on, and at least the chunk budget of unextracted prose.
	public func turnSettled(_ chatId: String) {
		let eff = effective
		guard extractionEnabled(eff.graph), let record = (try? chats.get(chatId)) ?? nil, record.resolvedKind != .practice else { return }
		let cov = coverageOf(record.messages, entries: graph.readCoverage(), chatId: chatId)
		guard cov.uncoveredTokens >= eff.graph.extractionChunkTokens else { return }
		_ = start(chatId)
	}

	/// The per-session Extract action: no threshold.
	public func extractNow(_ chatId: String) -> StartResult { start(chatId) }

	/// The one-time backfill (your answer): every non-practice session with any
	/// unextracted prose, threshold ignored. Marked done once all were attempted.
	public func backfillIfNeeded() async {
		let g = graph
		guard !g.backfillDone, extractionEnabled(effective.graph) else { return }
		guard (try? keychain.anthropicKey()) ?? nil != nil else { return }
		let entries = g.readCoverage()
		for summary in chats.listChats() where summary.kind != .practice {
			guard let record = (try? chats.get(summary.id)) ?? nil else { continue }
			if coverageOf(record.messages, entries: entries, chatId: summary.id).uncoveredCount > 0 { _ = start(summary.id) }
		}
		for task in sourceTasks.values { await task.value }
		try? g.markBackfillDone()
	}

	private func start(_ chatId: String) -> StartResult {
		if inFlight.contains(chatId) { return .alreadyRunning }
		guard (try? keychain.anthropicKey()) ?? nil != nil else { return .refused("No Anthropic key") }
		guard let record = (try? chats.get(chatId)) ?? nil else { return .refused("Chat not found: \(chatId)") }
		let cov = coverageOf(record.messages, entries: graph.readCoverage(), chatId: chatId)
		if cov.uncovered.isEmpty { return .nothingToDo }
		inFlight.insert(chatId)
		let budget = effective.graph.extractionChunkTokens
		let batches = batchRuns(cov.slots, uncovered: cov.uncovered, budget: budget)
		sourceTasks[chatId] = Task { [weak self] in
			await self?.runChat(chatId, title: record.title, batches: batches)
			await self?.finishSource(chatId)
		}
		return .started
	}

	private func finishSource(_ id: String) {
		inFlight.remove(id)
		sourceTasks[id] = nil
		publish()
	}

	/// End (Background agents) or a session delete: true cancellation — nothing
	/// more merges; merged batches keep their coverage.
	public func abort(_ sourceId: String) -> Bool {
		guard let task = sourceTasks[sourceId] else { return false }
		task.cancel()
		return true
	}

	/// Abort and wait for the run to wind down (before a session delete).
	public func windDown(_ sourceId: String) async {
		guard let task = sourceTasks[sourceId] else { return }
		task.cancel()
		await task.value
	}

	// MARK: The chat pipeline

	private func runChat(_ chatId: String, title: String, batches: [[CoverageSlot]]) async {
		for (index, batch) in batches.enumerated() {
			if Task.isCancelled { break }
			let part = batches.count > 1 ? Part(i: index + 1, n: batches.count) : nil
			let messages = batch.map(\.message)
			let view = proseView(messages, title: title)
			let anchors = batchAnchorIds(messages)
			let coverage = batch.filter { !messageViewLines($0.message, mid: $0.message.id).isEmpty }
			do {
				_ = try await runJob(sourceId: chatId, kind: .chat, label: nil, part: part) { jobKey in
					try await self.pipeline(jobKey: jobKey, sourceId: chatId, notes: false, view: view, anchors: anchors) { tx, foldedAt in
						guard tx.chatExists(chatId) else { throw CancellationError() }
						return MergeSource(foldedAt: foldedAt, coverage: coverage.map { CoverageEntry(chatId: chatId, fp: $0.fp, tokens: $0.tokens, foldedAt: foldedAt) })
					}
				}
			} catch is CancellationError {
				break
			} catch {
				// A failed batch is isolated: its messages stay uncovered.
				continue
			}
		}
	}

	/// extract → (audit lock) audit → merge, one batch.
	private func pipeline(jobKey: String, sourceId: String, notes: Bool, view: String, anchors: Set<String>,
		source: @escaping @Sendable (GraphTransaction, String) throws -> MergeSource) async throws -> EmissionStats
	{
		let s = settings
		let client = MessagesClient(transport: makeTransport(), apiKey: { [keychain] in try keychain.anthropicKey() })
		let extractor = SubagentModel(client: client, spec: resolveRoleSpec(.extractor, record: s, catalog: catalog))
		let auditor = SubagentModel(client: client, spec: resolveRoleSpec(.auditor, record: s, catalog: catalog))

		// Nothing between the slot's acquire and release throws.
		try await extractSlots.acquire()
		setPhase(jobKey, .extracting)
		let g0 = getGraph(graph)
		let existing = Set(g0.nodes.map(\.id))
		let prompt = extractorPrompt(digest: sourceDigest(g0, sourceId: sourceId), view: view)
		let submitFindings = SubmitTool(
			name: "submit_findings",
			description: notes ? GeneratedGraphTools.submitFindingsNotesDescription : GeneratedGraphTools.submitFindingsDescription,
			schema: notes ? GeneratedGraphTools.submitFindingsNotesSchema : GeneratedGraphTools.submitFindingsSchema,
			decode: { decodeFindings($0, notes: notes) },
			validate: { notes ? validateFindingsChains($0, existingIds: existing) : (validateSessionAnchors($0, batchIds: anchors) ?? validateFindingsChains($0, existingIds: existing)) },
			capture: SubmitCapture<SessionFindings>())
		let system = LHResources.promptSegment(notes ? "extraction/notes-extractor.md" : "extraction/extractor.md") ?? ""
		let extracted = await runSubmitAgent(model: extractor, system: system, prompt: prompt, submit: submitFindings)
		record(jobKey, .extractor, extracted.steps)
		await extractSlots.release()
		if extracted.aborted || Task.isCancelled { throw CancellationError() }
		guard let findings = extracted.value else { throw SubagentError(extracted.failure ?? "the extractor never submitted findings") }

		setPhase(jobKey, .waiting)
		try await auditLock.acquire()
		do {
			let stats = try await auditAndMerge(jobKey: jobKey, sourceId: sourceId, findings: findings, auditor: auditor, source: source)
			await auditLock.release()
			return stats
		} catch {
			await auditLock.release()
			throw error
		}
	}

	/// The audit-lock critical section: the identity verdicts, then the merge.
	private func auditAndMerge(jobKey: String, sourceId: String, findings: SessionFindings, auditor: SubagentModel,
		source: @escaping @Sendable (GraphTransaction, String) throws -> MergeSource) async throws -> EmissionStats
	{
		setPhase(jobKey, .auditing)
		let g = getGraph(graph)
		let capture = SubmitCapture<AuditVerdicts>()
		let submit = SubmitTool(name: "submit_review", description: GeneratedGraphTools.submitReviewDescription, schema: GeneratedGraphTools.submitReviewSchema,
			decode: decodeVerdicts, validate: { _ in nil }, capture: capture)
		let database = database
		let tools = auditorGraphTools(GraphToolDeps { GraphDeps(chatStore: ChatRepository(database), graphStore: GraphRepository(database)) })
		let out = await runSubmitAgent(model: auditor, system: LHResources.promptSegment("extraction/auditor.md") ?? "",
			prompt: auditorPrompt(findings, graphNodeCount: g.nodes.count), submit: submit, extraTools: tools, maxTurns: 16)
		record(jobKey, .auditor, out.steps)
		if out.aborted || Task.isCancelled { throw CancellationError() }
		guard let verdicts = out.value else { throw SubagentError(out.failure ?? "the auditor never submitted a review") }

		setPhase(jobKey, .merging)
		let foldedAt = ISOClock.string()
		return try graph.transaction { tx in
			let merge = try source(tx, foldedAt)
			let stats = try mergeFindings(chatId: sourceId, findings: findings, verdicts: verdicts,
				deps: GraphDeps(chatStore: ChatRepository(database), graphStore: tx), source: merge)
			try settleGraphLayout(tx)
			return stats
		}
	}

	// MARK: Jobs, phases, usage

	private enum Stage { case extractor, auditor }

	/// One registered batch job: its row, then its usage persisted on exit (success or failure).
	private func runJob(sourceId: String, kind: SourceKind, label: String?, part: Part?,
		_ body: @escaping (String) async throws -> EmissionStats) async throws -> EmissionStats
	{
		let jobKey = part.map { "\(sourceId)#\($0.i)" } ?? sourceId
		lastStartedAt = max(MessageID.nowMillis(), lastStartedAt + 1)
		rows[jobKey] = Row(id: jobKey, sourceId: sourceId, kind: kind, label: label, part: part, phase: .queued, startedAt: lastStartedAt)
		publish()
		let t0 = ContinuousClock.now
		defer {
			rows[jobKey] = nil
			publish()
		}
		do {
			let stats = try await body(jobKey)
			persistUsage(jobKey, since: t0, stats: stats)
			return stats
		} catch {
			persistUsage(jobKey, since: t0, stats: nil)
			throw error
		}
	}

	private func setPhase(_ jobKey: String, _ phase: Phase) {
		rows[jobKey]?.phase = phase
		publish()
	}

	private func record(_ jobKey: String, _ stage: Stage, _ steps: [UsageStepRecord]) {
		guard var row = rows[jobKey], let model = steps.first?.model else { return }
		var usage = (stage == .extractor ? row.extractor : row.auditor) ?? ExtractionStageUsage(model: model, steps: [])
		usage.steps += steps.map(\.usage)
		if stage == .extractor { row.extractor = usage } else { row.auditor = usage }
		rows[jobKey] = row
		publish()
	}

	private func persistUsage(_ jobKey: String, since t0: ContinuousClock.Instant, stats: EmissionStats?) {
		guard let row = rows[jobKey] else { return }
		let elapsed = ContinuousClock.now - t0
		let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
		let run = ExtractionRunUsage(startedAt: row.startedAt, at: ISOClock.string(), durationMs: ms, stats: stats,
			stages: .init(extractor: row.extractor ?? ExtractionStageUsage(model: "unknown", steps: []),
				auditor: row.auditor ?? ExtractionStageUsage(model: "unknown", steps: [])))
		switch row.kind {
		case .chat:
			guard ((try? chats.get(row.sourceId)) ?? nil) != nil else { return }
			try? chats.appendExtractionUsage(run, chatId: row.sourceId)
		case .notes:
			try? graph.appendSourceUsage(run, sourceId: row.sourceId)
		}
	}

	// MARK: Notes import

	/// The import (app/api/graph/import): three files at a time, each file's
	/// chunks in order. Works whatever the Extraction switch says (your answer).
	public func importNotes(_ files: [NotesFile]) async -> [NotesResult] {
		var results = [NotesResult?](repeating: nil, count: files.count)
		await withTaskGroup(of: (Int, NotesResult).self) { group in
			var next = 0
			func add() {
				guard next < files.count else { return }
				let i = next, file = files[i]
				next += 1
				group.addTask { (i, await self.importOne(file)) }
			}
			for _ in 0..<min(3, files.count) { add() }
			for await (i, r) in group {
				results[i] = r
				add()
			}
		}
		return results.compactMap { $0 }
	}

	private func importOne(_ file: NotesFile) async -> NotesResult {
		let id = notesSourceId(path: file.path)
		let empty = EmissionStats(nodes: 0, chains: 0)
		if inFlight.contains(id) { return NotesResult(path: file.path, outcome: .busy, stats: empty, error: "This file is already being imported. Try again when it finishes.") }
		guard (try? keychain.anthropicKey()) ?? nil != nil else { return NotesResult(path: file.path, outcome: .failed, stats: empty, error: "No Anthropic key") }
		inFlight.insert(id)
		defer { inFlight.remove(id); publish() }
		let importedAt = ISOClock.string()
		do { try graph.upsertSource(NotesSource(id: id, filePath: file.path, importedAt: importedAt)) } catch {
			return NotesResult(path: file.path, outcome: .failed, stats: empty, error: "\(error)")
		}
		let chunks = chunkNotes(file.text, budget: effective.graph.extractionChunkTokens)
		var merged = EmissionStats(nodes: 0, chains: 0)
		var fulfilled = 0, errors: [String] = [], aborted = false
		for (index, chunk) in chunks.enumerated() {
			let part = chunks.count > 1 ? Part(i: index + 1, n: chunks.count) : nil
			let view = notesView(filePath: file.path, text: chunk, part: part.map { ($0.i, $0.n) })
			do {
				let stats = try await runJob(sourceId: id, kind: .notes, label: file.path, part: part) { jobKey in
					try await self.pipeline(jobKey: jobKey, sourceId: id, notes: true, view: view, anchors: []) { _, _ in MergeSource(foldedAt: importedAt) }
				}
				merged.nodes += stats.nodes
				merged.chains = (merged.chains ?? 0) + (stats.chains ?? 0)
				if let d = stats.droppedChains { merged.droppedChains = (merged.droppedChains ?? 0) + d }
				fulfilled += 1
			} catch is CancellationError {
				aborted = true
				break
			} catch {
				errors.append("\(error)")
			}
		}
		if fulfilled == chunks.count { return NotesResult(path: file.path, outcome: .completed, stats: merged, error: nil) }
		let outcome: NotesResult.Outcome = aborted ? .aborted : fulfilled > 0 ? .partial : .failed
		return NotesResult(path: file.path, outcome: outcome, stats: merged, error: errors.isEmpty ? (aborted ? "aborted" : "Notes import did not complete") : errors.joined(separator: "; "))
	}
}

/// A FIFO, cancellation-aware counting semaphore.
actor AsyncLimiter {
	private var available: Int
	private var waiters: [(id: UUID, c: CheckedContinuation<Void, Error>)] = []
	private var holders = 0

	init(_ permits: Int) { available = permits }

	func acquire() async throws {
		try Task.checkCancellation()
		if available > 0, waiters.isEmpty {
			available -= 1
			holders += 1
			return
		}
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in waiters.append((id, c)) }
		} onCancel: {
			Task { await self.cancel(id) }
		}
		holders += 1
	}

	private func cancel(_ id: UUID) {
		guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
		waiters.remove(at: i).c.resume(throwing: CancellationError())
	}

	func release() {
		guard holders > 0 else { return }
		holders -= 1
		if waiters.isEmpty { available += 1 } else { waiters.removeFirst().c.resume() }
	}
}
