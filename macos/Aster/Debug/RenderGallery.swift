import AppKit
import Foundation
import LHCore
import LHStore

/// A synthetic session that exercises every transcript renderer: each
/// marker kind, every card, and every markdown construct (math, mermaid,
/// callouts, tables, code). The M4 acceptance fixture — the hosted tests
/// pin its coverage; Debug → Add Render Gallery Session inserts it.
enum RenderGallery {
	static let chatId = "chat_render_gallery"

	static let markdown = """
		# Markdown gallery

		Prose with **bold**, *italic*, ~~struck~~, `inline code`, a [link](https://example.com), \
		inline math $e^{i\\pi} + 1 = 0$, legacy \\(\\nabla f(x)^\\top u\\), and an escaped \\$5 price.
		A single newline breaks the line.

		## Display math

		$$
		\\int_0^1 x^2\\,dx = \\tfrac{1}{3}
		$$

		\\[
		\\begin{aligned} a &= b + c \\\\ d &= \\operatorname{argmax}_x f(x) \\end{aligned}
		\\]

		Braces under: $\\underbrace{x+y}_{n}$. An undefined command renders as raw TeX: $\\notacommand{x}$.

		- A bullet with $\\alpha$
		- [x] A finished task
		- Nested:
		  1. one
		  2. two

		> An ordinary quote stays muted and italic.

		> [!IMPORTANT]
		> The key idea sits in the sharp outlined box.

		| Model | Context | Notes |
		| :--- | :---: | ---: |
		| Opus | 1M | $x^2$ |
		| Sonnet | 1M | fast |

		```swift startLine=10
		let answer = 42
		print("hello, \\(answer)")
		```

		```mermaid
		graph TD
		  A[Probe] --> B[Plan]
		  B --> C[Teach]
		  C --> D{Check}
		  D -->|correct| C
		```

		---

		That's the whole gallery.
		"""

	static func record(now: Date = Date()) -> ChatRecord {
		let iso = ISO8601DateFormatter()
		iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let t = Int(now.timeIntervalSince1970 * 1000) - 600_000
		var clock = t
		func tick() -> Int { clock += 1000; return clock }
		func assistant(_ id: String, _ blocks: [Block], stop: String = "end_turn", details: JSONValue? = nil) -> Message {
			Message(id: id, timestamp: tick(), body: .assistant(AssistantBody(content: blocks, model: "claude-opus-5-5", stopReason: stop, stopDetails: details)))
		}
		func result(_ call: String, _ tool: String, _ details: JSONValue?, error: Bool = false, text: String = "ok") -> Message {
			Message(id: "tr_\(call)", timestamp: tick(), body: .toolResult(ToolResultBody(toolUseId: call, toolName: tool, content: [.text(text)], isError: error, details: details)))
		}

		let tree: JSONValue = ["nodes": [
			["id": "joins", "title": "What a join combines"],
			["id": "inner", "title": "Inner joins keep only matching rows"],
			["id": "outer", "title": "Outer joins keep unmatched rows with NULLs"],
			["id": "keys", "title": "Keys decide the match"],
		], "edges": [["from": "joins", "to": "inner"], ["from": "joins", "to": "outer"], ["from": "keys", "to": "inner"], ["from": "inner", "to": "outer"]], "version": 1]
		let block = PlanBlockData(at: iso.string(from: now), current: nil,
			nodes: [.init(id: "joins", title: "What a join combines", status: .upcoming), .init(id: "inner", title: "Inner joins keep only matching rows", status: .upcoming),
				.init(id: "outer", title: "Outer joins keep unmatched rows with NULLs", status: .upcoming), .init(id: "keys", title: "Keys decide the match", status: .upcoming)],
			edges: [PlanEdge(from: "joins", to: "inner"), PlanEdge(from: "joins", to: "outer"), PlanEdge(from: "keys", to: "inner"), PlanEdge(from: "inner", to: "outer")])

		var quizAnswer = QuestionAnswerData(kind: .quiz, questionText: "Which rows does an **inner join** keep when $k$ matches?", dontKnow: false,
			answers: [OptionAnswer(label: "Only matching rows", value: "a", index: 1)], answeredAt: iso.string(from: now))
		quizAnswer.tool = "quiz"
		quizAnswer.questionType = .predict
		quizAnswer.options = [.init(index: 1, label: "Only matching rows"), .init(index: 2, label: "All left rows"), .init(index: 3, label: "Every pair")]
		quizAnswer.correct = true
		quizAnswer.correctIndices = [1]
		quizAnswer.confidence = 70
		quizAnswer.explanation = "Inner joins drop rows with no partner on the other side."
		quizAnswer.thinking = "The word inner suggests the overlap."
		quizAnswer.readingThinking = "So a join is a filtered cross product?"

		var probeAnswer = QuestionAnswerData(kind: .quiz, questionText: "What does SQL stand for?", dontKnow: true, answers: [], answeredAt: iso.string(from: now))
		probeAnswer.tool = "probe"
		probeAnswer.options = [.init(index: 1, label: "Structured Query Language"), .init(index: 2, label: "Simple Query Logic")]
		probeAnswer.correctIndices = [1]

		var askAnswer = QuestionAnswerData(kind: .ask, questionText: "How deep should we go?", dontKnow: false,
			answers: [OptionAnswer(label: "Deep", value: "deep", index: 2)], answeredAt: iso.string(from: now))
		askAnswer.tool = "ask_user_question"
		askAnswer.options = [.init(index: 1, label: "Overview"), .init(index: 2, label: "Deep")]
		askAnswer.other = "Deep, with examples"

		var explainAnswer = QuestionAnswerData(kind: .explain, questionText: "Explain why a LEFT JOIN can produce NULLs.", dontKnow: false, answers: [], answeredAt: iso.string(from: now))
		explainAnswer.tool = "explain"
		explainAnswer.text = "Unmatched left rows still need right-side columns."
		explainAnswer.committed = "Missing partners are filled with NULL."

		let dismissed = dismissedAnswer(.quiz, questionText: "A skipped check")

		let research = SubagentResult.research(ResearchResult(brief: "## Findings\n\nJoins date back to **Codd** (1970).", sources: [ResearchSource(title: "A Relational Model of Data", url: "https://example.com/codd")]))
		let pdf = SubagentResult.pdf(PdfResult(path: "/tmp/notes.pdf", question: "What is 3NF?", brief: "Third normal form removes **transitive** dependencies.", pagesRead: [3, 4], pagesConsulted: [3, 4, 9]))
		let visual = SubagentResult.visual(VisualResult(svg: """
			<svg xmlns="http://www.w3.org/2000/svg" width="320" height="140" viewBox="0 0 320 140"><rect x="10" y="20" width="120" height="100" fill="none" stroke="#1565c0" stroke-width="3"/><circle cx="230" cy="70" r="50" fill="#ef6c00" opacity="0.8"/><text x="70" y="75" text-anchor="middle" font-family="sans-serif" font-size="14">table A</text></svg>
			"""))
		let demo = SubagentResult.demo(DemoResult(title: "Join Explorer", html: """
			<!doctype html><html><head><style>body{font:14px -apple-system,sans-serif;margin:16px}canvas{border:1px solid #ccc;display:block;margin:8px 0}</style></head>
			<body><label>Overlap <input id="k" type="range" min="0" max="100" value="40"></label> <span id="v">40%</span>
			<canvas id="c" width="420" height="140"></canvas><button id="boom">Throw an error</button>
			<script>
			const c = document.getElementById("c").getContext("2d"), k = document.getElementById("k"), v = document.getElementById("v");
			function draw() { const o = +k.value; v.textContent = o + "%"; c.clearRect(0, 0, 420, 140);
				c.globalAlpha = 0.6; c.fillStyle = "#1565c0"; c.beginPath(); c.arc(150, 70, 60, 0, 7); c.fill();
				c.fillStyle = "#ef6c00"; c.beginPath(); c.arc(270 - o, 70, 60, 0, 7); c.fill(); }
			k.oninput = draw; draw();
			document.getElementById("boom").onclick = () => { null.rows; };
			</script></body></html>
			"""))

		var messages: [Message] = []
		messages.append(newGraphContextMessage(picks: [GraphContextPick(id: "n_1", name: "Relation", statement: "A set of tuples sharing a schema.")], chains: ["Relation, Key → Join"], id: "gc", now: tick()))
		messages.append(newUserMessage("Teach me SQL joins — I know some Python.", id: "u1", now: tick()))
		messages.append(assistant("a1", [.thinking("The learner knows Python; start with a probe.", signature: nil), .text("Let's see what you already know."), .toolUse(id: "c_probe", name: "probe", input: ["question": "What does SQL stand for?"])], stop: "tool_use"))
		messages.append(result("c_probe", "probe", probeAnswer.json))
		messages.append(assistant("a2", [.toolUse(id: "c_ask", name: "ask_user_question", input: ["question": "How deep should we go?", "details": "Pick one — or write your own.", "options": [["label": "Overview", "description": "The shape of it"], ["label": "Deep", "description": "Every join kind"]]])], stop: "tool_use"))
		messages.append(result("c_ask", "ask_user_question", askAnswer.json))
		messages.append(assistant("a3", [.toolUse(id: "c_ls", name: "ls", input: ["path": "~/notes"]), .toolUse(id: "c_grep", name: "grep", input: ["pattern": "JOIN"])], stop: "tool_use"))
		messages.append(result("c_ls", "ls", ["text": "joins.md\nkeys.md"]))
		messages.append(result("c_grep", "grep", nil, error: true, text: "Pattern failed to compile"))
		messages.append(assistant("a4", [.toolUse(id: "c_done", name: "probe_done", input: ["assessment": ["strands": [["strand": "SQL basics", "assessment": "Knows SELECT; joins are new."]], "summary": "Ready for joins."]])], stop: "tool_use"))
		messages.append(result("c_done", "probe_done", ["ok": true]))
		messages.append(newHandoffMessage(chatId: chatId, now: tick()))
		messages.append(assistant("a5", [.text("Here's the plan."), .toolUse(id: "c_plan", name: "plan_init", input: ["nodes": tree["nodes"]!])], stop: "tool_use"))
		messages.append(result("c_plan", "plan_init", ["ok": true, "tree": tree]))
		messages.append(newPlanBlockMessage(planCallId: "c_plan", block: block.blockJSON, now: tick()))
		messages.append(assistant("a6", [.text(markdown), .toolUse(id: "c_quiz", name: "quiz", input: ["nodeId": "inner", "question": "Which rows does an **inner join** keep when $k$ matches?", "details": "Think about the *overlap*."])], stop: "tool_use"))
		messages.append(result("c_quiz", "quiz", quizAnswer.json))
		messages.append(assistant("a7", [.toolUse(id: "c_explain", name: "explain", input: ["nodeId": "outer", "question": "Explain why a LEFT JOIN can produce NULLs."]), .toolUse(id: "c_skip", name: "quiz", input: ["nodeId": "keys", "question": "A skipped check"])], stop: "tool_use"))
		messages.append(result("c_explain", "explain", explainAnswer.json))
		messages.append(result("c_skip", "quiz", dismissed.json))
		messages.append(assistant("a8", [.toolUse(id: "c_research", name: "research", input: ["question": "History of joins"]), .toolUse(id: "c_pdf", name: "pdf", input: ["path": "/tmp/notes.pdf"]), .toolUse(id: "c_visual", name: "visual", input: ["brief": "Two tables"]), .toolUse(id: "c_demo", name: "demo", input: ["brief": "Join explorer"])], stop: "tool_use"))
		for (c, tool) in [("c_research", "research"), ("c_pdf", "pdf"), ("c_visual", "visual"), ("c_demo", "demo")] {
			messages.append(Message(id: "tr_\(c)", timestamp: tick(), body: .toolResult(ToolResultBody(toolUseId: c, toolName: tool, content: [.text("Dispatched.")], isError: false))))
		}
		messages.append(buildSubagentSteer(jobId: "job_r", kind: .research, toolCallId: "c_research", result: research, now: tick()))
		messages.append(buildSubagentSteer(jobId: "job_p", kind: .pdf, toolCallId: "c_pdf", result: pdf, now: tick()))
		messages.append(buildSubagentSteer(jobId: "job_v", kind: .visual, toolCallId: "c_visual", result: visual, now: tick()))
		messages.append(buildSubagentSteer(jobId: "job_d", kind: .demo, toolCallId: "c_demo", result: demo, now: tick()))
		messages.append(buildAbortSteer(jobId: "job_x", kind: .research, toolCallId: "c_research_2", now: tick()))
		messages.append(newUserMessage("Can you help me with something harmful?", id: "u2", now: tick()))
		messages.append(assistant("a9", [.text("I can't help with that part.")], stop: "refusal", details: ["category": "cyber", "explanation": "This request falls outside what I can help with."]))
		messages.append(newCompactionMarker(summary: "Summary of joins so far.", details: CompactionDetails(firstKeptMessageId: "u3", tokensBefore: 182_000, at: iso.string(from: now)), id: "cmp", now: tick()))
		messages.append(newUserMessage("Let's practice.", id: "u3", now: tick()))
		messages.append(assistant("a10", [.toolUse(id: "c_problem", name: "problem", input: ["statement": "Write a query joining $A$ and $B$ on `id`.", "modelSolution": "SELECT * FROM A JOIN B USING (id);", "mode": "practice", "target": ["n_1"]])], stop: "tool_use"))
		messages.append(newThinkingMessage(problemCallId: "c_problem", text: "Maybe USING (id) works here.", id: "pt", now: tick()))
		messages.append(assistant("a11", [.toolUse(id: "c_conclude", name: "conclude", input: ["outcome": "solvedWithHints", "verdict": "Right idea — the hint about USING landed.", "rung": "R1", "missClass": "execution", "retest": true])], stop: "tool_use"))
		messages.append(result("c_conclude", "conclude", ["ok": true]))
		messages.append(newNextMessage(id: "pn", now: tick()))
		let (call, res) = concludedByDismissalPair(problemCallId: "c_problem", now: tick())
		messages.append(newProblemDismissedMarker(problemCallId: "c_problem", id: "pd", now: tick()))
		messages.append(call)
		messages.append(res)
		// End settled: a gallery that owed a turn would resume on open (M5) and
		// spend a real request.
		messages.append(assistant("a12", [.text("That's every card in the gallery.")]))

		let created = iso.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
		let turns = [TurnUsage(id: "turn_1", messageId: "a6", at: created, model: "claude-opus-5-5", steps: [
			CallUsage(inputTokens: 1200, outputTokens: 800, cacheReadTokens: 30_000, cacheWriteTokens: 4_000),
		])]
		return ChatRecord(id: chatId, title: "Render gallery — every marker kind", createdAt: created, updatedAt: iso.string(from: now), messages: messages, kind: .teach, turns: turns)
	}
}

extension AppModel {
	/// Debug: (re)insert the gallery session and open it.
	func addRenderGallery() {
		let repo = ChatRepository(database)
		_ = try? repo.delete(RenderGallery.chatId)
		do {
			try repo.insert(RenderGallery.record(), origin: .native)
			selection = RenderGallery.chatId
		} catch {
			let alert = NSAlert(error: error)
			alert.runModal()
		}
	}
}
