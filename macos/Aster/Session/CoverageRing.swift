import LHAgent
import LHCore
import LHStore
import SwiftUI

/// extraction-coverage.tsx: the session toolbar's ring — filled toward the
/// chunk threshold, pulsing while extracting — and its popover.
struct CoverageRing: View {
	var chatId: String
	@Environment(AppModel.self) private var app
	@State private var open = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var pulse = false

	var body: some View {
		let enabled = extractionEnabled(resolveSettings((try? SettingsRepository(app.database).read()) ?? nil, catalog: app.catalog).graph)
		// Re-read whenever the running rows or the record change.
		let _ = app.extractionRows
		let _ = app.session?.record?.messages.count
		if enabled, let c = app.coverage(chatId) {
			let threshold = app.extractionChunkTokens
			let fill = threshold > 0 ? min(1, Double(c.uncoveredTokens) / Double(threshold)) : 0
			Button { open.toggle() } label: {
				ZStack {
					Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
					Circle().trim(from: 0, to: fill).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
				}
				.frame(width: 14, height: 14)
				.opacity(c.running && pulse && !reduceMotion ? 0.35 : 1)
				.animation(c.running && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
				.onAppear { pulse = c.running }
				.onChange(of: c.running) { _, r in pulse = r }
			}
			.help("Extraction coverage")
			.popover(isPresented: $open) { popover(c, threshold: threshold) }
		}
	}

	private func popover(_ c: ExtractionService.SessionCoverage, threshold: Int) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("EXTRACTION").font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
			row("Uncovered", "\(c.uncoveredTokens) tok")
			row("Covered", "\(c.coveredTokens) tok")
			row("Messages covered", "\(c.coveredCount) / \(c.coveredCount + c.uncoveredCount)")
			row("Chunk threshold", "\(threshold) tok")
			row("Last extraction", c.lastFoldedAt.flatMap(ISOClock.date).map { $0.formatted(.relative(presentation: .named)) } ?? "never")
			if c.running { Text("extracting…").foregroundStyle(.secondary) }
			Divider()
			Button(c.running ? "Running" : "Extract now") { app.extract(chatId) }.disabled(c.running || c.uncoveredCount == 0)
		}
		.font(.system(size: 12))
		.monospacedDigit()
		.padding(12)
		.frame(width: 240)
	}

	private func row(_ k: String, _ v: String) -> some View {
		HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
	}
}
