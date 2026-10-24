import LHCore
import SwiftUI

/// The ⌘N draft (new-session.tsx): the Teach / Practice switch (M8), the
/// empty state, the picks ("Pick Nodes…" opens the chain table as a sheet)
/// and the composer. Sending creates the chat and starts it.
struct DraftView: View {
	@Bindable var model: AppModel
	@State private var text = ""
	@State private var picking = false
	@FocusState private var focused: Bool
	@Environment(DictationService.self) private var dictation: DictationService?

	private var practice: Bool { model.draftKind == .practice }

	var body: some View {
		VStack(spacing: 0) {
			Picker("Mode", selection: $model.draftKind) {
				Text("Teach").tag(ChatKind?.none)
				Text("Practice").tag(ChatKind?.some(.practice))
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
			.padding(.top, 16)
			ContentUnavailableView(practice ? "New practice session" : "New session", systemImage: practice ? "dumbbell" : "graduationcap",
				description: Text(practice
					? "Pick nodes from your knowledge graph, describe what you want to practice, or bring your own problem."
					: "The teacher will open by probing what you already know."))
				.frame(maxHeight: .infinity)
			HStack(spacing: 8) {
				Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.muted)
				if model.draftPicks.isEmpty {
					Text("No graph context").font(Theme.ui).foregroundStyle(Theme.muted)
				} else {
					// The picks ride message[0] as the Graph context card.
					Text("Graph context · \(model.draftPicks.count) proposition\(model.draftPicks.count == 1 ? "" : "s")").font(Theme.ui).foregroundStyle(Theme.muted)
				}
				Spacer()
				Button(model.draftPicks.isEmpty ? "Pick Nodes…" : "Edit Picks…") { picking = true }.buttonStyle(.link).font(Theme.ui)
				if !model.draftPicks.isEmpty {
					Button("Remove") { model.draftPicks = [] }.buttonStyle(.link).font(Theme.ui)
				}
			}
			.frame(maxWidth: DockView.width)
			.padding(.horizontal, 16)
			HStack(alignment: .bottom, spacing: 8) {
				ZStack(alignment: .topLeading) {
					if text.isEmpty {
						Text(practice ? "What do you want to practice?" : "What do you want to learn?")
							.foregroundStyle(Theme.muted).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
					}
					TextEditor(text: $text)
						.scrollContentBackground(.hidden)
						.focused($focused)
						.dictationTarget("draft", .composer, text: $text)
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
		.navigationTitle(practice ? "New practice session" : "New session")
		.onAppear { focused = true }
		.sheet(isPresented: $picking) {
			PickNodesSheet(app: model, initial: Set(model.draftPicks.map(\.id))) { picks in
				model.draftPicks = Array(picks.prefix(64))
			}
		}
	}

	private func start() {
		guard let dictation, dictation.isRecording else { return startNow() }
		dictation.thenSubmit { startNow() }
	}

	private func startNow() {
		model.startSession(prompt: text)
		text = ""
	}
}

/// "Pick Nodes…" (M8): the chain table in select mode as a sheet; Done
/// attaches the selection to the draft, Cancel leaves the picks as they were.
struct PickNodesSheet: View {
	@State private var graph: GraphWindowModel
	let initial: Set<String>
	let onDone: ([GraphContextPick]) -> Void
	@Environment(\.dismiss) private var dismiss

	init(app: AppModel, initial: Set<String>, onDone: @escaping ([GraphContextPick]) -> Void) {
		_graph = State(initialValue: GraphWindowModel(app: app))
		self.initial = initial
		self.onDone = onDone
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Pick Nodes").font(.headline)
				Spacer()
				TextField("Search", text: $graph.query).textFieldStyle(.roundedBorder).frame(width: 220)
			}
			.padding(12)
			Divider()
			ChainTableView(model: graph, picker: true)
			Divider()
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("Done") {
					onDone(graph.picks(from: graph.chainSelection))
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
			.padding(12)
		}
		.frame(minWidth: 640, minHeight: 480)
		.task {
			graph.reload()
			graph.chainSelection = initial
			await graph.observe()
		}
	}
}
