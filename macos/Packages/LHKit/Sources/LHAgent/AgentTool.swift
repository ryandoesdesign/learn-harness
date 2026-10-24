import Foundation
import LHAnthropic
import LHCore

/// A client tool the agent loop can run (port of pi's AgentTool as the app
/// uses it). Inputs arrive validated against `schema`.
public protocol AgentTool: Sendable {
	var name: String { get }
	var description: String { get }
	var schema: JSONSchema { get }
	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
	public var definition: ToolDefinition { .client(name: name, description: description, inputSchema: schema.json) }
}

public struct ToolContext: Sendable {
	public var toolCallId: String
	public var chatId: String?
	public init(toolCallId: String, chatId: String? = nil) {
		self.toolCallId = toolCallId
		self.chatId = chatId
	}
}

/// One tool execution's result.
public struct ToolOutput: Sendable, Hashable {
	/// Model-facing content (text / image blocks).
	public var content: [Block]
	/// The UI payload (never model-visible).
	public var details: JSONValue?
	public var isError: Bool
	/// Ends the turn when EVERY call in the batch terminates (pi semantics).
	public var terminate: Bool
	/// In-memory only — never persisted (the question tools' placeholder).
	public var ephemeral: Bool

	public init(content: [Block], details: JSONValue? = nil, isError: Bool = false, terminate: Bool = false, ephemeral: Bool = false) {
		self.content = content
		self.details = details
		self.isError = isError
		self.terminate = terminate
		self.ephemeral = ephemeral
	}

	public static func error(_ text: String, details: JSONValue? = [:]) -> ToolOutput {
		ToolOutput(content: [.text(text)], details: details, isError: true)
	}

	/// tool-execute.ts toToolResult: a string verbatim, anything else as JSON; details ride the raw value.
	public static func value(_ v: JSONValue) -> ToolOutput {
		ToolOutput(content: [.text(v.stringValue ?? v.serialized())], details: v)
	}

	/// The question tools' placeholder (tool-execute.ts questionResult).
	public static var questionPosed: ToolOutput {
		ToolOutput(content: [.text("Question posed — the turn ends here; the learner's graded answer arrives as this call's result.")], details: nil, terminate: true, ephemeral: true)
	}

	/// The practice pose ack (tool-execute.ts problemResult) — persisted.
	public static var problemPosed: ToolOutput {
		ToolOutput(content: [.text("Problem posed — the turn ends here; the learner's thinking traces and answer commits arrive as labeled messages.")], details: nil, terminate: true)
	}

	/// The conclude ack (tool-execute.ts concludeResult).
	public static var concluded: ToolOutput { ToolOutput(content: [.text(CONCLUDE_ACK_TEXT)], details: nil) }

	/// tool-execute.ts invalidInputResult.
	public static func invalidInput(tool: String, problems: [String]) -> ToolOutput {
		ToolOutput(content: [.text("Invalid tool input for tool \"\(tool)\":\n" + problems.map { "- \($0)" }.joined(separator: "\n"))],
			details: ["tool": .string(tool), "problems": .array(problems.map(JSONValue.string))], isError: true)
	}
}

/// The system-level guard every tool runs under (tool-execute.ts
/// runWithAbortGuard): a timeout, and abort forwarding with a short grace
/// for cooperative tools to settle a partial result.
public enum ToolGuard {
	public static let defaultTimeout: Duration = .seconds(30)
	public static let grace: Duration = .milliseconds(250)

	enum Outcome: Sendable {
		case finished(Result<ToolOutput, Error>)
		case timedOut
		case cancelled
		case graceOver
	}

	public static func run(_ toolName: String, timeout: Duration = defaultTimeout, _ body: @escaping @Sendable () async throws -> ToolOutput) async throws -> ToolOutput {
		let work = Task { try await body() }
		let first = await race(work, limit: timeout)
		switch first {
		case .finished(let r): return try r.get()
		case .timedOut, .cancelled, .graceOver:
			work.cancel()
			// A cooperative tool may still settle within the grace (a body that
			// just rethrows the cancellation did not settle anything).
			if case .finished(let r) = await race(work, limit: grace, honourCancellation: false) {
				if case .failure(let e) = r, e is CancellationError {} else { return try r.get() }
			}
			if case .timedOut = first { throw ToolGuardError.timedOut(tool: toolName, timeout: timeout) }
			throw ToolGuardError.aborted
		}
	}

	/// Wait for `work`, at most `limit`; the caller's cancellation ends the wait.
	static func race(_ work: Task<ToolOutput, Error>, limit: Duration, honourCancellation: Bool = true) async -> Outcome {
		let once = Once<Outcome>()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
				once.set(c)
				Task { once.resume(.finished(await work.result)) }
				Task {
					try? await Task.sleep(for: limit)
					once.resume(honourCancellation ? .timedOut : .graceOver)
				}
				if honourCancellation, Task.isCancelled { once.resume(.cancelled) }
			}
		} onCancel: {
			if honourCancellation { once.resume(.cancelled) }
		}
	}
}

public enum ToolGuardError: Error, Equatable, CustomStringConvertible {
	case timedOut(tool: String, timeout: Duration)
	case aborted

	public var description: String {
		switch self {
		case .timedOut(let tool, let timeout):
			let ms = Int(timeout.components.seconds * 1000) + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
			let human = ms >= 1000 ? "\(Int((Double(ms) / 1000).rounded()))s" : "\(ms)ms"
			return "Tool \"\(tool)\" timed out after \(human) — the result was discarded"
		case .aborted:
			return "Operation aborted"
		}
	}
}

/// A continuation resumed at most once (later resumes are ignored).
final class Once<T: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<T, Never>?
	private var early: T?
	private var done = false

	func set(_ c: CheckedContinuation<T, Never>) {
		lock.lock()
		if let early {
			lock.unlock()
			c.resume(returning: early)
			return
		}
		continuation = c
		lock.unlock()
	}

	func resume(_ value: T) {
		lock.lock()
		guard !done else { lock.unlock(); return }
		done = true
		if let c = continuation {
			continuation = nil
			lock.unlock()
			c.resume(returning: value)
		} else {
			early = value
			lock.unlock()
		}
	}
}
