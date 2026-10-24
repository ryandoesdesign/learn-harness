import Foundation
import LHAnthropic
import LHCore

/// The steering queue for one chat: composer steers and wake deliveries
/// wait here and enter at the next turn boundary.
public actor SteeringQueue: SteeringSource {
	private var queued: [Message] = []
	public init() {}
	public func push(_ m: Message) { queued.append(m) }
	public func drain() -> [Message] {
		defer { queued.removeAll() }
		return queued
	}
	public var count: Int { queued.count }
}

/// One chat's live engine: owns the running turn, its steering queue and
/// abort, and fans the turn's events out to any number of views (each
/// subscriber first replays the settled events, then follows live).
public actor SessionEngine {
	public let chatId: String
	public let steering = SteeringQueue()
	private var running: Task<TurnOutcome, Never>?
	private var log: [AgentEvent] = []
	private var subscribers: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

	public init(chatId: String) { self.chatId = chatId }

	public var isRunning: Bool { running != nil }

	public enum StartError: Error, Equatable { case turnAlreadyRunning }

	/// Start a turn (one per chat, ever). Returns the outcome when it settles.
	@discardableResult
	public func start(_ loop: AgentLoop, history: [Message], inputs: [Message] = []) throws -> Task<TurnOutcome, Never> {
		guard running == nil else { throw StartError.turnAlreadyRunning }
		log.removeAll()
		let steering = steering
		// Events funnel through one ordered stream into the actor (a Task per
		// event would not preserve order).
		let (events, sink) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
		let task = Task {
			let outcome = await loop.run(history: history, inputs: inputs, steering: steering) { sink.yield($0) }
			sink.finish()
			return outcome
		}
		running = task
		Task { [weak self] in
			for await event in events { await self?.publish(event) }
			await self?.settled()
		}
		return task
	}

	/// The remote kill: cancels the turn; the loop records the partial as aborted.
	public func abort() { running?.cancel() }

	public func steer(_ m: Message) async { await steering.push(m) }

	/// A view onto the current turn: replay, then live, ending at agentEnd.
	public func subscribe() -> AsyncStream<AgentEvent> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
		for e in log { continuation.yield(e) }
		if running == nil, !log.isEmpty {
			continuation.finish()
			return stream
		}
		subscribers[id] = continuation
		continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
		return stream
	}

	private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

	private func publish(_ event: AgentEvent) {
		// The log keeps settled events plus only the latest snapshot.
		if case .messageUpdate = event, case .messageUpdate? = log.last { log[log.count - 1] = event } else { log.append(event) }
		for c in subscribers.values { c.yield(event) }
		if case .agentEnd = event {
			for c in subscribers.values { c.finish() }
			subscribers.removeAll()
		}
	}

	private func settled() { running = nil }
}

/// Holds one SessionEngine per chat; the single entry point the app uses.
public actor TurnCoordinator {
	private var engines: [String: SessionEngine] = [:]
	public init() {}

	public func engine(for chatId: String) -> SessionEngine {
		if let e = engines[chatId] { return e }
		let e = SessionEngine(chatId: chatId)
		engines[chatId] = e
		return e
	}

	public func isRunning(_ chatId: String) async -> Bool {
		guard let e = engines[chatId] else { return false }
		return await e.isRunning
	}

	public func abort(_ chatId: String) async { await engines[chatId]?.abort() }
}
