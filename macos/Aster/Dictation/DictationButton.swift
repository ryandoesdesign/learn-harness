import AppKit
import SwiftUI

/// dictation.tsx's button, in the status bar's middle slot: "Dictate";
/// while recording a red Stop pill with a pulsing dot and a level meter;
/// a spinner while preparing or finishing; an error replaces the label and
/// the next click retries (microphone access opens System Settings).
struct DictationButton: View {
	@Environment(DictationService.self) private var dictation

	var body: some View {
		if dictation.available {
			switch dictation.state {
			case .idle:
				Button { dictation.toggle() } label: {
					Label("Dictate", systemImage: "mic").font(Theme.ui)
				}
				.buttonStyle(.plain)
				.foregroundStyle(Theme.muted)
				.help("Dictate (⌘D)")
			case .preparing(let message):
				HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(message) }
					.font(Theme.ui).foregroundStyle(Theme.muted)
			case .recording:
				Button { dictation.toggle() } label: {
					HStack(spacing: 6) {
						PulsingDot()
						Text("Stop").font(Theme.uiMedium)
						LevelMeter(level: dictation.level)
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 2)
					.foregroundStyle(.white)
					.background(Capsule().fill(Theme.red))
				}
				.buttonStyle(.plain)
				.help("Stop (⌘D) · Esc discards")
				.accessibilityLabel("Stop dictation")
			case .finishing:
				ProgressView().controlSize(.mini)
			case .error(let message):
				Button {
					if message == DictationError.microphoneDenied.message,
					   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
					{
						NSWorkspace.shared.open(url)
					} else {
						dictation.toggle()
					}
				} label: {
					Label(message, systemImage: "mic.slash").font(Theme.ui).lineLimit(1)
				}
				.buttonStyle(.plain)
				.foregroundStyle(Theme.red)
				.help("Try again")
			}
		}
	}
}

private struct PulsingDot: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var dim = false
	var body: some View {
		Circle().fill(.white).frame(width: 6, height: 6)
			.opacity(dim ? 0.35 : 1)
			.onAppear {
				guard !reduceMotion else { return }
				withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true }
			}
	}
}

/// A fixed-width meter: 16 cells lit up to the level.
private struct LevelMeter: View {
	var level: Double
	var body: some View {
		HStack(spacing: 1) {
			ForEach(0..<16, id: \.self) { i in
				RoundedRectangle(cornerRadius: 0.5)
					.fill(.white.opacity(Double(i) / 16 < level ? 0.95 : 0.3))
					.frame(width: 2, height: 9)
			}
		}
	}
}

extension View {
	/// Make this field a dictation target while it's on screen.
	func dictationTarget(_ id: String, _ priority: DictationService.Priority, text: Binding<String>) -> some View {
		modifier(DictationTargetModifier(id: id, priority: priority, text: text))
	}
}

private struct DictationTargetModifier: ViewModifier {
	let id: String
	let priority: DictationService.Priority
	let text: Binding<String>
	@Environment(DictationService.self) private var dictation: DictationService?

	func body(content: Content) -> some View {
		content
			.onAppear { dictation?.register(id, priority) { text.wrappedValue = appendDictation(text.wrappedValue, $0) } }
			.onDisappear { dictation?.unregister(id) }
	}
}

extension DictationService {
	/// Submit after any running dictation lands in its field.
	func thenSubmit(_ action: @escaping @MainActor () -> Void) {
		guard isRecording else { return action() }
		Task {
			await finish()
			action()
		}
	}
}
