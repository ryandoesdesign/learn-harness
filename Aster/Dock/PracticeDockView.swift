import LHCore
import SwiftUI

/// practice-dock.tsx, in the question dock's chrome (docs/native-macos-m8.md):
/// PROBLEM, the statement (hugging its height up to a cap, then scrolling),
/// YOUR THINKING and Submit thinking. It replaces the composer while a
/// problem is active; the chevron folds it to a one-line bar and the
/// half-written thinking survives. Enter submits, ⇧Enter is a newline; a
/// submission mid-turn queues as a steer.
struct PracticeDockView: View {
	@Bindable var session: SessionModel
	var problem: (toolCallId: String, statement: String)
	@FocusState private var focused: Bool
	@Environment(DictationService.self) private var dictation: DictationService?

	static let maxBody: CGFloat = 320

	var body: some View {
		if !session.problemDockExpanded {
			DockBar(reveal: false, label: "Problem", question: problem.statement) { session.problemDockExpanded = true }
		} else {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Eyebrow("Problem")
					Spacer()
					Button { session.problemDockExpanded = false } label: { Image(systemName: "chevron.down") }
						.buttonStyle(.borderless)
						.help("Fold the problem")
						.accessibilityLabel("Fold the problem")
				}
				HuggingScroll(maxHeight: Self.maxBody) {
					MarkdownView(problem.statement, unit: "dock.p", font: .system(size: 15, design: .serif), fontSize: 15)
				}
				VStack(alignment: .leading, spacing: 4) {
					Eyebrow("Your thinking")
					ZStack(alignment: .topLeading) {
						if session.practiceThinking.isEmpty {
							Text("Work here, think out loud.")
								.foregroundStyle(Theme.faint)
								.padding(.horizontal, 5)
								.padding(.vertical, 2)
								.allowsHitTesting(false)
						}
						TextEditor(text: $session.practiceThinking)
							.scrollContentBackground(.hidden)
							.focused($focused)
							.dictationTarget("practice", .practice, text: $session.practiceThinking)
							.frame(minHeight: 54, maxHeight: 200)
							.fixedSize(horizontal: false, vertical: true)
							.onKeyPress(.return, phases: .down) { press in
								if press.modifiers.contains(.shift) { return .ignored }
								submit()
								return .handled
							}
					}
					.font(Theme.small)
				}
				HStack {
					Text(session.compacting ? "compacting session…" : "↵ submits · ⇧↵ newline").font(Theme.ui).foregroundStyle(Theme.faint)
					Spacer()
					Button("Submit thinking") { submit() }
						.buttonStyle(.borderedProminent)
						.disabled(session.practiceThinking.jsTrimmed.isEmpty || session.compacting)
				}
			}
			.padding(16)
			.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
			.onAppear { focused = true }
		}
	}

	private func submit() {
		if let dictation { dictation.thenSubmit { session.submitThinking() } } else { session.submitThinking() }
	}
}
