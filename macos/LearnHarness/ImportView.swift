import AppKit
import LHImport
import SwiftUI

/// File → Import from LearnHarness (Electron)… — the panel opens at the old
/// app's Application Support folder; the pick is read-only and one-shot.
struct ImportCommand: View {
	let model: AppModel

	var body: some View {
		Button("Import from LearnHarness (Electron)…") { pickFolder() }
			.disabled({ if case .running = model.importState { return true }; return false }())
	}

	private func pickFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = "Import"
		panel.message = "Choose the LearnHarness folder (it holds data/ and auth.json). Nothing in it is changed."
		panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
			.appending(path: "Library/Application Support/LearnHarness", directoryHint: .isDirectory)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		Task { await model.runImport(from: url) }
	}
}

/// The progress / report sheet.
struct ImportSheet: View {
	@Bindable var model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			switch model.importState {
			case .idle:
				EmptyView()
			case .running(let step):
				HStack(spacing: 12) {
					ProgressView().controlSize(.small)
					Text("Importing — \(step)…")
				}
			case .failed(let message):
				Label("Import failed", systemImage: "exclamationmark.triangle").font(.headline)
				Text(message).textSelection(.enabled)
				doneButton
			case .finished(let report):
				ReportView(report: report)
				doneButton
			}
		}
		.padding(24)
		.frame(minWidth: 460, idealWidth: 520, maxHeight: 560)
	}

	private var doneButton: some View {
		HStack {
			Spacer()
			Button("Done") { model.importState = .idle }.keyboardShortcut(.defaultAction)
		}
	}
}

private struct ReportView: View {
	let report: LegacyImporter.Report

	var body: some View {
		Text("Import finished").font(.headline)
		Text(report.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
		Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
			GridRow {
				Text("").gridColumnAlignment(.leading)
				Text("Imported").foregroundStyle(.secondary)
				Text("Skipped").foregroundStyle(.secondary)
			}
			ForEach(Array(Set(report.imported.keys).union(report.skipped.keys)).sorted(), id: \.self) { entity in
				GridRow {
					Text(entity.prefix(1).uppercased() + entity.dropFirst())
					Text("\(report.imported[entity] ?? 0)").monospacedDigit()
					Text("\(report.skipped[entity] ?? 0)").monospacedDigit()
				}
			}
		}
		if report.keyImported {
			Label("Your Anthropic key is now in the Keychain.", systemImage: "key")
		}
		if !report.otherKeys.isEmpty {
			Text("Other provider keys were not imported: \(report.otherKeys.joined(separator: ", ")).")
				.font(.callout).foregroundStyle(.secondary)
		}
		if !report.warnings.isEmpty {
			Text("Warnings").font(.subheadline.weight(.semibold))
			ScrollView {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, w in
						Text(w).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
					}
				}
			}
			.frame(maxHeight: 180)
			.textSelection(.enabled)
		}
	}
}
