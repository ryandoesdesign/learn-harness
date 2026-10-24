import Foundation
import Testing
@testable import LHAgent
@testable import LHCore

// Ports of tests/fs-tools.test.ts and read-tool.test.ts, plus the native
// learner-folder gate (docs/native-macos-m6.md) and the four fixes: `~`
// paths, grep's invalid-regex message, the read size limit, binary files.

/// The TS fixture tree in a fresh temp folder (the granted learner folder).
private func fixture() throws -> URL {
	let root = FileManager.default.temporaryDirectory.appending(path: "lh-fs-\(UUID().uuidString)").resolvingSymlinksInPath()
	let fm = FileManager.default
	for d in ["notes/sub", "code", "node_modules", "Library"] { try fm.createDirectory(at: root.appending(path: d), withIntermediateDirectories: true) }
	func write(_ p: String, _ s: String) throws { try Data(s.utf8).write(to: root.appending(path: p)) }
	try write("notes/calculus.md", "Calculus notes\nThe derivative measures force.\nChapter 1\n")
	try write("notes/linear.txt", "Eigenvectors keep their direction\nonly scaling remains\n")
	try write("notes/sub/hidden.md", "deep file about MU\n")
	try write("code/main.ts", "const x = 1;\nconst eigenvector = 'here';\n")
	try write("node_modules/skipme.txt", "eigenvector in node_modules\n")
	try write("Library/alsoskip.txt", "eigenvector in Library\n")
	try Data([0x00, 0x01, 0x02, 0x65, 0x69, 0x67, 0x03]).write(to: root.appending(path: "binary.bin"))
	return root
}

private struct Tools {
	let root: URL
	let read: ReadTool, ls: LsTool, find: FindTool, grep: GrepTool
	init(home: URL? = nil) throws {
		let root = try fixture()
		self.root = root
		let access = FileAccess(folders: { [root] }, home: home ?? root.deletingLastPathComponent(), denied: [])
		let all = fileTools(access)
		read = all[0] as! ReadTool
		ls = all[1] as! LsTool
		find = all[2] as! FindTool
		grep = all[3] as! GrepTool
	}
}

private func text(_ tool: any AgentTool, _ input: JSONValue) async throws -> String {
	let out = try await tool.execute(input, context: ToolContext(toolCallId: "c"))
	return out.content.first?.raw["text"]?.stringValue ?? ""
}

private func failure(_ tool: any AgentTool, _ input: JSONValue) async -> String? {
	do {
		_ = try await tool.execute(input, context: ToolContext(toolCallId: "c"))
		return nil
	} catch {
		return "\(error)"
	}
}

@Suite struct GlobHelperTests {
	@Test func basenameModeMatchesAtAnyDepth() {
		#expect(matchGlob("notes/sub/calculus.md", "*.md"))
		#expect(matchGlob("calculus.md", "*.md"))
		#expect(!matchGlob("notes/calculus.md", "*.ts"))
	}
	@Test func starStaysInASegmentDoubleStarCrosses() {
		#expect(matchGlob("a/b/c.txt", "*.txt"))
		#expect(matchGlob("src/x/a.spec.ts", "src/**/*.spec.ts"))
		#expect(!matchGlob("other/x/a.spec.ts", "src/**/*.spec.ts"))
		#expect(matchGlob("src/a.spec.ts", "src/**/*.spec.ts"), "** covers zero dirs")
	}
	@Test func slashPatternsGetAnImpliedDeepPrefix() {
		#expect(matchGlob("deep/nested/x/main.ts", "**/nested/**/main.ts"))
		#expect(!matchGlob("x/main.ts", "nested/main.ts"))
	}
	@Test func braceAlternativesExpand() {
		#expect(expandBraces("*.{ts,tsx}") == ["*.ts", "*.tsx"])
		#expect(matchGlob("code/main.ts", "*.{ts,tsx,js}"))
		#expect(!matchGlob("code/main.ts", "*.{js,jsx}"))
	}
	@Test func questionMarkIsOneCharLiteralsEscaped() {
		let re = globToRegex("a?c")!
		#expect(re.firstMatch(in: "abc", range: NSRange(location: 0, length: 3)) != nil)
		#expect(re.firstMatch(in: "ac", range: NSRange(location: 0, length: 2)) == nil)
		#expect(matchGlob("a.b.txt", "a.b*"))
	}
}

@Suite struct FileToolsTests {
	// MARK: ls
	@Test func lsListsSortedDirsSuffixedDotfilesIncluded() async throws {
		let t = try Tools()
		try Data().write(to: t.root.appending(path: ".hidden"))
		let out = try await text(t.ls, ["path": .string(t.root.path)])
		#expect(out.contains("code/") && out.contains("notes/") && out.contains("binary.bin") && out.contains(".hidden"))
		let lines = out.components(separatedBy: "\n").filter { !$0.hasPrefix("[") }
		#expect(lines == lines.sorted { $0.lowercased().localizedCompare($1.lowercased()) == .orderedAscending })
	}
	@Test func lsHonorsTheLimit() async throws {
		let t = try Tools()
		#expect(try await text(t.ls, ["path": .string(t.root.path), "limit": 2]).contains("[Truncated: 2 entries limit]"))
	}
	@Test func lsMissingAndNonDirectoryThrow() async throws {
		let t = try Tools()
		#expect(await failure(t.ls, ["path": .string(t.root.appending(path: "nope").path)])?.contains("Path not found") == true)
		#expect(await failure(t.ls, ["path": .string(t.root.appending(path: "binary.bin").path)])?.contains("Not a directory") == true)
	}

	// MARK: find
	@Test func findIsRelativeToTheSearchRootAndSkipsExcludedDirs() async throws {
		let t = try Tools()
		let md = try await text(t.find, ["pattern": "*.md", "path": .string(t.root.path)])
		#expect(md.contains("notes/calculus.md") && md.contains("notes/sub/hidden.md") && !md.contains(t.root.path))
		let txt = try await text(t.find, ["pattern": "*.txt", "path": .string(t.root.path)])
		#expect(!txt.contains("node_modules") && !txt.contains("Library") && txt.contains("notes/linear.txt"))
	}
	@Test func findLimitNoMatchAndSlashPatterns() async throws {
		let t = try Tools()
		#expect(try await text(t.find, ["pattern": "*", "path": .string(t.root.path), "limit": 2]).contains("[2 results limit reached]"))
		#expect(try await text(t.find, ["pattern": "*.nomatch", "path": .string(t.root.path)]) == "No files found matching pattern")
		let deep = try await text(t.find, ["pattern": "notes/**/*.md", "path": .string(t.root.path)])
		#expect(deep.contains("notes/sub/hidden.md") && !deep.contains("code/"))
	}

	// MARK: grep
	@Test func grepFormatsPiStyleAndSkipsExcludedAndBinary() async throws {
		let t = try Tools()
		#expect(try await text(t.grep, ["pattern": "eigenvector", "path": .string(t.root.path)]) == "code/main.ts:2: const eigenvector = 'here';")
	}
	@Test func grepIgnoreCaseLiteralContextAndGlob() async throws {
		let t = try Tools()
		#expect(try await text(t.grep, ["pattern": "EIGENVECTOR", "path": .string(t.root.path), "ignoreCase": true]).contains("linear.txt:1:"))
		#expect(try await text(t.grep, ["pattern": "e.gen", "literal": true, "path": .string(t.root.appending(path: "code").path)]) == "No matches found")
		let ctx = try await text(t.grep, ["pattern": "scaling", "path": .string(t.root.path), "context": 1])
		#expect(ctx.contains("notes/linear.txt:2: only scaling remains"))
		#expect(ctx.contains("notes/linear.txt-1- Eigenvectors keep their direction"))
		#expect(ctx.contains("notes/linear.txt-3- "))
		let globbed = try await text(t.grep, ["pattern": "eigenvector", "path": .string(t.root.path), "glob": "*.ts"])
		#expect(globbed.contains("main.ts:2:") && !globbed.contains("linear.txt"))
	}
	@Test func grepSingleFileUsesTheBasenameAndTheLimitNotice() async throws {
		let t = try Tools()
		let file = t.root.appending(path: "notes/calculus.md").path
		#expect(try await text(t.grep, ["pattern": "e", "path": .string(file)]).hasPrefix("calculus.md:1: "))
		#expect(try await text(t.grep, ["pattern": "e", "path": .string(file), "limit": 1]).contains("[1 matches limit reached]"))
		#expect(try await text(t.grep, ["pattern": "zzzz", "path": .string(t.root.path)]) == "No matches found")
	}
	@Test func grepReportsAnInvalidRegex() async throws {
		let t = try Tools()
		#expect(await failure(t.grep, ["pattern": "a(b", "path": .string(t.root.path)]) == "Invalid regex: a(b")
	}

	// MARK: read
	@Test func readVerbatimRelativeOffsetLimitAndEOF() async throws {
		let t = try Tools()
		#expect(try await text(t.read, ["path": "notes/linear.txt"]).contains("Eigenvectors keep their direction"), "relative → the first folder")
		let lines = (1...10).map { "line \($0)" }.joined(separator: "\n")
		try Data(lines.utf8).write(to: t.root.appending(path: "ten.txt"))
		#expect(try await text(t.read, ["path": "ten.txt", "offset": 3, "limit": 2]) == "line 3\nline 4\n\n[6 more lines in file. Use offset=5 to continue.]")
		#expect(await failure(t.read, ["path": "ten.txt", "offset": 50]) == "Offset 50 is beyond end of file (10 lines total)")
		#expect(await failure(t.read, ["path": "missing.txt"])?.contains("ENOENT") == true)
	}
	@Test func readTruncatesAt2000LinesAnd50KB() async throws {
		let t = try Tools()
		try Data((1...2500).map { "l\($0)" }.joined(separator: "\n").utf8).write(to: t.root.appending(path: "long.txt"))
		#expect(try await text(t.read, ["path": "long.txt"]).hasSuffix("[Showing lines 1-2000 of 2500 (2000 line limit). Use offset=2001 to continue.]"))
		try Data((1...100).map { _ in String(repeating: "x", count: 1000) }.joined(separator: "\n").utf8).write(to: t.root.appending(path: "wide.txt"))
		#expect(try await text(t.read, ["path": "wide.txt"]).contains("(50.0KB limit). Use offset="))
	}
	@Test func readAttachesImagesAndRefusesBinaryAndHugeFiles() async throws {
		let t = try Tools()
		let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
		try png.write(to: t.root.appending(path: "dot.png"))
		let out = try await t.read.execute(["path": "dot.png"], context: ToolContext(toolCallId: "c"))
		#expect(out.content.count == 2)
		#expect(out.content.last?.type == "image")
		#expect(try await text(t.read, ["path": "binary.bin"]).hasPrefix("Binary file — binary.bin"))
		let huge = t.root.appending(path: "huge.txt")
		FileManager.default.createFile(atPath: huge.path, contents: nil)
		let h = try FileHandle(forWritingTo: huge)
		try h.truncate(atOffset: 26 * 1024 * 1024)
		try h.close()
		#expect(await failure(t.read, ["path": "huge.txt"])?.hasPrefix("File is too large to read (") == true)
	}

	// MARK: The learner-folder gate
	@Test func pathsOutsideTheFoldersAreRefusedWithTheSettingsHint() async throws {
		let t = try Tools()
		let msg = await failure(t.read, ["path": "/etc/hosts"])
		#expect(msg?.hasPrefix("\"/etc/hosts\" is outside the folders Aster can read (\(t.root.path)).") == true, "\(msg ?? "")")
		#expect(await failure(t.read, ["path": "../outside.txt"])?.contains("is outside the folders") == true, "no escaping by ..")
	}
	@Test func tildeExpandsToTheRealHome() async throws {
		let t = try Tools(home: nil)
		// home = the fixture's parent, so ~/<fixture>/notes is inside the folder.
		#expect(try await text(t.read, ["path": .string("~/\(t.root.lastPathComponent)/notes/linear.txt")]).contains("Eigenvectors"))
	}
	@Test func symlinksOutOfAFolderAreRefused() async throws {
		let t = try Tools()
		try FileManager.default.createSymbolicLink(at: t.root.appending(path: "escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
		#expect(await failure(t.read, ["path": "escape/hosts"])?.contains("is outside the folders") == true)
	}
	@Test func noFoldersIsItsOwnRefusal() async throws {
		let read = fileTools(FileAccess(folders: { [] }, denied: []))[0]
		#expect(await failure(read, ["path": "x"]) == "No learner folders are set up yet. Ask the learner to add one in Settings → Learner folders.")
	}
	@Test func theContainerIsAlwaysDenied() throws {
		let t = try Tools()
		let access = FileAccess(folders: { [t.root] }, denied: [t.root.appending(path: "notes")])
		#expect(!access.isAllowed(t.root.appending(path: "notes/linear.txt"), roots: [t.root]))
		#expect(access.isAllowed(t.root.appending(path: "code/main.ts"), roots: [t.root]))
	}
}
