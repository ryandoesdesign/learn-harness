import Foundation
import GRDB
import LHCore

/// Port of src/store/jobs.ts. Demo HTML / visual SVG never sit in the row:
/// a result carrying them is externalized to `artifacts/<jobId>/demo.html`
/// or `visual.svg`, and the stored result carries `artifactPath` (relative
/// to the data directory) instead (docs/native-macos-m2.md).
public struct JobRepository: Sendable {
	public let database: AppDatabase
	/// The data directory artifacts live under.
	public let dataDirectory: URL

	public init(_ database: AppDatabase, dataDirectory: URL) {
		self.database = database
		self.dataDirectory = dataDirectory
	}

	public struct Patch: Sendable {
		public var status: JobStatus?
		public var activity: String?
		public var result: JSONValue?
		public var error: String?
		public var usage: JobUsage?
		public var updatedAt: String?
		public init(status: JobStatus? = nil, activity: String? = nil, result: JSONValue? = nil, error: String? = nil, usage: JobUsage? = nil, updatedAt: String? = nil) {
			self.status = status
			self.activity = activity
			self.result = result
			self.error = error
			self.usage = usage
			self.updatedAt = updatedAt
		}
	}

	@discardableResult
	public func createJob(kind: JobKind, chatId: String, toolCallId: String, activity: String? = nil, now: Date = Date()) throws -> JobRecord {
		let stamp = ISOClock.string(now)
		let ms = Int(now.timeIntervalSince1970 * 1000)
		let record = JobRecord(
			id: "job_\(String(ms, radix: 36))_\(UUID().uuidString.lowercased().prefix(8))",
			kind: kind, chatId: chatId, toolCallId: toolCallId, status: .running,
			activity: activity ?? "starting", createdAt: stamp, updatedAt: stamp)
		try insert(record)
		return record
	}

	/// The dispatch's get-or-insert: the job for this tool call, created when
	/// new (`created` = the caller spawns the run).
	public func getOrCreate(kind: JobKind, chatId: String, toolCallId: String, now: Date = Date()) throws -> (job: JobRecord, created: Bool) {
		if let existing = try findJob(chatId: chatId, toolCallId: toolCallId) { return (existing, false) }
		do {
			return (try createJob(kind: kind, chatId: chatId, toolCallId: toolCallId, now: now), true)
		} catch let e as DatabaseError where e.resultCode == .SQLITE_CONSTRAINT {
			guard let existing = try findJob(chatId: chatId, toolCallId: toolCallId) else { throw e }
			return (existing, false)
		}
	}

	/// A job's model calls, appended to `usage_step` (owner `job`).
	public func appendUsageSteps(_ steps: [(model: String, usage: CallUsage)], jobId: String) throws {
		try database.writer.write { db in
			let start = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(step_index) + 1, 0) FROM usage_step WHERE owner_kind = 'job' AND owner_id = ?", arguments: [jobId]) ?? 0
			for (i, s) in steps.enumerated() {
				try UsageRows.insertSteps([s.usage], ownerKind: "job", ownerId: jobId, model: s.model, startIndex: start + i, db: db)
			}
		}
	}

	public func usageSteps(jobId: String) throws -> [CallUsage] {
		try database.writer.read { db in try UsageRows.steps(ownerKind: "job", ownerId: jobId, db: db) }
	}

	/// Every job still marked running (launch recovery: all are orphans).
	public func runningJobs() throws -> [JobRecord] {
		try database.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM job WHERE status = 'running' ORDER BY created_at").map(Self.decode) }
	}

	/// Observe one chat's jobs (the dispatch cards' live form).
	public func observe(chatId: String) -> AsyncValueObservation<[JobRecord]> {
		ValueObservation.tracking { db in try Row.fetchAll(db, sql: "SELECT * FROM job WHERE chat_id = ?", arguments: [chatId]).map(Self.decode) }
			.values(in: database.writer)
	}

	/// Observe the running jobs across all chats (the sidebar's Background agents).
	public func observeRunning() -> AsyncValueObservation<[JobRecord]> {
		ValueObservation.tracking { db in try Row.fetchAll(db, sql: "SELECT * FROM job WHERE status = 'running' ORDER BY created_at").map(Self.decode) }
			.values(in: database.writer)
	}

	/// Insert a whole record (the importer's path; also createJob's).
	public func insert(_ record: JobRecord) throws {
		guard validId(record.id) else { throw StoreError.invalidId(record.id) }
		let result = try record.result.map { try externalize($0, kind: record.kind, jobId: record.id) }
		try database.writer.write { db in
			try db.execute(sql: """
				INSERT INTO job (id, kind, chat_id, tool_call_id, status, activity, created_at, updated_at, result_json, error, usage_json)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
				""", arguments: [record.id, record.kind.rawValue, record.chatId, record.toolCallId, record.status.rawValue, record.activity,
					record.createdAt, record.updatedAt, result?.serialized(), record.error, try record.usage.map { try JSONCodec.encode($0).serialized() }])
		}
	}

	public func getJob(_ id: String) throws -> JobRecord? {
		try database.writer.read { db in
			try Row.fetchOne(db, sql: "SELECT * FROM job WHERE id = ?", arguments: [id]).map(Self.decode)
		}
	}

	public func contains(_ id: String) throws -> Bool {
		try database.writer.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM job WHERE id = ?", arguments: [id]) == true }
	}

	/// Merge a patch (identity fields immutable); nil when the job is unknown.
	@discardableResult
	public func updateJob(_ id: String, _ patch: Patch, now: Date = Date()) throws -> JobRecord? {
		guard var record = try getJob(id) else { return nil }
		if let s = patch.status { record.status = s }
		if let a = patch.activity { record.activity = a }
		if let r = patch.result { record.result = try externalize(r, kind: record.kind, jobId: id) }
		if let e = patch.error { record.error = e }
		if let u = patch.usage { record.usage = u }
		record.updatedAt = patch.updatedAt ?? ISOClock.string(now)
		try database.writer.write { db in
			try db.execute(sql: "UPDATE job SET status = ?, activity = ?, updated_at = ?, result_json = ?, error = ?, usage_json = ? WHERE id = ?",
				arguments: [record.status.rawValue, record.activity, record.updatedAt, record.result?.serialized(), record.error,
					try record.usage.map { try JSONCodec.encode($0).serialized() }, id])
		}
		return record
	}

	/// A chat's jobs, most recently updated first.
	public func listJobs(chatId: String) throws -> [JobRecord] {
		try database.writer.read { db in
			try Row.fetchAll(db, sql: "SELECT * FROM job WHERE chat_id = ?", arguments: [chatId]).map(Self.decode)
		}.sorted { $1.updatedAt.utf16.lexicographicallyPrecedes($0.updatedAt.utf16) }
	}

	public func findJob(chatId: String, toolCallId: String) throws -> JobRecord? {
		try listJobs(chatId: chatId).first { $0.toolCallId == toolCallId }
	}

	@discardableResult
	public func deleteJobs(chatId: String) throws -> Int {
		let ids = try listJobs(chatId: chatId).map(\.id)
		try database.writer.write { db in
			for id in ids {
				try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [id])
			}
		}
		for id in ids { try? FileManager.default.removeItem(at: artifactDirectory(id)) }
		return ids.count
	}

	// MARK: Artifacts

	public func artifactDirectory(_ jobId: String) -> URL {
		dataDirectory.appending(path: "artifacts/\(jobId)", directoryHint: .isDirectory)
	}

	/// The artifact text a stored result points at (artifactPath), if any.
	public func artifactText(for result: JSONValue) throws -> String? {
		guard let rel = result["artifactPath"]?.stringValue else { return nil }
		return try String(contentsOf: dataDirectory.appending(path: rel), encoding: .utf8)
	}

	/// Move a demo's html / a visual's svg out to its artifact file.
	func externalize(_ result: JSONValue, kind: JobKind, jobId: String) throws -> JSONValue {
		let (key, file): (String, String)
		switch kind {
		case .demo: (key, file) = ("html", "demo.html")
		case .visual: (key, file) = ("svg", "visual.svg")
		case .research, .pdf: return result
		}
		guard case .object(var obj) = result, let text = obj[key]?.stringValue, !text.isEmpty else { return result }
		let dir = artifactDirectory(jobId)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try Data(text.utf8).write(to: dir.appending(path: file), options: .atomic)
		var out = JSONObject()
		for (k, v) in obj {
			if k == key { out["artifactPath"] = .string("artifacts/\(jobId)/\(file)") } else { out[k] = v }
		}
		obj = out
		return .object(obj)
	}

	static func decode(_ r: Row) throws -> JobRecord {
		JobRecord(
			id: r["id"], kind: JobKind(rawValue: r["kind"]) ?? .research, chatId: r["chat_id"], toolCallId: r["tool_call_id"],
			status: JobStatus(rawValue: r["status"]) ?? .error, activity: r["activity"], createdAt: r["created_at"], updatedAt: r["updated_at"],
			result: try (r["result_json"] as String?).map(JSONValue.parse), error: r["error"],
			usage: try (r["usage_json"] as String?).map { try JSONCodec.decode(JobUsage.self, from: JSONValue.parse($0)) })
	}
}
