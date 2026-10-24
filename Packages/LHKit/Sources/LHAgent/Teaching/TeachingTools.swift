import Foundation
import LHCore

// Port of agent/tools.ts, tools/plan.ts and tools/probe.ts — the TEACHING
// tool set (docs/native-macos-m5.md: the M6 file/job tools and the M7 graph
// tools are not registered yet). Names, descriptions, schemas and error
// wording are byte-identical to the TS (pinned by the golden dumps).

/// What the teaching tools read and write: the live chat record, the plan
/// tree, and the handoff queue.
public struct TeachingContext: Sendable {
	public var chatId: String
	/// The record as persisted now (mid-turn writes included).
	public var record: @Sendable () async -> ChatRecord?
	public var saveTree: @Sendable (PlanTree) async throws -> Void
	/// Queue the probe→teach handoff wake.
	public var queueHandoff: @Sendable () async -> Void

	public init(chatId: String, record: @escaping @Sendable () async -> ChatRecord?, saveTree: @escaping @Sendable (PlanTree) async throws -> Void,
		queueHandoff: @escaping @Sendable () async -> Void)
	{
		self.chatId = chatId
		self.record = record
		self.saveTree = saveTree
		self.queueHandoff = queueHandoff
	}
}

/// The quizzing mechanics: `agent.tools.explain == true` ⇒ free recall.
public enum QuizMechanics: Sendable { case choice, free }

public func quizMechanics(_ enabled: [String: Bool]?) -> QuizMechanics {
	enabled?["explain"] == true ? .free : .choice
}

/// The prober's registry: probe|recall, ask_user_question, the file tools,
/// research and pdf (every phase), the graph map (M7, gated), probe_done.
public func proberTools(_ ctx: TeachingContext, enabled: [String: Bool]?, background: BackgroundWiring? = nil, graph: GraphToolDeps? = nil) -> [any AgentTool] {
	let quizzing: any AgentTool = quizMechanics(enabled) == .free ? QuestionTool.recall : QuestionTool.probe
	var tools: [any AgentTool] = [QuestionTool.ask]
	if let background { tools += fileTools(background.files) + [DispatchTool.research(background), DispatchTool.pdf(background)] }
	// M7: the persistent map, only while graphToolsEnabled (the caller gates).
	if let graph { tools += proberGraphTools(graph) }
	// probe_done stays on regardless (it is how the phase ends).
	return [quizzing] + filteredOptional(tools, enabled) + [ProbeDoneTool(ctx: ctx)]
}

/// The teacher's registry: quiz|explain (nodeId-validated), ask_user_question,
/// the file tools, plan_init, then the four job dispatch tools.
public func teacherTools(_ ctx: TeachingContext, enabled: [String: Bool]?, background: BackgroundWiring? = nil) -> [any AgentTool] {
	let quizzing: any AgentTool = quizMechanics(enabled) == .free ? QuestionTool.explain(ctx) : QuestionTool.quiz(ctx)
	var tools: [any AgentTool] = [QuestionTool.ask]
	if let background { tools += fileTools(background.files) }
	tools.append(PlanInitTool(ctx: ctx))
	if let background { tools += [DispatchTool.research(background), DispatchTool.demo(background), DispatchTool.visual(background), DispatchTool.pdf(background)] }
	return [quizzing] + filteredOptional(tools, enabled)
}

/// filterEnabledTools over everything but the quizzing mechanics.
func filteredOptional(_ tools: [any AgentTool], _ enabled: [String: Bool]?) -> [any AgentTool] {
	filterEnabledTools(tools.map { (name: $0.name, tool: $0) }, enabled: enabled?.filter { $0.key != "explain" && $0.key != "quiz" }).map(\.tool)
}

// MARK: - Question tools

/// One client-answered question tool: validate the authoring refinements,
/// then pose (the ephemeral placeholder, terminate).
public struct QuestionTool: AgentTool {
	public enum Kind: Sendable { case ask, quiz, explain }

	public let name: String
	public let description: String
	public let schema: JSONSchema
	let kind: Kind
	let nodeIdCtx: TeachingContext?

	public var sequential: Bool { true }

	/// GLM wobble guard (prepareQuestionArguments): a JSON-encoded `options`
	/// string is parsed before validation; then the standard heal.
	public func prepare(_ input: JSONValue) -> JSONValue {
		var args = input
		if case .object(var o) = input, case .string? = o["options"], let parsed = parseOptionsIfString(o["options"]), parsed != o["options"] {
			o["options"] = parsed
			args = .object(o)
		}
		return healEncodedArguments(args, schema: schema)
	}

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		var problems: [String] = []
		let v = schema.clean(input)
		switch kind {
		case .ask:
			let options = (v["options"]?.arrayValue ?? []).map(optionInput)
			problems = askOptionProblems(options)
		case .quiz:
			let options = (v["options"]?.arrayValue ?? []).map(optionInput)
			let correct = v["correctAnswer"].flatMap(CorrectAnswer.init(json:)) ?? .single("")
			problems = quizInputProblems(options: options, correctAnswer: correct, multiSelect: v["multiSelect"]?.boolValue)
		case .explain:
			problems = explainInputProblems(correctAnswer: v["correctAnswer"]?.stringValue ?? "")
		}
		if let ctx = nodeIdCtx, let problem = await nodeIdProblem(ctx, v["nodeId"]?.stringValue ?? "") { problems.append(problem) }
		if !problems.isEmpty { return .invalidInput(tool: name, problems: problems) }
		return .questionPosed
	}

	private func optionInput(_ o: JSONValue) -> QuizOptionInput {
		QuizOptionInput(label: o["label"]?.stringValue ?? "", value: o["value"]?.stringValue, description: o["description"]?.stringValue)
	}

	public static let ask = QuestionTool(
		name: "ask_user_question",
		description:
			"Ask the learner a single question and pause until they answer. NOT graded — there is no correct answer. " +
			"Use when requirements are ambiguous, preferences are needed, a decision would materially affect the lesson, " +
			"or you need an open-ended response. ONE question per turn: call a single ask_user_question, then end your " +
			"turn — his answer determines the next.",
		schema: askInputSchema, kind: .ask, nodeIdCtx: nil)

	public static let probe = QuestionTool(
		name: "probe", description: quizDescription(name: "probe", nodeId: false, types: false),
		schema: probeQuizInputSchema, kind: .quiz, nodeIdCtx: nil)

	public static let recall = QuestionTool(
		name: "recall", description: explainDescription(name: "recall", nodeId: false),
		schema: explainInputBase, kind: .explain, nodeIdCtx: nil)

	public static func quiz(_ ctx: TeachingContext) -> QuestionTool {
		QuestionTool(name: "quiz", description: quizDescription(name: "quiz", nodeId: true, types: true),
			schema: quizInputObject, kind: .quiz, nodeIdCtx: ctx)
	}

	public static func explain(_ ctx: TeachingContext) -> QuestionTool {
		QuestionTool(name: "explain", description: explainDescription(name: "explain", nodeId: true),
			schema: explainInputObject, kind: .explain, nodeIdCtx: ctx)
	}
}

/// The nodeId-against-live-tree check (tools.ts nodeIdProblem).
func nodeIdProblem(_ ctx: TeachingContext, _ nodeId: String) async -> String? {
	let known = await ctx.record()?.tree?.nodes.map(\.id) ?? []
	guard !known.contains(nodeId) else { return nil }
	return "nodeId \"\(nodeId)\" matches no node in this session's plan map. " +
		(known.isEmpty
			? "No plan map exists yet — call plan_init before posing quizzes."
			: "Copy one of your plan_init slugs exactly (\(known.prefix(5).joined(separator: ", "))\(known.count > 5 ? ", …" : "")).")
}

/// The canonical example body (tools.ts quizExampleBody), key order kept.
let quizExampleBody: [(String, JSONValue)] = [
	("question", "A signal is $y=\\sin(2x)$ and $\\frac{dx}{dt}=3$. What is $\\frac{dy}{dt}$?"),
	("options", [
		["label": "$6\\cos(2x)$", "value": "a"],
		["label": "$2\\cos(2x)$", "value": "b"],
		["label": "$3\\cos(2x)$", "value": "c"],
	]),
	("explanation", "The phase changes twice as fast as $x$; multiply by the sine's slope:\n$$\n\\frac{dy}{dt}=\\cos(2x)\\cdot2\\cdot3=6\\cos(2x)\n$$"),
	("correctAnswer", "a"),
]

func quizDescription(name: String, nodeId: Bool, types: Bool) -> String {
	let base =
		"Ask the learner a GRADED question with a known correct answer, then instantly grade and give feedback. " +
		"Unlike ask_user_question (which collects preferences/decisions with no right answer), " +
		name +
		" always has a " +
		"correct answer supplied by you, marks the learner's selection right/wrong, reveals the correct answer, and " +
		"can show an explanation. Options-only: single-select or multi-select, plus an automatic 'I don't know' " +
		"choice so the learner can signal a genuine gap instead of guessing. An always-present optional thinking " +
		"field lets the learner attach his reasoning to ANY answer; it reaches you only when non-empty. " +
		"No free-text answers — for non-graded questions use ask_user_question instead. " +
		(types ? "Every call declares `type` — the question's role in the teaching cycle; the field's own description says when each kind fires. " : "") +
		(nodeId ? "Set `nodeId` (required) to the plan node this question is about — validated at call time against the session's plan map. For off-map checks use ask_user_question. " : "") +
		"ONE question per turn: call a single " +
		name +
		", then end your turn — his answer determines the next."
	let example: JSONValue = .object(JSONObject(pairs: (nodeId ? [("type", "check"), ("nodeId", "chain-rule")] : []) + quizExampleBody))
	return base +
		"\nExample arguments — copy the escaping exactly: inside JSON strings a LaTeX backslash is \\\\ and a newline is \\n.\n```json\n" +
		example.serialized(indent: 2) +
		"\n```" +
		(nodeId ? " The example's nodeId is illustrative — copy an exact id from this session's plan_init." : "")
}

func explainDescription(name: String, nodeId: Bool) -> String {
	"Ask the learner to EXPLAIN something in his own words — a graded check with NO options: he types a free-text " +
		"answer. Unlike ask_user_question (no right answer), " +
		name +
		" always has one. THE COMMITMENT RULE: " +
		"correctAnswer is the FULL correct answer in your own words, reasoning included, COMMITTED before he ever " +
		"sees the question. When his answer returns, grade it strictly against the commitment — never revise it " +
		"after seeing his words. He sees the committed answer on submit. " +
		(nodeId ? "Set `nodeId` (required) to the plan node this question is about — validated at call time against the session's plan map. " : "") +
		"ONE question per turn: call a single " + name + ", then end your turn — his answer determines the next."
}

// MARK: - plan_init

let PLAN_NODE_IDS_REMINDER =
	"These are the plan's node ids — the only valid nodeId values for every quiz and explain call from here on. Reference them exactly."

public struct PlanInitTool: AgentTool {
	let ctx: TeachingContext
	public let name = "plan_init"
	public let description =
		"Write or REWRITE this session's plan map — the dependency graph the learner follows live in the plan window. " +
		"Call once right after the probe concludes, to present the map; re-call whenever the map is wrong (the new block replaces the old tree). " +
		"A mermaid graph block (any direction): one node per line (`slug[Short Title]` — slugs are permanent lowercase ids: a-z, 0-9, hyphens/underscores), " +
		"`-->` edges meaning 'from must be understood before to' (chains fine). 5–15 nodes: a map, not a syllabus — one reasoning step per node, compress. " +
		"Every check you fire names the node it assesses via `nodeId`; where the lesson stands derives from those tags."
	public let schema = JSONSchema.object([
		"mermaid": .string(minLength: 1, description:
			"A mermaid graph block (any direction), e.g.:\ngraph TD\n  primitives[Number primitives] --> operators[Arithmetic operators] --> expressions[Evaluating expressions]\n" +
			"The only strict rule: ids are permanent lowercase slugs (a-z, 0-9, hyphens/underscores) — checks reference them via nodeId. " +
			"Titles are free single-line text; `-->` means 'from = prerequisite' (chains fine); no subgraphs, styles, or classes."),
	])

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		guard await ctx.record() != nil else { return refusal("Chat not found: \(ctx.chatId)") }
		let parsed = parseMermaidPlan(input["mermaid"]?.stringValue ?? "")
		guard parsed.ok, let plan = parsed.plan else { return refusal(parsed.problems.joined(separator: "\n")) }
		do {
			let tree = try createTree(plan.nodes, plan.edges)
			try await ctx.saveTree(tree)
			let text = JSONValue.object(JSONObject(pairs: [
				("ok", true), ("nodeIds", .array(tree.nodes.map { .string($0.id) })), ("reminder", .string(PLAN_NODE_IDS_REMINDER)),
			])).serialized()
			return ToolOutput(content: [.text(text)], details: ["ok": true, "tree": try JSONCodec.encode(tree)])
		} catch let e as PlanTreeError {
			return refusal(e.message)
		}
	}
}

/// serverExecute's refusal: `{ok:false, error}` as a NORMAL result.
func refusal(_ error: String) -> ToolOutput {
	.value(.object(JSONObject(pairs: [("ok", false), ("error", .string(error))])))
}

// MARK: - probe_done

public struct ProbeDoneTool: AgentTool {
	let ctx: TeachingContext
	public let name = "probe_done"
	public let description =
		"Conclude the probing phase and hand off to the teaching phase. Call this ONCE, when the probe is " +
		"complete: every strand the lesson depends on is bracketed (a floor he reliably gets right AND a " +
		"ceiling where it runs out), and his learning goal is concrete. The input IS the learner assessment — " +
		"one strand per dependency the lesson will rest on, with your read of where his edge sits on it " +
		"(floor, ceiling, misconceptions, what to build from). It streams to the learner live and becomes " +
		"the handoff artifact the teacher plans from. Refused while a question is still open, and after " +
		"the probe is already concluded. After it succeeds, say your closing sentence and end your turn."
	public let schema = probeDoneInputSchema

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		guard let record = await ctx.record() else { return refusal("Chat not found: \(ctx.chatId)") }
		// Messages persist as they settle, so the call's own assistant message
		// (and any sibling calls) is already recorded: judge the record BEFORE
		// it — what the TS record held at execute time.
		let prior = Array(record.messages.prefix { m in !(m.assistant?.toolUses.contains { $0.id == context.toolCallId } ?? false) })
		if danglingQuestionOf(prior) != nil {
			return refusal("A question is still open — resolve it (or let him answer) before concluding the probe. " +
				"probe_done only fires with no question outstanding.")
		}
		if hasProbeDone(prior) {
			return refusal("The probe is already concluded — probe_done fires exactly once.")
		}
		await ctx.queueHandoff()
		return ToolOutput(content: [.text(PROBE_DONE_ACK_TEXT)], details: ["ok": true])
	}
}
