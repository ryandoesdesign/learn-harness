import Foundation
import LHAnthropic
import LHCore

/// A sub-agent's model: the client plus the resolved role spec.
public struct SubagentModel: Sendable {
	public var client: MessagesClient
	public var spec: EffectiveModelSpec
	public init(client: MessagesClient, spec: EffectiveModelSpec) {
		self.client = client
		self.spec = spec
	}

	/// The sub-agent request shape: no displayed thinking, the 5-minute cache.
	func config(system: String, tools: [any AgentTool] = [], declarations: [ToolDefinition] = [], maxTurns: Int? = nil) -> AgentConfig {
		var c = AgentConfig(model: spec.model, effort: spec.effort, system: system, tools: tools, serverTools: declarations,
			thinkingDisplay: .omitted, cacheTTL: .fiveMinutes)
		c.maxTurns = maxTurns
		return c
	}
}

public struct SubagentError: Error, Sendable, CustomStringConvertible {
	public var message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// One raw model call over `context` with declaration-only tools (the
/// hand-rolled loops dispatch tools themselves): the visual maker's and pdf
/// reader's `streamOnce`. Provider errors throw; cancellation throws.
func subagentCall(_ model: SubagentModel, system: String, declarations: [ToolDefinition], context: [Message]) async throws -> (assistant: Message, steps: [UsageStepRecord]) {
	let loop = AgentLoop(client: model.client, config: model.config(system: system, declarations: declarations))
	let id = MessageID.mint()
	switch await loop.streamOne(context: context, messageId: id, emit: { _ in }) {
	case .completed(let r):
		return (loop.assistantMessage(r, id: id, stopReason: r.stopReason ?? "end_turn", errorMessage: nil), loop.usageSteps(r))
	case .failed(_, let message):
		throw SubagentError(message)
	case .cancelled:
		throw CancellationError()
	}
}

/// The assistant message's text blocks, joined and trimmed.
func assistantText(_ m: Message) -> String {
	(m.assistant?.content ?? []).compactMap { $0.type == "text" ? $0.raw["text"]?.stringValue : nil }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A declaration-only client tool (its loop owns execution).
func declaration(_ name: String, _ description: String, _ schema: JSONSchema) -> ToolDefinition {
	.client(name: name, description: description, inputSchema: schema.json)
}

/// A tool result message for a hand-rolled loop.
func toolResultMessage(_ call: ToolUse, _ text: String, isError: Bool) -> Message {
	Message(id: MessageID.mint(), timestamp: MessageID.nowMillis(), body: .toolResult(ToolResultBody(
		toolUseId: call.id, toolName: call.name, content: [.text(text)], isError: isError)))
}

/// A user message carrying text and PNG images (the image-in-the-loop idiom).
func imageMessage(_ text: String, pngs: [Data]) -> Message {
	Message(id: MessageID.mint(), timestamp: MessageID.nowMillis(), body: .user(UserBody(content:
		[.text(text)] + pngs.map { Block.image(mediaType: "image/png", base64: $0.base64EncodedString()) })))
}
