import Foundation
import LHAnthropic
import LHCore
import LHStore

/// The live teaching session service (docs/native-macos-m5.md) — the port of
/// server/chat-handler.ts, turn-service.ts, turn-liveness.ts and the parts
/// of jobs.ts that carry user steers and the probe handoff, over the M3
/// TurnCoordinator/SessionEngine. One per app.
///
/// Persistence (your answer): the input's appends are written ahead; then
/// every settled message (assistant step, tool result, delivered steer) is
/// appended as it completes; usage and plan blocks are written at settle.
public actor TurnService {
	public enum Refusal: Error, Sendable, Hashable, CustomStringConvertible {
		case noChat
		/// No Anthropic key (the UI's "Add a key" pill keeps the draft).
		case noKey
		/// The input targets nothing it can apply to (TS 400).
		case invalid(String)
		/// One turn per chat (TS 409).
		case turnRunning

		public var description: String {
			switch self {
			case .noChat: "Unknown chat"
			case .noKey: "No Anthropic key"
			case .invalid(let m): m
			case .turnRunning: "A turn is already running for this session"
			}
		}
	}

	public enum SendResult: Sendable, Hashable {
		/// A turn started.
		case started
		/// Saved without a turn (an answer that leaves a sibling question open).
		case saved
	}

	public enum SteerResult: Sendable, Hashable {
		/// Queued into the running turn (it lands at the next boundary).
		case queued(id: String)
		/// No turn was running — sent as a plain message.
		case sent
	}

	/// Session-level notifications (the TS server-event bus).
	public enum Event: Sendable, Hashable {
		case turnStarted(chatId: String)
		case turnSettled(chatId: String)
		case compaction(chatId: String, running: Bool)
		/// A turn's request failed before the model (no key, …) — UI copy.
		case error(chatId: String, message: String)
	}

	let database: AppDatabase
	let keychain: any KeychainStore
	let catalog: ModelCatalog
	let makeTransport: @Sendable () -> any AnthropicTransport
	public let coordinator = TurnCoordinator()
	let compaction: CompactionService

	private var parkedDismissals: [String: (toolCallId: String, answer: QuestionAnswerData)] = [:]
	private var handoffQueued: Set<String> = []
	private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
	private var running: Set<String> = []

	public init(database: AppDatabase, keychain: any KeychainStore, catalog: ModelCatalog,
		makeTransport: @escaping @Sendable () -> any AnthropicTransport = { URLSessionTransport() },
		summarizer: CompactionService.Summarizer? = nil)
	{
		self.database = database
		self.keychain = keychain
		self.catalog = catalog
		self.makeTransport = makeTransport
		let client = MessagesClient(transport: makeTransport(), apiKey: { try keychain.anthropicKey() })
		let relay = CompactionRelay()
		compaction = CompactionService(database: database, summarize: summarizer ?? CompactionService.summarizer(client: client)) { chatId, running in
			relay.fire(chatId, running)
		}
		relay.target = { [weak self] chatId, running in
			Task { await self?.broadcast(.compaction(chatId: chatId, running: running)) }
		}
	}

	// MARK: - Observation

	public func events() -> AsyncStream<Event> {
		let id = UUID()
		let (stream, c) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
		subscribers[id] = c
		c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
		return stream
	}

	private func drop(_ id: UUID) { subscribers[id] = nil }

	private func broadcast(_ e: Event) {
		for c in subscribers.values { c.yield(e) }
	}

	/// The running turn's live events (replay + follow), or nil when idle.
	public func live(_ chatId: String) async -> AsyncStream<AgentEvent>? {
		guard running.contains(chatId) else { return nil }
		return await coordinator.engine(for: chatId).subscribe()
	}

	public func isRunning(_ chatId: String) -> Bool { running.contains(chatId) }
	public func isCompacting(_ chatId: String) async -> Bool { await compaction.isRunning(chatId) }

	// MARK: - Inputs

	/// A learner input that may start a turn (chat-handler handleChatInput).
	@discardableResult
	public func send(_ chatId: String, _ input: ChatInput) async throws(Refusal) -> SendResult {
		let repo = ChatRepository(database)
		guard var record = (try? repo.get(chatId)) ?? nil else { throw .noChat }
		guard ((try? keychain.anthropicKey()) ?? nil) != nil else { throw .noKey }

		// The compaction gate, then read the record again.
		await compaction.ensureCompacted(chatId, deps: compactionDeps(record))
		record = (try? repo.get(chatId) ?? record) ?? record

		let appends: [Message]
		do {
			appends = try inputAppends(record.messages, kind: record.kind, input)
		} catch {
			throw .invalid(error.message)
		}

		// The parallel-question gate: an answer that leaves a sibling question
		// open is saved; the LAST answer fires the one reaction turn.
		if case .answer = input, danglingQuestionOf(record.messages + appends) != nil {
			try? repo.append(appends, to: chatId)
			return .saved
		}
		guard !running.contains(chatId) else { throw .turnRunning }

		// Write-ahead.
		try? repo.append(appends, to: chatId)
		await startTurn(chatId)
		return .started
	}

	/// A message sent while a turn runs: persisted pending in the outbox and
	/// handed to the running loop. With no turn running it is a plain send.
	public func steer(_ chatId: String, text: String) async throws(Refusal) -> SteerResult {
		guard running.contains(chatId) else {
			try await send(chatId, .text(text))
			return .sent
		}
		let message = newUserSteer(text, id: "steer_\(MessageID.mint())")
		try? SteerOutboxRepository(database).enqueue(message, chatId: chatId)
		await handOff(chatId, [message])
		return .queued(id: message.id)
	}

	/// The pending steers not yet in the record (the UI's queued lines).
	public func queuedSteers(_ chatId: String) -> [Message] {
		let outbox = SteerOutboxRepository(database)
		return ((try? outbox.steers(chatId: chatId, state: .pending)) ?? []) + ((try? outbox.steers(chatId: chatId, state: .handed)) ?? [])
	}

	/// Dismiss the open question (no turn). Mid-turn it is parked and applied
	/// at settle (dismissal-park.ts).
	public func dismiss(_ chatId: String, toolCallId: String, answer: QuestionAnswerData) throws(Refusal) {
		if running.contains(chatId) {
			parkedDismissals[chatId] = (toolCallId, answer)
			return
		}
		let repo = ChatRepository(database)
		guard let record = (try? repo.get(chatId)) ?? nil else { throw .noChat }
		do {
			let appends = try dismissAppends(record.messages, .dismiss(toolCallId: toolCallId, answer: answer))
			try? repo.append(appends, to: chatId)
		} catch {
			throw .invalid(error.message)
		}
	}

	/// The remote kill: the partial is recorded as aborted.
	public func abort(_ chatId: String) async {
		await coordinator.abort(chatId)
	}

	// MARK: - Resume and launch recovery

	/// Resume on open (your answer): an idle session whose record ends in
	/// learner text, an answer, an undelivered wake marker, or that has
	/// pending steers starts its turn — unless a question is open or the
	/// record ends in a dismissal.
	public func resumeIfNeeded(_ chatId: String) async {
		guard !running.contains(chatId), let record = (try? ChatRepository(database).get(chatId)) ?? nil else { return }
		guard ((try? keychain.anthropicKey()) ?? nil) != nil else { return }
		let messages = record.messages
		guard danglingQuestionOf(messages) == nil, !endsInDismissal(messages) else { return }
		let pending = ((try? SteerOutboxRepository(database).steers(chatId: chatId, state: .pending)) ?? []).isEmpty == false
		if Self.owesTurn(messages) || pending {
			await startTurn(chatId)
		}
	}

	/// Does the record end where the agent owes a turn?
	public static func owesTurn(_ messages: [Message]) -> Bool {
		guard let last = messages.last else { return false }
		if needsContinuation(messages) { return true }
		switch last.body {
		case .user: return true
		case .marker(let m): return m.kind == .probeHandoff || m.kind == .subagentSteer || m.kind == .subagentAbort
		default: return false
		}
	}

	/// At launch: handed steers whose message never landed go back to pending.
	public func recoverOnLaunch() {
		try? SteerOutboxRepository(database).recover()
	}

	// MARK: - The turn

	private func startTurn(_ chatId: String) async {
		let repo = ChatRepository(database)
		guard let record = (try? repo.get(chatId)) ?? nil else { return }
		let engine = await coordinator.engine(for: chatId)
		let config = agentConfig(record)
		let client = MessagesClient(transport: makeTransport(), apiKey: { [keychain] in try keychain.anthropicKey() })
		let loop = AgentLoop(client: client, config: config)

		// Pending steers (the outbox) ride this turn: handed to the loop,
		// which delivers them before its first call.
		let pending = (try? SteerOutboxRepository(database).steers(chatId: chatId, state: .pending)) ?? []
		do {
			try await engine.start(loop, history: record.messages)
		} catch {
			return
		}
		running.insert(chatId)
		broadcast(.turnStarted(chatId: chatId))
		if !pending.isEmpty { await handOff(chatId, pending) }
		let events = await engine.subscribe()
		Task { await self.follow(chatId, events: events) }
	}

	private func handOff(_ chatId: String, _ steers: [Message]) async {
		let engine = await coordinator.engine(for: chatId)
		for s in steers { await engine.steer(s) }
		try? SteerOutboxRepository(database).mark(steers.map(\.id), .handed)
	}

	/// Persist settled messages as they complete, then settle.
	private func follow(_ chatId: String, events: AsyncStream<AgentEvent>) async {
		let repo = ChatRepository(database)
		let outbox = SteerOutboxRepository(database)
		for await event in events {
			switch event {
			case .settled(let m):
				try? repo.append([m], to: chatId)
				if m.id.hasPrefix("steer_") { try? outbox.mark([m.id], .delivered) }
			case .agentEnd(let outcome):
				await settle(chatId, outcome)
			default:
				break
			}
		}
	}

	/// The settle sequence (onFinish): usage, plan blocks, parked dismissal,
	/// end + notify, compaction kick, then the handoff wake / pending steers.
	private func settle(_ chatId: String, _ outcome: TurnOutcome) async {
		let repo = ChatRepository(database)
		if !outcome.steps.isEmpty, let first = outcome.newMessages.first(where: { $0.assistant != nil }) {
			try? repo.appendTurnUsage(TurnUsage(id: UUID().uuidString.lowercased(), messageId: first.id, at: ISOClock.string(Date()),
				model: outcome.model, steps: outcome.steps.map(\.usage)), chatId: chatId)
		}
		if let record = (try? repo.get(chatId)) ?? nil {
			let blocks = planBlocksFor(record: record.messages, newMessages: outcome.newMessages, tree: record.tree, transcript: record.messages)
			try? repo.append(blocks, to: chatId)
		}
		if let parked = parkedDismissals.removeValue(forKey: chatId), let record = (try? repo.get(chatId)) ?? nil,
		   let appends = try? dismissAppends(record.messages, .dismiss(toolCallId: parked.toolCallId, answer: parked.answer))
		{
			try? repo.append(appends, to: chatId)
		}
		// Steers the loop never drained (a question stop, an abort) leave the
		// engine's queue and go back to pending — the outbox re-hands them.
		_ = await coordinator.engine(for: chatId).steering.drain()
		let outbox = SteerOutboxRepository(database)
		try? outbox.mark(((try? outbox.steers(chatId: chatId, state: .handed)) ?? []).map(\.id), .pending)

		running.remove(chatId)
		broadcast(.turnSettled(chatId: chatId))
		if let record = (try? repo.get(chatId)) ?? nil { await compaction.kick(chatId, deps: compactionDeps(record)) }

		// The handoff wake: the teacher's first turn (its marker written ahead).
		if handoffQueued.remove(chatId) != nil, let record = (try? repo.get(chatId)) ?? nil {
			let handoff = newHandoffMessage(chatId: chatId)
			if !steerDelivered(record.messages, steerId: handoff.id) { try? repo.append([handoff], to: chatId) }
			if danglingQuestionOf(record.messages) == nil {
				await startTurn(chatId)
				return
			}
		}
		// Pending steers start the next turn — unless a question is open (they
		// ride the answer turn) or the learner aborted (they ride the next send).
		if !outcome.aborted, let record = (try? repo.get(chatId)) ?? nil, danglingQuestionOf(record.messages) == nil,
		   !((try? outbox.steers(chatId: chatId, state: .pending)) ?? []).isEmpty
		{
			await startTurn(chatId)
		}
	}

	// MARK: - Agent construction

	/// The prober or teacher config for this record (teacher-agent.ts).
	func agentConfig(_ record: ChatRecord) -> AgentConfig {
		let settings = (try? SettingsRepository(database).read()) ?? nil
		let spec = conversationSpec(record, settings)
		let teaching = hasProbeDone(record.messages)
		let ctx = TeachingContext(
			chatId: record.id,
			record: { [database] in (try? ChatRepository(database).get(record.id)) ?? nil },
			saveTree: { [database] tree in try ChatRepository(database).saveTree(tree, chatId: record.id) },
			queueHandoff: { [weak self] in await self?.queueHandoff(record.id) })
		let enabled = settings?.agent?.tools
		let tools = teaching ? teacherTools(ctx, enabled: enabled) : proberTools(ctx, enabled: enabled)
		let system = composer(settings).compose(teaching ? .teacher : .prober, tools: Set(tools.map(\.name)))
		let maxTokens = min(64_000, catalog.model(spec.model)?.maxTokens ?? 64_000)
		return AgentConfig(
			model: spec.model, effort: spec.effort, system: system, tools: tools,
			thinkingDisplay: .summarized, cacheTTL: .oneHour, maxTokens: maxTokens,
			projection: WireProjection.Options(stripProberThinking: teaching), chatId: record.id,
			shouldStop: questionStopper)
	}

	func queueHandoff(_ chatId: String) { handoffQueued.insert(chatId) }

	func conversationSpec(_ record: ChatRecord, _ settings: UserSettings?) -> EffectiveModelSpec {
		resolveConversationSpec(record.settings, strong: settings?.models?.strong, catalog: catalog)
	}

	func composer(_ settings: UserSettings?) -> PromptComposer {
		let repo = PromptOverrideRepository(database)
		var overrides: [String: String] = [:]
		for path in (try? repo.list()) ?? [] { overrides[path] = (try? repo.read(path)) ?? nil }
		return PromptComposer(overrides: overrides, switches: settings?.agent?.prompts ?? [:])
	}

	/// The compaction inputs for the agent that will actually run (a TS fix:
	/// the prober's estimate used the teacher's prompt).
	func compactionDeps(_ record: ChatRecord) -> CompactionService.Deps {
		let settings = (try? SettingsRepository(database).read()) ?? nil
		let spec = conversationSpec(record, settings)
		let teaching = hasProbeDone(record.messages)
		let system = agentConfig(record).system ?? ""
		return CompactionService.Deps(
			spec: spec,
			kind: record.kind == .practice ? .practice : teaching ? .teach : .probe,
			thresholdTokens: CompactionService.effectiveThreshold(setting: settings?.compaction?.thresholdTokens, contextWindow: catalog.contextWindow(spec.model)),
			systemPromptTokens: system.jsLength / 4)
	}
}

/// The question stopper (teacher-agent.ts makeQuestionStopper): end the run
/// when every question call in the message resolved cleanly.
let questionStopper: @Sendable (Message, [(ToolUse, ToolOutput)]) -> Bool = { assistant, results in
	let called = Set((assistant.assistant?.toolUses ?? []).filter { QUESTION_TOOLS.contains($0.name) }.map(\.id))
	guard !called.isEmpty else { return false }
	return !results.contains { called.contains($0.0.id) && $0.1.isError }
}

/// Carries compaction notifications back to the service once it exists.
final class CompactionRelay: @unchecked Sendable {
	private let lock = NSLock()
	private var _target: (@Sendable (String, Bool) -> Void)?
	var target: (@Sendable (String, Bool) -> Void)? {
		get { lock.withLock { _target } }
		set { lock.withLock { _target = newValue } }
	}
	func fire(_ chatId: String, _ running: Bool) { target?(chatId, running) }
}
