import Foundation
import Testing
import LHCore
@testable import LHAnthropic

private func request(model: String = "claude-opus-5-5", messages: [WireMessage] = [WireMessage(role: .user, content: [["type": "text", "text": "hi"]])]) -> MessagesRequest {
	MessagesRequest(model: model, maxTokens: 64_000, system: "SYS", messages: messages,
		tools: [.client(name: "get_current_time", description: "Time", inputSchema: ["type": "object", "properties": ["timezone": ["type": "string"]], "required": ["timezone"], "additionalProperties": false]), .webSearch(maxUses: 3)],
		effort: .high, thinkingDisplay: .summarized, cacheTTL: .oneHour)
}

private func client(_ transport: ScriptedTransport, key: String? = "sk-ant-test") -> MessagesClient {
	var c = MessagesClient(transport: transport, apiKey: { key })
	c.backoff = { _ in 0.001 }
	c.jitter = { 0 }
	return c
}

@Suite struct RequestShapeTests {
	@Test func bodyCarriesTheApprovedRequestShapeInAFixedOrder() {
		let body = request().body.serialized()
		#expect(body == #"{"model":"claude-opus-5-5","max_tokens":64000,"system":[{"type":"text","text":"SYS","cache_control":{"type":"ephemeral","ttl":"1h"}}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"tools":[{"name":"get_current_time","description":"Time","input_schema":{"type":"object","properties":{"timezone":{"type":"string"}},"required":["timezone"],"additionalProperties":false},"eager_input_streaming":true},{"type":"web_search_20260209","name":"web_search","max_uses":3}],"thinking":{"type":"adaptive","display":"summarized","block_binding":{"prefix_mismatch_behavior":"drop_block"}},"output_config":{"effort":"high"},"cache_control":{"type":"ephemeral","ttl":"1h"},"fallbacks":"default","stream":true}"#)
	}

	@Test func haikuNeverSendsFallbacks() {
		let r = request(model: "claude-haiku-5-5")
		#expect(r.body["fallbacks"] == nil)
		#expect(r.betaHeader == "thinking-binding-controls-2026-08-01")
		#expect(request().betaHeader == "server-side-fallback-2026-07-01,thinking-binding-controls-2026-08-01")
	}

	@Test func headersAndMissingKey() throws {
		let t = ScriptedTransport([])
		let r = try client(t).urlRequest(request())
		#expect(r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
		#expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
		#expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
		#expect(throws: AnthropicError.self) { try client(t, key: nil).urlRequest(request()) }
		do { _ = try client(t, key: "").urlRequest(request()) } catch let e as AnthropicError {
			#expect(e.isAuthentication)
			#expect(e.message == "No Anthropic key is set — add one in Settings → Keys")
		}
	}
}

@Suite struct SSEAndAccumulatorTests {
	@Test func parserFramesOnBlankLinesAndIgnoresComments() {
		var p = SSEParser()
		#expect(p.feed("event: ping") == nil)
		#expect(p.feed(": comment") == nil)
		#expect(p.feed("data: {\"a\":1}") == nil)
		#expect(p.feed("") == "{\"a\":1}")
		#expect(p.feed("") == nil)
		#expect(p.feed("data: x") == nil)
		#expect(p.finish() == "x")
	}

	@Test func accumulatesEveryBlockKindExactly() async throws {
		let sse = ScriptedSSE.message([
			.thinking("Let me think about time zones.", signature: "sig-abc"),
			.text("Checking the clock."),
			.toolUse(id: "toolu_1", name: "get_current_time", json: #"{"timezone":"Europe/Paris"}"#),
			.toolUse(id: "toolu_2", name: "get_current_time", json: #"{"timezone": "Asia/To"#),
		], stopReason: "tool_use", chunk: 5)
		let t = ScriptedTransport([.sse(sse)])
		let r = try await client(t).send(request())
		#expect(r.content[0].serialized() == #"{"type":"thinking","thinking":"Let me think about time zones.","signature":"sig-abc"}"#)
		#expect(r.content[1].serialized() == #"{"type":"text","text":"Checking the clock."}"#)
		#expect(r.content[2].serialized() == #"{"type":"tool_use","id":"toolu_1","name":"get_current_time","input":{"timezone":"Europe/Paris"}}"#)
		#expect(r.invalidToolInput == [3: #"{"timezone": "Asia/To"#])
		#expect(r.stopReason == "tool_use")
	}

	@Test func usageMapsToTheNativeClassesIncludingOneHourWritesAndServerTools() {
		let u: JSONValue = ["input_tokens": 12, "output_tokens": 40, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 300,
			"cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200], "server_tool_use": ["web_search_requests": 2]]
		let c = AssistantResponse.callUsage(u)
		#expect(c == CallUsage(inputTokens: 12, outputTokens: 40, cacheReadTokens: 900, cacheWriteTokens: 300, cacheWrite1hTokens: 200, webSearchRequests: 2))
	}

	@Test func iterationsSplitFallbackAttempts() {
		let r = AssistantResponse(model: "claude-opus-5", usage: ["input_tokens": 5, "output_tokens": 1, "iterations": [
			["type": "message", "model": "claude-opus-5-5", "input_tokens": 100, "output_tokens": 0],
			["type": "fallback_message", "model": "claude-opus-5", "input_tokens": 100, "output_tokens": 50],
		]])
		let steps = r.callUsages
		#expect(steps.count == 2)
		#expect(steps[0].model == "claude-opus-5-5" && steps[0].fallbackFrom == nil)
		#expect(steps[1].model == "claude-opus-5" && steps[1].fallbackFrom == "claude-opus-5-5")
	}

	@Test func finalUsageMergesOverStartUsage() async throws {
		let sse = ScriptedSSE.message([.text("ok")], usage: ["input_tokens": 7, "cache_read_input_tokens": 1000, "output_tokens": 1],
			finalUsage: ["output_tokens": 42])
		let r = try await client(ScriptedTransport([.sse(sse)])).send(request())
		#expect(r.messageUsage == MessageUsage(input: 7, output: 42, cacheRead: 1000, cacheWrite: 0))
	}
}

@Suite struct RetryTests {
	@Test func retriesOverloadAndHonoursRetryAfter() async throws {
		let t = ScriptedTransport([
			.http(status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
			.http(status: 429, headers: ["Retry-After": "0.002"], body: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#),
			.sse(ScriptedSSE.message([.text("finally")])),
		])
		let notices = Box<[String]>([])
		let r = try await client(t).send(request(), onRetry: { attempt, delay, reason in notices.mutate { $0.append("\(attempt):\(delay):\(reason)") } })
		#expect(r.content.first?["text"] == "finally")
		#expect(notices.value.count == 2)
		#expect(notices.value[1].hasPrefix("2:0.002 seconds:rate_limit_error (429)"))
		#expect(t.requests.count == 3)
	}

	@Test func aBadRequestIsNotRetried() async {
		let t = ScriptedTransport([.http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#), .sse("")])
		await #expect(throws: AnthropicError(status: 400, type: "invalid_request_error", message: "bad")) {
			_ = try await client(t).send(request())
		}
		#expect(t.remaining == 1)
	}

	@Test func connectionErrorsRetryAndAnOverloadedFirstEventRetries() async throws {
		let t = ScriptedTransport([
			.connectionError(.networkConnectionLost),
			.sse(ScriptedSSE.errorEvent()),
			.sse(ScriptedSSE.message([.text("ok")])),
		])
		let r = try await client(t).send(request())
		#expect(r.content.first?["text"] == "ok")
	}

	@Test func aMidStreamFailureIsNotRetried() async {
		let sse = ScriptedSSE.message([.text("partial text that keeps going")])
		let t = ScriptedTransport([.sseThenFail(sse, afterLines: 12, error: .networkConnectionLost), .sse("")])
		await #expect(throws: URLError.self) { _ = try await client(t).send(request()) }
		#expect(t.remaining == 1)
	}

	@Test func exhaustedRetriesSurfaceTheLastError() async {
		let overloaded = ScriptedTransport.Response.http(status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
		let t = ScriptedTransport(Array(repeating: overloaded, count: 5))
		await #expect(throws: AnthropicError(status: 529, type: "overloaded_error", message: "Overloaded")) {
			_ = try await client(t).send(request())
		}
	}

	@Test func retryAfterParsesSecondsAndDates() {
		#expect(MessagesClient.retryAfter("3") == 3)
		#expect(MessagesClient.retryAfter(nil) == nil)
		#expect(MessagesClient.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == 0)
	}
}

/// A tiny lock-protected box for collecting values from @Sendable closures.
final class Box<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var v: T
	init(_ v: T) { self.v = v }
	var value: T { lock.withLock { v } }
	func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
