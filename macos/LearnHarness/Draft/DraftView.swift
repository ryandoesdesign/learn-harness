import SwiftUI

/// The ⌘N draft (new-session.tsx): the empty state and the composer —
/// "What do you want to learn?". Sending creates the chat and starts it.
struct DraftView: View {
	var model: AppModel
	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 0) {
			ContentUnavailableView("New session", systemImage: "graduationcap",
				description: Text("The teacher will open by probing what you already know."))
				.frame(maxHeight: .infinity)
			if !model.draftPicks.isEmpty {
				// New Session from Selection… (M7): the picks ride message[0].
				HStack(spacing: 8) {
					Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.muted)
					Text("Graph context · \(model.draftPicks.count) proposition\(model.draftPicks.count == 1 ? "" : "s")").font(Theme.ui).foregroundStyle(Theme.muted)
					Spacer()
					Button("Remove") { model.draftPicks = [] }.buttonStyle(.link).font(Theme.ui)
				}
				.frame(maxWidth: DockView.width)
				.padding(.horizontal, 16)
			}
			HStack(alignment: .bottom, spacing: 8) {
				ZStack(alignment: .topLeading) {
					if text.isEmpty {
						Text("What do you want to learn?").foregroundStyle(Theme.muted).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
					}
					TextEditor(text: $text)
						.scrollContentBackground(.hidden)
						.focused($focused)
						.frame(minHeight: 36, maxHeight: 192)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.vertical, 4)
						.onKeyPress(.return, phases: .down) { press in
							if press.modifiers.contains(.shift) { return .ignored }
							start()
							return .handled
						}
				}
				.font(Theme.prose)
				Button(action: start) { Image(systemName: "return").frame(width: 28, height: 28) }
					.buttonStyle(.borderedProminent)
					.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					.accessibilityLabel("Send")
					.padding(.bottom, 4)
			}
			.padding(.horizontal, 10)
			.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
			.frame(maxWidth: DockView.width)
			.padding(16)
		}
		.navigationTitle("New session")
		.onAppear { focused = true }
	}

	private func start() {
		model.startSession(prompt: text)
		text = ""
	}
}
