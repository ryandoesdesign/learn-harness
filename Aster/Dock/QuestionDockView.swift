import LHCore
import SwiftUI

/// question-dock.tsx: the pending question, shown inline where it was
/// asked — every teaching kind — quiz
/// single/multi (seeded shuffle), predict, probe, recall/explain (free
/// text), ask (option descriptions + "Other"). "I don't know", the
/// confidence rail, the thinking field; Submit builds the answer (buildAnswer).
/// "Ask about it" sets the question aside to ask the teacher instead (the
/// field below becomes the question; Discuss.swift).
/// Keys (the dock's own): ↑/↓ walk the rows (clamped), Space acts on the
/// walked row, ←/→ step confidence, Enter submits.
struct QuestionDockView: View {
	@Bindable var session: SessionModel
	var tool: String
	var toolCallId: String
	var input: JSONValue

	@State private var sel = emptyDockSelection()
	@State private var thinking = ""
	@State private var other = ""
	@State private var text = ""
	@State private var confIdx = DEFAULT_CONFIDENCE_INDEX
	/// "Ask about it": the learner field holds a question for the teacher.
	@State private var asking = false
	@State private var askText = ""
	@State private var walked: Int?
	static let maxBody: CGFloat = 420
	@FocusState private var focus: Field?
	@Environment(DictationService.self) private var dictation: DictationService?

	enum Field: Hashable { case rows, other, learner }

	/// The skill this question tests: its own nodeId's title (an untagged
	/// question names none — the map's node may already be behind).
	private var skill: String? { questionSkill(input: input, plan: session.plan) }

	var body: some View {
		Group { card }
			// A card set aside to ask about it comes back as it was left.
			.onAppear {
				guard let d = session.cardDrafts.removeValue(forKey: reposeOrigin(toolCallId)) else { return }
				(sel, thinking, other, text, confIdx) = (d.sel, d.thinking, d.other, d.text, d.confIdx)
				// The same card (scrolled back, or a refused ask) keeps its asking; a
				// re-posed copy comes back without the question already asked.
				if d.callId == toolCallId { (asking, askText) = (d.asking, d.askText) }
			}
			// Also a card scrolled out of the lazy transcript keeps what was started;
			// an answered one (in flight, not set aside) has nothing to keep.
			.onDisappear {
				guard session.discussedOrigin == reposeOrigin(toolCallId) || session.status == .idle else { return }
				session.cardDrafts[reposeOrigin(toolCallId)] = QuestionCardDraft(callId: toolCallId, sel: sel, thinking: thinking, other: other, text: text, confIdx: confIdx, asking: asking, askText: askText)
			}
	}

	@ViewBuilder private var card: some View {
		if let qd = dockQuestion(tool: tool, toolCallId: toolCallId, input: input) {
			let label = dockLabel(tool: tool, question: qd, skill: skill)
			if session.waitsForReveal(tool: tool, toolCallId: toolCallId, input: input) {
				DockBar(reveal: true, label: label, question: qd.question) { session.revealedChecks.insert(toolCallId) }
			} else {
				form(qd, label: label)
			}
		} else {
			Text("This question arrived malformed — the transcript keeps the retry.")
				.font(Theme.small)
				.foregroundStyle(Theme.muted)
				.padding(12)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
		}
	}

	// MARK: Form

	private func form(_ qd: QuestionData, label: String) -> some View {
		let mode: SelectMode = qd.mode == .multiSelect ? .multiSelect : .singleSelect
		let rows = rowCount(qd)
		return VStack(alignment: .leading, spacing: 10) {
			Eyebrow(label + (qd.mode == .multiSelect ? " · select all that apply" : ""))
				.lineLimit(1)
			HuggingScroll(maxHeight: Self.maxBody) {
				VStack(alignment: .leading, spacing: 10) {
					MarkdownView(qd.question, unit: "dock.q").fontWeight(.medium)
					if let context = qd.context {
						MarkdownView(context, unit: "dock.d", font: Theme.small, fontSize: 13).foregroundStyle(Theme.muted)
					}
					if qd.mode != .text {
						VStack(alignment: .leading, spacing: 6) {
							ForEach(Array(qd.options.enumerated()), id: \.offset) { i, opt in
								optionRow(opt, index: i, mode: mode, kind: qd.kind, walkedHere: walked == i)
							}
							if qd.kind == .quiz { dontKnowRow(walkedHere: walked == qd.options.count) }
							if qd.kind == .ask { otherRow(mode: mode, index: qd.options.count, walkedHere: walked == qd.options.count) }
							askRow(walkedHere: walked == askIndex(qd))
						}
						.focusable()
						.focused($focus, equals: .rows)
						.focusEffectDisabled()
						.onKeyPress(keys: [.upArrow, .downArrow, .space, .return, .leftArrow, .rightArrow]) { press in
							handleRowKey(press.key, qd: qd, mode: mode, rows: rows)
						}
					}
					if qd.kind == .quiz { confidence(disabled: sel.dontKnow || asking) }
				}
			}
			learnerField(qd)
			HStack {
				Text(session.compacting ? "compacting session…" : asking ? "↵ asks · ⇧↵ newline" : "↵ submits · ⇧↵ newline").font(Theme.ui).foregroundStyle(Theme.faint)
				Spacer()
				Button(asking ? "Ask" : "Submit answer") { submit(qd) }
					.buttonStyle(.borderedProminent)
					.disabled(!canSubmit(qd) || session.compacting)
			}
		}
		.padding(16)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
		// The first time a card shows it takes the focus — not again when it scrolls back into view.
		.onAppear {
			guard session.focusedCards.insert(toolCallId).inserted else { return }
			focus = qd.mode != .text ? .rows : .learner
		}
	}

	private func optionRow(_ opt: QuizOption, index: Int, mode: SelectMode, kind: QuestionKind, walkedHere: Bool) -> some View {
		let selected = sel.selected.contains(index)
		return Button {
			sel = toggleOption(mode, sel, index)
			asking = false
			walked = index
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				indicator(selected: selected, multi: mode == .multiSelect)
				VStack(alignment: .leading, spacing: 2) {
					MarkdownView(opt.label, unit: "dock.o\(index)", font: Theme.small, fontSize: 13)
					if kind == .ask, let d = opt.description {
						MarkdownView(d, unit: "dock.od\(index)", font: Theme.ui, fontSize: 11).foregroundStyle(Theme.muted)
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.contentShape(Rectangle())
			.background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : walkedHere ? Theme.muted : Theme.border))
		}
		.buttonStyle(.plain)
	}

	private func indicator(selected: Bool, multi: Bool) -> some View {
		Group {
			if multi {
				Image(systemName: selected ? "checkmark.square.fill" : "square")
			} else {
				Image(systemName: selected ? "largecircle.fill.circle" : "circle")
			}
		}
		.foregroundStyle(selected ? Color.accentColor : Theme.muted)
	}

	private func dontKnowRow(walkedHere: Bool) -> some View {
		Button {
			sel = sel.dontKnow ? emptyDockSelection() : DockSelection(selected: [], otherSelected: false, dontKnow: true)
			asking = false
		} label: {
			HStack(spacing: 10) {
				indicator(selected: sel.dontKnow, multi: false)
				Text("I don't know").font(Theme.small).foregroundStyle(sel.dontKnow ? .primary : Theme.muted)
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.contentShape(Rectangle())
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sel.dontKnow ? Color.accentColor : walkedHere ? Theme.muted : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
		}
		.buttonStyle(.plain)
	}

	/// "Ask about it": last in the rows, dashed like "I don't know"; it
	/// clears any selection (and an option or "I don't know" clears it).
	private func askRow(walkedHere: Bool) -> some View {
		Button { toggleAsking() } label: {
			HStack(spacing: 10) {
				indicator(selected: asking, multi: false)
				Text("Ask about it").font(Theme.small).foregroundStyle(asking ? .primary : Theme.muted)
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.contentShape(Rectangle())
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(asking ? Color.accentColor : walkedHere ? Theme.muted : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
		}
		.buttonStyle(.plain)
	}

	private func toggleAsking() {
		asking.toggle()
		if asking {
			sel = emptyDockSelection()
			focus = .learner
		}
	}

	private func otherRow(mode: SelectMode, index: Int, walkedHere: Bool) -> some View {
		HStack(spacing: 10) {
			Button { sel = toggleOther(mode, sel); asking = false } label: { indicator(selected: sel.otherSelected, multi: mode == .multiSelect) }
				.buttonStyle(.plain)
			TextField("Type your own answer…", text: $other)
				.textFieldStyle(.plain)
				.font(Theme.small)
				.focused($focus, equals: .other)
				.onChange(of: other) { _, v in
					if !v.isEmpty, !sel.otherSelected { sel = toggleOther(mode, sel); asking = false }
				}
				// Esc leaves the field and parks the row cursor on "Other".
				.onKeyPress(.escape) {
					walked = index
					focus = .rows
					return .handled
				}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sel.otherSelected ? Color.accentColor : walkedHere ? Theme.muted : Theme.border))
	}

	private func confidence(disabled: Bool) -> some View {
		HStack(spacing: 12) {
			Eyebrow("Confidence")
			Slider(value: Binding(get: { Double(confIdx) }, set: { confIdx = Int($0.rounded()) }), in: 0...Double(CONFIDENCE_STOPS.count - 1), step: 1)
				.disabled(disabled)
			Text(disabled ? "—" : "\(Int(CONFIDENCE_STOPS[confIdx]))%")
				.font(Theme.mono)
				.monospacedDigit()
				.foregroundStyle(Theme.muted)
				.frame(width: 40, alignment: .trailing)
		}
		.opacity(disabled ? 0.5 : 1)
	}

	@ViewBuilder
	private func learnerField(_ qd: QuestionData) -> some View {
		let textMode = qd.mode == .text
		VStack(alignment: .leading, spacing: 4) {
			// No label: the placeholder says what it's for, as in the composer.
			ZStack(alignment: .topLeading) {
				// The asked question is its own text: switching back restores the answer or thinking.
				let binding = asking ? $askText : textMode ? $text : $thinking
				if binding.wrappedValue.isEmpty {
					Text(asking ? "Ask about the question…" : textMode ? "Type your answer…" : "Why this answer? Whatever comes to mind.")
						.foregroundStyle(Theme.faint)
						.padding(.horizontal, 5)
						.padding(.vertical, 2)
						.allowsHitTesting(false)
				}
				TextEditor(text: binding)
					.dictationTarget("question", .question, text: binding)
					.scrollContentBackground(.hidden)
					.focused($focus, equals: .learner)
					.frame(minHeight: session.phase == .teach || textMode ? 54 : 40, maxHeight: 160)
					.fixedSize(horizontal: false, vertical: true)
					.onKeyPress(.return, phases: .down) { press in
						if press.modifiers.contains(.shift) { return .ignored }
						submit(qd)
						return .handled
					}
			}
			.font(Theme.prose)
			// The composer's box; the editor's own 5pt text inset makes up its 12pt padding.
			.padding(.horizontal, 7)
			.padding(.vertical, 10)
			.background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
			// Text answers have no rows: asking is a link under the box.
			if textMode {
				Button(asking ? "Answer instead" : "Ask about it instead") {
					asking.toggle()
					focus = .learner
				}
				.buttonStyle(.link)
				.font(Theme.ui)
			}
		}
	}

	// MARK: Keys and submit

	/// The rows: the options, "I don't know" (quiz) or "Other" (ask), then "Ask about it".
	private func rowCount(_ qd: QuestionData) -> Int {
		askIndex(qd) + 1
	}

	private func askIndex(_ qd: QuestionData) -> Int {
		qd.options.count + (qd.kind == .quiz || qd.kind == .ask ? 1 : 0)
	}

	private func handleRowKey(_ key: KeyEquivalent, qd: QuestionData, mode: SelectMode, rows: Int) -> KeyPress.Result {
		switch dockKeyRoute(key, typing: focus == .other) {
		case .field:
			return .ignored
		case .submit:
			submit(qd)
			return .handled
		case .rows:
			break
		}
		switch key {
		case .downArrow:
			walked = min((walked ?? -1) + 1, rows - 1)
		case .upArrow:
			walked = max((walked ?? 1) - 1, 0)
		case .space:
			guard let w = walked else { return .ignored }
			if w < qd.options.count { sel = toggleOption(mode, sel, w); asking = false }
			else if w == askIndex(qd) { toggleAsking() }
			else if qd.kind == .quiz { sel = sel.dontKnow ? emptyDockSelection() : DockSelection(selected: [], otherSelected: false, dontKnow: true); asking = false }
			else { sel = toggleOther(mode, sel); asking = false; focus = .other }
		case .leftArrow:
			guard qd.kind == .quiz, !sel.dontKnow, !asking else { return .ignored }
			confIdx = max(confIdx - 1, 0)
		case .rightArrow:
			guard qd.kind == .quiz, !sel.dontKnow, !asking else { return .ignored }
			confIdx = min(confIdx + 1, CONFIDENCE_STOPS.count - 1)
		case .return:
			submit(qd)
		default:
			return .ignored
		}
		return .handled
	}

	private func canSubmit(_ qd: QuestionData) -> Bool {
		if asking { return !askText.jsTrimmed.isEmpty }
		if qd.mode == .text { return !text.jsTrimmed.isEmpty }
		return sel.dontKnow || (sel.otherSelected && !other.jsTrimmed.isEmpty) || !sel.selected.isEmpty
	}

	/// A running dictation lands in its field first (dictation.tsx finishDictation).
	private func submit(_ qd: QuestionData) {
		if let dictation, dictation.isRecording { return dictation.thenSubmit { submitNow(qd) } }
		submitNow(qd)
	}

	private func submitNow(_ qd: QuestionData) {
		guard canSubmit(qd), !session.compacting else { return }
		if asking {
			// Set aside, not answered: it comes back open (without the asked text).
			session.discuss(askText.jsTrimmed, toolCallId: toolCallId, fromCard: true)
			return
		}
		let req = AnswerRequest(
			dontKnow: sel.dontKnow,
			values: sel.selected.sorted().map { qd.options[$0].value },
			other: sel.otherSelected ? other : nil,
			text: qd.mode == .text ? text : nil,
			thinking: qd.mode != .text ? (thinking.jsTrimmed.isEmpty ? nil : thinking.jsTrimmed) : nil,
			confidence: qd.kind == .quiz ? CONFIDENCE_STOPS[confIdx] : nil)
		session.submitAnswer(buildAnswer(qd, req, tool: tool), toolCallId: toolCallId)
	}
}

/// Where a key pressed inside the option rows goes (question-dock.tsx: a
/// typing field keeps its keys). In the "Other…" field every key belongs to
/// the field except Return, which submits.
enum DockKeyRoute: Equatable { case rows, field, submit }

func dockKeyRoute(_ key: KeyEquivalent, typing: Bool) -> DockKeyRoute {
	guard typing else { return .rows }
	return key == .return ? .submit : .field
}

/// A scroll area that hugs its content up to `maxHeight`, then scrolls. A
/// ScrollView alone takes every point it's offered, and so does
/// .frame(maxHeight:) (it fills up to its max), so the content's measured
/// height sets the frame instead.
struct HuggingScroll<Content: View>: View {
	var maxHeight: CGFloat
	@ViewBuilder var content: Content
	@State private var height: CGFloat?

	var body: some View {
		ScrollView {
			content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
		}
		.frame(height: min(height ?? maxHeight, maxHeight))
	}
}

/// A question card's unsent state (SessionModel.cardDrafts).
struct QuestionCardDraft {
	/// The call the draft was saved from (a re-posed copy has a new one).
	var callId = ""
	var sel = emptyDockSelection()
	var thinking = ""
	var other = ""
	var text = ""
	var confIdx = DEFAULT_CONFIDENCE_INDEX
	var asking = false
	var askText = ""
}
