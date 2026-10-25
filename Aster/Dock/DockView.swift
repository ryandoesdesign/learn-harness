import AppKit
import LHCore
import LHResources
import LHStore
import SwiftUI

/// The pinned dock (docs/native-macos-m5.md: pinned below the transcript):
/// queued steers, then the composer — or practice's problem. Questions show
/// inline where they were asked, and the dock is empty while one is open
/// (the card's "Ask about it" asks the teacher instead; the transcript's
/// "Question below" pill jumps to one out of view).
struct DockView: View {
	@Bindable var session: SessionModel
	@Environment(\.openSettings) private var openSettings

	/// TS DOCK max-w-[46rem].
	static let width: CGFloat = 736

	var body: some View {
		VStack(spacing: 6) {
			if session.needsKey {
				Button {
					openSettings()
				} label: {
					HStack(spacing: 6) {
						Image(systemName: "key")
						Text("No Anthropic key")
						Text("·").foregroundStyle(Theme.faint)
						Text("Add a key").fontWeight(.medium)
					}
					.font(Theme.ui)
					.padding(.horizontal, 12)
					.padding(.vertical, 6)
					.background(Capsule().fill(Theme.card))
					.overlay(Capsule().strokeBorder(Theme.border))
				}
				.buttonStyle(.plain)
			}
			if !session.queuedSteers.isEmpty {
				QueuedSteersView(steers: session.queuedSteers)
			}
			if session.pending != nil {
				// Nothing: the open question's card asks about it ("Ask about it").
			} else if let problem = session.activeProblem {
				// Practice (M8): the problem replaces the composer while it's active.
				PracticeDockView(session: session, problem: problem)
					.id(problem.toolCallId)
			} else {
				ComposerView(session: session)
			}
		}
		.frame(maxWidth: Self.width)
		.padding(.horizontal, 16)
		.padding(.bottom, 10)
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Composer

/// composer.tsx: Enter sends (a steer while busy), ⇧Enter adds a newline;
/// Send becomes Stop while busy with an empty field.
struct ComposerView: View {
	@Bindable var session: SessionModel
	var onSend: (() -> Void)?
	@FocusState private var focused: Bool
	@Environment(DictationService.self) private var dictation: DictationService?

	var body: some View {
		let action = enterAction(busy: session.busy, canSend: session.canSend, nextProblem: session.nextReady)
		HStack(alignment: .bottom, spacing: 8) {
			TextField("", text: $session.draft, prompt: Text(session.compacting ? "Compacting session…" : session.pending != nil ? "Ask about the question…" : session.nextReady ? "Ask anything, or press Enter for the next one." : "Ask, answer, or steer the lesson…"), axis: .vertical)
				.textFieldStyle(.plain)
				.focused($focused)
				.dictationTarget("composer", .composer, text: $session.draft)
				.onKeyPress(.return, phases: .down) { press in
					if press.modifiers.contains(.shift) {
						// A text field's Return ends editing (selecting it all): ⇧Return
						// inserts the newline ⌥Return would, at the cursor.
						NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
						return .handled
					}
					act(action)
					return .handled
				}
				.padding(12)
				.font(Theme.prose)
			if action == .next {
				// The practice pause (composer.tsx): the button becomes Next Problem.
				Button { act(.next) } label: {
					HStack(spacing: 4) { Text("Next Problem"); Image(systemName: "arrow.right") }
						.font(Theme.uiMedium)
				}
				.buttonStyle(.borderedProminent)
				.tint(Theme.green)
				.help("The next problem (↩)")
			} else {
				Button {
					act(session.busy && !session.canSend ? .stop : .send)
				} label: {
					Image(systemName: session.busy && !session.canSend ? "stop.fill" : "return")
				}
				.buttonStyle(.plain)
				.disabled(!session.busy && !session.canSend)
				.accessibilityLabel(session.busy && !session.canSend ? "Stop" : "Send")
				.padding(12)
			}
		}
		.background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
		// An open question keeps the focus; the composer under it is for asking about it.
		.onAppear { if session.pending == nil { focused = true } }
	}

	private func send() {
		if let onSend { onSend() } else { session.sendDraft() }
	}

	private func act(_ action: EnterAction) {
		switch action {
		case .send:
			if let dictation, dictation.isRecording { dictation.thenSubmit { send() } } else { send() }
		case .stop:
			session.abortTurn()
		case .next:
			session.requestNext()
		case .none:
			break
		}
	}
}

// MARK: - Bars, steers

/// question-dock.tsx teaserText: math and commands flattened to one line.
func teaserText(_ q: String) -> String {
	var t = q
	t = t.replacing(/\\\(([\s\S]*?)\\\)/) { String($0.1) }
	t = t.replacing(/\\\[([\s\S]*?)\\\]/) { String($0.1) }
	t = t.replacing(/\$\$?([^$]*)\$\$?/) { String($0.1) }
	t = t.replacing(/\\frac\{([^{}]*)\}\{([^{}]*)\}/) { "\($0.1)/\($0.2)" }
	t = t.replacing(/\\([a-zA-Z]+)/) { String($0.1) }
	t = t.replacing(/[{}]/, with: "")
	t = t.replacing(/\s+/, with: " ")
	return t.trimmingCharacters(in: .whitespaces)
}

/// The folded dock: "reveal" (a teach check's invitation) or "collapsed".
struct DockBar: View {
	var reveal: Bool
	var label: String
	var question: String
	var onExpand: () -> Void

	var body: some View {
		Button(action: onExpand) {
			HStack(spacing: reveal ? 12 : 10) {
				if reveal {
					Image(systemName: "play.fill")
						.font(.system(size: 11))
						.foregroundStyle(Color.accentColor)
						.frame(width: 28, height: 28)
						.background(Circle().fill(Color.accentColor.opacity(0.15)))
					VStack(alignment: .leading, spacing: 1) {
						Text("Check your understanding").font(Theme.small).fontWeight(.medium)
						Text(teaserText(question)).font(Theme.ui).foregroundStyle(Theme.muted).lineLimit(1)
					}
					Spacer(minLength: 8)
					HStack(spacing: 2) { Text("Open"); Image(systemName: "chevron.right") }
						.font(Theme.uiMedium).foregroundStyle(Color.accentColor)
				} else {
					Eyebrow(label).lineLimit(1)
					Text(teaserText(question)).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
					Spacer(minLength: 8)
					HStack(spacing: 2) { Text("Answer"); Image(systemName: "arrow.down") }.font(Theme.uiMedium)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, reveal ? 12 : 10)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.keyboardShortcut(.defaultAction)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
	}
}

/// queued-steers.tsx: right-aligned muted lines until delivered.
struct QueuedSteersView: View {
	var steers: [Message]
	var body: some View {
		VStack(alignment: .trailing, spacing: 2) {
			ForEach(steers, id: \.id) { s in
				Text(s.user?.content.compactMap { $0.raw["text"]?.stringValue }.joined(separator: " ") ?? "")
					.font(.system(size: 11))
					.foregroundStyle(Theme.muted.opacity(0.6))
					.lineLimit(1)
					.truncationMode(.tail)
					.frame(maxWidth: 240, alignment: .trailing)
			}
		}
		.frame(maxWidth: .infinity, alignment: .trailing)
	}
}

// MARK: - Previews

/// The dock under an idle teaching session: the composer.
#Preview("Composer") {
	let dir = FileManager.default.temporaryDirectory.appending(path: "lhpv-\(UUID().uuidString)", directoryHint: .isDirectory)
	let db = try! AppDatabase.open(directory: dir)
	let chat = try! ChatRepository(db).createChat(title: "Joins")
	let session = SessionModel(chatId: chat.id, database: db, dataDirectory: dir, catalog: try! ModelCatalog(data: LHResources.modelsJSON))
	session.load()
	return DockView(session: session)
		.environment(session)
		.environment(session.find)
		.environment(session.overlays)
		.environment(DictationService(engine: SystemSpeechEngine()))
		.frame(width: 900)
}

