import Foundation
import ImageIO
import LHCore
import UniformTypeIdentifiers

// Ports of agent/tools/read.ts, ls.ts, find.ts, grep.ts — the learner file
// tools (definitions generated from the TS golden dump). Output formats,
// notices and error wording are TS-identical; paths resolve through the
// learner-folder gate, and docs/native-macos-m6.md's fixes apply: `~`
// expansion, a 25 MB read limit, binary files reported, images over
// 2,000 px downscaled, and an honest "Invalid regex" from grep.

/// The four tools in registry order.
public func fileTools(_ access: FileAccess) -> [any AgentTool] {
	[ReadTool(access: access), LsTool(access: access), FindTool(access: access), GrepTool(access: access)]
}

let READ_MAX_LINES = 2000
let READ_MAX_BYTES = 50 * 1024
let READ_MAX_FILE_BYTES = 25 * 1024 * 1024
let IMAGE_MAX_PIXELS = 2000
let GREP_MAX_FILE_BYTES = 2 * 1024 * 1024
let IMAGE_MIME: [String: String] = [".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp"]

private func isDirectory(_ url: URL) -> Bool? {
	var isDir: ObjCBool = false
	guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
	return isDir.boolValue
}

// MARK: - read

public struct ReadTool: AgentTool {
	let access: FileAccess
	public let name = "read"
	public let description = GeneratedTools.readDescription
	public let schema = GeneratedTools.readSchema

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		try access.withAccess { roots in
			let url = try access.resolve(input["path"]?.stringValue, roots: roots)
			let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
			guard let attrs else { throw FileToolError("ENOENT: no such file or directory, open '\(url.path)'") }
			let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
			if size > READ_MAX_FILE_BYTES {
				throw FileToolError("File is too large to read (\(formatSize(size)); the limit is 25 MB): \(url.path)")
			}
			let data = try Data(contentsOf: url)
			if let mime = IMAGE_MIME["." + url.pathExtension.lowercased()] {
				let (bytes, outMime) = downscaledImage(data, mime: mime)
				return ToolOutput(content: [
					.text("Read image file [\(outMime)] — \(url.lastPathComponent) (\(formatSize(data.count))), attached as an image."),
					.image(mediaType: outMime, base64: bytes.base64EncodedString()),
				])
			}
			if data.prefix(8192).contains(0) {
				return .value(.string("Binary file — \(url.lastPathComponent) (\(formatSize(data.count))) is not text, so it can't be read as text."))
			}
			let text = String(decoding: data, as: UTF8.self)
			return .value(.string(try readTextSlice(text, offset: input["offset"]?.intValue, limit: input["limit"]?.intValue)))
		}
	}
}

/// read.ts readTextSlice: the 2000-line / 50 KB windows with continuation notices.
func readTextSlice(_ text: String, offset: Int?, limit: Int?) throws(FileToolError) -> String {
	let all = text.components(separatedBy: "\n")
	let total = all.count
	let start = offset.map { max(0, $0 - 1) } ?? 0
	if start >= total { throw FileToolError("Offset \(offset ?? 0) is beyond end of file (\(total) lines total)") }
	var selected = Array(all[start..<(limit.map { min(total, start + $0) } ?? total)])
	var truncatedBy: String?
	if selected.count > READ_MAX_LINES {
		selected = Array(selected.prefix(READ_MAX_LINES))
		truncatedBy = "lines"
	}
	if selected.joined(separator: "\n").utf8.count > READ_MAX_BYTES {
		while !selected.isEmpty, selected.joined(separator: "\n").utf8.count > READ_MAX_BYTES { selected.removeLast() }
		truncatedBy = "bytes"
	}
	guard let truncatedBy else {
		let remaining = total - (start + selected.count)
		if remaining > 0 {
			return "\(selected.joined(separator: "\n"))\n\n[\(remaining) more lines in file. Use offset=\(start + selected.count + 1) to continue.]"
		}
		return selected.joined(separator: "\n")
	}
	let end = start + selected.count
	let reason = truncatedBy == "lines" ? "\(READ_MAX_LINES) line limit" : "\(formatSize(READ_MAX_BYTES)) limit"
	return "\(selected.joined(separator: "\n"))\n\n[Showing lines \(start + 1)-\(end) of \(total) (\(reason)). Use offset=\(end + 1) to continue.]"
}

/// Images over IMAGE_MAX_PIXELS on the long edge are downscaled (PNG/JPEG out).
func downscaledImage(_ data: Data, mime: String) -> (Data, String) {
	guard let src = CGImageSourceCreateWithData(data as CFData, nil),
	      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
	      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
	      max(w, h) > IMAGE_MAX_PIXELS
	else { return (data, mime) }
	let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: IMAGE_MAX_PIXELS, kCGImageSourceCreateThumbnailWithTransform: true]
	guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return (data, mime) }
	let jpeg = mime == "image/jpeg"
	let out = NSMutableData()
	guard let dest = CGImageDestinationCreateWithData(out, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return (data, mime) }
	CGImageDestinationAddImage(dest, thumb, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
	guard CGImageDestinationFinalize(dest) else { return (data, mime) }
	return (out as Data, jpeg ? "image/jpeg" : "image/png")
}

// MARK: - ls

public struct LsTool: AgentTool {
	let access: FileAccess
	public let name = "ls"
	public let description = GeneratedTools.lsDescription
	public let schema = GeneratedTools.lsSchema

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		try access.withAccess { roots in
			let dir = try access.resolve(input["path"]?.stringValue, roots: roots)
			guard let isDir = isDirectory(dir) else { throw FileToolError("Path not found: \(dir.path)") }
			guard isDir else { throw FileToolError("Not a directory: \(dir.path)") }
			let entries: [String]
			do { entries = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
				throw FileToolError("Cannot read directory: \(error.localizedDescription)")
			}
			let sorted = entries.sorted { $0.lowercased().localizedCompare($1.lowercased()) == .orderedAscending }
			let limit = input["limit"]?.intValue ?? 500
			var lines: [String] = []
			var limitReached = false
			for entry in sorted {
				if lines.count >= limit { limitReached = true; break }
				let full = dir.appending(path: entry)
				// stat follows links — but only inside the granted folders.
				guard access.isAllowed(full, roots: roots), let d = isDirectory(full) else { continue }
				lines.append(d ? "\(entry)/" : entry)
			}
			if lines.isEmpty { return .value("Directory is empty") }
			let (content, truncated) = capOutput(lines)
			var notices: [String] = []
			if limitReached { notices.append("\(limit) entries limit") }
			if truncated { notices.append("\(formatSize(MAX_OUTPUT_BYTES)) limit") }
			return .value(.string(notices.isEmpty ? content : "\(content)\n\n[Truncated: \(notices.joined(separator: ", "))]"))
		}
	}
}

// MARK: - find

public struct FindTool: AgentTool {
	let access: FileAccess
	public let name = "find"
	public let description = GeneratedTools.findDescription
	public let schema = GeneratedTools.findSchema

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		if Task.isCancelled { return .value("Operation aborted") }
		return try access.withAccess { roots in
			let root = try access.resolve(input["path"]?.stringValue, roots: roots)
			guard let isDir = isDirectory(root) else { throw FileToolError("Path not found: \(root.path)") }
			guard isDir else { throw FileToolError("Not a directory: \(root.path)") }
			let pattern = input["pattern"]?.stringValue ?? ""
			let limit = input["limit"]?.intValue ?? 1000
			var matches: [String] = []
			var limitReached = false
			let (timedOut, aborted) = walkFiles(root) { file in
				let rel = relativePath(file, to: root)
				guard matchGlob(rel, pattern) else { return false }
				if matches.count >= limit { limitReached = true; return true }
				matches.append(rel)
				return false
			}
			if aborted {
				return .value(.string(matches.isEmpty ? "Search aborted before any results." : "\(matches.joined(separator: "\n"))\n\n[search aborted — partial results]"))
			}
			if matches.isEmpty, !limitReached {
				return .value(.string(timedOut ? "Search timed out after 10s with no matches yet. Narrow the search to a subdirectory." : "No files found matching pattern"))
			}
			let (content, truncated) = capOutput(matches)
			var notices: [String] = []
			if limitReached || matches.count >= limit { notices.append("\(limit) results limit reached") }
			if truncated { notices.append("\(formatSize(MAX_OUTPUT_BYTES)) limit reached") }
			if timedOut { notices.append("search timed out after 10s — partial results, narrow the directory") }
			return .value(.string(notices.isEmpty ? content : "\(content)\n\n[\(notices.joined(separator: ". "))]"))
		}
	}
}

// MARK: - grep

public struct GrepTool: AgentTool {
	let access: FileAccess
	public let name = "grep"
	public let description = GeneratedTools.grepDescription
	public let schema = GeneratedTools.grepSchema

	public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		if Task.isCancelled { return .value("Operation aborted") }
		return try access.withAccess { roots in
			let target = try access.resolve(input["path"]?.stringValue, roots: roots)
			guard let isDir = isDirectory(target) else { throw FileToolError("Path not found: \(target.path)") }
			let raw = input["pattern"]?.stringValue ?? ""
			let pattern = input["literal"]?.boolValue == true ? NSRegularExpression.escapedPattern(for: raw) : raw
			let regex: NSRegularExpression
			do {
				regex = try NSRegularExpression(pattern: pattern, options: input["ignoreCase"]?.boolValue == true ? [.caseInsensitive] : [])
			} catch {
				throw FileToolError("Invalid regex: \(raw)")
			}
			let context = max(0, input["context"]?.intValue ?? 0)
			let limit = max(1, input["limit"]?.intValue ?? 100)
			let glob = input["glob"]?.stringValue

			var files: [URL] = []
			var timedOut = false
			var aborted = false
			if !isDir {
				files = [target]
			} else {
				let r = walkFiles(target) { file in
					if let glob, !matchGlob(relativePath(file, to: target), glob) { return false }
					files.append(file)
					return false
				}
				timedOut = r.timedOut
				aborted = r.aborted
			}

			var out: [String] = []
			var count = 0
			var limitReached = false
			var linesTruncated = false
			let deadline = ContinuousClock.now + WALK_TIMEOUT
			var scanTimedOut = false
			for file in files {
				if Task.isCancelled { aborted = true; break }
				if ContinuousClock.now > deadline { scanTimedOut = true; break }
				if count >= limit { limitReached = true; break }
				let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
				if size > GREP_MAX_FILE_BYTES || isBinaryFile(file) { continue }
				guard let data = try? Data(contentsOf: file) else { continue }
				let lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
				let rel = isDir ? relativePath(file, to: target) : file.lastPathComponent
				for (i, line) in lines.enumerated() where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
					if count >= limit { limitReached = true; break }
					count += 1
					let start = context > 0 ? max(1, i + 1 - context) : i + 1
					let end = context > 0 ? min(lines.count, i + 1 + context) : i + 1
					for current in start...end {
						var text = lines[current - 1]
						if text.count > GREP_MAX_LINE_LENGTH {
							text = String(text.prefix(GREP_MAX_LINE_LENGTH)) + "… [truncated]"
							linesTruncated = true
						}
						out.append(current == i + 1 ? "\(rel):\(current): \(text)" : "\(rel)-\(current)- \(text)")
					}
				}
				if limitReached { break }
			}
			if aborted {
				return .value(.string(out.isEmpty ? "Search aborted before any results." : "\(capOutput(out).content)\n\n[search aborted — partial results]"))
			}
			if out.isEmpty {
				return .value(.string(timedOut || scanTimedOut ? "Search timed out after 10s with no matches yet. Narrow the search to a subdirectory." : "No matches found"))
			}
			let (content, truncated) = capOutput(out)
			var notices: [String] = []
			if limitReached || count >= limit { notices.append("\(limit) matches limit reached") }
			if linesTruncated { notices.append("Some lines truncated to \(GREP_MAX_LINE_LENGTH) chars. Use read tool to see full lines") }
			if truncated { notices.append("\(formatSize(MAX_OUTPUT_BYTES)) limit reached") }
			if timedOut || scanTimedOut { notices.append("search timed out after 10s — partial results, narrow the directory") }
			return .value(.string(notices.isEmpty ? content : "\(content)\n\n[\(notices.joined(separator: ". "))]"))
		}
	}
}
