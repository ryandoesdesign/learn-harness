import LHAgent
import LHCore
import LHStore
import SwiftUI

/// activity-dock.tsx ActivitySection: every running job across all chats —
/// kind icon, session title, activity, cost, a ticking elapsed time, and
/// End on the row's face; a click expands the detail (cost, context,
/// model, steps, Open session). The header carries the total cost.
struct BackgroundAgentsSection: View {
	var model: AppModel
	@State private var open: String?
	@State private var ending: [String: EndState] = [:]

	enum EndState { case pending, failed }

	var body: some View {
		let jobs = model.runningJobs
		let extractions = model.extractionRows
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				Image(systemName: "waveform.path.ecg")
				Text("BACKGROUND AGENTS").tracking(1.2)
				Spacer()
				if !jobs.isEmpty || !extractions.isEmpty {
					let priced = jobs.compactMap { jobCost($0, catalog: model.catalog) } + extractions.compactMap(extractionCost)
					Text(priced.isEmpty ? "—" : formatUsd(priced.reduce(0, +))).monospacedDigit().help("Total running cost (inferred)")
				}
			}
			.font(Theme.ui)
			.foregroundStyle(Theme.faint)
			if !jobs.isEmpty || !extractions.isEmpty {
				TimelineView(.periodic(from: .now, by: 1)) { context in
					ScrollView {
						VStack(spacing: 2) {
							ForEach(jobs, id: \.id) { job in
								row(job, now: context.date)
							}
							ForEach(extractions) { row in extractionRow(row, now: context.date) }
						}
					}
					.frame(maxHeight: 240)
				}
			}
		}
		.padding(.horizontal, 4)
		.padding(.vertical, 8)
		.overlay(alignment: .top) { Divider() }
	}

	private func row(_ job: JobRecord, now: Date) -> some View {
		let elapsed = formatElapsed(now.timeIntervalSince(ISOClock.date(job.createdAt) ?? now))
		let cost = jobCost(job, catalog: model.catalog).map(formatUsd) ?? "—"
		let activity = isProviderKeyRefusal(job.error) ? "needs a provider key" : job.activity
		let isOpen = open == job.id
		return VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Button {
					open = isOpen ? nil : job.id
				} label: {
					HStack(spacing: 8) {
						Image(systemName: kindIcon(job.kind)).foregroundStyle(Theme.muted).frame(width: 14)
						VStack(alignment: .leading, spacing: 1) {
							Text(model.sessionTitle(job.chatId)).font(.system(size: 12, weight: .medium)).lineLimit(1)
							Text(activity.isEmpty ? kindLabel(job.kind) : activity).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).help(activity)
						}
						Spacer(minLength: 4)
						Text(cost).monospacedDigit()
						Text(elapsed).monospacedDigit()
					}
					.font(.system(size: 11))
					.foregroundStyle(Theme.muted)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				Button {
					ending[job.id] = .pending
					Task { if !(await model.endJob(job.id)) { ending[job.id] = nil } }
				} label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
					.buttonStyle(.borderless)
					.disabled(ending[job.id] != nil)
					.help(ending[job.id] == .failed ? "Abort failed — try again" : "End this background process")
					.accessibilityLabel("End \(kindLabel(job.kind)) in \(model.sessionTitle(job.chatId))")
			}
			if isOpen { detail(job, cost: cost, elapsed: elapsed, activity: activity) }
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 5)
		.background(RoundedRectangle(cornerRadius: 6).fill(isOpen ? Color.primary.opacity(0.05) : .clear))
	}

	/// An extraction batch (activity-dock.tsx extraction blob): the title
	/// (with "· i/N" for a chunked source), "Extraction — <phase>", cost,
	/// elapsed, and End (aborts the whole source).
	private func extractionRow(_ r: ExtractionService.Row, now: Date) -> some View {
		let base = r.kind == .notes ? ((r.label ?? r.sourceId) as NSString).lastPathComponent : model.sessionTitle(r.sourceId)
		let title = base + (r.part.map { " · \($0.i)/\($0.n)" } ?? "")
		let elapsed = formatElapsed(now.timeIntervalSince1970 - Double(r.startedAt) / 1000)
		return HStack(spacing: 8) {
			Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.muted).frame(width: 14)
			VStack(alignment: .leading, spacing: 1) {
				Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
				Text("Extraction — \(r.phase.rawValue)").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
			}
			Spacer(minLength: 4)
			Text(extractionCost(r).map(formatUsd) ?? "—").monospacedDigit()
			Text(elapsed).monospacedDigit()
			Button {
				ending[r.id] = .pending
				Task { _ = await model.extraction.abort(r.sourceId) }
			} label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
				.buttonStyle(.borderless)
				.disabled(ending[r.id] != nil)
				.help("End this background process")
				.accessibilityLabel("End extraction in \(title)")
		}
		.font(.system(size: 11))
		.foregroundStyle(Theme.muted)
		.padding(.horizontal, 6)
		.padding(.vertical, 5)
	}

	/// The batch's live cost: each stage's steps at its model's price.
	private func extractionCost(_ r: ExtractionService.Row) -> Double? {
		let stages = [r.extractor, r.auditor].compactMap { $0 }
		if stages.isEmpty { return nil }
		var total = 0.0
		for stage in stages {
			for step in stage.steps {
				guard let c = callCost(step, model: stage.model, catalog: model.catalog) else { return nil }
				total += c
			}
		}
		return total
	}

	private func detail(_ job: JobRecord, cost: String, elapsed: String, activity: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Image(systemName: kindIcon(job.kind))
				Text(kindLabel(job.kind)).fontWeight(.medium)
				Spacer()
				Text(elapsed).monospacedDigit()
			}
			if !activity.isEmpty { Text(activity).fixedSize(horizontal: false, vertical: true) }
			pair("Cost", cost)
			pair("Context", contextLine(job) ?? "—")
			if let m = job.usage?.model { pair("Model", m) }
			if let steps = job.usage?.steps { pair("Steps", "\(steps)") }
			Button("Open session →") { model.selection = job.chatId }
				.buttonStyle(.link)
			if ending[job.id] == .pending { Text("Stopping…").foregroundStyle(Theme.faint) }
		}
		.font(.system(size: 11))
		.foregroundStyle(Theme.muted)
		.padding(8)
		.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
	}

	private func pair(_ k: String, _ v: String) -> some View {
		HStack {
			Text(k)
			Spacer()
			Text(v).foregroundStyle(.primary).monospacedDigit().lineLimit(1)
		}
	}

	/// The last step's whole context against the model's window.
	private func contextLine(_ job: JobRecord) -> String? {
		guard let usage = job.usage, let last = usage.lastStep, let input = last.inputTokens,
		      let limit = model.catalog.model(usage.model)?.contextWindow else { return nil }
		let used = input + (last.outputTokens ?? 0) + (last.cacheReadTokens ?? 0) + (last.cacheWriteTokens ?? 0)
		return "\(formatTokens(used)) / \(formatTokens(limit))"
	}
}

func kindIcon(_ kind: JobKind) -> String {
	switch kind {
	case .research: "magnifyingglass"
	case .demo: "play"
	case .visual: "pencil.tip"
	case .pdf: "doc.text"
	}
}

func kindLabel(_ kind: JobKind) -> String {
	switch kind {
	case .research: "Researcher"
	case .demo: "Demo builder"
	case .visual: "Figure maker"
	case .pdf: "PDF reader"
	}
}

/// activity-dock.tsx formatElapsed: 42s, 3m 07s, 1h 05m.
func formatElapsed(_ seconds: TimeInterval) -> String {
	let s = max(0, Int(seconds))
	if s < 60 { return "\(s)s" }
	let m = s / 60
	if m < 60 { return "\(m)m \(String(format: "%02d", s % 60))s" }
	return "\(m / 60)h \(String(format: "%02d", m % 60))m"
}
