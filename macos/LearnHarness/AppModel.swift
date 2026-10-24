import Foundation
import LHCore
import LHImport
import LHStore
import Observation

/// The app's composition root: one database, its repositories, and the
/// state the shell renders. MainActor; long work hops off it.
@MainActor
@Observable
final class AppModel {
	let database: AppDatabase
	let dataDirectory: URL
	let keychain: any KeychainStore

	private(set) var sessions: [ChatSummary] = []
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
		do {
			database = try AppDatabase.open(directory: dataDirectory)
		} catch {
			// Fall back to an in-memory database so the window still opens and says why.
			database = try! AppDatabase.inMemory()
			startupError = "Could not open the database: \(error)"
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
}
