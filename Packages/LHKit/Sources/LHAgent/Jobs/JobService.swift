import Foundation
import LHAnthropic
import LHCore
import LHStore

/// The background-job service (docs/native-macos-m6.md) — the port of
/// subagents/runner.ts, aborts.ts and the job half of server/jobs.ts. A
/// dispatch creates the job (once per tool call) and runs it as a Task;
/// the result (or failure shape, or abort) becomes a deterministic
/// `steer_<jobId>` marker delivered through the TurnService's steer outbox
/// (exactly once); the job settles when that marker lands in the record.
public actor JobService {
	public enum AbortOutcome: Sendable, Equatable { case ok, notFound, notRunning }

	let database: AppDatabase
	let jobs: JobRepository
	let keychain: any KeychainStore
	let catalog: ModelCatalog
	let makeTransport: @Sendable () -> any AnthropicTransport
	let verifier: (any HeadlessVerifier)?
	nonisolated let fileAccess: FileAccess
	private weak var turns: TurnService?
	private var tasks: [String: Task<Void, Never>] = [:]

	public init(database: AppDatabase, dataDirectory: URL, keychain: any KeychainStore, catalog: ModelCatalog,
		makeTransport: @escaping @Sendable () -> any AnthropicTransport = { URLSessionTransport() },
		verifier: (any HeadlessVerifier)?, fileAccess: FileAccess)
	{
		self.database = database
		jobs = JobRepository(database, dataDirectory: dataDirectory)
		self.keychain = keychain
		self.catalog = catalog
		self.makeTransport = makeTransport
		self.verifier = verifier
		self.fileAccess = fileAccess
	}

	/// Wire the delivery vehicle (the TurnService reports landed steers back).
	public func attach(_ turns: TurnService) async {
		self.turns = turns
		await turns.setSteerObserver { [weak self] chatId, steerId in
			Task { await self?.steerLanded(chatId: chatId, steerId: steerId) }
		}
		await turns.setBackground { [weak self] chatId in
			self?.wiring(chatId: chatId) ?? BackgroundWiring(files: FileAccess(folders: { [] })) { _, _, _, _ in "Dispatch failed: the job service is gone" }
		}
	}

	public func isLive(_ jobId: String) -> Bool { tasks[jobId] != nil }

	// MARK: Dispatch

	/// tools/jobs.ts dispatch: get-or-insert by tool call, spawn only a new job.
	func dispatch(kind: JobKind, chatId: String, toolCallId: String, input: JSONValue, ack: String) -> String {
		do {
			let (job, created) = try jobs.getOrCreate(kind: kind, chatId: chatId, toolCallId: toolCallId)
			if created { spawn(job, input: input) }
			return "Dispatched (job \(job.id)). \(ack)"
		} catch {
			return "Dispatch failed: \(error)"
		}
	}

	private func spawn(_ job: JobRecord, input: JSONValue) {
		let task = Task { [weak self] in _ = await self?.run(job, input: input) }
		tasks[job.id] = task
	}

	private func finishedRun(_ jobId: String) { tasks[jobId] = nil }

	// MARK: The run

	/// runner.ts runJob: resolve the role's model, run the kind, deliver the
	/// result (or the kind's failure shape — failures still steer).
	private func run(_ job: JobRecord, input: JSONValue) async {
		defer { finishedRun(job.id) }
		let role: ModelRole = switch job.kind {
		case .research: .researcher
		case .demo: .demoBuilder
		case .visual: .visualMaker
		case .pdf: .pdfReader
		}
		let settings = (try? SettingsRepository(database).read()) ?? nil
		let spec = resolveRoleSpec(role, record: settings, catalog: catalog)
		let keychain = keychain
		guard ((try? keychain.anthropicKey()) ?? nil) != nil else {
			update(job.id, JobRepository.Patch(error: "No Anthropic key"))
			await finish(job, failure(job.kind, input, reason: "No Anthropic key"))
			return
		}
		let model = SubagentModel(client: MessagesClient(transport: makeTransport(), apiKey: { try keychain.anthropicKey() }), spec: spec)
		let jobId = job.id
		let onUsage: @Sendable ([UsageStepRecord]) -> Void = { [weak self] steps in Task { await self?.addUsage(jobId, steps) } }
		let onActivity: @Sendable (String) -> Void = { [weak self] line in Task { await self?.update(jobId, JobRepository.Patch(activity: line)) } }

		let result: SubagentResult
		switch job.kind {
		case .research:
			update(job.id, JobRepository.Patch(activity: "researching"))
			result = .research(await runResearcher(question: input["question"]?.stringValue ?? "", context: input["context"]?.stringValue, model: model, onUsage: onUsage, onActivity: onActivity))
		case .demo:
			update(job.id, JobRepository.Patch(activity: "building demo"))
			let title = input["title"]?.stringValue.flatMap { $0.jsTrimmed.isEmpty ? nil : $0 } ?? "Interactive demo"
			guard let verifier else { await finish(job, .demo(DemoResult(title: title, html: "", tested: true, notes: "FAILED: the demo verifier is unavailable"))); return }
			result = .demo(await runDemoBuilder(title: title, brief: input["brief"]?.stringValue ?? "", model: model, verifier: verifier, onUsage: onUsage, onActivity: onActivity))
		case .visual:
			update(job.id, JobRepository.Patch(activity: "drawing figure"))
			guard let verifier else { await finish(job, .visual(VisualResult(svg: "", notes: "FAILED: the SVG renderer is unavailable"))); return }
			result = .visual(await runVisualMaker(brief: input["brief"]?.stringValue ?? "", model: model, verifier: verifier, onUsage: onUsage, onActivity: onActivity))
		case .pdf:
			update(job.id, JobRepository.Patch(activity: "reading pdf"))
			result = .pdf(await runPdf(input, model: model, onUsage: onUsage, onActivity: onActivity))
		}
		if Task.isCancelled { return } // aborted: the abort steer is already on its way
		if isSubagentFailure(result), stillRunning(job.id) { update(job.id, JobRepository.Patch(error: failureReason(result))) }
		await finish(job, result)
	}

	/// The pdf job: the path resolves through the learner-folder gate
	/// (docs/native-macos-m6.md fix), then the reader runs inside the scope.
	private func runPdf(_ input: JSONValue, model: SubagentModel, onUsage: @escaping @Sendable ([UsageStepRecord]) -> Void, onActivity: @escaping @Sendable (String) -> Void) async -> PdfResult {
		let raw = input["path"]?.stringValue?.jsTrimmed ?? ""
		let question = input["question"]?.stringValue ?? ""
		let access = fileAccess
		let roots = access.folders()
		let started = roots.map { $0.startAccessingSecurityScopedResource() }
		defer { for (u, s) in zip(roots, started) where s { u.stopAccessingSecurityScopedResource() } }
		let url: URL
		do { url = try access.resolve(raw, roots: roots) } catch {
			return PdfResult(path: raw, question: question, brief: "PDF failed: \(error.message)", pagesRead: [], pagesConsulted: [])
		}
		return await runPdfReader(url: url, displayPath: raw, question: question, model: model, onUsage: onUsage, onActivity: onActivity)
	}

	/// The kind's failure shape for a refusal before the loop.
	private func failure(_ kind: JobKind, _ input: JSONValue, reason: String) -> SubagentResult {
		switch kind {
		case .research: .research(ResearchResult(brief: "Research failed: \(reason)", sources: []))
		case .demo: .demo(DemoResult(title: input["title"]?.stringValue ?? "Interactive demo", html: "", tested: true, notes: "FAILED: \(reason)"))
		case .visual: .visual(VisualResult(svg: "", notes: "FAILED: \(reason)"))
		case .pdf: .pdf(PdfResult(path: input["path"]?.stringValue ?? "", question: input["question"]?.stringValue ?? "", brief: "PDF failed: \(reason)", pagesRead: [], pagesConsulted: []))
		}
	}

	private func failureReason(_ r: SubagentResult) -> String {
		switch r {
		case .research(let x): x.brief.replacing(/^Research failed:\s*/, with: "")
		case .demo(let x): (x.notes ?? "demo build failed").replacing(/^FAILED:\s*/, with: "")
		case .visual(let x): (x.notes ?? "visual build failed").replacing(/^FAILED:\s*/, with: "")
		case .pdf(let x): x.brief.replacing(/(?i)^PDF failed:\s*/, with: "")
		}
	}

	/// runner.ts finishJob: store the result ("delivering result"), then
	/// deliver its steer. The status settles when the steer lands.
	private func finish(_ job: JobRecord, _ result: SubagentResult) async {
		guard stillRunning(job.id) else { return }
		update(job.id, JobRepository.Patch(activity: "delivering result", result: result.json))
		await deliver(job, result)
	}

	private func deliver(_ job: JobRecord, _ result: SubagentResult) async {
		var steer = buildSubagentSteer(jobId: job.id, kind: job.kind, toolCallId: job.toolCallId, result: result)
		// New steers carry the stored (artifact-externalized) result (M2).
		if let stored = try? jobs.getJob(job.id)?.result, case .marker(var marker) = steer.body, case .object(var details) = marker.details {
			details["result"] = stored
			marker.details = .object(details)
			steer = Message(id: steer.id, timestamp: steer.timestamp, body: .marker(marker))
		}
		await turns?.deliverSteer(job.chatId, steer)
	}

	// MARK: Settle, abort, recovery

	/// A steer landed in the record: settle its job (done, or error for a
	/// failure shape). Never overwrites a settled status.
	func steerLanded(chatId: String, steerId: String) {
		guard steerId.hasPrefix("steer_job_") else { return }
		let jobId = String(steerId.dropFirst("steer_".count))
		guard let job = (try? jobs.getJob(jobId)) ?? nil, job.status == .running else { return }
		let failed = job.result.flatMap { SubagentResult.decode(kind: job.kind, resolvedResult($0, kind: job.kind)) }.map(isSubagentFailure) ?? true
		update(jobId, JobRepository.Patch(status: failed ? .error : .done, activity: "delivered"))
	}

	/// A stored result with its artifact (demo html / visual svg) read back in.
	private func resolvedResult(_ result: JSONValue, kind: JobKind) -> JSONValue {
		let key: String
		switch kind {
		case .demo: key = "html"
		case .visual: key = "svg"
		case .research, .pdf: return result
		}
		guard case .object(var o) = result, let text = (try? jobs.artifactText(for: result)) ?? nil else { return result }
		o[key] = .string(text)
		o["artifactPath"] = nil
		return .object(o)
	}

	/// End (the learner's abort): cancel, drop the undelivered result steer,
	/// mark the job, deliver the abort steer (same id — first to land wins).
	public func abort(_ jobId: String) async -> AbortOutcome {
		guard let job = (try? jobs.getJob(jobId)) ?? nil else { return .notFound }
		guard job.status == .running else { return .notRunning }
		tasks[jobId]?.cancel()
		tasks[jobId] = nil
		await turns?.dropPendingSteer("steer_\(jobId)")
		update(jobId, JobRepository.Patch(status: .error, activity: "aborted", error: "Aborted by learner"))
		await turns?.deliverSteer(job.chatId, buildAbortSteer(jobId: jobId, kind: job.kind, toolCallId: job.toolCallId))
		return .ok
	}

	/// A chat is being deleted: stop its runs without delivering anything.
	public func cancelAll(chatId: String) {
		for job in (try? jobs.listJobs(chatId: chatId)) ?? [] {
			tasks[job.id]?.cancel()
			tasks[job.id] = nil
		}
	}

	/// Launch recovery (your answer): every running row is an orphan — a
	/// stored result is re-delivered; otherwise the job re-runs from its tool
	/// input in the transcript, or fails when that input was never saved.
	public func recoverOnLaunch() async {
		for job in (try? jobs.runningJobs()) ?? [] where tasks[job.id] == nil {
			if let stored = job.result, let result = SubagentResult.decode(kind: job.kind, resolvedResult(stored, kind: job.kind)) {
				update(job.id, JobRepository.Patch(activity: "recovering: re-delivering"))
				await deliver(job, result)
				continue
			}
			let record = (try? ChatRepository(database).get(job.chatId)) ?? nil
			let call = record?.messages.compactMap(\.assistant).flatMap(\.toolUses).first { $0.id == job.toolCallId }
			if let call {
				update(job.id, JobRepository.Patch(activity: "recovering: re-running"))
				spawn(job, input: call.input)
			} else if record != nil {
				update(job.id, JobRepository.Patch(error: "interrupted — its input was never saved"))
				await finish(job, failure(job.kind, .object(JSONObject()), reason: "interrupted — its input was never saved"))
			} else {
				update(job.id, JobRepository.Patch(status: .error, activity: "orphaned", error: "its session no longer exists"))
			}
		}
	}

	// MARK: Store helpers

	private func stillRunning(_ id: String) -> Bool { ((try? jobs.getJob(id)) ?? nil)?.status == .running }

	private func update(_ id: String, _ patch: JobRepository.Patch) { _ = try? jobs.updateJob(id, patch) }

	/// Usage per step: the `usage_step` rows, and the job's folded total.
	private func addUsage(_ id: String, _ steps: [UsageStepRecord]) {
		guard !steps.isEmpty, var job = (try? jobs.getJob(id)) ?? nil else { return }
		try? jobs.appendUsageSteps(steps.map { ($0.model, $0.usage) }, jobId: id)
		for s in steps { job.usage = accumulateJobUsage(job.usage, model: s.model, call: s.usage) }
		update(id, JobRepository.Patch(usage: job.usage))
	}
}

// MARK: - Dispatch tools (tools/jobs.ts)

let FIRE_AND_FORGET = "This call is fire-and-forget: continue your turn and keep teaching — do not wait, poll, or mention waiting. "
let RESEARCH_ACK = FIRE_AND_FORGET + "The researched brief arrives as a new message when ready and the lesson resumes from it; cite its sources when you use them."
let DEMO_ACK = FIRE_AND_FORGET + "The tested demo arrives as a new message when ready and is rendered in the lesson; teach with it then."
let VISUAL_ACK = FIRE_AND_FORGET + "The verified figure arrives as a new message when ready and is rendered in the lesson; reference it then."
let PDF_ACK = FIRE_AND_FORGET + "The document brief arrives as a new message when ready; weave it into the lesson and cite its pages."

/// What the registries need for the M6 tools: the learner-folder gate and
/// the job dispatch for this chat (tests pass a stub).
public struct BackgroundWiring: Sendable {
	public typealias Dispatch = @Sendable (_ kind: JobKind, _ toolCallId: String, _ input: JSONValue, _ ack: String) async -> String
	public var files: FileAccess
	public var dispatch: Dispatch
	public init(files: FileAccess, dispatch: @escaping Dispatch) {
		self.files = files
		self.dispatch = dispatch
	}
}

extension JobService {
	/// The wiring for one chat's registries.
	public nonisolated func wiring(chatId: String) -> BackgroundWiring {
		BackgroundWiring(files: fileAccess) { [weak self] kind, toolCallId, input, ack in
			await self?.dispatch(kind: kind, chatId: chatId, toolCallId: toolCallId, input: input, ack: ack) ?? "Dispatch failed: the job service is gone"
		}
	}
}

/// One dispatch tool (research, demo, visual, pdf): create the job, ack.
public struct DispatchTool: AgentTool {
	public let name: String
	public let description: String
	public let schema: JSONSchema
	let kind: JobKind
	let ack: String
	let dispatch: BackgroundWiring.Dispatch

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		.value(.string(await dispatch(kind, context.toolCallId, input, ack)))
	}

	public static func research(_ w: BackgroundWiring) -> DispatchTool {
		DispatchTool(name: "research", description: GeneratedTools.researchDescription, schema: GeneratedTools.researchSchema, kind: .research, ack: RESEARCH_ACK, dispatch: w.dispatch)
	}
	public static func demo(_ w: BackgroundWiring) -> DispatchTool {
		DispatchTool(name: "demo", description: GeneratedTools.demoDescription, schema: GeneratedTools.demoSchema, kind: .demo, ack: DEMO_ACK, dispatch: w.dispatch)
	}
	public static func visual(_ w: BackgroundWiring) -> DispatchTool {
		DispatchTool(name: "visual", description: GeneratedTools.visualDescription, schema: GeneratedTools.visualSchema, kind: .visual, ack: VISUAL_ACK, dispatch: w.dispatch)
	}
	public static func pdf(_ w: BackgroundWiring) -> DispatchTool {
		DispatchTool(name: "pdf", description: GeneratedTools.pdfDescription, schema: GeneratedTools.pdfSchema, kind: .pdf, ack: PDF_ACK, dispatch: w.dispatch)
	}
}
