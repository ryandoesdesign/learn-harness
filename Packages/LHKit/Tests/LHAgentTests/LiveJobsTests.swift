import Foundation
import Testing
import LHAnthropic
import LHResources
import LHWeb
@testable import LHAgent
@testable import LHCore
import LHStore

/// The M6 live acceptance (docs/native-macos-m6.md): opt-in only —
/// `LH_LIVE=1 ANTHROPIC_API_KEY=… swift test --filter LiveJobs`. Every
/// kind runs for real on Haiku 5.5 at low effort (real web search, real
/// WebKit, a real PDF) and delivers exactly once — idle and mid-turn; an
/// abort lands as one abort steer; a killed job re-runs at launch.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"), .serialized)
struct LiveJobsTests {
	struct Env {
		let db: AppDatabase
		let service: TurnService
		let jobs: JobService
		let chatId: String
		let folder: URL
		let key: String
		let catalog: ModelCatalog
		let dir: URL

		init() async throws {
			key = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
			db = try AppDatabase.inMemory()
			catalog = try ModelCatalog(data: LHResources.modelsJSON)
			let haiku = ModelSlot(model: "claude-haiku-5-5", effort: .low)
			try SettingsRepository(db).update { s in s.models = ModelsSettings(strong: haiku, cheap: haiku, vision: haiku) }
			service = TurnService(database: db, keychain: InMemoryKeychain(key: key), catalog: catalog)
			folder = FileManager.default.temporaryDirectory.appending(path: "lh-live-\(UUID().uuidString)").resolvingSymlinksInPath()
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			dir = folder.appending(path: "data")
			let folderURL = folder
			jobs = await JobService(database: db, dataDirectory: dir, keychain: InMemoryKeychain(key: key), catalog: catalog,
				verifier: WebHeadlessVerifier.shared, fileAccess: FileAccess(folders: { [folderURL] }))
			await jobs.attach(service)
			let chat = try ChatRepository(db).createChat(title: "Live jobs")
			chatId = chat.id
			try ChatRepository(db).append([
				newUserMessage("Teach me about derivatives. Keep every reply to one sentence.", now: 0),
				Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.text("Let's start with slopes.")], model: "claude-haiku-5-5", stopReason: "end_turn"))),
			], to: chat.id)
		}

		var repo: JobRepository { JobRepository(db, dataDirectory: dir) }
		func job(_ tc: String) throws -> JobRecord? { try repo.findJob(chatId: chatId, toolCallId: tc) }
		func steers(_ jobId: String) throws -> [Message] { try ChatRepository(db).get(chatId)!.messages.filter { $0.id == "steer_\(jobId)" } }

		/// Wait until the job settles and no turn is running (the wake finished).
		func settled(_ tc: String, timeout: Duration = .seconds(400)) async throws -> JobRecord {
			let deadline = ContinuousClock.now + timeout
			while ContinuousClock.now < deadline {
				if let j = try job(tc), j.status != .running, await !service.isRunning(chatId) { return j }
				try await Task.sleep(for: .milliseconds(250))
			}
			Issue.record("job \(tc) never settled (activity: \(try job(tc)?.activity ?? "-"))")
			throw CancellationError()
		}
	}

	@Test(.timeLimit(.minutes(10)))
	func eachKindDeliversExactlyOnceWhileIdle() async throws {
		let env = try await Env()
		let pdf = try makePdf(["Derivatives", "The derivative of x squared is 2x.\nIt measures the instantaneous rate of change."])
		try FileManager.default.moveItem(at: pdf, to: env.folder.appending(path: "notes.pdf"))
		let cases: [(JobKind, String, JSONValue)] = [
			(.research, "tc_r", ["question": "What year did Leibniz first publish his calculus notation? Answer in one line.", "context": "a one-line aside in a lesson"]),
			(.pdf, "tc_p", ["path": "notes.pdf", "question": "What is the derivative of x squared?"]),
			(.visual, "tc_v", ["brief": "A 400x300 SVG: the parabola y = x^2 for x in [-2, 2] with its tangent line at x = 1, labelled 'slope 2'."]),
			(.demo, "tc_d", ["title": "Tangent slider", "brief": "A slider for a in [-2, 2] that redraws y = x^2 on a canvas with the tangent at x = a, and shows the slope 2a as text."]),
		]
		for (kind, tc, input) in cases {
			_ = await env.jobs.dispatch(kind: kind, chatId: env.chatId, toolCallId: tc, input: input, ack: "ack")
			let job = try await env.settled(tc)
			let result = try #require(job.result)
			print("LIVE \(kind):", job.status, job.activity, "steps:", job.usage?.steps ?? 0, "cost:", jobCost(job, catalog: env.catalog).map(formatUsd) ?? "—")
			#expect(job.status == .done, "\(kind): \(result.serialized().prefix(400))")
			#expect(try env.steers(job.id).count == 1, "\(kind) delivered exactly once")
			switch kind {
			case .research: #expect(result["sources"]?.arrayValue?.isEmpty == false)
			case .pdf:
				#expect(result["brief"]?.stringValue?.contains("2x") == true)
				#expect(result["pagesRead"]?.arrayValue?.contains(.number(2)) == true)
			case .visual, .demo: #expect(try env.repo.artifactText(for: result)?.isEmpty == false)
			}
		}
	}

	@Test(.timeLimit(.minutes(6)))
	func aSteerLandsOnceWhileATurnRuns() async throws {
		let env = try await Env()
		_ = await env.jobs.dispatch(kind: .research, chatId: env.chatId, toolCallId: "tc_live", input: ["question": "Who coined the word 'derivative' in calculus? One line."], ack: "ack")
		try await env.service.send(env.chatId, .text("While that runs: in one sentence, what is a slope?"))
		let job = try await env.settled("tc_live")
		#expect(job.status == .done)
		#expect(try env.steers(job.id).count == 1)
	}

	@Test(.timeLimit(.minutes(4)))
	func endLandsOneAbortSteer() async throws {
		let env = try await Env()
		_ = await env.jobs.dispatch(kind: .demo, chatId: env.chatId, toolCallId: "tc_a", input: ["title": "Big demo", "brief": "An elaborate 3D surface plotter."], ack: "ack")
		try await Task.sleep(for: .seconds(3))
		let job = try #require(try env.job("tc_a"))
		#expect(await env.jobs.abort(job.id) == .ok)
		_ = try await env.settled("tc_a")
		try await Task.sleep(for: .seconds(5))
		let steers = try env.steers(job.id)
		#expect(steers.count == 1)
		#expect(steers.first?.marker?.kind == .subagentAbort)
		#expect(try env.job("tc_a")?.error == "Aborted by learner")
	}

	@Test(.timeLimit(.minutes(6)))
	func aKilledJobReRunsAtLaunch() async throws {
		let env = try await Env()
		let call = Message(id: "a1", timestamp: 1, body: .assistant(AssistantBody(content: [
			Block(raw: ["type": "tool_use", "id": "tc_k", "name": "research", "input": ["question": "What is the derivative of sin x? One line."]]),
		], model: "claude-haiku-5-5", stopReason: "tool_use")))
		try ChatRepository(env.db).append([call, Message(id: "r1", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "tc_k", toolName: "research", content: [.text("Dispatched")], isError: false)))], to: env.chatId)
		_ = await env.jobs.dispatch(kind: .research, chatId: env.chatId, toolCallId: "tc_k", input: call.assistant!.toolUses[0].input, ack: "ack")
		try await Task.sleep(for: .seconds(2))
		await env.jobs.cancelAll(chatId: env.chatId) // the kill: the run dies silently, the row stays running
		#expect(try env.job("tc_k")?.status == .running)
		// Relaunch: a fresh pair of services over the same store.
		let service = TurnService(database: env.db, keychain: InMemoryKeychain(key: env.key), catalog: env.catalog)
		let folder = env.folder
		let jobs = await JobService(database: env.db, dataDirectory: env.dir, keychain: InMemoryKeychain(key: env.key), catalog: env.catalog,
			verifier: WebHeadlessVerifier.shared, fileAccess: FileAccess(folders: { [folder] }))
		await jobs.attach(service)
		await service.recoverOnLaunch()
		await jobs.recoverOnLaunch()
		let deadline = ContinuousClock.now + .seconds(300)
		while ContinuousClock.now < deadline, try env.job("tc_k")?.status == .running { try await Task.sleep(for: .milliseconds(250)) }
		let job = try #require(try env.job("tc_k"))
		#expect(job.status == .done)
		#expect(try env.steers(job.id).count == 1)
	}
}
