import Foundation
import LHCore
import LHStore

/// The one-time importer from the TS app's folder (docs/native-macos-m2.md).
///
/// - Input: the picked `…/Application Support/LearnHarness` folder (its
///   `data/` + `auth.json`), or a `data/` folder itself.
/// - The source is only ever read.
/// - Skip-existing idempotency: ids already in the database are never
///   touched; ledgers import as multisets (a line is skipped when the
///   database already holds as many copies as the source has seen so far),
///   so re-running adds nothing and genuine duplicate lines survive.
/// - Each entity lands in its own transaction; one failure is a warning,
///   never an abort.
public struct LegacyImporter: Sendable {
	public let database: AppDatabase
	public let dataDirectory: URL
	public let keychain: any KeychainStore

	public init(database: AppDatabase, dataDirectory: URL, keychain: any KeychainStore) {
		self.database = database
		self.dataDirectory = dataDirectory
		self.keychain = keychain
	}

	public struct Report: Sendable, Hashable {
		public var sourcePath = ""
		public var imported: [String: Int] = [:]
		public var skipped: [String: Int] = [:]
		public var warnings: [String] = []
		/// Provider keys found in auth.json besides Anthropic's (names only).
		public var otherKeys: [String] = []
		public var keyImported = false

		mutating func add(_ entity: String, imported n: Int = 1) { self.imported[entity, default: 0] += n }
		mutating func skip(_ entity: String, _ n: Int = 1) { skipped[entity, default: 0] += n }
	}

	/// Locate `data/` and `auth.json` under the picked folder.
	public static func layout(of root: URL) -> (data: URL, auth: URL?) {
		let fm = FileManager.default
		let nested = root.appending(path: "data", directoryHint: .isDirectory)
		var isDir: ObjCBool = false
		if fm.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue {
			return (nested, root.appending(path: "auth.json"))
		}
		return (root, nil)
	}

	public func run(root: URL, progress: (@Sendable (String) -> Void)? = nil) throws -> Report {
		var report = Report()
		report.sourcePath = root.path
		let started = ISOClock.string()
		let (data, auth) = Self.layout(of: root)

		progress?("Sessions")
		importChats(data.appending(path: "chats"), &report)
		progress?("Background jobs")
		importJobs(data.appending(path: "jobs"), &report)
		progress?("Knowledge graph")
		importGraph(data.appending(path: "graph"), &report)
		progress?("Settings")
		importSettings(data.appending(path: "settings.json"), &report)
		importPrompts(data.appending(path: "prompts"), &report)
		progress?("API key")
		importKey(auth, &report)

		try ImportLog(database).record(sourcePath: report.sourcePath, imported: report.imported, skipped: report.skipped, warnings: report.warnings, startedAt: started)
		return report
	}

	// MARK: Chats

	func importChats(_ dir: URL, _ report: inout Report) {
		let repo = ChatRepository(database)
		for file in Self.jsonFiles(in: dir) {
			let name = file.lastPathComponent
			do {
				let raw = try JSONValue.parse(Data(contentsOf: file))
				if let v = raw["version"]?.intValue, v > CURRENT_CHAT_VERSION {
					report.warnings.append("\(name): stamped with schema version \(v) > \(CURRENT_CHAT_VERSION) — skipped")
					report.skip("chats")
					continue
				}
				guard var record = ChatRecord(legacyJSON: raw) else {
					report.warnings.append("\(name): not a chat record — skipped")
					continue
				}
				if try repo.contains(record.id) {
					report.skip("chats")
					continue
				}
				if let model = record.settings?.model, Self.isForeign(model) {
					report.warnings.append("\(record.id): dropped non-Anthropic model override \(model) (the chat now uses the Strong slot)")
					record.settings?.model = nil
				}
				try repo.insert(record, origin: .import)
				report.add("chats")
				report.add("messages", imported: record.messages.count)
			} catch {
				report.warnings.append("\(name): \(error)")
			}
		}
	}

	// MARK: Jobs

	func importJobs(_ dir: URL, _ report: inout Report) {
		let repo = JobRepository(database, dataDirectory: dataDirectory)
		for file in Self.jsonFiles(in: dir) {
			let name = file.lastPathComponent
			do {
				let raw = try JSONValue.parse(Data(contentsOf: file))
				guard let job = Self.legacyJob(raw) else {
					report.warnings.append("\(name): not a job record — skipped")
					continue
				}
				if try repo.contains(job.id) {
					report.skip("jobs")
					continue
				}
				try repo.insert(job)
				report.add("jobs")
			} catch {
				report.warnings.append("\(name): \(error)")
			}
		}
	}

	static func legacyJob(_ v: JSONValue) -> JobRecord? {
		guard let id = v["id"]?.stringValue, let kind = v["kind"]?.stringValue.flatMap(JobKind.init(rawValue:)),
			let chatId = v["chatId"]?.stringValue, let toolCallId = v["toolCallId"]?.stringValue,
			let status = v["status"]?.stringValue.flatMap(JobStatus.init(rawValue:)) else { return nil }
		var usage = v["usage"].flatMap { try? JSONCodec.decode(JobUsage.self, from: $0) }
		if let model = usage?.model { usage?.model = ChatRecord.legacyModelKey(model) }
		return JobRecord(
			id: id, kind: kind, chatId: chatId, toolCallId: toolCallId, status: status,
			activity: v["activity"]?.stringValue ?? "", createdAt: v["createdAt"]?.stringValue ?? "", updatedAt: v["updatedAt"]?.stringValue ?? "",
			result: v["result"]?.nonNull, error: v["error"]?.stringValue, usage: usage)
	}

	// MARK: Graph

	func importGraph(_ dir: URL, _ report: inout Report) {
		let fm = FileManager.default
		guard fm.fileExists(atPath: dir.path) else { return }
		if let format = try? JSONValue.parse(Data(contentsOf: dir.appending(path: "format.json"))),
			let v = format["version"]?.intValue, v > CURRENT_GRAPH_FORMAT_VERSION {
			report.warnings.append("graph: format version \(v) > \(CURRENT_GRAPH_FORMAT_VERSION) — this app build is older; graph not imported")
			return
		}
		let graph = GraphRepository(database)
		importLedger(dir.appending(path: "nodes.jsonl"), .nodes, "node lines", graph, &report) { line, v in
			guard let id = v["id"]?.stringValue else { return false }
			try graph.appendNodeLine(line, nodeId: id)
			return true
		}
		importLedger(dir.appending(path: "chains.jsonl"), .chains, "chain lines", graph, &report) { line, v in
			guard let id = v["id"]?.stringValue else { return false }
			try graph.appendChainLine(line, chainId: id)
			return true
		}
		importLedger(dir.appending(path: "sessions.jsonl"), .sessions, "checkpoint lines", graph, &report) { line, v in
			guard let chat = v["chatId"]?.stringValue else { return false }
			try graph.appendSessionLine(line, chatId: chat)
			return true
		}
		importLedger(dir.appending(path: "coverage.jsonl"), .coverage, "coverage lines", graph, &report) { line, v in
			guard let chat = v["chatId"]?.stringValue, let fp = v["fp"]?.stringValue else { return false }
			try graph.appendCoverageLine(line, chatId: chat, fp: fp)
			return true
		}
		importSources(dir.appending(path: "sources.json"), graph, &report)
		importPositions(dir.appending(path: "positions.json"), graph, &report)
		importRenderSettings(dir.appending(path: "render-settings.json"), &report)
	}

	/// Multiset line import: verbatim bytes, append order kept, unparseable
	/// lines skipped with a warning (the TS reader skips them too).
	func importLedger(_ file: URL, _ ledger: GraphRepository.Ledger, _ entity: String, _ graph: GraphRepository, _ report: inout Report,
		append: (String, JSONValue) throws -> Bool)
	{
		guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
		var existing: [String: Int] = [:]
		for line in (try? graph.rawLines(ledger)) ?? [] { existing[line, default: 0] += 1 }
		var seen: [String: Int] = [:]
		for (n, sub) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
			let line = String(sub).jsTrimmed
			if line.isEmpty { continue }
			seen[line, default: 0] += 1
			if seen[line]! <= existing[line, default: 0] {
				report.skip(entity)
				continue
			}
			do {
				guard try append(line, try JSONValue.parse(line)) else {
					report.warnings.append("\(file.lastPathComponent):\(n + 1): missing id — skipped")
					continue
				}
				report.add(entity)
			} catch {
				report.warnings.append("\(file.lastPathComponent):\(n + 1): unparseable line — skipped")
			}
		}
	}

	func importSources(_ file: URL, _ graph: GraphRepository, _ report: inout Report) {
		guard let raw = try? JSONValue.parse(Data(contentsOf: file)), case .object(let map) = raw else { return }
		let known = Set(graph.readSources().map(\.id))
		for (key, value) in map {
			guard var source = try? JSONCodec.decode(NotesSource.self, from: value) else {
				report.warnings.append("sources.json: \(key) is not a source record — skipped")
				continue
			}
			if known.contains(source.id) {
				report.skip("notes sources")
				continue
			}
			source.extractions = source.extractions?.map { run in
				var run = run
				run.stages.extractor.model = ChatRecord.legacyModelKey(run.stages.extractor.model)
				run.stages.auditor.model = ChatRecord.legacyModelKey(run.stages.auditor.model)
				return run
			}
			do {
				try graph.upsertSource(source)
				report.add("notes sources")
			} catch {
				report.warnings.append("sources.json: \(key): \(error)")
			}
		}
	}

	func importPositions(_ file: URL, _ graph: GraphRepository, _ report: inout Report) {
		guard let raw = try? JSONValue.parse(Data(contentsOf: file)), case .object(let map)? = raw["positions"] else { return }
		guard graph.readPositions().isEmpty else {
			report.skip("layout positions", map.count)
			return
		}
		let ordered: [(key: String, value: Position)] = map.compactMap { (id, v) in
			guard let x = v["x"]?.doubleValue, let y = v["y"]?.doubleValue, x.isFinite, y.isFinite else { return nil }
			return (id, Position(x: x, y: y))
		}
		do {
			try graph.writePositions(ordered, updatedAt: raw["updatedAt"]?.stringValue ?? ISOClock.string())
			report.add("layout positions", imported: ordered.count)
		} catch {
			report.warnings.append("positions.json: \(error)")
		}
	}

	func importRenderSettings(_ file: URL, _ report: inout Report) {
		guard let raw = try? JSONValue.parse(Data(contentsOf: file)) else { return }
		let settings = SettingsRepository(database)
		do {
			if try settings.readRenderSettings() != nil {
				report.skip("render settings")
				return
			}
			try settings.writeRenderSettings(raw)
			report.add("render settings")
		} catch {
			report.warnings.append("render-settings.json: \(error)")
		}
	}

	// MARK: Settings + prompts

	func importSettings(_ file: URL, _ report: inout Report) {
		guard let raw = try? JSONValue.parse(Data(contentsOf: file)) else { return }
		guard var imported = UserSettings(legacyJSON: raw) else {
			report.warnings.append("settings.json: not a settings record — skipped")
			return
		}
		for slot in ModelSlotName.allCases {
			if let model = imported.models?[slot]?.model, Self.isForeign(model) {
				report.warnings.append("settings: \(slot.rawValue) slot model \(model) is not an Anthropic model — the slot now uses its default")
				imported.models?[slot]?.model = nil
			}
		}
		for (role, override) in imported.agent?.models ?? [:] {
			if let model = override.model, Self.isForeign(model) {
				report.warnings.append("settings: \(role.rawValue) override model \(model) is not an Anthropic model — dropped")
				imported.agent?.models?[role]?.model = nil
			}
		}
		let repo = SettingsRepository(database)
		do {
			// Skip-existing at top-level key granularity: only sections the
			// stored record lacks are added.
			let stored = try repo.read()
			guard case .object(let incoming) = imported.json else { return }
			var merged = stored.map { $0.json.objectValue ?? JSONObject() } ?? JSONObject()
			var added = 0
			for (key, value) in incoming where merged[key] == nil {
				merged[key] = value
				if key != "version" { added += 1 }
			}
			let skippedKeys = incoming.keys.filter { $0 != "version" }.count - added
			guard added > 0, let next = sanitizeUserSettings(.object(merged)) else {
				if skippedKeys > 0 { report.skip("settings sections", skippedKeys) }
				return
			}
			try repo.write(next)
			report.add("settings sections", imported: added)
			if skippedKeys > 0 { report.skip("settings sections", skippedKeys) }
		} catch {
			report.warnings.append("settings.json: \(error)")
		}
	}

	func importPrompts(_ dir: URL, _ report: inout Report) {
		let repo = PromptOverrideRepository(database)
		guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
		let base = dir.standardizedFileURL.path
		for case let url as URL in walker where url.pathExtension == "md" {
			let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
			guard PromptOverrideRepository.isValidSegmentPath(rel) else { continue }
			do {
				let body = try String(contentsOf: url, encoding: .utf8)
				if try repo.insertIfAbsent(rel, body: body) { report.add("prompt overrides") } else { report.skip("prompt overrides") }
			} catch {
				report.warnings.append("prompts/\(rel): \(error)")
			}
		}
	}

	// MARK: Key

	func importKey(_ auth: URL?, _ report: inout Report) {
		guard let auth else {
			report.warnings.append("API key: you picked the data folder itself, so auth.json was out of reach — add the key in Settings")
			return
		}
		guard let raw = try? JSONValue.parse(Data(contentsOf: auth)), case .object(let map) = raw else {
			report.warnings.append("API key: no readable auth.json next to data/")
			return
		}
		report.otherKeys = map.keys.filter { $0 != "ANTHROPIC_API_KEY" }.sorted()
		guard let key = map["ANTHROPIC_API_KEY"]?.stringValue?.jsTrimmed, !key.isEmpty else {
			report.warnings.append("API key: auth.json has no ANTHROPIC_API_KEY")
			return
		}
		do {
			if try keychain.anthropicKey() != nil {
				report.skip("API key")
				return
			}
			try keychain.setAnthropicKey(key)
			report.keyImported = true
			report.add("API key")
		} catch {
			report.warnings.append("API key: \(error)")
		}
	}

	// MARK: Helpers

	/// Provider-qualified ids are what the legacy decoders keep for non-Anthropic models.
	static func isForeign(_ model: String) -> Bool { model.contains(":") }

	static func jsonFiles(in dir: URL) -> [URL] {
		((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}
}
