import AppKit
import Foundation
import LHAgent
import LHCore
import LHImport
import LHResources
import LHStore
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
	private(set) var sessions: [ChatSummary] = []
	/// Chats with a running turn / a running compaction (sidebar spinners).
	private(set) var runningChats: Set<String> = []
	private(set) var compactingChats: Set<String> = []
	/// The ⌘N draft is open in the detail column.
	var drafting = false
	/// The sidebar selection; opening a session builds its model.
	var selection: String? {
		didSet {
			guard selection != oldValue else { return }
			if selection != nil { drafting = false }
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

	init(dataDirectory: URL = AppDatabase.defaultDirectory, keychain: any KeychainStore = SystemKeychain()) {
		self.dataDirectory = dataDirectory
		self.keychain = keychain
		catalog = (try? ModelCatalog(data: LHResources.modelsJSON)) ?? ModelCatalog(models: [])
		do {
			database = try AppDatabase.open(directory: dataDirectory)
		} catch {
			// Fall back to an in-memory database so the window still opens and says why.
			database = try! AppDatabase.inMemory()
			startupError = "Could not open the database: \(error)"
		}
		service = TurnService(database: database, keychain: keychain, catalog: catalog)
	}

	/// Relay the service's events for as long as the app runs (the TS
	/// server-event bus): sidebar spinners, the open session's live state.
	func observeService() async {
		await service.recoverOnLaunch()
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
	func newSession() {
		selection = nil
		drafting = true
	}

	/// The draft's first send: create the chat (titled from the prompt, its
	/// settings stamped from the Strong slot), open it, send the prompt.
	func startSession(prompt: String) {
		let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		do {
			let repo = ChatRepository(database)
			let chat = try repo.createChat(title: titleFromPrompt(text))
			let settings = (try? SettingsRepository(database).read()) ?? nil
			let spec = resolveConversationSpec(nil, strong: settings?.models?.strong, catalog: catalog)
			try repo.saveSettings(ChatSettings(model: spec.model, effort: spec.effort), chatId: chat.id)
			selection = chat.id
			session?.draft = text
			session?.sendDraft()
		} catch {
			let alert = NSAlert(error: error)
			alert.runModal()
		}
	}

	func rename(_ chatId: String, to title: String) {
		let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty else { return }
		try? ChatRepository(database).rename(chatId, title: t)
	}

	/// Delete a session (refused while its turn runs — TS 409 turn_in_flight).
	/// Its graph traces stay (the traces option arrives with M7).
	func delete(_ chatId: String) async -> String? {
		if await service.isRunning(chatId) { return "A turn is still running in this session — wait for it to finish or stop it, then try again." }
		do {
			_ = try JobRepository(database, dataDirectory: dataDirectory).deleteJobs(chatId: chatId)
			try SteerOutboxRepository(database).deleteAll(chatId: chatId)
			try ChatRepository(database).delete(chatId)
			if selection == chatId { selection = nil }
			return nil
		} catch {
			return "Delete failed — \(error). Try again."
		}
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
