import AVFoundation
import AppKit
import Foundation
import Observation
import Speech

/// dictation.tsx, on device (docs/native-macos-m8.md): one microphone for the
/// app, final results only, the text added once when the run stops (joined
/// with single spaces). The text goes to the highest-priority field on
/// screen: a pending question's field, then the practice dock, then the
/// reading-thinking field, then the composer. Esc cancels and discards.
@MainActor
@Observable
final class DictationService {
	enum State: Equatable {
		case idle
		/// Fetching the language data or opening the microphone ("Downloading…").
		case preparing(String)
		case recording
		case finishing
		case error(String)
	}

	/// Where a run's text can go, by priority (higher wins).
	enum Priority: Int, Comparable {
		case composer = 0, readingThinking = 1, practice = 2, question = 3
		static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
	}

	struct Target {
		var id: String
		var priority: Priority
		var insert: @MainActor (String) -> Void
	}

	private(set) var state: State = .idle
	/// The input level, 0…1 over −50…−10 dB, sampled every 60 ms while recording.
	private(set) var level: Double = 0
	/// False when the system language can't be dictated at all (the button hides).
	private(set) var available = true

	private let engine: any SpeechEngine
	private var run: (any SpeechRun)?
	private var targets: [Target] = []

	init(engine: any SpeechEngine = SystemSpeechEngine()) {
		self.engine = engine
		Task { available = await engine.isSupported() }
	}

	var isRecording: Bool { state == .recording }
	var isActive: Bool {
		switch state {
		case .preparing, .recording, .finishing: true
		default: false
		}
	}

	// MARK: Targets

	func register(_ id: String, _ priority: Priority, insert: @escaping @MainActor (String) -> Void) {
		targets.removeAll { $0.id == id }
		targets.append(Target(id: id, priority: priority, insert: insert))
	}

	func unregister(_ id: String) { targets.removeAll { $0.id == id } }

	/// The field a run's text goes to now (the newest of the highest priority).
	var target: Target? {
		targets.enumerated().max { a, b in a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.offset < b.offset }?.element
	}

	// MARK: Runs

	/// ⌘D / the button: start, or stop and keep.
	func toggle() {
		switch state {
		case .idle, .error: Task { await start() }
		case .recording: Task { await finish() }
		case .preparing, .finishing: break
		}
	}

	func start() async {
		guard state == .idle || isError else { return }
		state = .preparing("Starting…")
		do {
			if await engine.needsDownload() {
				state = .preparing("Downloading…")
				try await engine.install()
			}
			run = try await engine.start { [weak self] level in
				Task { @MainActor in self?.level = level }
			}
			state = .recording
		} catch let error as DictationError {
			state = .error(error.message)
		} catch {
			state = .error("Dictation failed: \(error.localizedDescription)")
		}
	}

	/// Stop and keep: the run's text goes to the target. Submit actions await
	/// this first, so a run still going is never lost.
	func finish() async {
		guard state == .recording, let run else { return }
		state = .finishing
		self.run = nil
		do {
			let text = try await run.finish()
			if !text.isEmpty { target?.insert(text) }
			state = .idle
		} catch {
			state = .error("Dictation failed: \(error.localizedDescription)")
		}
		level = 0
	}

	/// Esc: stop and discard.
	func cancel() {
		guard let run else { return }
		self.run = nil
		run.cancel()
		state = .idle
		level = 0
	}

	private var isError: Bool {
		if case .error = state { return true }
		return false
	}
}

/// "A run's text joins with single spaces" (dictation.tsx joinDictation).
nonisolated func joinDictation(_ segments: [String]) -> String {
	segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
}

/// An existing field's text plus dictated text: one space between them.
func appendDictation(_ existing: String, _ text: String) -> String {
	guard !existing.isEmpty else { return text }
	return existing.last?.isWhitespace == true ? existing + text : existing + " " + text
}

nonisolated struct DictationError: Error {
	var message: String
	static let microphoneDenied = DictationError(message: "Microphone access denied")
	static let unsupported = DictationError(message: "Dictation isn't available for this language")
}

// MARK: - The engine

/// The recognizer behind the service (scripted in tests).
nonisolated protocol SpeechEngine: Sendable {
	func isSupported() async -> Bool
	func needsDownload() async -> Bool
	func install() async throws
	func start(level: @escaping @Sendable (Double) -> Void) async throws -> any SpeechRun
}

nonisolated protocol SpeechRun: Sendable {
	/// Stop listening and return the run's text.
	func finish() async throws -> String
	/// Stop listening and drop everything.
	func cancel()
}

/// SpeechAnalyzer with a DictationTranscriber (punctuated, like the system's
/// dictation) in the system language, falling back to English.
nonisolated struct SystemSpeechEngine: SpeechEngine {
	func locale() async -> Locale? {
		if let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) { return l }
		return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
	}

	private func transcriber() async throws -> DictationTranscriber {
		guard let locale = await locale() else { throw DictationError.unsupported }
		return DictationTranscriber(locale: locale, preset: .longDictation)
	}

	func isSupported() async -> Bool { await locale() != nil }

	func needsDownload() async -> Bool {
		guard let t = try? await transcriber() else { return false }
		return await AssetInventory.status(forModules: [t]) != .installed
	}

	func install() async throws {
		let t = try await transcriber()
		if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
			try await request.downloadAndInstall()
		}
	}

	func start(level: @escaping @Sendable (Double) -> Void) async throws -> any SpeechRun {
		guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationError.microphoneDenied }
		let t = try await transcriber()
		return try await SystemSpeechRun.begin(transcriber: t, level: level)
	}
}

/// One recording: the microphone tap converts to the analyzer's format and
/// feeds it; final results collect until the input ends.
nonisolated final class SystemSpeechRun: SpeechRun, @unchecked Sendable {
	private let audio = AVAudioEngine()
	private let analyzer: SpeechAnalyzer
	private let input: AsyncStream<AnalyzerInput>.Continuation
	private let collector: Task<[String], any Error>
	private let lock = NSLock()
	private var lastLevel = Date.distantPast

	private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, collector: Task<[String], any Error>) {
		self.analyzer = analyzer
		self.input = input
		self.collector = collector
	}

	static func begin(transcriber: DictationTranscriber, level: @escaping @Sendable (Double) -> Void) async throws -> SystemSpeechRun {
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		let collector = Task {
			var finals: [String] = []
			for try await result in transcriber.results where result.isFinal {
				finals.append(String(result.text.characters))
			}
			return finals
		}
		let run = SystemSpeechRun(analyzer: analyzer, input: continuation, collector: collector)
		let inputNode = run.audio.inputNode
		let natural = inputNode.outputFormat(forBus: 0)
		guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
		      let converter = AVAudioConverter(from: natural, to: format)
		else { throw DictationError(message: "The microphone's audio format isn't supported") }
		try await analyzer.start(inputSequence: stream)
		try inputNode.installAudioTap(onBus: 0, bufferSize: 4096, format: natural) { [weak run] tapped, _ in
			guard let run else { return }
			let buffer = AVAudioPCMBuffer(copying: tapped)
			run.meter(buffer, level)
			if let converted = convert(buffer, with: converter, to: format) { run.input.yield(AnalyzerInput(buffer: converted)) }
		}
		run.audio.prepare()
		try run.audio.start()
		return run
	}

	/// The meter: RMS in dB over −50…−10, every 60 ms.
	private func meter(_ buffer: AVAudioPCMBuffer, _ report: @Sendable (Double) -> Void) {
		let now = Date()
		let due = lock.withLock { () -> Bool in
			guard now.timeIntervalSince(lastLevel) >= 0.06 else { return false }
			lastLevel = now
			return true
		}
		guard due, let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
		var sum: Float = 0
		for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
		let rms = (sum / Float(buffer.frameLength)).squareRoot()
		let db = 20 * log10(max(rms, 1e-7))
		report(min(1, max(0, (Double(db) + 50) / 40)))
	}

	private func stopAudio() {
		audio.inputNode.removeTap(onBus: 0)
		audio.stop()
		input.finish()
	}

	func finish() async throws -> String {
		stopAudio()
		try await analyzer.finalizeAndFinishThroughEndOfInput()
		return joinDictation(try await collector.value)
	}

	func cancel() {
		stopAudio()
		collector.cancel()
		Task { await analyzer.cancelAndFinishNow() }
	}
}

nonisolated private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
	let ratio = format.sampleRate / buffer.format.sampleRate
	let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
	guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
	var fed = false
	var error: NSError?
	converter.convert(to: out, error: &error) { _, status in
		if fed {
			status.pointee = .noDataNow
			return nil
		}
		fed = true
		status.pointee = .haveData
		return buffer
	}
	return error == nil ? out : nil
}
