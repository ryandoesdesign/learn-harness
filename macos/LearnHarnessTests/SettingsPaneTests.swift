import AppKit
import Foundation
import LHAgent
import LHCore
import LHStore
import SwiftUI
import Testing
@testable import LearnHarness

// Settings (docs/native-macos-m8.md): the Prompts pane lists every segment
// of every agent exactly once (Teacher, Prober, Practice, then Shared), and
// the window renders.

@MainActor
@Suite struct SettingsPaneTests {
	@Test func everyPromptSegmentIsListedOnce() {
		let listed = PromptOverridesPane.sections.flatMap(\.paths)
		#expect(Set(listed).count == listed.count, "no duplicates")
		let all = Set(PromptAgent.allCases.flatMap { PromptComposer.segmentPaths($0) })
		#expect(Set(listed) == all)
		#expect(PromptOverridesPane.sections.map(\.title) == ["Teacher", "Prober", "Practice", "Shared"])
		#expect(PromptOverridesPane.sections.last?.paths.first == "system-prompt.md")
	}

	@Test func theSettingsWindowRenders() {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhset-\(UUID().uuidString)", directoryHint: .isDirectory)
		let app = AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
		let host = NSHostingView(rootView: SettingsView(model: app))
		host.layoutSubtreeIfNeeded()
		#expect(host.fittingSize.width >= 600)
	}
}
