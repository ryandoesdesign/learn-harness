import Foundation
import LHCore

/// Raw provider stream recordings for debugging (port of
/// src/agent/provider-events.ts): one JSONL file per chat under
/// `debug/provider-events/`, capped in bytes; off unless enabled (a Debug
/// setting, replacing the LH_PROVIDER_EVENTS env var). Never throws.
public final class ProviderEventRecorder: @unchecked Sendable {
	public static let defaultCap = 20 * 1024 * 1024

	public let directory: URL
	public let cap: Int
	public let enabled: Bool
	private let lock = NSLock()
	private var files: [String: (bytes: Int, capped: Bool)] = [:]
	private let clock: @Sendable () -> Int

	public init(directory: URL, enabled: Bool, cap: Int = ProviderEventRecorder.defaultCap, clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
		self.directory = directory
		self.enabled = enabled
		self.cap = cap
		self.clock = clock
	}

	func file(for chatId: String) -> URL {
		let safe = String(chatId.unicodeScalars.map { s -> Character in
			(("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "_" || s == "-") ? Character(s) : "_"
		})
		return directory.appending(path: "\(safe).jsonl")
	}

	/// An observer for the client: one line per raw event payload, or nil when off.
	public func observer(chatId: String, context: String, model: String) -> (@Sendable (String) -> Void)? {
		guard enabled else { return nil }
		return { [self] data in
			let event: JSONValue = JSONValue.tryParse(data) ?? ["__nonJSON": .string(String(data.prefix(200)))]
			write(chatId, JSONObject(["ctx": .string(context), "provider": "anthropic", "model": .string(model), "event": event]))
		}
	}

	public func note(chatId: String, context: String, _ text: String) {
		guard enabled else { return }
		write(chatId, JSONObject(["ctx": .string(context), "note": .string(text)]))
	}

	func write(_ chatId: String, _ fields: JSONObject) {
		let url = file(for: chatId)
		lock.lock()
		defer { lock.unlock() }
		let state = files[url.path]
		if state?.capped == true { return }
		var line = JSONObject(["t": .number(clock())])
		for (k, v) in fields { line[k] = v }
		let text = JSONValue.object(line).serialized() + "\n"
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			let before = state?.bytes ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
			try append(text, to: url)
			let bytes = before + text.utf8.count
			if bytes > cap {
				files[url.path] = (bytes, true)
				let marker = JSONValue.object(JSONObject(["t": .number(clock()), "note": .string("cap \(cap) bytes reached — recording stopped")])).serialized() + "\n"
				try append(marker, to: url)
			} else {
				files[url.path] = (bytes, false)
			}
		} catch {
			// Debug recording never breaks a turn.
		}
	}

	private func append(_ text: String, to url: URL) throws {
		if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
	}
}
