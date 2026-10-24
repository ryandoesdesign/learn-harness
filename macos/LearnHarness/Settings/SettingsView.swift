import LHCore
import LHStore
import SwiftUI

/// Settings (⌘,) — the M5 minimum (docs/native-macos-m5.md): one Anthropic
/// pane with the API key (Keychain) and the Strong / Cheap / Vision slots,
/// each a model and its effort. The rest of Settings arrives with M8.
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
		}
		.formStyle(.grouped)
		.frame(width: 520)
		.onAppear(perform: reload)
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
