import Foundation
import GRDB

/// Security-scoped bookmarks: how the sandboxed app keeps access to folders
/// the user granted through an open panel. M2 uses `withAccess` for the
/// one-shot import pick; M6 persists the file tools' folders here.
public struct BookmarkStore: Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	public struct Folder: Sendable, Hashable {
		public var id: String
		public var path: String
		public var bookmark: Data
	}

	/// Persist a granted folder (security-scoped, read-only).
	@discardableResult
	public func add(_ url: URL, now: Date = Date()) throws -> Folder {
		let data = try Self.makeBookmark(url)
		let folder = Folder(id: "fb_\(UUID().uuidString.lowercased().prefix(12))", path: url.path, bookmark: data)
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO folder_bookmark (id, path, bookmark, created_at) VALUES (?, ?, ?, ?)",
				arguments: [folder.id, folder.path, folder.bookmark, ISOClock.string(now)])
		}
		return folder
	}

	public func list() throws -> [Folder] {
		try database.writer.read { db in
			try Row.fetchAll(db, sql: "SELECT id, path, bookmark FROM folder_bookmark ORDER BY created_at").map {
				Folder(id: $0["id"], path: $0["path"], bookmark: $0["bookmark"])
			}
		}
	}

	public func remove(_ id: String) throws {
		try database.writer.write { db in try db.execute(sql: "DELETE FROM folder_bookmark WHERE id = ?", arguments: [id]) }
	}

	/// Resolve a stored bookmark; a stale one is re-created and saved.
	/// Throws when the folder is gone (the UI re-requests it).
	public func resolve(_ folder: Folder) throws -> URL {
		var stale = false
		let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
		if stale {
			let fresh = try url.withSecurityScope { try Self.makeBookmark(url) }
			try database.writer.write { db in
				try db.execute(sql: "UPDATE folder_bookmark SET bookmark = ?, path = ? WHERE id = ?", arguments: [fresh, url.path, folder.id])
			}
		}
		return url
	}

	static func makeBookmark(_ url: URL) throws -> Data {
		try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
	}
}

extension URL {
	/// Run `body` inside the URL's security scope (a no-op scope outside the
	/// sandbox or for non-scoped URLs).
	public func withSecurityScope<T>(_ body: () throws -> T) rethrows -> T {
		let started = startAccessingSecurityScopedResource()
		defer { if started { stopAccessingSecurityScopedResource() } }
		return try body()
	}
}
