import CryptoKit
import Foundation
import Testing
import LHCore
@testable import LHImport
@testable import LHStore

private enum Repo {
	static let root: URL = {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<6 { url.deleteLastPathComponent() }
		return url
	}()
	static let goldenData = root.appending(path: "tests/fixtures/golden-data")
	static func golden(_ name: String) throws -> JSONValue {
		try JSONValue.parse(Data(contentsOf: root.appending(path: "macos/Packages/LHKit/Tests/LHCoreTests/Golden/\(name).json")))
	}
}

private struct Harness {
	let db: AppDatabase
	let dataDir: URL
	let keychain = InMemoryKeychain()

	init() throws {
		db = try AppDatabase.inMemory()
		dataDir = FileManager.default.temporaryDirectory.appending(path: "lhimport-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
	}

	var importer: LegacyImporter { LegacyImporter(database: db, dataDirectory: dataDir, keychain: keychain) }
}

/// SHA-256 of every file under a tree (relative path → digest).
private func treeDigest(_ root: URL) throws -> [String: String] {
	var out: [String: String] = [:]
	let base = root.standardizedFileURL.path
	for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
		out[String(url.standardizedFileURL.path.dropFirst(base.count))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
	}
	return out
}

/// A scratch copy of the golden data laid out like the Electron userData dir.
private func userDataCopy(auth: JSONValue?) throws -> URL {
	let root = FileManager.default.temporaryDirectory.appending(path: "lhsrc-\(UUID().uuidString)/LearnHarness", directoryHint: .isDirectory)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	try FileManager.default.copyItem(at: Repo.goldenData, to: root.appending(path: "data"))
	if let auth { try Data(auth.serialized().utf8).write(to: root.appending(path: "auth.json")) }
	return root
}

@Suite struct GoldenImportTests {
	@Test func reproducesTheTSGraphAndRecordsFromTheGoldenDataDir() throws {
		let h = try Harness()
		let report = try h.importer.run(root: Repo.goldenData)
		#expect(report.imported["chats"] == 2)
		#expect(report.imported["jobs"] == 5)
		#expect(report.imported["node lines"] == 298)
		#expect(report.imported["chain lines"] == 173)
		#expect(report.imported["checkpoint lines"] == 8)
		#expect(report.imported["coverage lines"] == 105)
		#expect(report.imported["notes sources"] == 4)

		let chats = ChatRepository(h.db)
		let graph = GraphRepository(h.db)
		#expect(graph.readNodes().count == 298)
		#expect(graph.readChains().count == 173)

		// Raw ledger bytes survive verbatim.
		let sourceLines = try String(contentsOf: Repo.goldenData.appending(path: "graph/nodes.jsonl"), encoding: .utf8)
			.split(separator: "\n").map(String.init)
		#expect(try graph.rawLines(.nodes) == sourceLines)

		// The snapshot equals the TS dump over the same data dir.
		let snap = graphSnapshot(GraphDeps(chatStore: chats, graphStore: graph))
		var o = JSONObject()
		o["nodes"] = try JSONCodec.encode(snap.nodes)
		o["propositions"] = try JSONCodec.encode(snap.propositions)
		o["edges"] = try JSONCodec.encode(snap.edges)
		o["logicalEdges"] = try JSONCodec.encode(snap.logicalEdges)
		o["impLinks"] = try JSONCodec.encode(snap.impLinks)
		o["chains"] = try JSONCodec.encode(snap.chains)
		o["sessions"] = try JSONCodec.encode(snap.sessions)
		o["fileSources"] = try JSONCodec.encode(snap.fileSources)
		o["nodeSessions"] = try JSONCodec.encode(snap.nodeSessions)
		o["clusters"] = .array(snap.clusters.map { ["id": .string($0.id), "label": $0.label.map(JSONValue.string) ?? .null, "members": .array($0.members.map(JSONValue.string))] })
		if let p = snap.positions { o["positions"] = try JSONCodec.encode(p) }
		let diff = jsonDiff(.object(o), try Repo.golden("graph.snapshot"))
		#expect(diff == nil, "\(diff ?? "")")

		// The session index matches the TS derivation.
		let index = graphSessionIndex(GraphDeps(chatStore: chats, graphStore: graph))
		let goldenIndex = try Repo.golden("graph.derived")["sessionIndex"]?.arrayValue ?? []
		#expect(index.map(\.id) == goldenIndex.compactMap { $0["id"]?.stringValue })
		#expect(index.map(\.name) == goldenIndex.compactMap { $0["name"]?.stringValue })

		// Both chats, message for message.
		for id in ["chat_mv27rrra_feff23b6", "chat_mv293wv5_10656952"] {
			let expected = try #require(ChatRecord(legacyJSON: JSONValue.parse(Data(contentsOf: Repo.goldenData.appending(path: "chats/\(id).json")))))
			let back = try #require(try chats.get(id))
			#expect(back.messages == expected.messages)
			#expect(back.turns == expected.turns)
			#expect(back.tree == expected.tree)
		}
	}

	@Test func jobsMoveArtifactsToFiles() throws {
		let h = try Harness()
		_ = try h.importer.run(root: Repo.goldenData)
		let jobs = JobRepository(h.db, dataDirectory: h.dataDir)
		// Jobs reference chats the fixture set doesn't carry — read them by id.
		let ids = try FileManager.default.contentsOfDirectory(atPath: Repo.goldenData.appending(path: "jobs").path).map { String($0.dropLast(5)) }
		let all = try ids.compactMap { try jobs.getJob($0) }
		#expect(all.count == 5)
		for job in all where job.status == .done && (job.kind == .demo || job.kind == .visual) {
			let result = try #require(job.result)
			#expect(result["html"] == nil && result["svg"] == nil)
			let text = try #require(try jobs.artifactText(for: result))
			#expect(!text.isEmpty)
		}
		#expect(all.contains { $0.kind == .demo && $0.status == .done })
	}

	@Test func settingsDropForeignModelsAndKeepEverythingElse() throws {
		let h = try Harness()
		let report = try h.importer.run(root: Repo.goldenData)
		let s = try #require(try SettingsRepository(h.db).read())
		#expect(s.models?.strong?.model == nil)
		#expect(s.models?.strong?.effort == .low)
		#expect(s.agent?.tools == ["explain": false])
		#expect(s.compaction?.thresholdTokens == 50000)
		#expect(report.warnings.filter { $0.hasPrefix("settings:") }.count == 3)
		let effective = try SettingsRepository(h.db).effective(catalog: try ModelCatalog(data: LHCatalogFixture.data))
		#expect(effective.models.strong.model == "claude-opus-5-5")
	}

	@Test func reimportAddsNothingAndNeverTouchesTheSource() throws {
		let h = try Harness()
		let before = try treeDigest(Repo.goldenData)
		_ = try h.importer.run(root: Repo.goldenData)
		let counts = try h.db.writer.read { db in
			try ["chat", "message", "job", "graph_node_line", "graph_chain_line", "graph_session", "coverage", "source", "node_position", "turn", "usage_step"]
				.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
		}
		let second = try h.importer.run(root: Repo.goldenData)
		let after = try h.db.writer.read { db in
			try ["chat", "message", "job", "graph_node_line", "graph_chain_line", "graph_session", "coverage", "source", "node_position", "turn", "usage_step"]
				.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
		}
		#expect(counts == after)
		#expect(second.imported.filter { $0.key != "API key" }.isEmpty, "\(second.imported)")
		#expect(second.skipped["chats"] == 2)
		#expect(second.skipped["node lines"] == 298)
		#expect(try treeDigest(Repo.goldenData) == before)
		#expect(try ImportLog(h.db).entries().count == 2)
	}

	@Test func duplicateLedgerLinesSurviveAsAMultiset() throws {
		let h = try Harness()
		let root = try userDataCopy(auth: nil)
		let nodes = root.appending(path: "data/graph/nodes.jsonl")
		let first = try String(contentsOf: nodes, encoding: .utf8).split(separator: "\n").first.map(String.init)!
		try (try String(contentsOf: nodes, encoding: .utf8) + first + "\n").write(to: nodes, atomically: true, encoding: .utf8)
		_ = try h.importer.run(root: root)
		_ = try h.importer.run(root: root)
		#expect(try GraphRepository(h.db).rawLines(.nodes).count == 299)
	}
}

@Suite struct ImportKeyAndRefusalTests {
	@Test func movesTheAnthropicKeyIntoTheKeychainAndListsTheRest() throws {
		let h = try Harness()
		let root = try userDataCopy(auth: ["ANTHROPIC_API_KEY": "sk-ant-test", "OPENROUTER_API_KEY": "sk-or-x", "TAVILY_API_KEY": "t"])
		let report = try h.importer.run(root: root)
		#expect(report.keyImported)
		#expect(try h.keychain.anthropicKey() == "sk-ant-test")
		#expect(report.otherKeys == ["OPENROUTER_API_KEY", "TAVILY_API_KEY"])
		#expect(!report.warnings.joined().contains("sk-"), "key values never reach the report")
		let again = try h.importer.run(root: root)
		#expect(!again.keyImported && again.skipped["API key"] == 1)
	}

	@Test func pickingTheDataFolderItselfReportsTheKeyOutOfReach() throws {
		let h = try Harness()
		let report = try h.importer.run(root: Repo.goldenData)
		#expect(!report.keyImported)
		#expect(report.warnings.contains { $0.hasPrefix("API key: you picked the data folder") })
	}

	@Test func newerStampsAreRefusedAndCorruptFilesAreIsolated() throws {
		let h = try Harness()
		let root = try userDataCopy(auth: nil)
		let chats = root.appending(path: "data/chats")
		var newer = try JSONValue.parse(Data(contentsOf: chats.appending(path: "chat_mv293wv5_10656952.json")))
		newer["version"] = 2
		try Data(newer.serialized().utf8).write(to: chats.appending(path: "chat_mv293wv5_10656952.json"))
		try Data("{not json".utf8).write(to: chats.appending(path: "chat_broken.json"))
		try Data(#"{"version":2}"#.utf8).write(to: root.appending(path: "data/graph/format.json"))
		let report = try h.importer.run(root: root)
		#expect(report.imported["chats"] == 1)
		#expect(report.warnings.contains { $0.contains("schema version 2") })
		#expect(report.warnings.contains { $0.hasPrefix("chat_broken.json") })
		#expect(report.warnings.contains { $0.hasPrefix("graph: format version 2") })
		#expect(report.imported["node lines"] == nil)
	}
}

/// The bundled catalog's bytes (LHResources is not a dependency of this target).
enum LHCatalogFixture {
	static var data: Data {
		get throws { try Data(contentsOf: Repo.root.appending(path: "macos/Packages/LHKit/Sources/LHResources/Resources/models.json")) }
	}
}

/// Structural JSON diff (order-insensitive keys) — the first differing path.
private func jsonDiff(_ a: JSONValue, _ b: JSONValue, path: String = "$") -> String? {
	switch (a, b) {
	case (.object(let x), .object(let y)):
		if Set(x.keys) != Set(y.keys) { return "\(path): keys differ" }
		for k in x.keys { if let d = jsonDiff(x[k]!, y[k]!, path: "\(path).\(k)") { return d } }
		return nil
	case (.array(let x), .array(let y)):
		if x.count != y.count { return "\(path): length \(x.count) ≠ \(y.count)" }
		for i in x.indices { if let d = jsonDiff(x[i], y[i], path: "\(path)[\(i)]") { return d } }
		return nil
	case (.number(let x), .number(let y)):
		return x.double == y.double ? nil : "\(path): \(x.lexeme) ≠ \(y.lexeme)"
	default:
		return a == b ? nil : "\(path): \(a.serialized().prefix(80)) ≠ \(b.serialized().prefix(80))"
	}
}
