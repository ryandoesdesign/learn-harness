import LHCore
import SwiftUI

/// question-dock.tsx: the pending question, every teaching kind — quiz
/// single/multi (seeded shuffle), predict, probe, recall/explain (free
/// text), ask (option descriptions + "Other"). "I don't know", the
/// confidence rail, the thinking field; Submit builds the answer (buildAnswer).
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
	@State private var walked: Int?
	static let maxBody: CGFloat = 420
	@FocusState private var focus: Field?
	@Environment(DictationService.self) private var dictation: DictationService?

	enum Field: Hashable { case rows, other, learner }

	/// The skill this question tests: its nodeId's title in the plan, else
	/// the plan's current node (the last one a check or explain tested).
	private var skill: String? {
		guard let plan = session.plan else { return nil }
		let id = input["nodeId"]?.stringValue.flatMap { id in plan.nodes.contains { $0.id == id } ? id : nil }
			?? derivePlanStatuses(plan, session.record?.messages ?? []).current
		return id.flatMap { id in plan.nodes.first { $0.id == id }?.title }
	}

	var body: some View {
		Group { card }
			// A card set aside to ask about it comes back as it was left.
			.onAppear {
				guard let d = session.cardDrafts.removeValue(forKey: reposeOrigin(toolCallId)) else { return }
				(sel, thinking, other, text, confIdx) = (d.sel, d.thinking, d.other, d.text, d.confIdx)
			}
			.onDisappear {
				guard session.discussedOrigin == reposeOrigin(toolCallId) else { return }
				session.cardDrafts[reposeOrigin(toolCallId)] = QuestionCardDraft(sel: sel, thinking: thinking, other: other, text: text, confIdx: confIdx)
			}
	}

	@ViewBuilder private var card: some View {
		if let qd = dockQuestion(tool: tool, toolCallId: toolCallId, input: input) {
			let label = dockLabel(tool: tool, question: qd, skill: skill)
			if !session.dockExpanded || !session.revealed {
				DockBar(reveal: session.requiresReveal && !session.revealed, label: label, question: qd.question) { session.expandDock() }
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
			HStack {
				Eyebrow(label + (qd.mode == .multiSelect ? " · select all that apply" : ""))
					.lineLimit(1)
				Spacer()
				Button { session.dockExpanded = false } label: { Image(systemName: "chevron.down") }
					.buttonStyle(.borderless)
					.help("Fold the question")
					.accessibilityLabel("Fold the question")
			}
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
						}
						.focusable()
						.focused($focus, equals: .rows)
						.focusEffectDisabled()
						.onKeyPress(keys: [.upArrow, .downArrow, .space, .return, .leftArrow, .rightArrow]) { press in
							handleRowKey(press.key, qd: qd, mode: mode, rows: rows)
						}
					}
					if qd.kind == .quiz { confidence(disabled: sel.dontKnow) }
				}
			}
			learnerField(qd)
			HStack {
				Text(session.compacting ? "compacting session…" : "↵ submits · ⇧↵ newline").font(Theme.ui).foregroundStyle(Theme.faint)
				Spacer()
				Button("Submit answer") { submit(qd) }
					.buttonStyle(.borderedProminent)
					.disabled(!canSubmit(qd) || session.compacting)
			}
		}
		.padding(16)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
		.onAppear { if qd.mode != .text { focus = .rows } else { focus = .learner } }
	}

	private func optionRow(_ opt: QuizOption, index: Int, mode: SelectMode, kind: QuestionKind, walkedHere: Bool) -> some View {
		let selected = sel.selected.contains(index)
		return Button {
			sel = toggleOption(mode, sel, index)
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

	private func otherRow(mode: SelectMode, index: Int, walkedHere: Bool) -> some View {
		HStack(spacing: 10) {
			Button { sel = toggleOther(mode, sel) } label: { indicator(selected: sel.otherSelected, multi: mode == .multiSelect) }
				.buttonStyle(.plain)
			TextField("Type your own answer…", text: $other)
				.textFieldStyle(.plain)
				.font(Theme.small)
				.focused($focus, equals: .other)
				.onChange(of: other) { _, v in
					if !v.isEmpty, !sel.otherSelected { sel = toggleOther(mode, sel) }
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
			Eyebrow(textMode ? "Your answer" : "Your thinking")
			ZStack(alignment: .topLeading) {
				let binding = textMode ? $text : $thinking
				if binding.wrappedValue.isEmpty {
					Text(textMode ? "Type your answer…" : "Why this answer? Whatever comes to mind.")
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
			.font(Theme.small)
		}
	}

	// MARK: Keys and submit

	private func rowCount(_ qd: QuestionData) -> Int {
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
			if w < qd.options.count { sel = toggleOption(mode, sel, w) }
			else if qd.kind == .quiz { sel = sel.dontKnow ? emptyDockSelection() : DockSelection(selected: [], otherSelected: false, dontKnow: true) }
			else { sel = toggleOther(mode, sel); focus = .other }
		case .leftArrow:
			guard qd.kind == .quiz, !sel.dontKnow else { return .ignored }
			confIdx = max(confIdx - 1, 0)
		case .rightArrow:
			guard qd.kind == .quiz, !sel.dontKnow else { return .ignored }
			confIdx = min(confIdx + 1, CONFIDENCE_STOPS.count - 1)
		case .return:
			submit(qd)
		default:
			return .ignored
		}
		return .handled
	}

	private func canSubmit(_ qd: QuestionData) -> Bool {
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
	var sel: DockSelection
	var thinking: String
	var other: String
	var text: String
	var confIdx: Int
}
