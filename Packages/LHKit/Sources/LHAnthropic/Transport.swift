import Foundation

/// The HTTP seam: real network, scripted fixtures, or a recorder.
public protocol AnthropicTransport: Sendable {
	/// Send the request; the response streams its body as lines (no
	/// terminators; blank lines kept — they delimit SSE frames).
	func send(_ request: URLRequest) async throws -> TransportResponse
}

public struct TransportResponse: Sendable {
	public var status: Int
	public var headers: [String: String]
	public var lines: AsyncThrowingStream<String, Error>

	public init(status: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
		self.status = status
		self.headers = headers
		self.lines = lines
	}

	/// Case-insensitive header lookup.
	public func header(_ name: String) -> String? {
		headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
	}

	/// The whole body (error responses).
	public func collectBody() async throws -> String {
		var out: [String] = []
		for try await line in lines { out.append(line) }
		return out.joined(separator: "\n")
	}
}

/// URLSession streaming transport. Lines are split by hand (not
/// `AsyncBytes.lines`, which drops the blank lines SSE framing needs).
public struct URLSessionTransport: AnthropicTransport {
	let session: URLSession

	public init(session: URLSession = .shared) { self.session = session }

	public func send(_ request: URLRequest) async throws -> TransportResponse {
		let (bytes, response) = try await session.bytes(for: request)
		let http = response as? HTTPURLResponse
		var headers: [String: String] = [:]
		for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
		let lines = AsyncThrowingStream<String, Error> { continuation in
			let task = Task {
				var buffer: [UInt8] = []
				do {
					for try await byte in bytes {
						if byte == 0x0A {
							if buffer.last == 0x0D { buffer.removeLast() }
							continuation.yield(String(decoding: buffer, as: UTF8.self))
							buffer.removeAll(keepingCapacity: true)
						} else {
							buffer.append(byte)
						}
					}
					if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
		return TransportResponse(status: http?.statusCode ?? 0, headers: headers, lines: lines)
	}
}

/// Replays scripted responses in order — `.sse` fixture text, or an HTTP
/// error — for deterministic tests (no network, no key). Records every
/// request body it receives.
public final class ScriptedTransport: AnthropicTransport, @unchecked Sendable {
	public enum Response: Sendable {
		/// A 200 streaming body (raw SSE text).
		case sse(String)
		/// A 200 body that fails mid-stream after `afterLines` lines.
		case sseThenFail(String, afterLines: Int, error: URLError.Code)
		/// A non-200 response.
		case http(status: Int, headers: [String: String] = [:], body: String)
		/// A connection-level failure.
		case connectionError(URLError.Code)
		/// An SSE body that stalls after `afterLines` lines until cancelled.
		case sseThenHang(String, afterLines: Int)
	}

	private let lock = NSLock()
	private var queue: [Response]
	public private(set) var requests: [URLRequest] = []

	public init(_ responses: [Response]) { queue = responses }

	/// Load `.sse` fixture files by name from a bundle directory.
	public convenience init(fixtures names: [String], in directory: URL) throws {
		try self.init(names.map { .sse(try String(contentsOf: directory.appending(path: "\($0).sse"), encoding: .utf8)) })
	}

	public var requestBodies: [String] {
		lock.withLock { requests.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } } }
	}

	public var remaining: Int { lock.withLock { queue.count } }

	public func send(_ request: URLRequest) async throws -> TransportResponse {
		let next: Response? = lock.withLock {
			requests.append(request)
			return queue.isEmpty ? nil : queue.removeFirst()
		}
		guard let next else { throw URLError(.resourceUnavailable) }
		switch next {
		case .connectionError(let code):
			throw URLError(code)
		case .http(let status, let headers, let body):
			return TransportResponse(status: status, headers: headers, lines: Self.stream(body.components(separatedBy: "\n")))
		case .sse(let text):
			return TransportResponse(status: 200, headers: ["content-type": "text/event-stream"], lines: Self.stream(Self.lines(text)))
		case .sseThenFail(let text, let n, let code):
			let lines = Array(Self.lines(text).prefix(n))
			return TransportResponse(status: 200, headers: [:], lines: AsyncThrowingStream { c in
				for l in lines { c.yield(l) }
				c.finish(throwing: URLError(code))
			})
		case .sseThenHang(let text, let n):
			let lines = Array(Self.lines(text).prefix(n))
			return TransportResponse(status: 200, headers: [:], lines: AsyncThrowingStream { c in
				for l in lines { c.yield(l) }
				let t = Task {
					while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
					c.finish(throwing: CancellationError())
				}
				c.onTermination = { _ in t.cancel() }
			})
		}
	}

	static func lines(_ text: String) -> [String] {
		text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
	}

	static func stream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
		AsyncThrowingStream { c in
			for l in lines { c.yield(l) }
			c.finish()
		}
	}
}

/// Tees a real transport's streamed lines into `.sse` fixture files —
/// active only when `LH_RECORD=1` (refreshes the scripted fixtures).
public struct RecordingTransport: AnthropicTransport {
	let inner: any AnthropicTransport
	let directory: URL
	let name: @Sendable () -> String

	public init(_ inner: any AnthropicTransport, directory: URL, name: @escaping @Sendable () -> String) {
		self.inner = inner
		self.directory = directory
		self.name = name
	}

	public static var isEnabled: Bool { ProcessInfo.processInfo.environment["LH_RECORD"] == "1" }

	public func send(_ request: URLRequest) async throws -> TransportResponse {
		let response = try await inner.send(request)
		guard Self.isEnabled else { return response }
		let file = directory.appending(path: "\(name()).sse")
		let source = response.lines
		let lines = AsyncThrowingStream<String, Error> { c in
			let task = Task {
				var captured: [String] = []
				do {
					for try await line in source {
						captured.append(line)
						c.yield(line)
					}
					try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
					try? Data(captured.joined(separator: "\n").utf8).write(to: file)
					c.finish()
				} catch {
					c.finish(throwing: error)
				}
			}
			c.onTermination = { _ in task.cancel() }
		}
		return TransportResponse(status: response.status, headers: response.headers, lines: lines)
	}
}
