import Foundation
import Testing
@testable import Aster

// Dictation in the host (docs/native-macos-m8.md) over a scripted engine:
// the run's text lands once, in the highest-priority field on screen;
// submitting waits for it; Esc discards; missing language data shows
// "Downloading…" first; an unsupported language hides the button.

private final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
	let lock = NSLock()
	var supported = true
	var download = false
	var installed = false
	var text = "the left join keeps every row"
	var startError: DictationError?
	private(set) var cancelled = false

	func isSupported() async -> Bool { supported }
	func needsDownload() async -> Bool { lock.withLock { download && !installed } }
	func install() async throws {
		try await Task.sleep(for: .milliseconds(50))
		lock.withLock { installed = true }
	}
	func start(level: @escaping @Sendable (Double) -> Void) async throws -> any SpeechRun {
		if let startError { throw startError }
		level(0.5)
		return Run(engine: self)
	}

	struct Run: SpeechRun {
		let engine: ScriptedEngine
		func finish() async throws -> String { engine.text }
		func cancel() { engine.lock.withLock { engine.cancelled = true } }
	}
}

@MainActor
@Suite struct DictationTests {
	private func service(_ engine: ScriptedEngine = ScriptedEngine()) async -> DictationService {
		let s = DictationService(engine: engine)
		try? await Task.sleep(for: .milliseconds(20)) // the availability probe
		return s
	}

	@Test func theTextLandsOnceInTheHighestPriorityField() async {
		let s = await service()
		var composer = "", question = "Because", reading = ""
		s.register("composer", .composer) { composer = appendDictation(composer, $0) }
		s.register("reading", .readingThinking) { reading = appendDictation(reading, $0) }
		s.register("question", .question) { question = appendDictation(question, $0) }
		await s.start()
		#expect(s.state == .recording)
		await s.finish()
		#expect(question == "Because the left join keeps every row")
		#expect(composer.isEmpty && reading.isEmpty)
		#expect(s.state == .idle)

		s.unregister("question")
		await s.start()
		await s.finish()
		#expect(reading == "the left join keeps every row", "the next field down takes it once the question is gone")
	}

	@Test func submittingWaitsForTheRunningDictation() async throws {
		let s = await service()
		var field = ""
		s.register("composer", .composer) { field = appendDictation(field, $0) }
		await s.start()
		var submitted: String?
		s.thenSubmit { submitted = field }
		try await Task.sleep(for: .milliseconds(100))
		#expect(submitted == "the left join keeps every row")
	}

	@Test func escDiscards() async {
		let engine = ScriptedEngine()
		let s = await service(engine)
		var field = ""
		s.register("composer", .composer) { field = $0 }
		await s.start()
		s.cancel()
		#expect(s.state == .idle && field.isEmpty && engine.cancelled)
	}

	@Test func missingLanguageDataDownloadsFirst() async throws {
		let engine = ScriptedEngine()
		engine.download = true
		let s = await service(engine)
		let task = Task { await s.start() }
		try await Task.sleep(for: .milliseconds(20))
		#expect(s.state == .preparing("Downloading…"))
		await task.value
		#expect(s.state == .recording)
	}

	@Test func anUnsupportedLanguageHidesDictationAndADeniedMicSaysSo() async {
		let engine = ScriptedEngine()
		engine.supported = false
		#expect(await !service(engine).available)
		let denied = ScriptedEngine()
		denied.startError = .microphoneDenied
		let s = await service(denied)
		await s.start()
		#expect(s.state == .error("Microphone access denied"))
	}

	@Test func joiningAndAppending() {
		#expect(joinDictation([" Hello ", "", "world. "]) == "Hello world.")
		#expect(appendDictation("", "Hi") == "Hi")
		#expect(appendDictation("So", "yes") == "So yes")
		#expect(appendDictation("So ", "yes") == "So yes")
	}
}
