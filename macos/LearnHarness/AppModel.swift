import AppKit
import Foundation
import LHAgent
import LHCore
import LHImport
import LHResources
import LHStore
import LHWeb
import Observation
import UniformTypeIdentifiers

/// The app's composition root: one database, its repositories, and the
/// state the shell renders. MainActor; long work hops off it.
@MainActor
@Observable
final class AppModel {
	let database: AppDatabase
	let dataDirectory: URL
	let keychain: any KeychainStore

	let catalog: ModelCatalog
	/// The live teaching service (M5): one per app.
	let service: TurnService
	/// The background jobs (M6): dispatch, runs, delivery, abort, recovery.
	let jobs: JobService
	/// Running jobs across all chats (the sidebar's Background agents).
	private(set) var runningJobs: [JobRecord] = []
	/// The extraction pipeline (M7) and its running batch jobs.
	let extraction: ExtractionService
	private(set) var extractionRows: [ExtractionService.Row] = []
	/// On-device dictation (M8): one microphone for the app.
	let dictation: DictationService
	/// Propositions the next ⌘N draft starts with (New Session from Selection…).
	var draftPicks: [GraphContextPick] = []
	/// The learner folders the file tools may read (Settings → Learner folders).
	private(set) var learnerFolders: [LearnerFolder] = []
	private(set) var sessions: [ChatSummary] = []
	/// Chats with a running turn / a running compaction (sidebar spinners).
	private(set) var runningChats: Set<String> = []
	private(set) var compactingChats: Set<String> = []
	/// The ⌘N draft is open in the detail column.
	var drafting = false
	/// The draft's mode (M8): nil = a teaching session, .practice = practice.
	var draftKind: ChatKind?
	/// The app's own model remembers the open session across launches
	/// (tests' models never touch it).
	private var remembersSelection = false
	private static let lastSessionKey = "lh.lastSession"

	/// At launch: reopen the session that was open last, if it still exists.
	func restoreLastSession() {
		remembersSelection = true
		guard selection == nil, !drafting, let id = UserDefaults.standard.string(forKey: Self.lastSessionKey),
		      ((try? ChatRepository(database).get(id)) ?? nil) != nil
		else { return }
		selection = id
	}

	/// The first-run key prompt (no Anthropic key when a draft starts).
	var keyPromptOpen = false
	/// Edit → Search Sessions (⇧⌘F): each bump focuses the sidebar search.
	var searchRequest = 0
	/// Session → Rename… (or Return on a sidebar row): the chat to rename.
	var renameRequest: String?
	/// The sidebar selection; opening a session builds its model.
	var selection: String? {
		didSet {
			guard selection != oldValue else { return }
			if selection != nil { drafting = false }
			if remembersSelection { UserDefaults.standard.set(selection, forKey: Self.lastSessionKey) }
			session = selection.map { SessionModel(chatId: $0, database: database, dataDirectory: dataDirectory, catalog: catalog, service: service) }
		}
	}
	private(set) var session: SessionModel?
	var importState: ImportState = .idle
	private(set) var startupError: String?

	enum ImportState: Equatable {
		case idle
		case running(step: String)
		case finished(LegacyImporter.Report)
		case failed(String)
	}

	init(dataDirectory: URL = AppDatabase.defaultDirectory, keychain: any KeychainStore = SystemKeychain(), speech: any SpeechEngine = SystemSpeechEngine()) {
		self.dataDirectory = dataDirectory
		self.keychain = keychain
		dictation = DictationService(engine: speech)
		catalog = (try? ModelCatalog(data: LHResources.modelsJSON)) ?? ModelCatalog(models: [])
		do {
			database = try AppDatabase.open(directory: dataDirectory)
		} catch {
			// Fall back to an in-memory database so the window still opens and says why.
			database = try! AppDatabase.inMemory()
			startupError = "Could not open the database: \(error)"
		}
		service = TurnService(database: database, keychain: keychain, catalog: catalog)
		let store = BookmarkStore(database)
		let access = FileAccess(folders: { (try? store.list())?.compactMap { try? store.resolve($0) } ?? [] })
		jobs = JobService(database: database, dataDirectory: dataDirectory, keychain: keychain, catalog: catalog,
			verifier: WebHeadlessVerifier.shared, fileAccess: access)
		extraction = ExtractionService(database: database, keychain: keychain, catalog: catalog)
		reloadFolders()
	}

	/// Relay the service's events for as long as the app runs (the TS
	/// server-event bus): sidebar spinners, the open session's live state.
	func observeService() async {
		await jobs.attach(service)
		let extraction = extraction
		await service.setSettleObserver { chatId in Task { await extraction.turnSettled(chatId) } }
		await service.recoverOnLaunch()
		// Eager job recovery (your answer): orphaned runs re-deliver or re-run.
		await jobs.recoverOnLaunch()
		// The one-time backfill (M7, your answer): runs in the background.
		Task { await extraction.backfillIfNeeded() }
		for await event in await service.events() {
			switch event {
			case .turnStarted(let chatId):
				runningChats.insert(chatId)
				if session?.chatId == chatId { session?.follow() }
			case .turnSettled(let chatId):
				runningChats.remove(chatId)
			case .compaction(let chatId, let running):
				if running { compactingChats.insert(chatId) } else { compactingChats.remove(chatId) }
				if session?.chatId == chatId { session?.compacting = running }
			case .error:
				break
			}
		}
	}

	// MARK: - Sessions (M5)

	/// File → New Session (⌘N): the draft in the detail column.
	func newSession(kind: ChatKind? = nil) {
		selection = nil
		draftPicks = []
		draftKind = kind
		drafting = true
	}

	/// New Session from Selection… (M7) and Practice from Selection… (M8):
	/// the draft, with the picks attached.
	func newSession(picks: [GraphContextPick], kind: ChatKind? = nil) {
		selection = nil
		draftPicks = Array(picks.prefix(64))
		draftKind = kind
		drafting = true
		// Bring the sessions window forward (the graph window stays open).
		NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !($0.identifier?.rawValue.contains("graph") ?? false) }?.makeKeyAndOrderFront(nil)
	}

	/// The draft's first send. With no Anthropic key the key prompt opens
	/// first and nothing is created (setup-dialog.tsx; the draft keeps its
	/// text): false. Otherwise the session begins and the prompt is sent.
	@discardableResult
	func startSession(prompt: String) -> Bool {
		guard ((try? keychain.anthropicKey()) ?? nil) != nil else {
			keyPromptOpen = true
			return false
		}
		guard let chatId = beginSession(prompt: prompt), session?.chatId == chatId else { return false }
		session?.draft = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		session?.sendDraft()
		return true
	}

	/// Create the chat (titled from the prompt, picks as message[0], its
	/// settings stamped from the Strong slot) and open it — no send.
	@discardableResult
	func beginSession(prompt: String) -> String? {
		let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }
		do {
			let repo = ChatRepository(database)
			let chat = try repo.createChat(title: titleFromPrompt(text), kind: draftKind)
			// Picks seed message[0]: the Graph context card (app/api/chats).
			if !draftPicks.isEmpty {
				let graph = GraphRepository(database)
				let known = Set(getGraph(graph).nodes.map(\.id))
				let ids = draftPicks.map(\.id).filter(known.contains)
				let names = Dictionary(draftPicks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
				let chains = chainsForSelection(ids, graph.readChains()).filter { !$0.premises.isEmpty }.map { formatChainLine($0, names: names) }
				try repo.append([newGraphContextMessage(picks: draftPicks, chains: chains)], to: chat.id)
				draftPicks = []
			}
			let settings = (try? SettingsRepository(database).read()) ?? nil
			let spec = resolveConversationSpec(nil, strong: settings?.models?.strong, catalog: catalog)
			try repo.saveSettings(ChatSettings(model: spec.model, effort: spec.effort), chatId: chat.id)
			selection = chat.id
			return chat.id
		} catch {
			let alert = NSAlert(error: error)
			alert.runModal()
			return nil
		}
	}

	/// The key prompt's Save (first run): store it, then the draft can start.
	func saveKey(_ key: String) throws {
		try keychain.setAnthropicKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
		session?.needsKey = false
	}

	func rename(_ chatId: String, to title: String) {
		let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty else { return }
		try? ChatRepository(database).rename(chatId, title: t)
	}

	/// Delete a session (refused while its turn runs — TS 409 turn_in_flight),
	/// and with `removeGraphTraces` the graph nodes only it contributed.
	func delete(_ chatId: String, removeGraphTraces: Bool = false) async -> String? {
		if await service.isRunning(chatId) { return "A turn is still running in this session — wait for it to finish or stop it, then try again." }
		await jobs.cancelAll(chatId: chatId)
		// Its extraction winds down first, so nothing merges for a deleted chat.
		await extraction.windDown(chatId)
		do {
			_ = try JobRepository(database, dataDirectory: dataDirectory).deleteJobs(chatId: chatId)
			try SteerOutboxRepository(database).deleteAll(chatId: chatId)
			// The traces and the chat go in one transaction (all or nothing).
			try GraphRepository(database).transaction { tx in
				try deleteChatTraces(tx, chatId: chatId, mode: removeGraphTraces ? .deleteNodes : .preserveGraph)
				_ = try tx.deleteChat(chatId)
			}
			if selection == chatId { selection = nil }
			return nil
		} catch {
			return "Delete failed — \(error). Try again."
		}
	}

	// MARK: - Background agents (M6)

	/// Mirror the running jobs for as long as the app runs.
	func observeJobs() async {
		do {
			for try await running in JobRepository(database, dataDirectory: dataDirectory).observeRunning() { runningJobs = running }
		} catch {}
	}

	/// End (the Background agents row): the learner's abort.
	func endJob(_ id: String) async -> Bool {
		await jobs.abort(id) != .notFound
	}

	func sessionTitle(_ chatId: String) -> String {
		sessions.first { $0.id == chatId }?.title ?? "Session"
	}

	// MARK: - Extraction and the graph (M7)

	func observeExtraction() async {
		for await rows in await extraction.observe() { extractionRows = rows }
	}

	/// A session's extraction coverage (the ring and the sidebar menu).
	func coverage(_ chatId: String) -> ExtractionService.SessionCoverage? {
		ExtractionService.coverage(database: database, chatId: chatId, running: extractionRows.contains { $0.sourceId == chatId })
	}

	var extractionChunkTokens: Int {
		resolveSettings((try? SettingsRepository(database).read()) ?? nil, catalog: catalog).graph.extractionChunkTokens
	}

	/// The per-session Extract action.
	func extract(_ chatId: String) {
		Task { _ = await extraction.extractNow(chatId) }
	}

	/// Delete nodes (or chains, by arg_ id) in one transaction. Refused while
	/// an extraction runs. nil = done; otherwise the message to show.
	func deleteGraphNodes(_ ids: [String]) async -> String? {
		if await extraction.anyRunning { return "An extraction is running — try again when Background agents is clear." }
		do {
			try GraphRepository(database).transaction { tx in
				for id in ids { _ = try deleteNodeTraces(tx, nodeId: id) }
			}
			return nil
		} catch {
			return "Delete failed — \(error)."
		}
	}

	/// Import notes…: pick .md/.markdown/.txt files; only failures come back.
	func importNotes() async -> [ExtractionService.NotesResult] {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.allowedContentTypes = ["md", "markdown", "txt"].compactMap { UTType(filenameExtension: $0) }
		panel.prompt = "Import"
		guard panel.runModal() == .OK else { return [] }
		var files: [ExtractionService.NotesFile] = []
		var failures: [ExtractionService.NotesResult] = []
		for url in panel.urls {
			if let text = url.withSecurityScope({ try? String(contentsOf: url, encoding: .utf8) }) {
				files.append(.init(path: url.path, text: text))
			} else {
				failures.append(.init(path: url.path, outcome: .failed, stats: EmissionStats(nodes: 0, chains: 0), error: "The file isn't readable UTF-8 text."))
			}
		}
		let results = await extraction.importNotes(files)
		return failures + results.filter { $0.outcome != .completed }
	}

	// MARK: - Learner folders (M6)

	struct LearnerFolder: Identifiable, Equatable {
		var id: String
		var path: String
		/// The bookmark no longer resolves (moved, deleted, or access lost).
		var stale: Bool
	}

	func reloadFolders() {
		let store = BookmarkStore(database)
		learnerFolders = ((try? store.list()) ?? []).map { f in
			LearnerFolder(id: f.id, path: (try? store.resolve(f).path) ?? f.path, stale: (try? store.resolve(f)) == nil)
		}
	}

	/// Add… / Re-grant: pick a folder; a re-grant replaces the stale row.
	func pickLearnerFolder(replacing id: String? = nil) {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = id == nil ? "Add Folder" : "Re-grant"
		panel.message = "LearnHarness can read files in this folder when the teacher looks something up."
		if let id, let old = learnerFolders.first(where: { $0.id == id }) { panel.directoryURL = URL(fileURLWithPath: old.path) }
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let store = BookmarkStore(database)
		do {
			if !learnerFolders.contains(where: { $0.path == url.path && !$0.stale && $0.id != id }) { try store.add(url) }
			if let id { try store.remove(id) }
		} catch {
			NSAlert(error: error).runModal()
		}
		reloadFolders()
	}

	func removeLearnerFolder(_ id: String) {
		try? BookmarkStore(database).remove(id)
		reloadFolders()
	}

	/// Mirror the session summaries for as long as the app runs.
	func observeSessions() async {
		do {
			for try await summaries in ChatRepository(database).observeSummaries() {
				sessions = summaries
			}
		} catch {
			startupError = "Session list stopped updating: \(error)"
		}
	}

	/// Import from the picked folder (security-scoped, read-only, one-shot).
	func runImport(from folder: URL) async {
		importState = .running(step: "Starting")
		let importer = LegacyImporter(database: database, dataDirectory: dataDirectory, keychain: keychain)
		let result = await Task.detached(priority: .userInitiated) { [weak self] () -> Result<LegacyImporter.Report, Error> in
			folder.withSecurityScope {
				Result {
					try importer.run(root: folder) { step in
						Task { @MainActor in self?.importState = .running(step: step) }
					}
				}
			}
		}.value
		switch result {
		case .success(let report): importState = .finished(report)
		case .failure(let error): importState = .failed("\(error)")
		}
	}

	/// Export as Markdown… (the TS `/api/chats/:id/markdown` route): the
	/// anchorless session document, named from the slugified title.
	func exportMarkdown(chatId: String) {
		guard let record = try? ChatRepository(database).get(chatId) else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "\(sessionExportSlug(record.title)).md"
		panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
		panel.canCreateDirectories = true
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try sessionMarkdown(record.messages, title: record.title, anchors: false).write(to: url, atomically: true, encoding: .utf8)
		} catch {
			let alert = NSAlert(error: error)
			alert.runModal()
		}
	}
}
