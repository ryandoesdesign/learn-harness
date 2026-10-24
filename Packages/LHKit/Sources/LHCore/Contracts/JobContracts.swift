import Foundation

// Port of src/core/contracts/jobs.ts — the async sub-agent protocol.

public enum JobKind: String, Sendable, Hashable, Codable, CaseIterable {
	case research, demo, visual, pdf
}

public enum JobStatus: String, Sendable, Hashable, Codable {
	case running, done, error
}

public struct JobUsage: Sendable, Hashable, Codable {
	public var model: String
	public var inputTokens: Int?
	public var outputTokens: Int?
	public var cacheReadTokens: Int?
	public var cacheWriteTokens: Int?
	public var reasoningTokens: Int?
	public var steps: Int
	public var lastStep: CallUsage?
	/// Native (M6): the 1-hour cache-write subset and the server-tool
	/// requests, so a job's cost includes its searches. Absent in TS rows.
	public var cacheWrite1hTokens: Int?
	public var webSearchRequests: Int?
	public var webFetchRequests: Int?
	public init(model: String, inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil, steps: Int, lastStep: CallUsage? = nil) {
		self.model = model
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.cacheReadTokens = cacheReadTokens
		self.cacheWriteTokens = cacheWriteTokens
		self.reasoningTokens = reasoningTokens
		self.steps = steps
		self.lastStep = lastStep
	}

	public var callUsage: CallUsage {
		var c = CallUsage(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens, reasoningTokens: reasoningTokens)
		c.cacheWrite1hTokens = cacheWrite1hTokens
		c.webSearchRequests = webSearchRequests
		c.webFetchRequests = webFetchRequests
		return c
	}
}

public struct JobRecord: Sendable, Hashable {
	public var id: String
	public var kind: JobKind
	public var chatId: String
	public var toolCallId: String
	public var status: JobStatus
	public var activity: String
	public var createdAt: String
	public var updatedAt: String
	/// The kind's result shape (`SubagentResult`), raw.
	public var result: JSONValue?
	public var error: String?
	public var usage: JobUsage?
	public init(id: String, kind: JobKind, chatId: String, toolCallId: String, status: JobStatus, activity: String, createdAt: String, updatedAt: String, result: JSONValue? = nil, error: String? = nil, usage: JobUsage? = nil) {
		self.id = id
		self.kind = kind
		self.chatId = chatId
		self.toolCallId = toolCallId
		self.status = status
		self.activity = activity
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.result = result
		self.error = error
		self.usage = usage
	}
}

/// One step's usage as the runner reports it (Anthropic usage: input
/// excludes the cached portion — the same semantics as pi's).
public struct UsageStep: Sendable, Hashable {
	public var inputTokens: Int?
	public var outputTokens: Int?
	public var cacheReadTokens: Int?
	public var cacheWriteTokens: Int?
	public var reasoningTokens: Int?
	public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil) {
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.cacheReadTokens = cacheReadTokens
		self.cacheWriteTokens = cacheWriteTokens
		self.reasoningTokens = reasoningTokens
	}
}

/// Fold one step into a job's running usage (absent stays absent).
public func accumulateJobUsage(_ total: JobUsage?, model: String, step: UsageStep) -> JobUsage {
	func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
	return JobUsage(
		model: model,
		inputTokens: add(total?.inputTokens, step.inputTokens),
		outputTokens: add(total?.outputTokens, step.outputTokens),
		cacheReadTokens: add(total?.cacheReadTokens, step.cacheReadTokens),
		cacheWriteTokens: add(total?.cacheWriteTokens, step.cacheWriteTokens),
		reasoningTokens: add(total?.reasoningTokens, step.reasoningTokens),
		steps: (total?.steps ?? 0) + 1,
		lastStep: CallUsage(inputTokens: step.inputTokens, outputTokens: step.outputTokens, cacheReadTokens: step.cacheReadTokens, cacheWriteTokens: step.cacheWriteTokens, reasoningTokens: step.reasoningTokens))
}

/// The native fold over one Anthropic call (M6): accumulateJobUsage plus
/// the 1-hour writes and server-tool requests.
public func accumulateJobUsage(_ total: JobUsage?, model: String, call: CallUsage) -> JobUsage {
	func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
	var next = accumulateJobUsage(total, model: model, step: UsageStep(inputTokens: call.inputTokens, outputTokens: call.outputTokens,
		cacheReadTokens: call.cacheReadTokens, cacheWriteTokens: call.cacheWriteTokens, reasoningTokens: call.reasoningTokens))
	next.cacheWrite1hTokens = add(total?.cacheWrite1hTokens, call.cacheWrite1hTokens)
	next.webSearchRequests = add(total?.webSearchRequests, call.webSearchRequests)
	next.webFetchRequests = add(total?.webFetchRequests, call.webFetchRequests)
	return next
}

// MARK: - Tool inputs / results

public struct ResearchToolInput: Sendable, Hashable, Codable {
	public var question: String
	public var context: String?
}

public struct ResearchSource: Sendable, Hashable, Codable {
	public var title: String
	public var url: String
	public init(title: String, url: String) {
		self.title = title
		self.url = url
	}
}

public struct ResearchResult: Sendable, Hashable, Codable {
	public var brief: String
	public var sources: [ResearchSource]
	public init(brief: String, sources: [ResearchSource]) {
		self.brief = brief
		self.sources = sources
	}
}

public struct DemoToolInput: Sendable, Hashable, Codable {
	public var title: String
	public var brief: String
}

public struct DemoResult: Sendable, Hashable, Codable {
	public var title: String
	public var html: String
	public var tested: Bool
	public var notes: String?
	public init(title: String, html: String, tested: Bool = true, notes: String? = nil) {
		self.title = title
		self.html = html
		self.tested = tested
		self.notes = notes
	}
}

public struct VisualToolInput: Sendable, Hashable, Codable {
	public var brief: String
}

public struct VisualResult: Sendable, Hashable, Codable {
	public var svg: String
	public var notes: String?
	public init(svg: String, notes: String? = nil) {
		self.svg = svg
		self.notes = notes
	}
}

public struct PdfToolInput: Sendable, Hashable, Codable {
	public var path: String
	public var question: String
}

public struct PdfResult: Sendable, Hashable, Codable {
	public var path: String
	public var question: String
	public var brief: String
	public var pagesRead: [Int]
	public var pagesConsulted: [Int]
	public init(path: String, question: String, brief: String, pagesRead: [Int], pagesConsulted: [Int]) {
		self.path = path
		self.question = question
		self.brief = brief
		self.pagesRead = pagesRead
		self.pagesConsulted = pagesConsulted
	}
}

public enum SubagentResult: Sendable, Hashable {
	case research(ResearchResult)
	case demo(DemoResult)
	case visual(VisualResult)
	case pdf(PdfResult)

	public var kind: JobKind {
		switch self {
		case .research: .research
		case .demo: .demo
		case .visual: .visual
		case .pdf: .pdf
		}
	}

	public var json: JSONValue {
		switch self {
		case .research(let r): (try? JSONCodec.encode(r)) ?? .null
		case .demo(let r): (try? JSONCodec.encode(r)) ?? .null
		case .visual(let r): (try? JSONCodec.encode(r)) ?? .null
		case .pdf(let r): (try? JSONCodec.encode(r)) ?? .null
		}
	}

	/// Decode a raw result of the given kind; lenient on missing strings
	/// (the TS checks `typeof html !== "string"` rather than trusting shape).
	public static func decode(kind: JobKind, _ v: JSONValue) -> SubagentResult? {
		switch kind {
		case .research: (try? JSONCodec.decode(ResearchResult.self, from: v)).map(SubagentResult.research)
		case .demo:
			.demo(DemoResult(title: v["title"]?.stringValue ?? "", html: v["html"]?.stringValue ?? "", tested: v["tested"]?.boolValue ?? false, notes: v["notes"]?.stringValue))
		case .visual: .visual(VisualResult(svg: v["svg"]?.stringValue ?? "", notes: v["notes"]?.stringValue))
		case .pdf: (try? JSONCodec.decode(PdfResult.self, from: v)).map(SubagentResult.pdf)
		}
	}
}

/// Did the sub-agent fail (an honest failure result rather than an artifact)?
public func isSubagentFailure(_ result: SubagentResult) -> Bool {
	switch result {
	case .research(let r): r.sources.isEmpty && r.brief.range(of: #"^Research failed:"#, options: [.regularExpression, .caseInsensitive]) != nil
	case .demo(let r): r.html.isEmpty
	case .pdf(let r): r.brief.range(of: #"^PDF failed:"#, options: [.regularExpression, .caseInsensitive]) != nil
	case .visual(let r): r.svg.isEmpty
	}
}

private func steerText(_ result: SubagentResult) -> String {
	if isSubagentFailure(result) {
		switch result {
		case .research(let r): return "\(r.brief)\n\nContinue with what you can establish and flag the uncertainty to the learner."
		case .demo(let r): return "The demo \"\(r.title)\" could not be built: \(r.notes ?? "unknown reason"). Fall back to explaining in prose; if the brief was the problem, re-call demo with a tighter one."
		case .pdf(let r): return "\(r.brief)\n\nContinue with what you can establish from the session and flag the gap to the learner."
		case .visual(let r): return "The figure could not be made: \(r.notes ?? "unknown reason"). Fall back to prose or mermaid, or re-call visual with a tighter brief."
		}
	}
	switch result {
	case .research(let r):
		return "Research complete — the researcher's full brief follows. Weave it into the lesson and cite its sources when you use its findings:\n\n\(r.brief)"
	case .pdf(let r):
		return "PDF reading complete — the reader's brief on \"\(r.path)\" follows, with page citations. Weave it into the lesson and cite pages when you use it:\n\n\(r.brief)"
	case .demo(let r):
		return "The demo \"\(r.title)\" is built, headlessly tested, and rendered in the lesson. Builder notes: \(r.notes ?? "(none)").\nTeach with it — reference its controls by name and point the learner at what to try."
	case .visual(let r):
		return "The figure is drawn, verified by inspection, and rendered in the lesson. Maker notes: \(r.notes ?? "(none)").\nReference its elements as you teach."
	}
}

private func abortText(_ kind: JobKind) -> String {
	switch kind {
	case .research: "Research aborted — the learner aborted the research job, so no brief is coming. Acknowledge it in one line and continue teaching without it (or offer to re-dispatch it)."
	case .demo: "The demo job was aborted by the learner — no demo is coming. Acknowledge it in one line and teach the topic in prose instead (a re-dispatch is fine if the learner wants it)."
	case .pdf: "The PDF reading job was aborted by the learner — no brief is coming. Acknowledge it in one line and continue without it (a re-dispatch is fine if the learner wants it)."
	case .visual: "The figure job was aborted by the learner — no figure is coming. Acknowledge it in one line and teach without it (a re-dispatch is fine if the learner wants it)."
	}
}

/// The delivery steer for a finished job (id `steer_<jobId>` — exactly-once key).
public func buildSubagentSteer(jobId: String, kind: JobKind, toolCallId: String, result: SubagentResult, now: Int = MessageID.nowMillis()) -> Message {
	Message(id: "steer_\(jobId)", timestamp: now, body: .marker(MarkerBody(
		kind: .subagentSteer, content: steerText(result), display: true,
		details: ["jobId": .string(jobId), "kind": .string(kind.rawValue), "toolCallId": .string(toolCallId), "result": result.json])))
}

/// The abort steer (same id as the delivery: one of the two lands, never both).
public func buildAbortSteer(jobId: String, kind: JobKind, toolCallId: String, now: Int = MessageID.nowMillis()) -> Message {
	Message(id: "steer_\(jobId)", timestamp: now, body: .marker(MarkerBody(
		kind: .subagentAbort, content: abortText(kind), display: true,
		details: ["jobId": .string(jobId), "kind": .string(kind.rawValue), "toolCallId": .string(toolCallId), "aborted": true])))
}

/// The probe→teach handoff wake.
public func newHandoffMessage(chatId: String, now: Int = MessageID.nowMillis()) -> Message {
	Message(id: "steer_probe_\(chatId)", timestamp: now, body: .marker(MarkerBody(
		kind: .probeHandoff, content: HANDOFF_TEXT, display: true, details: ["chatId": .string(chatId)])))
}

public func steerDelivered(_ messages: [Message], steerId: String) -> Bool {
	messages.contains { $0.id == steerId }
}

/// Flip a demo/visual steer card's inverted-colors UI flag.
public func setSteerUiInverted(_ messages: [Message], messageId: String, inverted: Bool) -> [Message] {
	messages.map { m in
		guard m.id == messageId, var marker = m.marker else { return m }
		let kind = marker.details["kind"]?.stringValue
		guard kind == "demo" || kind == "visual" else { return m }
		var ui = marker.details["ui"]?.objectValue ?? JSONObject()
		ui["inverted"] = .bool(inverted)
		marker.details["ui"] = .object(ui)
		var out = m
		out.body = .marker(marker)
		return out
	}
}

// MARK: - Probe

public struct ProbeStrand: Sendable, Hashable, Codable {
	public var strand: String
	public var assessment: String
}

public struct ProbeAssessment: Sendable, Hashable, Codable {
	public var strands: [ProbeStrand]
	public var summary: String?
}

public struct ProbeDoneInput: Sendable, Hashable, Codable {
	public var assessment: ProbeAssessment
}

public struct ProbeDoneResult: Sendable, Hashable, Codable {
	public var ok: Bool
	public var error: String?
}
