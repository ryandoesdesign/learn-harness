import LHAgent
import LHCore
import LHResources
import LHStore
import SwiftUI

/// Settings (⌘,), complete in M8 (docs/native-macos-m8.md): Anthropic (the
/// key, the Strong / Cheap / Vision slots, per-role models), Teaching
/// (quizzing, the tool switches, compaction), Prompts (a switch and an
/// editor per segment), Knowledge Graph (M7) and Learner Folders (M6).
struct SettingsView: View {
	var model: AppModel
	@State private var keyDraft = ""
	@State private var hasKey = false
	@State private var status: String?
	@State private var settings: UserSettings?

	var body: some View {
		TabView {
			Tab("Anthropic", systemImage: "key") {
				Form {
					anthropicSections
					roleSection
				}
				.formStyle(.grouped)
			}
			Tab("Teaching", systemImage: "graduationcap") {
				Form { teachingSections }.formStyle(.grouped)
			}
			Tab("Prompts", systemImage: "text.quote") {
				PromptOverridesPane(model: model, switches: settings?.agent?.prompts ?? [:]) { path, on in
					update { s in
						var agent = s.agent ?? AgentSettings()
						var prompts = agent.prompts ?? [:]
						if on { prompts[path] = true } else { prompts[path] = nil }
						agent.prompts = prompts
						s.agent = agent
					}
				}
			}
			Tab("Knowledge Graph", systemImage: "point.3.connected.trianglepath.dotted") {
				Form { graphSection }.formStyle(.grouped)
			}
			Tab("Learner Folders", systemImage: "folder") {
				Form { learnerSection }.formStyle(.grouped)
			}
		}
		.frame(width: 600, height: 560)
		.onAppear {
			reload()
			model.reloadFolders()
		}
	}

	@ViewBuilder private var anthropicSections: some View {
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

	@ViewBuilder private var learnerSection: some View {
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

	func update(_ edit: (inout UserSettings) -> Void) {
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

// MARK: - M8: per-role models, Teaching

/// The tools a switch can turn off (agent-section.tsx TOGGLE_TOOLS).
let TOGGLE_TOOLS = ["research", "demo", "visual", "pdf"]

private func roleLabel(_ role: ModelRole) -> String {
	switch role {
	case .prober: "Prober"
	case .teacher: "Teacher"
	case .researcher: "Researcher"
	case .demoBuilder: "Demo builder"
	case .visualMaker: "Figure maker"
	case .pdfReader: "PDF reader"
	case .extractor: "Extractor"
	case .auditor: "Auditor"
	}
}

extension SettingsView {
	/// Per-role overrides (agent.models): collapsed, since the slots cover
	/// most needs; "Slot default" clears the override.
	@ViewBuilder var roleSection: some View {
		let eff = resolveSettings(settings, catalog: model.catalog)
		Section {
			DisclosureGroup("Per-role models") {
				ForEach(BACKGROUND_MODEL_ROLES, id: \.self) { role in
					let stored = settings?.agent?.models?[role]
					let spec = eff.agent.models[role] ?? EffectiveModelSpec(model: eff.models.cheap.model, effort: eff.models.cheap.effort)
					let efforts = model.catalog.model(spec.model)?.efforts ?? Effort.allCases
					HStack {
						Text(roleLabel(role))
						Spacer()
						Picker("Model", selection: Binding(get: { stored?.model ?? "" }, set: { id in
							writeRole(role, id.isEmpty ? nil : ModelSlot(model: id, effort: clampEffort(spec.effort, supported: model.catalog.model(id)?.efforts ?? [])))
						})) {
							Text("Slot default").tag("")
							Divider()
							ForEach(model.catalog.models, id: \.id) { Text($0.name).tag($0.id) }
						}
						.labelsHidden()
						.fixedSize()
						Picker("Effort", selection: Binding(get: { spec.effort }, set: { e in
							writeRole(role, ModelSlot(model: stored?.model ?? spec.model, effort: e))
						})) {
							ForEach(efforts, id: \.self) { Text($0.rawValue).tag($0) }
						}
						.labelsHidden()
						.fixedSize()
						.disabled(stored == nil)
					}
				}
			}
		} footer: {
			Text("Each background agent runs on its slot's model unless you pick one here.").font(.caption).foregroundStyle(.secondary)
		}
	}

	private func writeRole(_ role: ModelRole, _ slot: ModelSlot?) {
		update { s in
			var agent = s.agent ?? AgentSettings()
			var models = agent.models ?? [:]
			models[role] = slot
			agent.models = models.isEmpty ? nil : models
			s.agent = agent
		}
	}

	/// Quizzing (agent.tools.explain), the tool switches, compaction.
	@ViewBuilder var teachingSections: some View {
		let eff = resolveSettings(settings, catalog: model.catalog)
		let tools = settings?.agent?.tools ?? [:]
		Section {
			Picker(selection: Binding(get: { tools["explain"] == true }, set: { free in setTool("explain", free ? true : nil) })) {
				Text("Multiple choice").tag(false)
				Text("Free recall").tag(true)
			} label: {
				Text("Quizzing")
				Text("How both tutors check your understanding").font(.caption).foregroundStyle(.secondary)
			}
			.pickerStyle(.segmented)
		} header: {
			Text("Questions")
		}
		Section {
			ForEach(TOGGLE_TOOLS, id: \.self) { id in
				Toggle(isOn: Binding(get: { tools[id] ?? true }, set: { setTool(id, $0 ? nil : false) })) {
					Text("Tool · \(id)")
				}
			}
		} header: {
			Text("Tools")
		} footer: {
			Text("A switched-off tool is left out for the prober, the teacher and practice.").font(.caption).foregroundStyle(.secondary)
		}
		Section {
			HStack {
				VStack(alignment: .leading) {
					Text("Compaction threshold")
					Text("\(eff.compaction.thresholdTokens) tokens (at least \(COMPACTION_THRESHOLD_FLOOR)). Empty is the default.").font(.caption).foregroundStyle(.secondary)
				}
				Spacer()
				TextField("Tokens", value: Binding(get: { settings?.compaction?.thresholdTokens }, set: { v in
					update { s in s.compaction = v.map { CompactionSettings(thresholdTokens: max(COMPACTION_THRESHOLD_FLOOR, $0)) } }
				}), format: .number, prompt: Text("\(eff.compaction.thresholdTokens)"))
					.frame(width: 90)
					.multilineTextAlignment(.trailing)
			}
		} header: {
			Text("Context")
		}
	}

	/// on = key removed (absent = enabled); an explicit value otherwise.
	private func setTool(_ id: String, _ value: Bool?) {
		update { s in
			var agent = s.agent ?? AgentSettings()
			var t = agent.tools ?? [:]
			t[id] = value
			agent.tools = t.isEmpty ? nil : t
			s.agent = agent
		}
	}
}

// MARK: - Prompts

/// The prompt overrides (agent-section.tsx segmentRow): per section —
/// Teacher, Prober, Practice, then Shared once — each segment with its
/// switch (only once your version exists), "Your version is in use" while
/// on, and Show Text: the source (read-only) and your version (Save, Delete).
struct PromptOverridesPane: View {
	let model: AppModel
	let switches: [String: Bool]
	let onSwitch: (String, Bool) -> Void
	@State private var overrides: [String: String] = [:]
	@State private var open: String?
	@State private var draft = ""
	@State private var status: String?

	static var sections: [(title: String, hint: String?, paths: [String])] {
		let own = { (a: PromptAgent) in PromptComposer.segmentPaths(a).filter { $0.hasPrefix("\(a.rawValue)/") } }
		// Shared: the base file, then the shared fragments (TS sectionedSegments).
		let shared = PromptComposer.segmentPaths(.teacher).filter { !$0.hasPrefix("teacher/") }
		return [
			("Teacher", nil, own(.teacher)),
			("Prober", nil, own(.prober)),
			("Practice", nil, own(.practice)),
			("Shared", "Used by more than one agent", shared),
		]
	}

	var body: some View {
		Form {
			ForEach(Self.sections, id: \.title) { section in
				Section {
					ForEach(section.paths, id: \.self) { path in row(path) }
				} header: {
					Text(section.title)
				} footer: {
					if let hint = section.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
				}
			}
		}
		.formStyle(.grouped)
		.onAppear(perform: reload)
	}

	@ViewBuilder private func row(_ path: String) -> some View {
		let exists = overrides[path] != nil
		let on = switches[path] == true
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				VStack(alignment: .leading, spacing: 1) {
					Text(path).font(.system(.body, design: .monospaced))
					if on { Text("Your version is in use").font(.caption).foregroundStyle(.secondary) }
				}
				Spacer()
				Button(open == path ? "Hide Text" : "Show Text") {
					open = open == path ? nil : path
					draft = overrides[path] ?? ""
					status = nil
				}
				.buttonStyle(.link)
				Toggle("Use your version", isOn: Binding(get: { on }, set: { onSwitch(path, $0) }))
					.labelsHidden()
					.toggleStyle(.switch)
					.disabled(!exists)
			}
			if open == path {
				Text("Source").font(.caption).foregroundStyle(.secondary)
				ScrollView {
					Text(LHResources.promptSegment(path) ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(height: 110)
				.background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
				Text("Your version").font(.caption).foregroundStyle(.secondary)
				TextEditor(text: $draft)
					.font(.system(size: 11, design: .monospaced))
					.frame(height: 110)
					.overlay(alignment: .topLeading) {
						if draft.isEmpty { Text("Add your own instructions…").font(.system(size: 11)).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
					}
				HStack {
					Button("Save") { save(path) }.disabled(draft == (overrides[path] ?? ""))
					if exists { Button("Delete", role: .destructive) { delete(path) } }
					if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
				}
			}
		}
	}

	private func reload() {
		let repo = PromptOverrideRepository(model.database)
		var out: [String: String] = [:]
		for path in (try? repo.list()) ?? [] { out[path] = (try? repo.read(path)) ?? nil }
		overrides = out
	}

	private func save(_ path: String) {
		try? PromptOverrideRepository(model.database).write(path, body: draft)
		reload()
		status = "Saved."
	}

	private func delete(_ path: String) {
		try? PromptOverrideRepository(model.database).delete(path)
		if switches[path] == true { onSwitch(path, false) }
		draft = ""
		reload()
		status = "Deleted."
	}
}
