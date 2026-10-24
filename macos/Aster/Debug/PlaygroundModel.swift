#if DEBUG
import Foundation
import LHAgent
import LHAnthropic
import LHCore
import LHResources
import LHStore
import Observation

/// The M3 acceptance harness (docs/native-macos-m3.md, "Debug playground"):
/// streams a real conversation through the agent loop with one client tool,
/// in memory only, and shows each turn's usage and cost.
@MainActor
@Observable
final class PlaygroundModel {
	var model = "claude-opus-5-5"
	var effort: Effort = .low
	var draft = ""
	var keyDraft = ""
	private(set) var hasKey = false
	private(set) var history: [Message] = []
	/// The assistant message streaming right now (nil between turns).
	private(set) var streaming: Message?
	private(set) var turns: [TurnLine] = []
	private(set) var status: String?
	private(set) var running = false

	struct TurnLine: Identifiable, Hashable {
		let id = UUID()
		var model: String
		var usage: CallUsage
		var dollars: Double?
		var calls: Int
	}

	let keychain: any KeychainStore
	let catalog: ModelCatalog
	private var task: Task<Void, Never>?

	init(keychain: any KeychainStore) {
		self.keychain = keychain
		catalog = (try? ModelCatalog(data: LHResources.modelsJSON)) ?? ModelCatalog(models: [])
		hasKey = ((try? keychain.anthropicKey()) ?? nil) != nil
	}

	var models: [CatalogModel] { catalog.models }

	var efforts: [Effort] { catalog.model(model)?.efforts ?? Effort.allCases }

	func saveKey() {
		let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty else { return }
		do {
			try keychain.setAnthropicKey(key)
			keyDraft = ""
			hasKey = true
			status = "Key saved to the Keychain."
		} catch {
			status = "Could not save the key: \(error)"
		}
	}

	func clear() {
		guard !running else { return }
		history = []
		turns = []
		status = nil
	}

	func send() {
		let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !running else { return }
		draft = ""
		if !efforts.contains(effort) { effort = efforts.last ?? .high }
		let keychain = keychain
		var client = MessagesClient(transport: URLSessionTransport(), apiKey: { try keychain.anthropicKey() })
		client.observer = nil
		let loop = AgentLoop(client: client, config: AgentConfig(
			model: model, effort: effort, system: Self.systemPrompt, tools: [CurrentTimeTool()],
			thinkingDisplay: .summarized, cacheTTL: .oneHour))
		let input = newUserMessage(text)
		let base = history
		running = true
		status = nil
		// One ordered stream carries events onto the main actor.
		let (events, sink) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
		let run = Task.detached { () -> TurnOutcome in
			let outcome = await loop.run(history: base, inputs: [input]) { sink.yield($0) }
			sink.finish()
			return outcome
		}
		task = Task {
			await withTaskCancellationHandler {
				for await event in events { apply(event) }
				finish(base: base, await run.value)
			} onCancel: {
				run.cancel()
			}
		}
	}

	func abort() { task?.cancel() }

	private func apply(_ event: AgentEvent) {
		switch event {
		case .messageStart(let m) where m.role == .assistant, .messageUpdate(let m):
			streaming = m
		case .messageStart(let m), .messageEnd(let m):
			if m.role == .assistant { streaming = nil }
			if !history.contains(where: { $0.id == m.id }) { history.append(m) }
		case .retrying(let attempt, let delay, let reason):
			status = "Retrying (attempt \(attempt)) in \(delay): \(reason)"
		case .inputTransformations(let t):
			status = "input_transformations: \(JSONValue.array(t).serialized())"
		default:
			break
		}
	}

	private func finish(base: [Message], _ outcome: TurnOutcome) {
		running = false
		streaming = nil
		// The settled list is authoritative (ephemeral placeholders already removed).
		history = base + outcome.newMessages
		for step in outcome.steps {
			turns.append(TurnLine(model: step.model, usage: step.usage, dollars: callCost(step.usage, model: step.model, catalog: catalog), calls: 1))
		}
		if outcome.aborted { status = "Aborted." }
		if let error = outcome.newMessages.last?.assistant?.errorMessage { status = error }
	}

	static let systemPrompt = """
		You are the Aster API playground: a short, friendly assistant used to check the native app's \
		Anthropic client end to end. Answer in a few sentences. When the user asks about the time anywhere, \
		call get_current_time with an IANA timezone name and report the result in plain words. You may call \
		the tool more than once in one turn when the user asks about several places; call them in parallel. \
		Never invent a time without calling the tool. Keep formatting light: short paragraphs, no headings.
		"""
}

/// The playground's one client tool.
struct CurrentTimeTool: AgentTool {
	let name = "get_current_time"
	let description = "Get the current local time in an IANA timezone (for example Europe/Paris)."
	let schema = JSONSchema.object(["timezone": .string(description: "An IANA timezone name, e.g. America/New_York")], additionalProperties: false)

	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		let name = input["timezone"]?.stringValue ?? ""
		guard let zone = TimeZone(identifier: name) else { return .error("Unknown timezone: \(name)") }
		let f = DateFormatter()
		f.timeZone = zone
		f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
		return .value(.string(f.string(from: Date())))
	}
}
#endif
