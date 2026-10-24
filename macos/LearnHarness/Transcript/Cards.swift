import LHCore
import LHMarkdown
import LHStore
import SwiftUI

// The transcript's cards, ported from the TS renderers named on each.

/// The document row for learner text (chat.tsx user band): a full-width
/// card-color band with the authorship rail; "YOU" heading inside it;
/// plain text at full opacity — no markdown, no LaTeX.
struct UserBand: View {
	var text: String
	var unit: String

	var body: some View {
		HStack(spacing: 0) {
			Rectangle().fill(Theme.muted.opacity(0.3)).frame(width: Theme.railWidth)
			VStack(alignment: .leading, spacing: 2) {
				Eyebrow("You")
				HighlightedPlainText(text: text, unit: unit, font: Theme.prose)
			}
			.padding(.leading, Theme.railGap)
			.padding(.trailing, 16)
			.padding(.vertical, 4)
		}
		.fixedSize(horizontal: false, vertical: true)
		.background(Theme.card)
		.padding(.vertical, 8)
	}
}

/// The learner's own thinking (thinking-block.tsx): a trigger row (label +
/// chevron); open shows the quote — rail, 50% italic. Transcript rows are
/// bands; in-card rows take no band.
struct ThinkingBlock: View {
	var label = "YOUR THINKING"
	var text: String
	var id: String
	var defaultOpen = false
	var inCard = false
	@Environment(SessionModel.self) private var session

	var body: some View {
		let open = session.isOpen(id, default: defaultOpen)
		HStack(spacing: 0) {
			Rectangle().fill(Theme.muted.opacity(0.3)).frame(width: Theme.railWidth)
			VStack(alignment: .leading, spacing: 4) {
				Button {
					session.setOpen(id, !open)
				} label: {
					HStack(spacing: 6) {
						Eyebrow(label)
						Chevron(open: open)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				if open {
					HighlightedPlainText(text: text, unit: "\(id).text", font: Theme.prose.italic())
						.opacity(0.5)
				}
			}
			.padding(.leading, Theme.railGap)
			.padding(.trailing, 16)
			.padding(.vertical, 4)
		}
		.fixedSize(horizontal: false, vertical: true)
		.background(inCard ? Color.clear : Theme.card)
		.padding(.vertical, inCard ? 4 : 8)
	}
}

/// The agent's reasoning (ai-elements/reasoning.tsx): collapsed by default,
/// "AGENT'S THINKING" + chevron; open shows the markdown, small and muted.
/// While streaming: spinner + shimmered "Thinking…"; if you opened it while
/// it streamed, it closes 1s after streaming ends.
struct ReasoningRow: View {
	var text: String
	var id: String
	var streaming = false
	@Environment(SessionModel.self) private var session
	@State private var openedWhileStreaming = false

	var body: some View {
		let open = session.isOpen(id)
		VStack(alignment: .leading, spacing: 6) {
			Button {
				session.setOpen(id, !open)
				if streaming, !open { openedWhileStreaming = true }
			} label: {
				HStack(spacing: 6) {
					if streaming {
						BrailleSpinner()
						ShimmerText(text: "Thinking…")
					} else {
						Eyebrow("Agent's thinking")
					}
					Chevron(open: open)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if open, !text.isEmpty {
				MarkdownView(text, unit: "\(id).body", font: Theme.small, fontSize: 13)
					.foregroundStyle(Theme.muted)
			}
		}
		.padding(.bottom, 8)
		.onChange(of: streaming) { was, now in
			guard was, !now, openedWhileStreaming else { return }
			openedWhileStreaming = false
			Task {
				try? await Task.sleep(for: .seconds(1))
				session.setOpen(id, false)
			}
		}
	}
}

/// live-tool-card.tsx: a tool call being written — spinner, the shimmered
/// activity label, the headline argument; expanding shows the streaming input.
struct LiveToolCard: View {
	var part: ViewPart
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		let open = session.isOpen(id)
		VStack(alignment: .leading, spacing: 6) {
			Button {
				session.setOpen(id, !open)
			} label: {
				HStack(spacing: 8) {
					BrailleSpinner()
					ShimmerText(text: toolActivityLabel(part.toolName ?? ""))
					if let arg = headline { Text(arg).font(Theme.ui).foregroundStyle(Theme.muted).lineLimit(1) }
					Chevron(open: open).opacity(0.5)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if open {
				VStack(alignment: .leading, spacing: 4) {
					Eyebrow("Input (streaming)")
					Text(part.input.map { $0.serialized(indent: 2) } ?? "…")
						.font(Theme.monoSmall)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.card(padding: 12)
			}
		}
		.padding(.vertical, 4)
	}

	private var headline: String? {
		let i = part.input
		return i?["path"]?.stringValue ?? i?["pattern"]?.stringValue ?? i?["session"]?.stringValue
	}
}

/// braille-spinner.tsx: the one working-state indicator.
struct BrailleSpinner: View {
	private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
	var body: some View {
		TimelineView(.periodic(from: .now, by: 0.08)) { context in
			let i = Int(context.date.timeIntervalSinceReferenceDate / 0.08) % Self.frames.count
			Text(Self.frames[i]).font(Theme.ui).foregroundStyle(Theme.muted)
		}
		.accessibilityLabel("Working")
	}
}

/// shimmer.tsx: muted caps text with a moving highlight.
struct ShimmerText: View {
	var text: String
	var body: some View {
		TimelineView(.animation) { context in
			let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
			Text(text.uppercased())
				.font(Theme.uiMedium)
				.tracking(0.6)
				.foregroundStyle(LinearGradient(
					stops: [.init(color: Theme.muted, location: 0), .init(color: Theme.muted, location: max(0, t - 0.15)),
						.init(color: .primary, location: t), .init(color: Theme.muted, location: min(1, t + 0.15)), .init(color: Theme.muted, location: 1)],
					startPoint: .leading, endPoint: .trailing))
		}
	}
}

/// PhaseDivider: Planning / Teaching (probe never renders a seam).
struct PhaseDividerView: View {
	var phase: Phase3
	var body: some View {
		switch phase {
		case .probe: EmptyView()
		case .plan: DottedDivider(label: "Planning")
		case .teach: DottedDivider(label: "Teaching")
		}
	}
}

/// The phase label (PhaseChip): toolbar register, non-interactive.
func phaseLabel(_ phase: Phase3) -> String {
	switch phase {
	case .probe: "Probing"
	case .plan: "Planning"
	case .teach: "Teaching"
	}
}

/// GraphContextCard: collapsed dashed one-liner; open lists the picked
/// propositions (name — statement) and the chain lines.
struct GraphContextCard: View {
	var data: JSONValue
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		let open = session.isOpen(id)
		let props = data["propositions"]?.arrayValue ?? []
		let chains = (data["chains"]?.arrayValue ?? []).compactMap(\.stringValue)
		VStack(alignment: .leading, spacing: 4) {
			Button {
				session.setOpen(id, !open)
			} label: {
				HStack(spacing: 8) {
					Chevron(open: open)
					Text("Graph context").fontWeight(.medium)
					Text(noun(props.count, "proposition", "propositions") + (chains.isEmpty ? "" : " · " + noun(chains.count, "chain", "chains")))
						.lineLimit(1)
					Spacer(minLength: 0)
				}
				.font(Theme.ui)
				.foregroundStyle(Theme.muted)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if open {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(props.enumerated()), id: \.offset) { _, p in
						(Text(p["name"]?.stringValue ?? "").fontWeight(.medium).foregroundStyle(.primary.opacity(0.8))
							+ Text(" — \(p["statement"]?.stringValue ?? "")").foregroundStyle(Theme.muted))
					}
					if !chains.isEmpty {
						VStack(alignment: .leading, spacing: 0) {
							ForEach(Array(chains.enumerated()), id: \.offset) { _, c in
								Text(c).font(Theme.monoSmall).foregroundStyle(Theme.muted)
							}
						}
						.padding(.top, 4)
					}
				}
				.font(Theme.ui)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
				.background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
			}
		}
		.padding(.vertical, 4)
	}

	private func noun(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

/// The refusal line (your answer, docs/native-macos-m4.md): one centered
/// muted line; the explanation, when stop_details carries one, behind a
/// disclosure.
struct RefusalLine: View {
	var explanation: String?
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		let open = session.isOpen(id)
		VStack(spacing: 6) {
			if let explanation {
				Button {
					session.setOpen(id, !open)
				} label: {
					HStack(spacing: 6) {
						Text("Claude declined to continue this response.")
						Chevron(open: open)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				if open {
					Text(explanation).textSelection(.enabled).multilineTextAlignment(.center)
				}
			} else {
				Text("Claude declined to continue this response.")
			}
		}
		.font(Theme.ui)
		.foregroundStyle(Theme.muted)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 6)
	}
}

// MARK: - The answered question (answered-card.tsx)

struct AnsweredCard: View {
	var answer: QuestionAnswerData
	var input: JSONValue?
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		if answer.dismissed == true {
			(Text(answer.questionText).fontWeight(.medium) + Text(" — skipped"))
				.font(Theme.small)
				.foregroundStyle(Theme.muted)
				.card()
		} else {
			VStack(alignment: .leading, spacing: 0) {
				if let reading = answer.readingThinking {
					ThinkingBlock(text: reading, id: "\(id).reading", defaultOpen: true)
				}
				content.card()
			}
		}
	}

	private var isQuiz: Bool { answer.kind == .quiz }
	private var isExplain: Bool { answer.kind == .explain }

	private var eyebrow: String {
		if answer.tool == "probe" { return "Probe" }
		if answer.tool == "recall" { return "Recall" }
		if isQuiz { return answer.questionType == .predict ? "Prediction" : "Check" }
		return isExplain ? "Explain" : "Question"
	}

	private var content: some View {
		let selected = Set(answer.answers.map(\.index))
		let correct = Set(answer.correctIndices ?? [])
		let askOptions = answer.kind == .ask ? input.flatMap(parseAskInput)?.options : nil
		return VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				Eyebrow(eyebrow)
				if isQuiz {
					if answer.dontKnow { Chip(text: "didn't know", tint: nil) }
					else if answer.correct == true { Chip(text: "correct", tint: Theme.green) }
					else { Chip(text: "incorrect", tint: Theme.red) }
				}
			}
			.padding(.bottom, 4)
			MarkdownView(answer.questionText, unit: "\(id).q").fontWeight(.medium).padding(.bottom, 12)
			if let details = answeredDetails(answer, input: input) {
				MarkdownView(details, unit: "\(id).d", font: Theme.small, fontSize: 13)
					.foregroundStyle(Theme.muted)
					.padding(.bottom, 12)
			}
			if !(answer.options ?? []).isEmpty || answer.other != nil {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(answer.options ?? [], id: \.index) { opt in
						optionRow(opt, selected: selected.contains(opt.index), key: isQuiz && correct.contains(opt.index),
							description: askOptions.flatMap { $0.indices.contains(opt.index - 1) ? $0[opt.index - 1].description : nil })
					}
					if let other = answer.other {
						Text("“\(other)”")
							.font(Theme.small)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
							.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor))
					}
				}
			}
			if let text = answer.text {
				Text("“\(text)”").font(Theme.prose).textSelection(.enabled).padding(.top, 8)
			}
			if isQuiz, let confidence = answer.confidence {
				HStack(spacing: 12) {
					ConfidenceRail(value: confidence)
					Text("\(Int(confidence.rounded()))%")
						.font(Theme.mono)
						.monospacedDigit()
						.foregroundStyle(Theme.muted)
						.frame(width: 36, alignment: .trailing)
				}
				.padding(.top, 12)
			}
			if answer.dontKnow && isQuiz {
				Text("Answered “I don't know”.").font(Theme.small).foregroundStyle(Theme.muted).padding(.top, 8)
			}
			if let thinking = answer.thinking ?? answer.note {
				ThinkingBlock(text: thinking, id: "\(id).thinking", inCard: true).padding(.top, 8)
			}
			if isQuiz, let why = answer.explanation {
				let open = session.isOpen("\(id).why")
				VStack(alignment: .leading, spacing: 6) {
					Button(open ? "Hide why" : "Why") { session.setOpen("\(id).why", !open) }
						.buttonStyle(.plain)
						.font(Theme.uiMedium)
						.foregroundStyle(Theme.muted)
					if open {
						HStack(alignment: .firstTextBaseline, spacing: 4) {
							Text("Why:").fontWeight(.medium).foregroundStyle(Theme.muted)
							MarkdownView(why, unit: "\(id).why", font: Theme.small, fontSize: 13).opacity(0.5)
						}
						.font(Theme.small)
						.padding(.vertical, 8)
						.padding(.horizontal, 8)
						.background(RoundedRectangle(cornerRadius: 8).fill(Theme.mutedFill))
					}
				}
				.padding(.top, 8)
			}
			if isExplain, let committed = answer.committed {
				HStack(alignment: .firstTextBaseline, spacing: 4) {
					Text("The answer:").fontWeight(.medium)
					MarkdownView(committed, unit: "\(id).c", font: Theme.small, fontSize: 13).foregroundStyle(Theme.muted)
				}
				.font(Theme.small)
				.padding(8)
				.background(RoundedRectangle(cornerRadius: 8).fill(Theme.mutedFill))
				.padding(.top, 12)
			}
		}
	}

	private func optionRow(_ opt: QuestionAnswerData.OptionSnapshot, selected sel: Bool, key: Bool, description: String?) -> some View {
		let stroke: Color = sel && key ? Theme.green.opacity(0.6) : sel && isQuiz ? Theme.red.opacity(0.6) : sel ? Color.accentColor : key ? Theme.green.opacity(0.4) : Theme.border
		let fill: Color = sel && key ? Theme.green.opacity(0.1) : sel && isQuiz ? Theme.red.opacity(0.1) : sel ? Color.accentColor.opacity(0.1) : .clear
		return HStack(alignment: .firstTextBaseline, spacing: 8) {
			if isQuiz {
				Group {
					if key { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
					else if sel { Image(systemName: "xmark").foregroundStyle(Theme.red) }
					else { Color.clear }
				}
				.font(.system(size: 11, weight: .semibold))
				.frame(width: 14)
			}
			VStack(alignment: .leading, spacing: 2) {
				MarkdownView(opt.label, unit: "\(id).o\(opt.index)", font: Theme.small, fontSize: 13)
					.foregroundStyle(sel ? .primary : Theme.muted)
				if let description {
					MarkdownView(description, unit: "\(id).od\(opt.index)", font: Theme.ui, fontSize: 11).foregroundStyle(Theme.muted)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(fill))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stroke))
	}
}

/// The confidence record (confidence-rail.tsx): the slider's rail without a
/// handle — a filled track up to the value with quarter ticks.
struct ConfidenceRail: View {
	var value: Double
	var body: some View {
		GeometryReader { geo in
			let w = geo.size.width
			ZStack(alignment: .leading) {
				Capsule().fill(Theme.mutedFill)
				Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(0, min(1, value / 100)) * w)
				ForEach([0.25, 0.5, 0.75], id: \.self) { t in
					Rectangle().fill(Theme.border).frame(width: 1, height: 8).offset(x: t * w)
				}
			}
		}
		.frame(height: 6)
	}
}

// MARK: - Tool cards (components/artifacts/*, practice-cards.tsx)

struct ToolPartCard: View {
	var part: ViewPart
	var id: String

	var body: some View {
		switch part.toolName ?? "" {
		case "probe_done": ProbeDoneCard(part: part)
		case "problem": ProblemCard(part: part, id: id)
		case "conclude": ConcludeCard(part: part, id: id)
		case let name where DISPATCH_TOOLS.contains(name): DispatchCard(part: part, kind: name)
		default: ToolCallCard(part: part, id: id)
		}
	}
}

/// probe-done-card.tsx: the learner assessment, strand by strand.
struct ProbeDoneCard: View {
	var part: ViewPart
	var body: some View {
		let ok = part.output?["ok"]?.boolValue
		let parsed = part.input.flatMap(parseProbeDoneInput)
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(Color.accentColor)
				Eyebrow("Probe concluded — your assessment")
			}
			if ok == false {
				Text("The prober retried: \(part.output?["error"]?.stringValue ?? "")").font(Theme.small).foregroundStyle(Theme.muted)
			} else if part.state == .outputError {
				Text("The assessment was malformed — the prober retried with a corrected one.").font(Theme.small).foregroundStyle(Theme.muted)
			} else if let assessment = parsed?.assessment {
				VStack(alignment: .leading, spacing: 8) {
					ForEach(Array(assessment.strands.enumerated()), id: \.offset) { _, s in
						VStack(alignment: .leading, spacing: 2) {
							Text(s.strand).font(Theme.small).fontWeight(.medium)
							Text(s.assessment).font(Theme.small).foregroundStyle(Theme.muted)
						}
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
						.background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
					}
					if let summary = assessment.summary {
						Text(summary).font(Theme.small).foregroundStyle(Theme.muted).textSelection(.enabled).padding(.horizontal, 4)
					}
				}
			} else {
				Text("Writing the assessment…").font(Theme.small).foregroundStyle(Theme.muted)
			}
		}
		.card(padding: 12)
		.padding(.vertical, 12)
	}
}

/// ProblemCard: always open — the PROBLEM eyebrow and the statement.
struct ProblemCard: View {
	var part: ViewPart
	var id: String
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Eyebrow("Problem")
			MarkdownView(repairMathForDisplay(part.input?["statement"]?.stringValue ?? ""), unit: "\(id).s", font: .system(size: 15, design: .serif), fontSize: 15)
		}
		.card()
		.padding(.vertical, 4)
	}
}

/// ConcludeCard: CONCLUDED + outcome chip, the verdict at half opacity, a
/// rule, MODEL SOLUTION; the METADATA popover. A dismissal is one line.
struct ConcludeCard: View {
	var part: ViewPart
	var id: String
	@State private var metadataOpen = false
	@Environment(SessionModel.self) private var session

	private static let outcomeLabel = ["solved": "Solved", "solvedWithHints": "Solved with hints", "movedOn": "Moved on", "surrendered": "Surrendered", "dismissed": "Dismissed"]

	var body: some View {
		let input = part.input ?? .object(JSONObject())
		let outcome = input["outcome"]?.stringValue ?? ""
		let verdict = input["verdict"]?.stringValue ?? ""
		let reveal = part.reveal ?? input["solutionReveal"]?.stringValue ?? ""
		if outcome == "dismissed" {
			Text("Problem dismissed.").font(Theme.small).foregroundStyle(Theme.faint).padding(.horizontal, 4).padding(.vertical, 4)
		} else {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					Eyebrow("Concluded")
					if let label = Self.outcomeLabel[outcome] { Chip(text: label, tint: tint(outcome)) }
				}
				.padding(.bottom, 4)
				if !verdict.isEmpty {
					MarkdownView(repairMathForDisplay(verdict), unit: "\(id).v", font: Theme.small, fontSize: 13).opacity(0.5)
				}
				if !reveal.isEmpty {
					Divider().padding(.vertical, 12)
					Eyebrow("Model solution").padding(.bottom, 2)
					MarkdownView(repairMathForDisplay(reveal), unit: "\(id).r", font: .system(size: 15, design: .serif), fontSize: 15)
				}
				metadata(input)
			}
			.card()
			.padding(.vertical, 4)
		}
	}

	private func tint(_ outcome: String) -> Color? {
		switch outcome {
		case "solved": Theme.green
		case "solvedWithHints": Theme.amber
		case "surrendered": Theme.red
		default: nil
		}
	}

	@ViewBuilder
	private func metadata(_ concludeInput: JSONValue) -> some View {
		let problem = part.problemInput ?? .object(JSONObject())
		let mode = problem["mode"]?.stringValue ?? ""
		let targets = (problem["target"]?.arrayValue ?? []).compactMap(\.stringValue)
		let rung = concludeInput["rung"]?.stringValue ?? ""
		let miss = concludeInput["missClass"]?.stringValue ?? ""
		let retest = concludeInput["retest"]?.boolValue
		let outcome = concludeInput["outcome"]?.stringValue ?? ""
		if !mode.isEmpty || !targets.isEmpty || !rung.isEmpty || !miss.isEmpty || retest != nil {
			Button("Metadata") { metadataOpen.toggle() }
				.buttonStyle(.plain)
				.font(Theme.uiMedium)
				.foregroundStyle(Theme.muted)
				.padding(.top, 12)
				.popover(isPresented: $metadataOpen, arrowEdge: .bottom) {
					Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
						row("Mode", mode.isEmpty ? "—" : mode)
						row("Targets", targets.isEmpty ? "untagged" : targets.map(session.nodeName).joined(separator: ", "))
						row("Outcome", outcome.isEmpty ? "—" : outcome)
						row("Hint rung", rung.isEmpty ? "none" : rung)
						row("Miss class", miss.isEmpty ? "none" : miss)
						row("Retest", retest.map { $0 ? "yes" : "no" } ?? "—")
					}
					.font(Theme.ui)
					.padding(16)
					.frame(width: 320, alignment: .leading)
				}
		}
	}

	private func row(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(label).foregroundStyle(Theme.muted)
			Text(value).font(Theme.monoSmall).textSelection(.enabled)
		}
	}
}

/// tool-call-card.tsx: a quiet one-liner (tool + headline argument),
/// expandable to INPUT and OUTPUT / ERROR.
struct ToolCallCard: View {
	var part: ViewPart
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		let tool = part.toolName ?? ""
		let open = session.isOpen(id)
		let failed = part.state == .outputError || part.errorText != nil
		VStack(alignment: .leading, spacing: 8) {
			Button {
				session.setOpen(id, !open)
			} label: {
				HStack(spacing: 8) {
					Eyebrow(tool, color: failed ? Theme.red : Theme.muted)
					let arg = headline(tool)
					if !arg.isEmpty { Text(arg).font(Theme.ui).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle) }
					Chevron(open: open).opacity(0.5)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if open {
				VStack(alignment: .leading, spacing: 8) {
					if let input = part.input {
						section("Input", input.serialized(indent: 2), color: .primary)
					}
					if let error = part.errorText {
						section("Error", error, color: Theme.red)
					} else if let out = outputText(part.output) {
						section("Output", out, color: .primary)
					} else if part.state != .outputAvailable {
						Text("running…").italic().foregroundStyle(Theme.muted)
					}
				}
				.font(Theme.ui)
				.card(padding: 12)
			}
		}
		.frame(maxWidth: 672, alignment: .leading)
		.padding(.vertical, 4)
	}

	private func headline(_ tool: String) -> String {
		let input = part.input
		if tool == "read" || tool == "ls" {
			let p = input?["path"]?.stringValue ?? ""
			return p.isEmpty ? "~" : p
		}
		if let pattern = input?["pattern"]?.stringValue { return pattern }
		if tool == "list_propositions", let s = input?["session"]?.stringValue, !s.isEmpty { return s }
		return ""
	}

	private func outputText(_ output: JSONValue?) -> String? {
		guard let output, !output.isNull else { return nil }
		if let s = output.stringValue { return s }
		if output["text"] != nil || output["images"] != nil {
			let text = output["text"]?.stringValue
			let n = output["images"]?.arrayValue?.count ?? 0
			if n > 0 { return "\(text ?? "")\n[\(n) image\(n > 1 ? "s" : "") attached to the model]".trimmingCharacters(in: .whitespacesAndNewlines) }
			return text
		}
		return output.serialized(indent: 2)
	}

	private func section(_ label: String, _ text: String, color: Color) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Eyebrow(label)
			ScrollView {
				Text(text).font(Theme.monoSmall).foregroundStyle(color).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: label == "Input" ? 128 : 256)
		}
	}
}

/// dispatch-card.tsx: the running form (spinner, label, `· Ns`, the
/// activity line, or "Dispatched…" before the job row exists), then the
/// settled "✓ LABEL delivered" / "✗ LABEL failed".
struct DispatchCard: View {
	var part: ViewPart
	var kind: String
	@Environment(SessionModel.self) private var session

	private var label: String {
		switch kind {
		case "research": "Research agent"
		case "demo": "Demo agent"
		case "visual": "Figure agent"
		default: "PDF reader"
		}
	}

	var body: some View {
		let job = part.toolCallId.flatMap(session.job(toolCallId:))
		Group {
			if let job, job.status != .running {
				HStack(spacing: 8) {
					if isProviderKeyRefusal(job.error) {
						Image(systemName: "gearshape")
						Eyebrow(label)
						Text("needs a provider key")
					} else {
						Image(systemName: job.status == .error ? "xmark" : "checkmark").foregroundStyle(job.status == .error ? Theme.red : Theme.muted)
						Eyebrow(label)
						Text(job.status == .error ? "failed" : "delivered")
					}
				}
				.font(Theme.ui)
				.foregroundStyle(Theme.muted)
			} else {
				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 8) {
						BrailleSpinner()
						Eyebrow(label)
						if let started = job.flatMap({ ISOClock.date($0.createdAt) }) {
							TimelineView(.periodic(from: .now, by: 1)) { context in
								Text("· \(max(0, Int(context.date.timeIntervalSince(started))))s").font(Theme.ui).foregroundStyle(Theme.muted).monospacedDigit()
							}
						}
					}
					Text(job.map(\.activity) ?? "Dispatched…").font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.card()
			}
		}
		.padding(.vertical, 4)
	}
}
