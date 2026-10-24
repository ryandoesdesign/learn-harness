import LHCore
import LHStore
import SwiftUI

/// Settings (⌘,) — the M5 minimum (docs/native-macos-m5.md): one Anthropic
/// pane with the API key (Keychain) and the Strong / Cheap / Vision slots,
/// each a model and its effort; M6 adds the learner folders the file tools
/// may read. The rest of Settings arrives with M8.
struct SettingsView: View {
	var model: AppModel
	@State private var keyDraft = ""
	@State private var hasKey = false
	@State private var status: String?
	@State private var settings: UserSettings?

	var body: some View {
		Form {
			Section("Anthropic API key") {
				if hasKey {
					HStack {
						Label("Key saved in the Keychain", systemImage: "checkmark.seal")
						Spacer()
						Button("Remove", role: .destructive) { removeKey() }
					}
				}
				HStack {
					SecureField(hasKey ? "Replace the key" : "sk-ant-…", text: $keyDraft)
					Button("Save") { saveKey() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
				}
				if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
			}
			Section {
				slotRow("Strong", .strong, help: "The default for new sessions — the teacher and the prober.")
				slotRow("Cheap", .cheap, help: "Background work.")
				slotRow("Vision", .vision, help: "Reading images and PDFs.")
			} header: {
				Text("Models")
			}
			graphSection
			Section {
				if model.learnerFolders.isEmpty {
					Text("No folders yet. The teacher can't read your files until you add one.").foregroundStyle(.secondary)
				}
				ForEach(model.learnerFolders) { folder in
					HStack {
						Image(systemName: folder.stale ? "exclamationmark.triangle" : "folder")
							.foregroundStyle(folder.stale ? Color.orange : Color.secondary)
						VStack(alignment: .leading, spacing: 1) {
							Text(folder.path).lineLimit(1).truncationMode(.middle)
							if folder.stale { Text("Access was lost — re-grant it to keep using this folder.").font(.caption).foregroundStyle(.secondary) }
						}
						Spacer()
						if folder.stale { Button("Re-grant…") { model.pickLearnerFolder(replacing: folder.id) } }
						Button("Remove", role: .destructive) { model.removeLearnerFolder(folder.id) }
					}
				}
				HStack {
					Spacer()
					Button("Add…") { model.pickLearnerFolder() }
				}
			} header: {
				Text("Learner folders")
			} footer: {
				Text("The teacher and its background agents can read files (and PDFs) only inside these folders. Relative paths resolve against the first one.")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.frame(width: 520)
		.onAppear {
			reload()
			model.reloadFolders()
		}
	}

	// MARK: Knowledge graph (M7)

	private var graphSection: some View {
		let eff = resolveSettings(settings, catalog: model.catalog)
		return Section {
			Toggle(isOn: Binding(get: { eff.graph.enabled }, set: { v in update { $0.graph = graph($0) { $0.enabled = v } } })) {
				Text("Extraction")
				Text("After lessons, build the knowledge graph from what was taught. Off: no extraction and no graph tools.").font(.caption).foregroundStyle(.secondary)
			}
			Toggle(isOn: Binding(get: { eff.graph.rendering }, set: { v in update { $0.graph = graph($0) { $0.rendering = v } } })) {
				Text("Graph rendering")
				Text("Draw the graph in its window. Off: the window shows the chain table.").font(.caption).foregroundStyle(.secondary)
			}
			HStack {
				VStack(alignment: .leading) {
					Text("Chunk budget")
					Text("Extraction runs once a session has this many unextracted tokens (at least \(EXTRACTION_CHUNK_TOKENS_FLOOR)).").font(.caption).foregroundStyle(.secondary)
				}
				Spacer()
				TextField("Tokens", value: Binding(get: { eff.graph.extractionChunkTokens }, set: { v in
					update { $0.graph = graph($0) { $0.extractionChunkTokens = max(EXTRACTION_CHUNK_TOKENS_FLOOR, v) } }
				}), format: .number)
					.frame(width: 80)
					.multilineTextAlignment(.trailing)
			}
			Toggle(isOn: Binding(get: { eff.agent.graphTools.enabled ?? true }, set: { v in
				update { s in
					var agent = s.agent ?? AgentSettings()
					agent.graphTools = GraphToolsSettings(enabled: v)
					s.agent = agent
				}
			})) {
				Text("Graph tools")
				Text("Let the prober read your persistent map (list_sessions, list_propositions).").font(.caption).foregroundStyle(.secondary)
			}
			.disabled(!eff.graph.enabled)
		} header: {
			Text("Knowledge graph")
		}
	}

	private func graph(_ s: UserSettings, _ edit: (inout GraphSettings) -> Void) -> GraphSettings {
		var g = s.graph ?? GraphSettings()
		edit(&g)
		return g
	}

	private func update(_ edit: (inout UserSettings) -> Void) {
		try? SettingsRepository(model.database).update(edit)
		reload()
	}

	private func slotRow(_ title: String, _ name: ModelSlotName, help: String) -> some View {
		let slots = resolveSettings(settings, catalog: model.catalog).models
		let current: EffectiveSlot = switch name {
		case .strong: slots.strong
		case .cheap: slots.cheap
		case .vision: slots.vision
		}
		let efforts = model.catalog.model(current.model)?.efforts ?? Effort.allCases
		return VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(title)
				Spacer()
				Picker("Model", selection: Binding(get: { current.model }, set: { write(name, model: $0, effort: current.effort) })) {
					ForEach(model.catalog.models, id: \.id) { Text($0.name).tag($0.id) }
				}
				.labelsHidden()
				.fixedSize()
				Picker("Effort", selection: Binding(get: { current.effort }, set: { write(name, model: current.model, effort: $0) })) {
					ForEach(efforts, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.labelsHidden()
				.fixedSize()
			}
			Text(help).font(.caption).foregroundStyle(.secondary)
		}
	}

	private func write(_ name: ModelSlotName, model id: String, effort: Effort) {
		let supported = model.catalog.model(id)?.efforts ?? []
		let slot = ModelSlot(model: id, effort: clampEffort(effort, supported: supported))
		try? SettingsRepository(model.database).update { s in
			var models = s.models ?? ModelsSettings()
			switch name {
			case .strong: models.strong = slot
			case .cheap: models.cheap = slot
			case .vision: models.vision = slot
			}
			s.models = models
		}
		reload()
	}

	private func reload() {
		settings = (try? SettingsRepository(model.database).read()) ?? nil
		hasKey = ((try? model.keychain.anthropicKey()) ?? nil) != nil
	}

	private func saveKey() {
		let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		do {
			try model.keychain.setAnthropicKey(key)
			keyDraft = ""
			status = "Key saved."
			model.session?.needsKey = false
		} catch {
			status = "Could not save the key: \(error)"
		}
		reload()
	}

	private func removeKey() {
		try? model.keychain.deleteAnthropicKey()
		status = "Key removed."
		reload()
	}
}
