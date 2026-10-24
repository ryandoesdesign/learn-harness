import Foundation

// Port of src/core/pending.ts (the native parts; the UIMessage-era
// findPendingToolCall / streamingToolActivity scans died with the AI SDK).

/// Tools that render in the question dock and gate the composer.
public let QUESTION_TOOLS: [String] = ["quiz", "probe", "ask_user_question", "explain", "recall"]

public enum QuestionKind: String, Sendable, Hashable, Codable {
	case quiz, ask, explain
}

/// The tool → dock kind map (probe-phase names fold onto their teach kinds).
public func toolQuestionKind(_ tool: String) -> QuestionKind {
	if tool == "quiz" || tool == "probe" { return .quiz }
	if tool == "explain" || tool == "recall" { return .explain }
	return .ask
}

/// Tools fulfilled by background sub-agent jobs.
public let JOB_TOOLS: [String] = ["research", "demo", "visual"]

/// The tools a user may toggle off in settings (the sub-agent job tools).
public let TOGGLEABLE_TOOLS: [String] = ["research", "demo", "visual", "pdf"]

/// The keys the settings write side accepts in agent.tools.
public let WRITABLE_TOOL_KEYS: [String] = TOGGLEABLE_TOOLS + ["explain"]

/// Drop every tool the resolved settings mark disabled (absent = enabled).
public func filterEnabledTools<T>(_ tools: [(name: String, tool: T)], enabled: [String: Bool]?) -> [(name: String, tool: T)] {
	guard let enabled else { return tools }
	return tools.filter { enabled[$0.name] != false }
}

private let ACTIVITY_LABELS: [String: String] = [
	"read": "Reading a file…",
	"ls": "Listing a directory…",
	"find": "Finding files…",
	"grep": "Searching file contents…",
	"research": "Dispatching research…",
	"demo": "Building a demo…",
	"visual": "Making a visual…",
	"pdf": "Reading a PDF…",
	"plan_init": "Drawing up the plan…",
	"probe_done": "Concluding the assessment…",
]

/// The live tool card's activity label.
public func toolActivityLabel(_ tool: String) -> String {
	if QUESTION_TOOLS.contains(tool) { return "Writing a question…" }
	return ACTIVITY_LABELS[tool] ?? "Working…"
}
