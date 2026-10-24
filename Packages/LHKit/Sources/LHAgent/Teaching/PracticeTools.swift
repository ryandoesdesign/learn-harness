import Foundation
import LHCore

// Port of agent/tools/practice.ts — the practice agent's registry: `problem`
// (pose; ends the turn) and `conclude` (end the problem; the turn goes on),
// plus the rarely-needed side tools. Names, descriptions and schemas match
// the TS (pinned by Golden/tools-practice.json) with two recorded
// differences (docs/native-macos-m8.md):
// - `conclude.outcome` drops `dismissed` — only the app writes it;
// - `problem` is refused after a `conclude` in the same turn (the pause law
//   the prompt states; the TS only states it).

/// The turn's gate (practice.ts PracticeGate, the BKT incident): seeded once
/// from the record when the turn's tools are built, then flipped by the two
/// executes — the intra-turn truth both gates read.
public final class PracticeGate: @unchecked Sendable {
	private let lock = NSLock()
	private var _problemActive: Bool
	private var _concludedThisTurn = false

	public init(problemActive: Bool) { _problemActive = problemActive }

	public convenience init(messages: [Message]) {
		self.init(problemActive: activeProblemOf(messages) != nil)
	}

	public var problemActive: Bool { lock.withLock { _problemActive } }

	/// Claim the pose: nil on success, else the refusal.
	func pose() -> String? {
		lock.withLock {
			if _problemActive { return "a problem is already active — call conclude on it before posing the next one" }
			if _concludedThisTurn {
				return "a problem was concluded in this turn — the next one waits for the learner's go-ahead (a *Next problem* message, or their own words asking for it): end your turn"
			}
			_problemActive = true
			return nil
		}
	}

	/// Claim the conclusion: nil on success, else the refusal.
	func conclude() -> String? {
		lock.withLock {
			guard _problemActive else { return "no active problem to conclude — pose one first" }
			_problemActive = false
			_concludedThisTurn = true
			return nil
		}
	}
}

/// The practice registry (practice.ts practiceTools): problem, conclude, the
/// learner-file tools, research and pdf, and the map readers when graph
/// tools are on. The side tools obey the Settings switches (a native change;
/// TS ignores them); problem and conclude can't be switched off.
public func practiceTools(gate: PracticeGate, graphNodes: (@Sendable () -> [GraphNode])?, enabled: [String: Bool]?,
	background: BackgroundWiring? = nil, graph: GraphToolDeps? = nil) -> [any AgentTool]
{
	var side: [any AgentTool] = []
	if let background { side += fileTools(background.files) + [DispatchTool.research(background), DispatchTool.pdf(background)] }
	if let graph { side += proberGraphTools(graph) }
	return [ProblemTool(gate: gate, graphNodes: graphNodes), ConcludeTool(gate: gate)] + filteredOptional(side, enabled)
}

// MARK: - problem

public let problemInputSchema = JSONSchema.object([
	"statement": .string(description:
		"REQUIRED — the problem as the learner sees it (markdown + LaTeX). Must be self-contained and " +
		"solvable from the session's material. NEVER announces the target proposition."),
	"mode": .union([.literal("recall"), .literal("discrimination"), .literal("composition")], description:
		"REQUIRED — the demand mode: recall, discrimination, or composition (bare words, no quotes)."),
	"target": JSONSchema.array(.string(), minItems: 1, description:
		"The proposition id(s) this problem exercises, from the session context's [id] list — include when " +
		"the material is in the map; OMIT entirely when it is not (a topic session poses untagged problems). " +
		"Names are normalized to ids at the seam; an unknown proposition is rejected.").optional(),
	"modelSolution": .string(description:
		"REQUIRED — the full solution, moves in order, committed BEFORE the learner sees the problem. This IS the reveal — conclude shows it verbatim; never re-author it."),
])

public struct ProblemTool: AgentTool {
	let gate: PracticeGate
	/// The WHOLE graph's propositions, read fresh per pose (targets validate
	/// against every node, not just the session's picks). Nil = no validation.
	let graphNodes: (@Sendable () -> [GraphNode])?

	public let name = PRACTICE_PROBLEM_TOOL
	public let description =
		"Pose one practice problem. Ends the turn — the learner works in the thinking field; their thinking " +
		"traces and answer commits arrive back as labeled messages. The modelSolution rides this call's " +
		"arguments and stays hidden from the learner until you conclude (conclude shows it verbatim — the " +
		"reveal needs no new field). Only one problem may be active — conclude it before posing the next."
	public var schema: JSONSchema { problemInputSchema }
	public var sequential: Bool { true }

	/// Target normalization: names become ids (unresolvable strings pass
	/// through for execute to reject); an empty list is healed away, so the
	/// record is tagged-or-absent, never [].
	public func prepare(_ input: JSONValue) -> JSONValue {
		let healed = healEncodedArguments(input, schema: schema)
		guard case .object(var o) = healed else { return healed }
		guard let target = o["target"]?.arrayValue else { return healed }
		if target.isEmpty {
			o["target"] = nil
			return .object(o)
		}
		guard let graphNodes else { return healed }
		let nodes = graphNodes()
		let normalized: [JSONValue] = target.map { t in
			guard let s = t.stringValue else { return t }
			return resolveTargetId(s, nodes).map(JSONValue.string) ?? t
		}
		if normalized == target { return healed }
		o["target"] = .array(normalized)
		return .object(o)
	}

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		if gate.problemActive { return .invalidInput(tool: name, problems: ["a problem is already active — call conclude on it before posing the next one"]) }
		if let graphNodes, let target = input["target"]?.arrayValue, !target.isEmpty {
			let nodes = graphNodes()
			let unknown = target.compactMap(\.stringValue).filter { resolveTargetId($0, nodes) == nil }
			if !unknown.isEmpty {
				return .invalidInput(tool: name, problems: [
					"target \(JSONValue.array(unknown.map(JSONValue.string)).serialized()) is not a known proposition — targets must be proposition ids from the session context; if the material is not in the map, omit target entirely",
				])
			}
		}
		if let refusal = gate.pose() { return .invalidInput(tool: name, problems: [refusal]) }
		return .problemPosed
	}
}

// MARK: - conclude

public let concludeInputSchema = JSONSchema.object([
	"outcome": .union([.literal("solved"), .literal("solvedWithHints"), .literal("movedOn"), .literal("surrendered")], description:
		"REQUIRED — the outcome: solved, solvedWithHints, movedOn, or surrendered — bare words, no quotes (dismissed is synthesized, never yours)."),
	"verdict": .string(description:
		"REQUIRED — the plain-language verdict: what was credited, where it broke. On a wrong answer: localize the break, do NOT give the correction."),
	"rung": .union([.literal("R0"), .literal("R1"), .literal("R2"), .literal("R3"), .literal("R4"), .literal("R5"), .null()], description:
		"REQUIRED — the hint-ladder rung the problem needed: R0 through R5, or null = no hint was given (bare, no quotes)."),
	"missClass": .union([.literal("cue"), .literal("discrimination"), .literal("execution"), .literal("careless"), .literal("structural"), .null()], description:
		"REQUIRED — the miss classification: cue, discrimination, execution, careless, or structural — or null = no miss (bare, no quotes)."),
	"retest": .boolean(description: "REQUIRED — true marks the problem for a fresh-surface retest before the session ends."),
])

public struct ConcludeTool: AgentTool {
	let gate: PracticeGate

	public let name = PRACTICE_CONCLUDE_TOOL
	public let description =
		"Conclude the active problem: records the outcome + verdict, reveals the committed solution, and frees " +
		"the learner's composer. After the result, say your closing words about the learner's work if useful, then " +
		"END YOUR TURN — no further tool calls. The next problem is NEVER posed here: it waits for the learner's " +
		"explicit go-ahead (a *Next problem* message, or their own words asking for the next one). Between problems, " +
		"answer their questions about the concluded one. Nothing may conclude unless a problem is active."
	public var schema: JSONSchema { concludeInputSchema }
	public var sequential: Bool { true }

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		if let refusal = gate.conclude() { return .invalidInput(tool: name, problems: [refusal]) }
		return .concluded
	}
}
