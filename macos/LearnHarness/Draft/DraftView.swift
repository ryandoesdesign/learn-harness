import LHCore
import LHStore
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
			DraftStatusBar(model: model)
		}
		.navigationTitle(practice ? "New practice session" : "New session")
		.onAppear { focused = true }
		.sheet(isPresented: $model.keyPromptOpen) {
			KeyPromptSheet(model: model) { startNow() }
		}
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
		if model.startSession(prompt: text) { text = "" }
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

/// First run (setup-cta.tsx / setup-dialog.tsx stage 1): starting a session
/// with no Anthropic key asks for one first; Save stores it in the Keychain
/// and the draft starts with its text intact.
struct KeyPromptSheet: View {
	let model: AppModel
	let onSaved: () -> Void
	@State private var key = ""
	@State private var error: String?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Add your Anthropic API key").font(.headline)
			Text("LearnHarness talks to Claude with your own key. It's stored in your Keychain and sent only to Anthropic.")
				.font(Theme.small).foregroundStyle(Theme.muted)
				.fixedSize(horizontal: false, vertical: true)
			SecureField("sk-ant-…", text: $key)
				.textFieldStyle(.roundedBorder)
				.onSubmit(save)
			if let error { Text(error).font(.caption).foregroundStyle(Theme.red) }
			HStack {
				Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(Theme.ui)
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("Save and Start", action: save)
					.keyboardShortcut(.defaultAction)
					.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
			}
		}
		.padding(20)
		.frame(width: 440)
	}

	private func save() {
		do {
			try model.saveKey(key)
			dismiss()
			onSaved()
		} catch {
			self.error = "Could not save the key: \(error.localizedDescription)"
		}
	}
}

/// The draft's status bar (stats-bar.tsx without a chat): dictation, and the
/// model and effort new sessions start on — the Strong slot.
struct DraftStatusBar: View {
	let model: AppModel
	@State private var settings: UserSettings?

	var body: some View {
		let strong = resolveSettings(settings, catalog: model.catalog).models.strong
		let efforts = model.catalog.model(strong.model)?.efforts ?? []
		VStack(spacing: 0) {
			Divider()
			HStack {
				Spacer()
				DictationButton()
				Spacer()
				Menu {
					Section("New sessions start on") {
						ForEach(model.catalog.models, id: \.id) { m in
							Button { write(m.id, strong.effort) } label: {
								if m.id == strong.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
							}
						}
					}
				} label: { Text(model.catalog.model(strong.model)?.name ?? strong.model) }
				Menu {
					ForEach(efforts, id: \.self) { e in
						Button { write(strong.model, e) } label: {
							if e == strong.effort { Label(e.rawValue, systemImage: "checkmark") } else { Text(e.rawValue) }
						}
					}
				} label: { Text(strong.effort.rawValue) }
				.disabled(efforts.isEmpty)
			}
			.menuStyle(.button)
			.buttonStyle(.borderless)
			.font(Theme.ui)
			.padding(.horizontal, 12)
			.frame(height: 28)
		}
		.onAppear { settings = (try? SettingsRepository(model.database).read()) ?? nil }
	}

	/// The Strong slot (TS: the draft's ModelControl is bound to it).
	private func write(_ id: String, _ effort: Effort) {
		let slot = ModelSlot(model: id, effort: clampEffort(effort, supported: model.catalog.model(id)?.efforts ?? []))
		try? SettingsRepository(model.database).update { s in
			var models = s.models ?? ModelsSettings()
			models.strong = slot
			s.models = models
		}
		settings = (try? SettingsRepository(model.database).read()) ?? nil
	}
}
