import Foundation
import Testing
@testable import LHCore

// tests/settings-pure.test.ts is almost entirely UI-layer (components/
// settings/*: appearance vars, compose helpers, keyboard, keys, setup
// dialog, prompt sections) — not LHCore; those cases are skipped (see the
// port report). Its one core case, the slotsConfigured first-run gate, is
// REWRITTEN below: factory slot defaults replace the gate. The adapted
// key refusal (settings.ts ProviderKeyMissing) is pinned here too.

@Suite struct FirstRunGateTests {
	// REWRITTEN (slotsConfigured): there is no unconfigured state — an empty
	// record resolves a model into every slot.
	@Test func everySlotResolvesWithoutAnyPick() {
		for record in [nil, UserSettings(), UserSettings(models: ModelsSettings(strong: ModelSlot(effort: .low)))] {
			let eff = resolveSettings(record, catalog: TestCatalog.shared)
			for slot in MODEL_SLOTS {
				#expect(TestCatalog.shared.model(eff.models[slot].model) != nil)
			}
		}
	}
}

@Suite struct AnthropicKeyRefusalTests {
	@Test func envelopeAndMatcher() {
		let r = ProviderKeyMissing()
		#expect(r.error == "No Anthropic key is set — add one in Settings → Keys")
		#expect(r.code == PROVIDER_KEY_MISSING_CODE)
		#expect(r.json.serialized() == #"{"error":"No Anthropic key is set — add one in Settings → Keys","code":"provider_key_missing"}"#)
		#expect(isProviderKeyRefusal(r.error))
		#expect(isProviderKeyRefusal("Research refused: \(r.error)"), "composed wording still matches")
		#expect(!isProviderKeyRefusal(nil))
		#expect(!isProviderKeyRefusal(""))
		#expect(!isProviderKeyRefusal("Rate limited"))
	}

	@Test func isThrowable() {
		#expect(throws: ProviderKeyMissing.self) { throw ProviderKeyMissing() }
	}
}
