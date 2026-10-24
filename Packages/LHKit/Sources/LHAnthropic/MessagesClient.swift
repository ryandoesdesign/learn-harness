import Foundation
import LHCore

/// A non-retryable or exhausted API failure.
public struct AnthropicError: Error, Sendable, Hashable, CustomStringConvertible {
	public var status: Int?
	public var type: String
	public var message: String

	public init(status: Int?, type: String, message: String) {
		self.status = status
		self.type = type
		self.message = message
	}

	public var description: String {
		status.map { "\(type) (\($0)): \(message)" } ?? "\(type): \(message)"
	}

	/// A missing/rejected key — the UI's "No Anthropic key" path.
	public var isAuthentication: Bool { status == 401 || type == "authentication_error" }
}

/// What a stream consumer sees: API events, plus the client's own retry notices.
public enum ClientEvent: Sendable, Hashable {
	case event(StreamEvent)
	/// A retryable failure before any event arrived; the next attempt starts after `delay`.
	case retrying(attempt: Int, delay: Duration, reason: String)
}

/// The Messages API client (docs/native-macos-m3.md, "Requests").
///
/// Retries 408/409/429/5xx/529 and connection errors with exponential
/// backoff (1s, 2s, 4s, 8s + jitter, ≤30s; `retry-after` honoured), but
/// only BEFORE the first stream event: once content has streamed, a failure
/// ends the stream (the caller records it as an `error` stop).
public struct MessagesClient: Sendable {
	public let transport: any AnthropicTransport
	public let apiKey: @Sendable () throws -> String?
	public var baseURL = URL(string: "https://api.anthropic.com")!
	public var maxRetries = 4
	/// Seconds for attempt n (1-based), before jitter. Tests shrink it.
	public var backoff: @Sendable (Int) -> Double = { min(30, pow(2, Double($0 - 1))) }
	public var jitter: @Sendable () -> Double = { Double.random(in: 0..<0.25) }
	/// Raw event observer (the provider-events debug recorder).
	public var observer: (@Sendable (String) -> Void)?

	public init(transport: any AnthropicTransport, apiKey: @escaping @Sendable () throws -> String?) {
		self.transport = transport
		self.apiKey = apiKey
	}

	public func urlRequest(_ request: MessagesRequest) throws -> URLRequest {
		guard let key = try apiKey(), !key.isEmpty else {
			throw AnthropicError(status: nil, type: "authentication_error", message: "No Anthropic key is set — add one in Settings → Keys")
		}
		var r = URLRequest(url: baseURL.appending(path: "v1/messages"))
		r.httpMethod = "POST"
		r.timeoutInterval = 600
		r.setValue("application/json", forHTTPHeaderField: "content-type")
		r.setValue(key, forHTTPHeaderField: "x-api-key")
		r.setValue(MessagesRequest.apiVersion, forHTTPHeaderField: "anthropic-version")
		if let beta = request.betaHeader { r.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
		r.httpBody = request.body.serializedData
		return r
	}

	static func isRetryable(status: Int) -> Bool {
		[408, 409, 429, 529].contains(status) || (500...599).contains(status)
	}

	static func isRetryable(_ error: Error) -> Bool {
		guard let e = error as? URLError else { return false }
		return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed].contains(e.code)
	}

	/// `retry-after` in seconds (delta-seconds or an HTTP date).
	static func retryAfter(_ value: String?) -> Double? {
		guard let value = value?.trimmingCharacters(in: .whitespaces) else { return nil }
		if let s = Double(value) { return max(0, s) }
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
		return f.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
	}

	static func errorFromBody(status: Int, body: String) -> AnthropicError {
		let json = JSONValue.tryParse(body)
		return AnthropicError(status: status, type: json?["error"]?["type"]?.stringValue ?? "api_error",
			message: json?["error"]?["message"]?.stringValue ?? (body.isEmpty ? "HTTP \(status)" : String(body.prefix(500))))
	}

	/// Stream one request. Cancelling the consuming task cancels the request.
	public func stream(_ request: MessagesRequest) -> AsyncThrowingStream<ClientEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let urlRequest = try urlRequest(request)
					var attempt = 0
					while true {
						attempt += 1
						var sawEvent = false
						do {
							let response = try await transport.send(urlRequest)
							if response.status != 200 {
								let body = try await response.collectBody()
								let error = Self.errorFromBody(status: response.status, body: body)
								guard Self.isRetryable(status: response.status), attempt <= maxRetries else { throw error }
								let delay = Self.retryAfter(response.header("retry-after")) ?? backoff(attempt) + jitter()
								continuation.yield(.retrying(attempt: attempt, delay: .milliseconds(Int(delay * 1000)), reason: error.description))
								try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
								continue
							}
							var parser = SSEParser()
							func dispatch(_ data: String) throws {
								observer?(data)
								guard let json = JSONValue.tryParse(data) else { return }
								let event = StreamEvent(json: json)
								if case .error(let type, let message) = event {
									throw AnthropicError(status: nil, type: type, message: message)
								}
								sawEvent = true
								continuation.yield(.event(event))
							}
							for try await line in response.lines {
								if let data = parser.feed(line) { try dispatch(data) }
							}
							if let data = parser.finish() { try dispatch(data) }
							continuation.finish()
							return
						} catch let error as AnthropicError where !sawEvent && attempt <= maxRetries && error.status == nil && ["overloaded_error", "api_error"].contains(error.type) {
							let delay = backoff(attempt) + jitter()
							continuation.yield(.retrying(attempt: attempt, delay: .milliseconds(Int(delay * 1000)), reason: error.description))
							try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
						} catch where !sawEvent && attempt <= maxRetries && Self.isRetryable(error) {
							let delay = backoff(attempt) + jitter()
							continuation.yield(.retrying(attempt: attempt, delay: .milliseconds(Int(delay * 1000)), reason: "\(error)"))
							try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
						}
					}
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Stream to completion, folding into the final response. `onEvent`
	/// sees every event (live UI); `onRetry` every retry notice.
	public func send(_ request: MessagesRequest, onEvent: (@Sendable (StreamEvent, MessageAccumulator) -> Void)? = nil, onRetry: (@Sendable (Int, Duration, String) -> Void)? = nil) async throws -> AssistantResponse {
		var acc = MessageAccumulator(model: request.model)
		for try await item in stream(request) {
			switch item {
			case .event(let e):
				acc.apply(e)
				onEvent?(e, acc)
			case .retrying(let attempt, let delay, let reason):
				onRetry?(attempt, delay, reason)
			}
		}
		return acc.response
	}
}
