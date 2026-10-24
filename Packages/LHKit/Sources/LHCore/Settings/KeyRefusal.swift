import Foundation

// Port of settings.ts's ProviderKeyMissing envelope, adapted per
// docs/native-macos-m1.md: Anthropic is the only provider, so the
// per-provider envelope collapses to the single "No Anthropic key" refusal
// (no `provider`, no `slots` — every slot needs the same key). The
// models-not-configured envelope died with the factory slot defaults.

/// The machine discriminator the client switches on.
public let PROVIDER_KEY_MISSING_CODE = "provider_key_missing"

/// The refusal wording's invariant tail — the matcher keys on it, so job
/// and turn surfaces may compose their own wording in front.
let PROVIDER_KEY_MISSING_TAIL = "key is set — add one in Settings → Keys"

/// The key-presence refusal: every per-need gate (turn, job spawn, notes
/// import, extraction) refuses with this when no Anthropic key is stored.
/// It is also the typed throw for in-process seams.
public struct ProviderKeyMissing: Error, Sendable, Hashable {
	/// Human-readable — safe to render as-is.
	public let error: String
	public let code: String

	public init() {
		self.error = "No Anthropic \(PROVIDER_KEY_MISSING_TAIL)"
		self.code = PROVIDER_KEY_MISSING_CODE
	}

	/// The envelope as JSON (`{error, code}`).
	public var json: JSONValue {
		["error": .string(error), "code": .string(code)]
	}
}

/// True when an error line is (or ends with) the key refusal — UI
/// consumers render refused work in the info tone, not as a failure. The
/// envelope's home module owns the string so writer and matcher never drift.
public func isProviderKeyRefusal(_ error: String?) -> Bool {
	guard let error else { return false }
	return error.hasSuffix(PROVIDER_KEY_MISSING_TAIL)
}
