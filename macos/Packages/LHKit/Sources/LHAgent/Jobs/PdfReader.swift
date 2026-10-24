import CoreGraphics
import Foundation
import ImageIO
import LHAnthropic
import LHCore
import LHResources
import PDFKit
import UniformTypeIdentifiers

// Ports of agent/subagents/pdf-ops.ts and pdf-reader.ts over PDFKit
// (docs/native-macos-m6.md). Formats and wording are TS-identical; the
// fixes: "all" means every page and ranges clamp to the document. Text
// keeps PDFKit's newlines, so search lines are real lines.

public struct PdfPageInfo: Sendable, Hashable {
	public var page: Int
	public var textLength: Int
	public var imageCount: Int
	public var mathDensity: Double
}

public struct PdfError: Error, Sendable, CustomStringConvertible {
	public var message: String
	public var description: String { message }
}

/// One opened document (PDFKit is not Sendable; it stays inside a call).
struct PdfDocument {
	let doc: PDFDocument
	let url: URL

	init(_ url: URL) throws(PdfError) {
		guard let doc = PDFDocument(url: url) else { throw PdfError(message: "not a readable PDF: \(url.lastPathComponent)") }
		if doc.isLocked { throw PdfError(message: "the PDF is password-protected") }
		self.doc = doc
		self.url = url
	}

	var pageCount: Int { doc.pageCount }
	func text(_ page: Int) -> String { doc.page(at: page - 1)?.string ?? "" }

	/// pdf_info: per-page triage signals.
	func info() -> (pages: [PdfPageInfo], meanTextLength: Int) {
		var total = 0
		var pages: [PdfPageInfo] = []
		for i in 1...max(pageCount, 1) where i <= pageCount {
			let t = text(i)
			total += t.jsLength
			pages.append(PdfPageInfo(page: i, textLength: t.jsLength, imageCount: imageCount(i), mathDensity: (mathDensity(t) * 10000).rounded() / 10000))
		}
		return (pages, Int((Double(total) / Double(max(pageCount, 1))).rounded()))
	}

	/// Image XObjects drawn on the page (the pdfjs paintImageXObject count).
	func imageCount(_ page: Int) -> Int {
		guard let cg = doc.page(at: page - 1)?.pageRef, let table = CGPDFOperatorTableCreate() else { return 0 }
		final class Counter { var n = 0; var xobjects: CGPDFDictionaryRef? }
		let counter = Counter()
		CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
			guard let info else { return }
			let c = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue()
			var name: UnsafePointer<CChar>?
			guard CGPDFScannerPopName(scanner, &name), let name, let xobjects = c.xobjects else { return }
			var stream: CGPDFStreamRef?
			guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
			var subtype: UnsafePointer<CChar>?
			if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" { c.n += 1 }
		}
		if let pageDict = cg.dictionary {
			var resources: CGPDFDictionaryRef?
			if CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources {
				var xo: CGPDFDictionaryRef?
				if CGPDFDictionaryGetDictionary(resources, "XObject", &xo) { counter.xobjects = xo }
			}
		}
		let stream = CGPDFContentStreamCreateWithPage(cg)
		let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counter).toOpaque())
		CGPDFScannerScan(scanner)
		return counter.n
	}

	/// Render pages to single-IDAT PNGs at `dpi` (out-of-range pages skipped).
	func render(_ pages: [Int], dpi: Int) -> [(page: Int, png: Data)] {
		pages.compactMap { n -> (Int, Data)? in
			guard n >= 1, n <= pageCount, let page = doc.page(at: n - 1) else { return nil }
			let box = page.bounds(for: .mediaBox)
			let scale = CGFloat(dpi) / 72
			let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
			guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
			ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
			ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
			ctx.scaleBy(x: scale, y: scale)
			page.draw(with: .mediaBox, to: ctx)
			guard let image = ctx.makeImage(), let png = pngData(image) else { return nil }
			return (n, png)
		}
	}
}

/// ImageIO PNG output (one IDAT chunk — the provider-safe shape).
func pngData(_ image: CGImage) -> Data? {
	let out = NSMutableData()
	guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
	CGImageDestinationAddImage(dest, image, nil)
	return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// pdf-ops.ts mathDensity: the share of math-block characters.
func mathDensity(_ text: String) -> Double {
	let extra = Set("∫∑∏√∂∇∞≈≠≤≥±×÷∈∉⊂⊃∪∩∧∨¬∀∃∅".unicodeScalars)
	var math = 0
	for s in text.unicodeScalars {
		let c = s.value
		if (0x2200...0x22FF).contains(c) || (0x2100...0x214F).contains(c) || (0x2190...0x21FF).contains(c) || (0x27C0...0x27EF).contains(c)
			|| (0x2980...0x29FF).contains(c) || (0x2A00...0x2AFF).contains(c) || (0x0370...0x03FF).contains(c) || (0x1D400...0x1D7FF).contains(c) || extra.contains(s)
		{
			math += 1
		}
	}
	return Double(math) / Double(max(text.jsLength, 1))
}

/// pdf-ops.ts parsePageSpec: "all", "1-5", "1,3,7" → pages within 1…total.
public func parsePageSpec(_ spec: String, total: Int) -> [Int] {
	if spec.jsTrimmed.lowercased() == "all" { return total > 0 ? Array(1...total) : [] }
	var pages = Set<Int>()
	for part in spec.split(separator: ",") {
		let p = part.trimmingCharacters(in: .whitespaces)
		if p.isEmpty { continue }
		if p.contains("-") {
			let bits = p.split(separator: "-", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) }
			guard let s = bits.first ?? nil else { continue }
			let e = (bits.count > 1 ? bits[1] : nil) ?? s
			let start = max(1, s), end = min(total, e)
			if start <= end { for n in start...end { pages.insert(n) } }
		} else if let n = Int(p), n >= 1, n <= total {
			pages.insert(n)
		}
	}
	return pages.sorted()
}

// MARK: - The reader

public let PDF_MAX_ITERATIONS = 14
let RENDER_BATCH_CAP = 6
let EXTRACT_CAP = 24_000
let UNREAD_FINISH_MESSAGE = "You finished without consulting any page of the PDF — your brief would be invention, not reading. Extract or render the relevant pages first, then write the brief from what you actually saw."

let pdfDeclarations: [ToolDefinition] = [
	declaration("pdf_info", "Metadata + per-page triage signals for the PDF (page count, text length, image count, math density). ALWAYS call this first.", .object([:])),
	declaration("pdf_extract", "Extract text from pages (spec: 'all', '1-5', '1,3,7', '3'). Use pdf_info first; narrow the spec for big documents.",
		.object(["pages": .string(description: "Page spec, e.g. 'all', '1-5', '1,3,7'")])),
	declaration("pdf_render", "Render pages to images and show them to you for visual reading (equations, diagrams, layout). DPI: 100 text, 150 default, 200 dense small print. Max 6 pages per call.",
		.object(properties: [
			.init("pages", .string(description: "Page spec, e.g. '1-3' or '2,5,8'")),
			.init("dpi", JSONSchema.integer(minimum: 72, description: "Render DPI (100 text / 150 default / 200 dense)").optional()),
		])),
	declaration("pdf_search", "Search the PDF's text by keyword or regex (case-insensitive); returns hits with context lines. Use for long documents before reading anything at length.",
		.object(properties: [
			.init("query", .string(description: "Keyword or regex")),
			.init("context_lines", JSONSchema.integer(minimum: 0, description: "Context lines around each hit (default 3)").optional()),
			.init("literal", JSONSchema.boolean(description: "true = treat the query literally (no regex; default false)").optional()),
		])),
]

/// pdf-reader.ts runPdfReaderAgent. `url` is already resolved through the
/// learner-folder gate (call inside its access scope).
public func runPdfReader(url: URL, displayPath: String, question: String, model: SubagentModel, maxIterations: Int = PDF_MAX_ITERATIONS,
	onUsage: @escaping @Sendable ([UsageStepRecord]) -> Void, onActivity: @escaping @Sendable (String) -> Void) async -> PdfResult
{
	func result(_ brief: String, _ read: Set<Int>, _ consulted: Set<Int>) -> PdfResult {
		PdfResult(path: displayPath, question: question, brief: brief, pagesRead: read.sorted(), pagesConsulted: consulted.sorted())
	}
	let doc: PdfDocument
	do {
		let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
		guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return result("PDF failed: not a regular file", [], []) }
		guard ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 0 else { return result("PDF failed: file is empty", [], []) }
		doc = try PdfDocument(url)
	} catch let e as PdfError {
		return result("PDF failed: \(e.message)", [], [])
	} catch {
		return result("PDF failed: \(error.localizedDescription)", [], [])
	}

	let system = LHResources.promptSegment("subagents/pdf-reader.md") ?? ""
	let prompt = [
		"PDF path: \(displayPath)",
		"Question (what the teacher needs from this document): \(question.isEmpty ? "(no question — give a structural overview)" : question)",
		"",
		"Read the document per your doctrine, then produce your final brief in the required format.",
	].joined(separator: "\n")
	var messages = [newUserMessage(prompt)]
	var consulted = Set<Int>()
	var read = Set<Int>()
	var finalText = ""
	var nudged = false
	do {
		for _ in 0..<maxIterations {
			try Task.checkCancellation()
			let (assistant, steps) = try await subagentCall(model, system: system, declarations: pdfDeclarations, context: messages)
			onUsage(steps)
			messages.append(assistant)
			let calls = assistant.assistant?.toolUses ?? []
			if calls.isEmpty {
				finalText = assistantText(assistant)
				if consulted.isEmpty, !nudged {
					nudged = true
					messages.append(newUserMessage(UNREAD_FINISH_MESSAGE))
					continue
				}
				return result(finalText.isEmpty ? "(no brief text)" : finalText, read, consulted)
			}
			var images: [(page: Int, png: Data)]?
			for call in calls {
				func reply(_ text: String) { messages.append(toolResultMessage(call, text, isError: text.hasPrefix("ERROR:"))) }
				switch call.name {
				case "pdf_info":
					onActivity("pdf_info: triaging")
					let info = doc.info()
					reply(([
						"File: \(displayPath)",
						"Pages: \(doc.pageCount) (mean text length/page: \(info.meanTextLength))",
					] + info.pages.map { "p\($0.page): len=\($0.textLength) img=\($0.imageCount) math=\(jsToFixed($0.mathDensity, 2))" }).joined(separator: "\n"))
				case "pdf_extract":
					let spec = call.input["pages"]?.stringValue ?? "all"
					onActivity("pdf_extract: \(spec)")
					let pages = parsePageSpec(spec, total: doc.pageCount)
					if pages.isEmpty { reply("No pages selected — page spec matched nothing."); continue }
					var text = pages.map { "--- Page \($0) ---\n\(doc.text($0))" }.joined(separator: "\n")
					if text.jsLength > EXTRACT_CAP {
						text = "\(text.jsSlice(0, EXTRACT_CAP))\n\n[Output truncated at \(EXTRACT_CAP) chars — narrow the page spec and extract in smaller batches.]"
					}
					reply(text)
					for p in pages { consulted.insert(p); read.insert(p) }
				case "pdf_search":
					let query = call.input["query"]?.stringValue ?? ""
					let contextLines = min(8, max(0, call.input["context_lines"]?.intValue ?? 3))
					onActivity("pdf_search: \"\(query)\"")
					let pattern = call.input["literal"]?.boolValue == true ? NSRegularExpression.escapedPattern(for: query) : query
					guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
						reply("ERROR: Invalid regex: \(query)")
						continue
					}
					var hits: [(page: Int, line: Int, context: String)] = []
					for page in 1...max(doc.pageCount, 1) where page <= doc.pageCount {
						let lines = doc.text(page).components(separatedBy: "\n")
						for (ln, line) in lines.enumerated() where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
							let start = max(0, ln - contextLines), end = min(lines.count, ln + contextLines + 1)
							let context = (start..<end).map { "\($0 == ln ? ">>>" : "   ") \(lines[$0])" }.joined(separator: "\n")
							hits.append((page, ln + 1, context))
						}
					}
					for h in hits { consulted.insert(h.page) }
					let cap = hits.prefix(40)
					reply(cap.isEmpty ? "No hits." : cap.map { "=== Page \($0.page), line \($0.line) ===\n\($0.context)" }.joined(separator: "\n")
						+ (hits.count > cap.count ? "\n\n[\(hits.count - cap.count) more hits — narrow the query.]" : ""))
				case "pdf_render":
					let spec = call.input["pages"]?.stringValue ?? "1"
					let dpi = min(300, max(72, call.input["dpi"]?.intValue ?? 150))
					let all = parsePageSpec(spec, total: doc.pageCount)
					let wanted = Array(all.prefix(RENDER_BATCH_CAP))
					onActivity("pdf_render: \(spec) @\(dpi)dpi")
					let pages = doc.render(wanted, dpi: dpi)
					for p in pages { consulted.insert(p.page); read.insert(p.page) }
					if pages.isEmpty {
						reply("ERROR: no pages rendered (spec matched nothing?)")
					} else {
						images = pages
						let capped = all.count > wanted.count ? " (\(all.count - wanted.count) more page(s) in the spec — render them in another call; max \(RENDER_BATCH_CAP) per call)" : ""
						reply("Rendered \(pages.count) page(s) at \(dpi) DPI — the images follow below. Read them carefully (equations, diagrams, layout).\(capped)")
					}
				default:
					reply("ERROR: unknown tool \"\(call.name)\"")
				}
			}
			if let images {
				messages.append(imageMessage("The rendered page(s), in order (\(images.map { "p\($0.page)" }.joined(separator: ", "))):", pngs: images.map(\.png)))
			}
		}
	} catch is CancellationError {
		return result("PDF failed: aborted", read, consulted)
	} catch {
		return result("PDF failed: the reader crashed — \(error)", read, consulted)
	}
	return result(finalText.isEmpty ? "PDF failed: iteration limit (\(maxIterations)) reached without a brief." : finalText, read, consulted)
}
