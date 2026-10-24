import Foundation
import GRDB
import LHCore

/// The money channel's rows: `usage_step` (one per model call) under a turn,
/// an extraction stage, or a job; `extraction_run` for run metadata.
/// Dollars are never stored — LHCore prices them at read time.
enum UsageRows {
	static func insertSteps(_ steps: [CallUsage], ownerKind: String, ownerId: String, model: String, db: Database) throws {
		for (i, s) in steps.enumerated() {
			try db.execute(sql: """
				INSERT INTO usage_step (owner_kind, owner_id, step_index, model, input_tokens, output_tokens,
					cache_read_tokens, cache_write_tokens, reasoning_tokens)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
				""", arguments: [ownerKind, ownerId, i, model, s.inputTokens, s.outputTokens, s.cacheReadTokens, s.cacheWriteTokens, s.reasoningTokens])
		}
	}

	static func steps(ownerKind: String, ownerId: String, db: Database) throws -> [CallUsage] {
		try Row.fetchAll(db, sql: "SELECT * FROM usage_step WHERE owner_kind = ? AND owner_id = ? ORDER BY step_index", arguments: [ownerKind, ownerId]).map {
			CallUsage(inputTokens: $0["input_tokens"], outputTokens: $0["output_tokens"], cacheReadTokens: $0["cache_read_tokens"],
				cacheWriteTokens: $0["cache_write_tokens"], reasoningTokens: $0["reasoning_tokens"])
		}
	}

	/// Idempotent per (owner, startedAt).
	static func insertRun(_ run: ExtractionRunUsage, ownerKind: String, ownerId: String, db: Database) throws {
		if try Bool.fetchOne(db, sql: "SELECT 1 FROM extraction_run WHERE owner_kind = ? AND owner_id = ? AND started_at = ?", arguments: [ownerKind, ownerId, run.startedAt]) == true { return }
		let seq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM extraction_run WHERE owner_kind = ? AND owner_id = ?", arguments: [ownerKind, ownerId]) ?? 0
		try db.execute(sql: """
			INSERT INTO extraction_run (owner_kind, owner_id, seq, started_at, at, duration_ms, stats_json, extractor_model, auditor_model)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			""", arguments: [ownerKind, ownerId, seq, run.startedAt, run.at, run.durationMs,
				try run.stats.map { try JSONCodec.encode($0).serialized() }, run.stages.extractor.model, run.stages.auditor.model])
		let key = runKey(ownerKind: ownerKind, ownerId: ownerId, startedAt: run.startedAt)
		try insertSteps(run.stages.extractor.steps, ownerKind: "extractor", ownerId: key, model: run.stages.extractor.model, db: db)
		try insertSteps(run.stages.auditor.steps, ownerKind: "auditor", ownerId: key, model: run.stages.auditor.model, db: db)
	}

	static func runs(ownerKind: String, ownerId: String, db: Database) throws -> [ExtractionRunUsage] {
		try Row.fetchAll(db, sql: "SELECT * FROM extraction_run WHERE owner_kind = ? AND owner_id = ? ORDER BY seq", arguments: [ownerKind, ownerId]).map { r in
			let startedAt: Int = r["started_at"]
			let key = runKey(ownerKind: ownerKind, ownerId: ownerId, startedAt: startedAt)
			return ExtractionRunUsage(
				startedAt: startedAt, at: r["at"], durationMs: r["duration_ms"],
				stats: try (r["stats_json"] as String?).map { try JSONCodec.decode(EmissionStats.self, from: JSONValue.parse($0)) },
				stages: .init(
					extractor: ExtractionStageUsage(model: r["extractor_model"], steps: try steps(ownerKind: "extractor", ownerId: key, db: db)),
					auditor: ExtractionStageUsage(model: r["auditor_model"], steps: try steps(ownerKind: "auditor", ownerId: key, db: db))))
		}
	}

	static func deleteRuns(ownerKind: String, ownerId: String, db: Database) throws {
		for startedAt in try Int.fetchAll(db, sql: "SELECT started_at FROM extraction_run WHERE owner_kind = ? AND owner_id = ?", arguments: [ownerKind, ownerId]) {
			let key = runKey(ownerKind: ownerKind, ownerId: ownerId, startedAt: startedAt)
			try db.execute(sql: "DELETE FROM usage_step WHERE owner_kind IN ('extractor', 'auditor') AND owner_id = ?", arguments: [key])
		}
		try db.execute(sql: "DELETE FROM extraction_run WHERE owner_kind = ? AND owner_id = ?", arguments: [ownerKind, ownerId])
	}

	/// A stage's usage_step owner id: "<owner kind>:<owner id>:<startedAt>".
	static func runKey(ownerKind: String, ownerId: String, startedAt: Int) -> String {
		"\(ownerKind):\(ownerId):\(startedAt)"
	}
}
