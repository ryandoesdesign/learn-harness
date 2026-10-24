import Foundation
import LHAnthropic
import LHCore

/// What a running turn publishes (pi's AgentEvent taxonomy, as the app used it).
public enum AgentEvent: Sendable {
	/// A message entered the turn (inputs, steers, the streaming assistant, tool results).
	case messageStart(Message)
	/// The streaming assistant message's latest full snapshot (coalesced ≈30 Hz).
	case messageUpdate(Message)
	case messageEnd(Message)
	/// A message the record keeps (everything but the in-memory question
	/// placeholders), in order — the per-message persistence seam.
	case settled(Message)
	case toolStart(toolCallId: String, name: String, input: JSONValue)
	case toolEnd(toolCallId: String, output: ToolOutput)
	case retrying(attempt: Int, delay: Duration, reason: String)
	/// The API dropped or flagged thinking blocks (`input_transformations`).
	case inputTransformations([JSONValue])
	case turnEnd
	case agentEnd(TurnOutcome)
}

/// One model call's usage, ready for the money channel.
public struct UsageStepRecord: Sendable, Hashable {
	public var model: String
	public var usage: CallUsage
	public var fallbackFrom: String?
}

/// The settled turn.
public struct TurnOutcome: Sendable {
	/// Every message the turn added, in order — persistable (ephemeral
	/// question placeholders already removed).
	public var newMessages: [Message]
	public var steps: [UsageStepRecord]
	public var aborted: Bool
	/// The served-by model of the last call (a fallback model after a switch).
	public var model: String
}

/// The per-agent configuration (the conversation agents and sub-agents
/// differ only in these values).
public struct AgentConfig: Sendable {
	public var model: String
	public var effort: Effort
	public var system: String?
	public var tools: [any AgentTool]
	public var serverTools: [ToolDefinition]
	public var thinkingDisplay: MessagesRequest.ThinkingDisplay
	public var cacheTTL: MessagesRequest.CacheTTL
	public var maxTokens: Int
	public var projection: WireProjection.Options
	public var chatId: String?
	public var toolTimeout: Duration
	/// Coalescing window for streaming snapshots.
	public var updateInterval: Duration
	/// The sub-agent turn budget (pi-run maxTurns): the run ends after this
	/// many assistant messages. nil = unbounded (the conversation agents).
	public var maxTurns: Int?
	/// pi's shouldStopAfterTurn (the question stopper): true ends the run
	/// after this message's tools — WITHOUT draining steers, which wait for
	/// the next run (a posed question must always end the turn).
	public var shouldStop: (@Sendable (_ assistant: Message, _ results: [(ToolUse, ToolOutput)]) -> Bool)?

	public init(model: String, effort: Effort, system: String? = nil, tools: [any AgentTool] = [], serverTools: [ToolDefinition] = [],
		thinkingDisplay: MessagesRequest.ThinkingDisplay = .summarized, cacheTTL: MessagesRequest.CacheTTL = .fiveMinutes,
		maxTokens: Int = 64_000, projection: WireProjection.Options = WireProjection.Options(), chatId: String? = nil,
		toolTimeout: Duration = ToolGuard.defaultTimeout, updateInterval: Duration = .milliseconds(33),
		shouldStop: (@Sendable (_ assistant: Message, _ results: [(ToolUse, ToolOutput)]) -> Bool)? = nil)
	{
		self.model = model
		self.effort = effort
		self.system = system
		self.tools = tools
		self.serverTools = serverTools
		self.thinkingDisplay = thinkingDisplay
		self.cacheTTL = cacheTTL
		self.maxTokens = maxTokens
		self.projection = projection
		self.chatId = chatId
		self.toolTimeout = toolTimeout
		self.updateInterval = updateInterval
		self.shouldStop = shouldStop
		maxTurns = nil
	}

	/// The request for a context (fixed tool order: client tools, then server tools).
	func request(for context: [Message]) -> MessagesRequest {
		MessagesRequest(
			model: model, maxTokens: maxTokens, system: system, messages: WireProjection.project(context, options: projection),
			tools: tools.map(\.definition) + serverTools, effort: effort, thinkingDisplay: thinkingDisplay, cacheTTL: cacheTTL)
	}
}

/// Steering delivery: polled at each turn boundary.
public protocol SteeringSource: Sendable {
	func drain() async -> [Message]
}

/// The agent loop (a port of how pi-agent-core's runLoop is used —
/// docs/native-macos-m3.md "Agent loop"):
///
/// 1. stream one assistant message;
/// 2. run its client tools in parallel (each under ToolGuard);
/// 3. return every result in one user message (adjacent records);
/// 4. stop when every call in the batch terminates, unless steers wait;
/// 5. poll steering at each turn boundary;
/// 6. abort = Task cancellation, recorded as stopReason "aborted".
public struct AgentLoop: Sendable {
	public let client: MessagesClient
	public let config: AgentConfig
	public var now: @Sendable () -> Int = { MessageID.nowMillis() }
	public var mintId: @Sendable () -> String = { MessageID.mint() }

	public init(client: MessagesClient, config: AgentConfig) {
		self.client = client
		self.config = config
	}

	public static func truncatedCallText(_ name: String) -> String {
		"Tool call \"\(name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
	}

	/// Run one turn over `history` plus `inputs` (appended first, as the
	/// write-ahead inputs). Never throws: provider and loop failures settle
	/// as an `error` assistant message, cancellation as `aborted`.
	public func run(history: [Message], inputs: [Message] = [], steering: (any SteeringSource)? = nil, emit: @escaping @Sendable (AgentEvent) -> Void) async -> TurnOutcome {
		var context = history
		var added: [Message] = []
		var ephemeral = Set<String>()
		var steps: [UsageStepRecord] = []
		var servedBy = config.model
		var aborted = false

		func append(_ m: Message, ephemeral isEphemeral: Bool = false) {
			context.append(m)
			added.append(m)
			emit(.messageStart(m))
			emit(.messageEnd(m))
			if !isEphemeral { emit(.settled(m)) }
		}

		for m in inputs { append(m) }
		var pending = await steering?.drain() ?? []

		turns: while true {
			for m in pending { append(m) }
			pending = []
			if Task.isCancelled {
				aborted = true
				break
			}

			// 1. Stream the assistant message (pause_turn re-sends within the turn).
			let response: AssistantResponse
			let messageId = mintId()
			switch await streamOne(context: context, messageId: messageId, emit: emit) {
			case .completed(let r):
				response = r
			case .failed(let partial, let message):
				let m = assistantMessage(partial, id: messageId, stopReason: "error", errorMessage: message)
				append(m)
				steps += usageSteps(partial)
				break turns
			case .cancelled(let partial):
				let m = assistantMessage(partial, id: messageId, stopReason: "aborted", errorMessage: nil)
				append(m)
				steps += usageSteps(partial)
				aborted = true
				break turns
			}
			steps += usageSteps(response)
			servedBy = response.model
			if !response.inputTransformations.isEmpty { emit(.inputTransformations(response.inputTransformations)) }
			let assistant = assistantMessage(response, id: messageId, stopReason: response.stopReason ?? "end_turn", errorMessage: nil)
			append(assistant)

			if response.stopReason == "pause_turn" { continue turns }
			if response.stopReason == "refusal" { break turns }

			// 2. Client tools.
			let calls = assistant.assistant?.toolUses ?? []
			var terminate = false
			if !calls.isEmpty {
				let outputs: [(ToolUse, ToolOutput)]
				if response.stopReason == "max_tokens" {
					outputs = calls.map { ($0, .error(Self.truncatedCallText($0.name))) }
					for (call, out) in outputs {
						emit(.toolStart(toolCallId: call.id, name: call.name, input: call.input))
						emit(.toolEnd(toolCallId: call.id, output: out))
					}
				} else {
					outputs = await executeAll(calls, response: response, emit: emit)
				}
				// 3. Results, adjacent to their calls.
				for (call, out) in outputs {
					let result = Message(id: mintId(), timestamp: now(), body: .toolResult(ToolResultBody(
						toolUseId: call.id, toolName: call.name, content: out.content, isError: out.isError, details: out.details)))
					if out.ephemeral { ephemeral.insert(result.id) }
					append(result, ephemeral: out.ephemeral)
				}
				// 4. Terminate only when every call in the batch terminates.
				terminate = response.stopReason != "max_tokens" && outputs.allSatisfy { $0.1.terminate }
				if Task.isCancelled {
					aborted = true
					break turns
				}
				// The stopper ends the run before steering drains (steers wait).
				if let shouldStop = config.shouldStop, shouldStop(assistant, outputs) {
					emit(.turnEnd)
					break turns
				}
			}
			emit(.turnEnd)

			if let maxTurns = config.maxTurns, added.filter({ $0.assistant != nil }).count >= maxTurns {
				emit(.turnEnd)
				break turns
			}

			// 5. Steering at the boundary.
			pending = await steering?.drain() ?? []
			let moreTools = !calls.isEmpty && !terminate
			if !moreTools && pending.isEmpty { break turns }
		}

		let outcome = TurnOutcome(newMessages: added.filter { !ephemeral.contains($0.id) }, steps: steps, aborted: aborted, model: servedBy)
		emit(.agentEnd(outcome))
		return outcome
	}

	// MARK: Streaming

	enum StreamResult {
		case completed(AssistantResponse)
		case failed(AssistantResponse, String)
		case cancelled(AssistantResponse)
	}

	func streamOne(context: [Message], messageId: String, emit: @escaping @Sendable (AgentEvent) -> Void) async -> StreamResult {
		var acc = MessageAccumulator(model: config.model)
		let started = now()
		var lastEmit = ContinuousClock.now
		var dirty = false
		var startedEmitted = false
		do {
			for try await item in client.stream(config.request(for: context)) {
				switch item {
				case .retrying(let attempt, let delay, let reason):
					emit(.retrying(attempt: attempt, delay: delay, reason: reason))
				case .event(let event):
					acc.apply(event)
					if !startedEmitted {
						startedEmitted = true
						emit(.messageStart(snapshot(acc.response, id: messageId, timestamp: started)))
					}
					dirty = true
					if ContinuousClock.now - lastEmit >= config.updateInterval {
						emit(.messageUpdate(snapshot(acc.response, id: messageId, timestamp: started)))
						lastEmit = .now
						dirty = false
					}
				}
			}
			if dirty { emit(.messageUpdate(snapshot(acc.response, id: messageId, timestamp: started))) }
			if Task.isCancelled { return .cancelled(acc.response) }
			return .completed(acc.response)
		} catch is CancellationError {
			return .cancelled(acc.response)
		} catch {
			if Task.isCancelled { return .cancelled(acc.response) }
			return .failed(acc.response, Self.describe(error))
		}
	}

	static func describe(_ error: Error) -> String {
		if let e = error as? AnthropicError { return e.message }
		if let e = error as? URLError { return e.localizedDescription }
		return "\(error)"
	}

	func snapshot(_ r: AssistantResponse, id: String, timestamp: Int) -> Message {
		Message(id: id, timestamp: timestamp, body: .assistant(AssistantBody(
			content: r.content.filter { !$0.isNull }.map(Block.init(raw:)), model: r.model, stopReason: r.stopReason ?? "streaming", usage: r.messageUsage)))
	}

	func assistantMessage(_ r: AssistantResponse, id: String, stopReason: String, errorMessage: String?) -> Message {
		Message(id: id, timestamp: now(), body: .assistant(AssistantBody(
			content: r.content.filter { !$0.isNull }.map(Block.init(raw:)), model: r.model, stopReason: stopReason,
			usage: r.messageUsage, errorMessage: errorMessage, stopDetails: r.stopDetails)))
	}

	func usageSteps(_ r: AssistantResponse) -> [UsageStepRecord] {
		guard r.usage.objectValue?.isEmpty == false else { return [] }
		return r.callUsages.map { UsageStepRecord(model: $0.model ?? r.model, usage: $0.usage, fallbackFrom: $0.fallbackFrom) }
	}

	// MARK: Tools

	func executeAll(_ calls: [ToolUse], response: AssistantResponse, emit: @escaping @Sendable (AgentEvent) -> Void) async -> [(ToolUse, ToolOutput)] {
		let toolsByName = Dictionary(config.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
		// Which content index each call came from (invalid streamed JSON is keyed by index).
		let invalid: [String: String] = Dictionary(uniqueKeysWithValues: response.invalidToolInput.compactMap { (index, raw) in
			response.content[index]["id"]?.stringValue.map { ($0, raw) }
		})
		for call in calls { emit(.toolStart(toolCallId: call.id, name: call.name, input: call.input)) }
		let timeout = config.toolTimeout
		let chatId = config.chatId
		// pi executionMode "sequential": any sequential tool in the batch runs
		// the whole batch in call order (parallel questions resolve in order).
		if calls.contains(where: { toolsByName[$0.name]?.sequential == true }) {
			var out: [(ToolUse, ToolOutput)] = []
			for call in calls {
				let o = await Self.execute(call, tool: toolsByName[call.name], invalidJSON: invalid[call.id], timeout: timeout, chatId: chatId)
				emit(.toolEnd(toolCallId: call.id, output: o))
				out.append((call, o))
			}
			return out
		}
		let results = await withTaskGroup(of: (Int, ToolOutput).self) { group in
			for (i, call) in calls.enumerated() {
				group.addTask {
					(i, await Self.execute(call, tool: toolsByName[call.name], invalidJSON: invalid[call.id], timeout: timeout, chatId: chatId))
				}
			}
			var out = [ToolOutput?](repeating: nil, count: calls.count)
			for await (i, o) in group {
				out[i] = o
				emit(.toolEnd(toolCallId: calls[i].id, output: o))
			}
			return out.map { $0! }
		}
		return Array(zip(calls, results))
	}

	static func execute(_ call: ToolUse, tool: (any AgentTool)?, invalidJSON: String?, timeout: Duration, chatId: String?) async -> ToolOutput {
		if Task.isCancelled { return .error(ToolGuardError.aborted.description) }
		guard let tool else { return .error("Tool \(call.name) not found") }
		if let raw = invalidJSON {
			return ToolOutput(content: [.text(JSONValue.object(JSONObject(["INVALID_JSON": .string(raw)])).serialized())], details: [:], isError: true)
		}
		let converted = tool.schema.convert(tool.prepare(call.input))
		guard tool.schema.check(converted) else {
			return .error("Validation failed for tool \"\(call.name)\":\n  - root: the arguments do not match the tool's input schema\n\nReceived arguments:\n\(call.input.serialized(indent: 2))")
		}
		do {
			return try await ToolGuard.run(call.name, timeout: timeout) {
				try await tool.execute(converted, context: ToolContext(toolCallId: call.id, chatId: chatId))
			}
		} catch {
			return .error((error as? ToolGuardError)?.description ?? "\(error)")
		}
	}
}
