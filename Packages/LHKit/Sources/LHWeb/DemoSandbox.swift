import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LHCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// The demo sandbox (docs/native-macos-m6.md, your answers: CDN scripts only,
// no bridge; a private scheme). One shape for the headless verifier and the
// live card: each view serves its document from its own `lhdemo://<uuid>/`
// handler with the display CSP as a response header, in a non-persistent
// store that dies with the view, and error hooks injected at document
// start. A real origin (not opaque) keeps uncaught errors' messages —
// WebKit masks them as "Script error." in an opaque one. The page can't
// call the app; the app reads the page with evaluateJavaScript.

/// The CDN hosts a demo may load scripts, styles and fonts from.
public let DEMO_CDN_HOSTS = ["https://cdnjs.cloudflare.com", "https://cdn.jsdelivr.net", "https://unpkg.com"]

/// The display CSP: inline code plus the CDN hosts; every other request
/// (fetch, XHR, images from the network, frames, other hosts) is blocked.
public let DEMO_CSP: String = {
	let hosts = DEMO_CDN_HOSTS.joined(separator: " ")
	return "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' \(hosts); style-src 'unsafe-inline' \(hosts); "
		+ "font-src data: \(hosts); img-src data: blob:; media-src data: blob:; worker-src blob:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
}()

public let DEMO_SCHEME = "lhdemo"

/// Serves one view's current demo document (any path) with the CSP header.
@MainActor
final class DemoSchemeHandler: NSObject, WKURLSchemeHandler {
	var html = ""
	private(set) var host = UUID().uuidString.lowercased()

	/// A fresh origin for a new document (nothing carries over).
	func next(_ html: String) -> URL {
		self.html = html
		host = UUID().uuidString.lowercased()
		return URL(string: "\(DEMO_SCHEME)://\(host)/")!
	}

	func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
		guard let url = task.request.url, url.host == host else {
			task.didFailWithError(URLError(.resourceUnavailable))
			return
		}
		let headers = ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": DEMO_CSP, "Cache-Control": "no-store"]
		task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
		task.didReceive(Data(html.utf8))
		task.didFinish()
	}

	func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Document-start hooks: console.error, uncaught errors, unhandled
/// rejections, failed subresources (capture-phase error events) and CSP
/// blocks land in arrays the app reads.
let DEMO_HOOKS = """
	(() => {
		const errors = [], consoleErrors = [], failed = [];
		Object.defineProperty(window, "__lhErrors", { value: errors });
		Object.defineProperty(window, "__lhConsole", { value: consoleErrors });
		Object.defineProperty(window, "__lhFailed", { value: failed });
		const text = (v) => { try { return v instanceof Error ? v.message : typeof v === "string" ? v : JSON.stringify(v); } catch { return String(v); } };
		const original = console.error;
		console.error = function (...args) { consoleErrors.push(args.map(text).join(" ")); return original.apply(this, args); };
		addEventListener("error", (e) => {
			const t = e.target;
			if (t && t !== window && (t.src || t.href)) { failed.push(`${t.src || t.href} (failed to load)`); return; }
			errors.push(e.error ? text(e.error) : (e.message || "Script error."));
		}, true);
		addEventListener("unhandledrejection", (e) => errors.push(`Unhandled rejection: ${text(e.reason)}`));
		document.addEventListener("securitypolicyviolation", (e) => failed.push(`${e.blockedURI || "inline"} (blocked by the demo's security policy: ${e.violatedDirective})`));
	})();
	"""

@MainActor
func makeDemoConfiguration(_ handler: DemoSchemeHandler) -> WKWebViewConfiguration {
	let config = WKWebViewConfiguration()
	config.websiteDataStore = .nonPersistent()
	config.setURLSchemeHandler(handler, forURLScheme: DEMO_SCHEME)
	config.userContentController.addUserScript(WKUserScript(source: DEMO_HOOKS, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
	return config
}

// MARK: - The headless verifier

public enum HeadlessError: Error, CustomStringConvertible, Sendable {
	case timeout
	case render(String)
	public var description: String {
		switch self {
		case .timeout: "the demo did not finish loading within 20 seconds"
		case .render(let m): m
		}
	}
}

/// The WebKit HeadlessVerifier: each run gets a fresh offscreen view.
@MainActor
public final class WebHeadlessVerifier: HeadlessVerifier {
	public static let shared = WebHeadlessVerifier()

	private let window: NSWindow
	public var loadTimeout: Duration = .seconds(20)
	public var settle: Duration = .seconds(2)

	public init() {
		window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1024, height: 768), styleMask: [.borderless], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.alphaValue = 0
		window.ignoresMouseEvents = true
	}

	public func runDemo(_ html: String, probe: String?) async throws -> DemoRunResult {
		let handler = DemoSchemeHandler()
		let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: makeDemoConfiguration(handler))
		let waiter = LoadWaiter()
		view.navigationDelegate = waiter
		window.contentView?.addSubview(view)
		defer {
			view.stopLoading()
			view.removeFromSuperview()
		}
		var result = DemoRunResult()
		view.load(URLRequest(url: handler.next(html)))
		do {
			try await waiter.wait(timeout: loadTimeout)
			try await Task.sleep(for: settle)
		} catch let e as HeadlessError {
			result.pageErrors.append(e.description)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			result.pageErrors.append(error.localizedDescription)
		}
		if let read = try? await view.evaluateJavaScript("[window.__lhConsole || [], window.__lhErrors || [], window.__lhFailed || []]") as? [[Any]], read.count == 3 {
			result.consoleErrors += read[0].map { "\($0)" }
			result.pageErrors += read[1].map { "\($0)" }
			result.failedRequests += Array(Set(read[2].map { "\($0)" })).sorted()
		}
		if let probe, !probe.jsTrimmed.isEmpty {
			do {
				let json = try await view.evaluateJavaScript("(() => { const v = (\(probe)\n); return v === undefined ? undefined : JSON.stringify(v); })()")
				if let s = json as? String { result.probeResult = try? JSONValue.parse(Data(s.utf8)) }
			} catch {
				result.pageErrors.append("probe failed: \(probeMessage(error))")
			}
		}
		return result
	}

	/// The SVG at 2× on white, as a PNG (one IDAT — the provider-safe shape).
	public func renderSvg(_ svg: String) async throws -> Data {
		let rendered = try await WebRenderer.shared.figure(svg)
		let w = Int((rendered.size.width * 2).rounded()), h = Int((rendered.size.height * 2).rounded())
		guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw HeadlessError.render("the figure has no size") }
		ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
		var rect = CGRect(x: 0, y: 0, width: w, height: h)
		guard let image = rendered.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw HeadlessError.render("the snapshot has no bitmap") }
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
		guard let out = ctx.makeImage(), let png = encodePNG(out) else { throw HeadlessError.render("PNG encoding failed") }
		return png
	}

	private func probeMessage(_ error: Error) -> String {
		let ns = error as NSError
		return (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
	}
}

/// ImageIO PNG encoding.
public func encodePNG(_ image: CGImage) -> Data? {
	let out = NSMutableData()
	guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
	CGImageDestinationAddImage(dest, image, nil)
	return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// One load: resumes on finish, failure, or the timeout. Links never navigate.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
	private var continuation: CheckedContinuation<Void, Error>?
	private var done = false

	func wait(timeout: Duration) async throws {
		if done { return }
		try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
			continuation = c
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: timeout)
				self?.finish(.failure(HeadlessError.timeout))
			}
		}
	}

	private func finish(_ result: Result<Void, Error>) {
		done = true
		continuation?.resume(with: result)
		continuation = nil
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel
	}
}

// MARK: - The live demo

/// The demo-card bridge's height (body plus its margins, not the viewport)
/// and the uncaught errors so far.
let DEMO_MEASURE = """
	(() => {
		const b = document.body;
		let h = document.documentElement.scrollHeight;
		if (b) { const cs = getComputedStyle(b); h = Math.max(b.scrollHeight, b.getBoundingClientRect().height) + (parseFloat(cs.marginTop) || 0) + (parseFloat(cs.marginBottom) || 0); }
		return [Math.ceil(h), (window.__lhErrors || []).slice(0, 5)];
	})()
	"""

/// A delivered demo in the transcript: the sandboxed document, its height
/// and uncaught errors polled from the page (clamped 80–2,400).
public struct DemoWebView: NSViewRepresentable {
	public var html: String
	@Binding public var height: CGFloat
	public var onErrors: ([String]) -> Void

	public init(html: String, height: Binding<CGFloat>, onErrors: @escaping ([String]) -> Void) {
		self.html = html
		_height = height
		self.onErrors = onErrors
	}

	public final class Coordinator: NSObject, WKNavigationDelegate {
		var parent: DemoWebView
		var loaded: String?
		let handler = DemoSchemeHandler()
		var timer: Timer?
		weak var view: WKWebView?
		init(_ parent: DemoWebView) { self.parent = parent }

		@MainActor func poll() {
			view?.evaluateJavaScript(DEMO_MEASURE) { [weak self] value, _ in
				MainActor.assumeIsolated {
					guard let self, let pair = value as? [Any], pair.count == 2 else { return }
					if let h = (pair[0] as? NSNumber)?.doubleValue, h > 0 {
						let clamped = min(2400, max(80, CGFloat(h)))
						if abs(clamped - self.parent.height) >= 1 { self.parent.height = clamped }
					}
					let errors = (pair[1] as? [Any] ?? []).map { "\($0)" }
					if !errors.isEmpty { self.parent.onErrors(errors) }
				}
			}
		}

		public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
			navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> WKWebView {
		let view = WKWebView(frame: .zero, configuration: makeDemoConfiguration(context.coordinator.handler))
		view.navigationDelegate = context.coordinator
		view.underPageBackgroundColor = .white
		context.coordinator.view = view
		let coordinator = context.coordinator
		context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
			MainActor.assumeIsolated { coordinator.poll() }
		}
		return view
	}

	public func updateNSView(_ view: WKWebView, context: Context) {
		context.coordinator.parent = self
		if context.coordinator.loaded != html {
			context.coordinator.loaded = html
			view.load(URLRequest(url: context.coordinator.handler.next(html)))
		}
	}

	public static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
		coordinator.timer?.invalidate()
		view.stopLoading()
	}
}
