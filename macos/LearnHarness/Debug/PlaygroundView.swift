#if DEBUG
import LHCore
import SwiftUI

/// Debug → Anthropic Playground.
struct PlaygroundView: View {
	@Bindable var model: PlaygroundModel

	var body: some View {
		VStack(spacing: 0) {
			controls
			Divider()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 12) {
						ForEach(model.history, id: \.id) { MessageRow(message: $0) }
						if let s = model.streaming { MessageRow(message: s).opacity(0.85) }
						Color.clear.frame(height: 1).id("end")
					}
					.padding()
				}
				.onChange(of: model.history.count) { proxy.scrollTo("end") }
			}
			Divider()
			usage
			composer
		}
		.frame(minWidth: 640, minHeight: 560)
	}

	private var controls: some View {
		HStack {
			Picker("Model", selection: $model.model) {
				ForEach(model.models, id: \.id) { Text($0.name).tag($0.id) }
			}
			.frame(maxWidth: 240)
			Picker("Effort", selection: $model.effort) {
				ForEach(model.efforts, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.frame(maxWidth: 160)
			Spacer()
			if !model.hasKey {
				SecureField("Anthropic API key", text: $model.keyDraft).frame(maxWidth: 220)
				Button("Save Key") { model.saveKey() }
			}
			Button("Clear") { model.clear() }.disabled(model.running)
		}
		.padding(10)
	}

	private var usage: some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(Array(model.turns.enumerated()), id: \.element.id) { i, t in
				Text("Call \(i + 1) · \(t.model) · in \(t.usage.inputTokens ?? 0) · cache read \(t.usage.cacheReadTokens ?? 0) · write 5m \((t.usage.cacheWriteTokens ?? 0) - (t.usage.cacheWrite1hTokens ?? 0)) · write 1h \(t.usage.cacheWrite1hTokens ?? 0) · out \(t.usage.outputTokens ?? 0) · \(t.dollars.map { String(format: "$%.5f", $0) } ?? "—")")
					.font(.caption.monospacedDigit())
			}
			if let s = model.status { Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 10)
		.padding(.vertical, model.turns.isEmpty && model.status == nil ? 0 : 6)
	}

	private var composer: some View {
		HStack {
			TextField("Ask something — try “What time is it in Paris and Tokyo?”", text: $model.draft, axis: .vertical)
				.lineLimit(1...4)
				.onSubmit { model.send() }
			if model.running {
				Button("Stop", role: .cancel) { model.abort() }
			} else {
				Button("Send") { model.send() }.keyboardShortcut(.return, modifiers: .command)
			}
		}
		.padding(10)
	}
}

private struct MessageRow: View {
	let message: Message

	var body: some View {
		switch message.body {
		case .user(let u):
			Text(u.content.compactMap(\.text).joined(separator: "\n"))
				.padding(8)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
				.frame(maxWidth: .infinity, alignment: .trailing)
		case .assistant(let a):
			VStack(alignment: .leading, spacing: 6) {
				ForEach(Array(a.content.enumerated()), id: \.offset) { _, block in
					if let t = block.thinking, !t.text.isEmpty {
						DisclosureGroup("Thinking") { Text(t.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
					} else if let text = block.text {
						Text(text).textSelection(.enabled)
					} else if let call = block.toolUse {
						Label("\(call.name)(\(call.input.serialized()))", systemImage: "wrench.and.screwdriver").font(.callout.monospaced())
					}
				}
				if a.stopReason == "refusal" {
					Label("Declined (\(a.stopDetails?["category"]?.stringValue ?? "no category"))", systemImage: "hand.raised").foregroundStyle(.orange)
				} else if let e = a.errorMessage {
					Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
				} else if a.stopReason == "aborted" {
					Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
				}
			}
		case .toolResult(let r):
			Label(r.firstText ?? "(no text)", systemImage: r.isError ? "xmark.circle" : "checkmark.circle")
				.font(.callout.monospaced())
				.foregroundStyle(r.isError ? .red : .secondary)
		case .marker(let m):
			Text(m.content).font(.caption).foregroundStyle(.secondary)
		}
	}
}
#endif
