import AppKit
import LHCore
import SwiftUI

/// The pinned dock (docs/native-macos-m5.md: pinned below the transcript,
/// folds on demand, never on scroll): queued steers, the reading-thinking
/// field, then the question dock or the composer. Plan marginalia sits to
/// its right when a question waits and the window is wide enough.
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
			if let p = session.pending {
				if session.requiresReveal {
					ReadingThinkingField(text: $session.readingThinking, onOpenCheck: { session.expandDock() }, checkOpen: session.revealed && session.dockExpanded)
				}
				QuestionDockView(session: session, tool: p.tool, toolCallId: p.toolCallId, input: p.input)
					.id(p.toolCallId)
			} else {
				ComposerView(session: session)
			}
		}
		.frame(maxWidth: Self.width)
		.padding(.horizontal, 16)
		.padding(.bottom, 10)
		.frame(maxWidth: .infinity)
		.overlay(alignment: .bottomTrailing) {
			if session.pending != nil, session.plan != nil, session.dockExpanded {
				PlanMarginalia(session: session)
			}
		}
	}
}

// MARK: - Composer

/// composer.tsx: Enter sends (a steer while busy), ⇧Enter adds a newline;
/// Send becomes Stop while busy with an empty field.
struct ComposerView: View {
	@Bindable var session: SessionModel
	var placeholder = "Ask, answer, or steer the lesson…"
	var onSend: (() -> Void)?
	@FocusState private var focused: Bool

	var body: some View {
		let action = enterAction(busy: session.busy, canSend: session.canSend)
		HStack(alignment: .bottom, spacing: 8) {
			ZStack(alignment: .topLeading) {
				if session.draft.isEmpty {
					Text(session.compacting ? "Compacting session…" : placeholder)
						.foregroundStyle(Theme.muted)
						.padding(.horizontal, 5)
						.padding(.vertical, 8)
						.allowsHitTesting(false)
				}
				TextEditor(text: $session.draft)
					.scrollContentBackground(.hidden)
					.focused($focused)
					.frame(minHeight: 36, maxHeight: 192)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.vertical, 4)
					.onKeyPress(.return, phases: .down) { press in
						if press.modifiers.contains(.shift) { return .ignored }
						act(action)
						return .handled
					}
			}
			.font(Theme.prose)
			Button {
				act(session.busy && !session.canSend ? .stop : .send)
			} label: {
				Image(systemName: session.busy && !session.canSend ? "stop.fill" : "return")
					.frame(width: 28, height: 28)
			}
			.buttonStyle(.borderedProminent)
			.tint(session.busy && !session.canSend ? Color.secondary : Color.accentColor)
			.disabled(!session.busy && !session.canSend)
			.accessibilityLabel(session.busy && !session.canSend ? "Stop" : "Send")
			.padding(.bottom, 4)
		}
		.padding(.horizontal, 10)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
		.onAppear { focused = true }
	}

	private func act(_ action: EnterAction) {
		switch action {
		case .send:
			if let onSend { onSend() } else { session.sendDraft() }
		case .stop:
			session.abortTurn()
		case .next, .none:
			break
		}
	}
}

// MARK: - Bars, steers, reading thinking

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
					Eyebrow(label)
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

/// reading-thinking.tsx: "Thinking while reading" — rides on the answer.
/// Enter opens a closed check; with the check open Enter is a newline.
struct ReadingThinkingField: View {
	@Binding var text: String
	var onOpenCheck: () -> Void
	var checkOpen: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Eyebrow("Thinking while reading")
			ZStack(alignment: .topLeading) {
				if text.isEmpty {
					Text("Whatever comes to mind as you read.").foregroundStyle(Theme.faint).padding(.horizontal, 5).padding(.vertical, 2).allowsHitTesting(false)
				}
				TextEditor(text: $text)
					.scrollContentBackground(.hidden)
					.frame(minHeight: 24, maxHeight: 160)
					.fixedSize(horizontal: false, vertical: true)
					.onKeyPress(.return, phases: .down) { press in
						if checkOpen || press.modifiers.contains(.shift) { return .ignored }
						onOpenCheck()
						return .handled
					}
			}
			.font(Theme.small)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.6)))
	}
}

/// plan-window.tsx PlanMarginalia: the plan beside the dock while a
/// question waits (wide windows only); a click opens the plan popup.
struct PlanMarginalia: View {
	var session: SessionModel
	var body: some View {
		GeometryReader { geo in
			let flank = (geo.size.width - DockView.width) / 2 - 16
			if flank >= 220, let tree = session.plan {
				let layout = planLayout(tree.nodes.map { PlanLayoutNode(id: $0.id, title: $0.title) }, tree.edges)
				let statuses = derivePlanStatuses(tree, session.record?.messages ?? [])
				let w = layout.width + 2 * PLAN_GRAPH_PAD
				let h = layout.height + 2 * PLAN_GRAPH_PAD
				let scale = min((flank - 16) / w, 160 / h, 1)
				Button {
					session.overlays.openPlan()
				} label: {
					PlanCanvas(layout: layout, status: { derivedNodeStatus(statuses, $0) }, current: statuses.current, zoom: scale)
						.frame(width: w * scale, height: h * scale)
				}
				.buttonStyle(.plain)
				.help("Open the plan")
				.frame(width: flank, height: geo.size.height, alignment: .bottomLeading)
				.offset(x: geo.size.width - flank - 4)
			}
		}
		.frame(height: 170)
		.allowsHitTesting(true)
	}
}
