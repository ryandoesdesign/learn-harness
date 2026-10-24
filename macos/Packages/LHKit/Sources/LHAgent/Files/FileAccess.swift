import Foundation
import LHCore

/// A file tool's failure — its message is the error result the model sees.
public struct FileToolError: Error, Sendable, CustomStringConvertible {
	public var message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// The learner-folder gate (docs/native-macos-m6.md, your answer): the
/// sandboxed app reads only the folders you granted in Settings → Learner
/// folders. No path, or a relative one, resolves against the first folder;
/// absolute and `~` paths must land inside a granted folder (symlinks
/// resolved); the app's own container data is always denied.
public struct FileAccess: Sendable {
	/// The granted folders, resolved from their bookmarks (first = default root).
	public var folders: @Sendable () -> [URL]
	/// The real home folder (`~` expands here, never the container's home).
	public var home: URL
	/// Paths never readable (the container's own data).
	public var denied: [URL]

	public init(folders: @escaping @Sendable () -> [URL], home: URL = FileAccess.realHome, denied: [URL] = [FileAccess.containerData]) {
		self.folders = folders
		self.home = home
		self.denied = denied
	}

	/// The user's real home directory (outside the sandbox container).
	public static var realHome: URL {
		if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
		return FileManager.default.homeDirectoryForCurrentUser
	}

	/// The sandbox container's data folder (Library/Containers/<id>/Data).
	public static var containerData: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

	/// Run `body` with every granted folder's security scope open.
	public func withAccess<T>(_ body: ([URL]) throws -> T) rethrows -> T {
		let roots = folders()
		let started = roots.map { $0.startAccessingSecurityScopedResource() }
		defer { for (url, s) in zip(roots, started) where s { url.stopAccessingSecurityScopedResource() } }
		return try body(roots)
	}

	/// Resolve a tool path to an allowed absolute URL (call inside `withAccess`).
	public func resolve(_ raw: String?, roots: [URL]) throws(FileToolError) -> URL {
		guard let root = roots.first else {
			throw FileToolError("No learner folders are set up yet. Ask the learner to add one in Settings → Learner folders.")
		}
		let p = (raw ?? "").trimmingCharacters(in: .whitespaces)
		let url: URL
		if p.isEmpty {
			url = root
		} else if p == "~" {
			url = home
		} else if p.hasPrefix("~/") {
			url = home.appending(path: String(p.dropFirst(2)))
		} else if p.hasPrefix("/") {
			url = URL(fileURLWithPath: p)
		} else {
			url = root.appending(path: p)
		}
		let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
		guard isAllowed(resolved, roots: roots) else {
			let list = roots.map(\.path).joined(separator: ", ")
			throw FileToolError("\"\(p.isEmpty ? url.path : p)\" is outside the folders LearnHarness can read (\(list)). Ask the learner to add its folder in Settings → Learner folders.")
		}
		return resolved
	}

	/// Inside a granted folder and outside every denied one.
	public func isAllowed(_ url: URL, roots: [URL]) -> Bool {
		let path = url.standardizedFileURL.resolvingSymlinksInPath().path
		func inside(_ base: URL) -> Bool {
			let b = base.standardizedFileURL.resolvingSymlinksInPath().path
			return path == b || path.hasPrefix(b.hasSuffix("/") ? b : b + "/")
		}
		if denied.contains(where: inside) { return false }
		return roots.contains(where: inside)
	}
}

// MARK: - Shared helpers (fs-shared.ts)

let MAX_OUTPUT_BYTES = 50 * 1024
let GREP_MAX_LINE_LENGTH = 500
let WALK_TIMEOUT: Duration = .seconds(10)
let EXCLUDED_DIR_NAMES: Set<String> = ["node_modules", ".git", "Library", ".Trash"]

/// `formatSize`: "12.3KB" / "512B".
func formatSize(_ bytes: Int) -> String {
	bytes >= 1024 ? "\(jsToFixed(Double(bytes) / 1024, 1))KB" : "\(bytes)B"
}

/// Cut at whole lines under MAX_OUTPUT_BYTES.
func capOutput(_ lines: [String]) -> (content: String, truncated: Bool) {
	var out: [String] = []
	var bytes = 0
	for line in lines {
		let add = line.utf8.count + (out.isEmpty ? 0 : 1)
		if bytes + add > MAX_OUTPUT_BYTES { return (out.joined(separator: "\n"), true) }
		out.append(line)
		bytes += add
	}
	return (out.joined(separator: "\n"), false)
}

/// Top-level brace expansion: `*.{ts,tsx}` → `*.ts`, `*.tsx`.
func expandBraces(_ pattern: String) -> [String] {
	guard let open = pattern.firstIndex(of: "{"), let close = pattern[open...].firstIndex(of: "}") else { return [pattern] }
	let before = String(pattern[..<open])
	let after = String(pattern[pattern.index(after: close)...])
	let alternatives = pattern[pattern.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
	var out: [String] = []
	for alt in alternatives { out += expandBraces(before + alt + after) }
	return out
}

/// fd-style glob → regex: `*` within a segment, `**` across, `?` one char.
func globToRegex(_ glob: String) -> NSRegularExpression? {
	var re = ""
	let chars = Array(glob)
	var i = 0
	while i < chars.count {
		let c = chars[i]
		if c == "*" {
			if i + 1 < chars.count, chars[i + 1] == "*" {
				re += "[\\s\\S]*"
				i += 1
				if i + 1 < chars.count, chars[i + 1] == "/" { i += 1 }
			} else {
				re += "[^/]*"
			}
		} else if c == "?" {
			re += "[^/]"
		} else {
			re += NSRegularExpression.escapedPattern(for: String(c))
		}
		i += 1
	}
	return try? NSRegularExpression(pattern: "^\(re)$")
}

/// `matchGlob`: a slash-less pattern matches the basename at any depth; a
/// pattern with a slash gets an implied `**/` unless it starts with `/`.
func matchGlob(_ relativePath: String, _ pattern: String) -> Bool {
	let basename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
	for alt in expandBraces(pattern) {
		let subject: String
		var effective = alt
		if !alt.contains("/") {
			subject = basename
		} else {
			if !effective.hasPrefix("/"), !effective.hasPrefix("**/"), effective != "**" { effective = "**/\(effective)" }
			if effective.hasPrefix("/") { effective.removeFirst() }
			subject = relativePath
		}
		if let re = globToRegex(effective), re.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil { return true }
	}
	return false
}

/// Walk files under `root` (skipping excluded dirs and symlinks, as Dirent
/// isDirectory/isFile do) until `visit` returns true, the 10s budget runs
/// out, or the task is cancelled. Unreadable directories are skipped.
func walkFiles(_ root: URL, _ visit: (URL) -> Bool) -> (timedOut: Bool, aborted: Bool) {
	let deadline = ContinuousClock.now + WALK_TIMEOUT
	let fm = FileManager.default
	func walk(_ dir: URL) -> (stop: Bool, timedOut: Bool, aborted: Bool) {
		if ContinuousClock.now > deadline { return (true, true, false) }
		if Task.isCancelled { return (true, false, true) }
		guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return (false, false, false) }
		for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			if ContinuousClock.now > deadline { return (true, true, false) }
			if Task.isCancelled { return (true, false, true) }
			let v = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
			if v?.isSymbolicLink == true { continue }
			if v?.isDirectory == true {
				if EXCLUDED_DIR_NAMES.contains(entry.lastPathComponent) { continue }
				let r = walk(entry)
				if r.stop { return r }
			} else if v?.isRegularFile == true {
				if visit(entry) { return (true, false, false) }
			}
		}
		return (false, false, false)
	}
	let r = walk(root)
	return (r.timedOut, r.aborted)
}

/// A NUL byte in the first 8 KB.
func isBinaryFile(_ url: URL) -> Bool {
	guard let h = try? FileHandle(forReadingFrom: url) else { return true }
	defer { try? h.close() }
	let data = (try? h.read(upToCount: 8192)) ?? Data()
	return data.contains(0)
}

/// POSIX path of `url` relative to `root`.
func relativePath(_ url: URL, to root: URL) -> String {
	let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
	guard p.hasPrefix(r) else { return p }
	return String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
