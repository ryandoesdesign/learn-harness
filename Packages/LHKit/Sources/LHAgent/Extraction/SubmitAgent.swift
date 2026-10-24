import Foundation
import LHAnthropic
import LHCore

// Port of src/agent/subagents/submit-agent.ts: a small agent loop whose
// deliverable is ONE valid call of its submit tool. Validation problems go
// back to the model as an error result and it re-submits within its turns;
// the run stops at the first valid submit.

/// The stage's outcome: the captured value (nil = never submitted), and its usage.
struct SubmitOutcome<T: Sendable>: Sendable {
	var value: T?
	var steps: [UsageStepRecord]
	var aborted: Bool
	/// A provider failure (the last call's error message).
	var failure: String?
}

final class SubmitCapture<T: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var _value: T?
	var value: T? {
		get { lock.withLock { _value } }
		set { lock.withLock { _value = newValue } }
	}
}

/// The submit tool: decode, validate, capture.
struct SubmitTool<T: Sendable>: AgentTool {
	let name: String
	let description: String
	let schema: JSONSchema
	let decode: @Sendable (JSONValue) -> T?
	let validate: @Sendable (T) -> String?
	let capture: SubmitCapture<T>

	/// healStringifiedArrays (weak models send the arrays as JSON strings), then the standard heal.
	func prepare(_ input: JSONValue) -> JSONValue {
		var v = input
		if case .object(var o) = input {
			for key in ["propositions", "chains"] {
				if let s = o[key]?.stringValue, !s.jsTrimmed.isEmpty, let parsed = try? JSONValue.parse(Data(s.utf8)), parsed.arrayValue != nil { o[key] = parsed }
			}
			v = .object(o)
		}
		return healEncodedArguments(v, schema: schema)
	}

	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		guard let value = decode(input) else { return .invalidInput(tool: name, problems: ["the payload does not have the submission's shape"]) }
		if let problem = validate(value) { return .invalidInput(tool: name, problems: [problem]) }
		capture.value = value
		return .value(input)
	}
}

func runSubmitAgent<T: Sendable>(model: SubagentModel, system: String, prompt: String, submit: SubmitTool<T>, extraTools: [any AgentTool] = [],
	maxTurns: Int = 4) async -> SubmitOutcome<T>
{
	var config = model.config(system: system, tools: extraTools + [submit], maxTurns: maxTurns)
	let name = submit.name
	config.shouldStop = { _, results in results.contains { $0.0.name == name && !$0.1.isError } }
	let loop = AgentLoop(client: model.client, config: config)
	let outcome = await loop.run(history: [], inputs: [newUserMessage(prompt)]) { _ in }
	let last = outcome.newMessages.last { $0.assistant != nil }?.assistant
	let failure = last?.stopReason == "error" ? (last?.errorMessage ?? "the model call failed") : nil
	return SubmitOutcome(value: submit.capture.value, steps: outcome.steps, aborted: outcome.aborted, failure: failure)
}
