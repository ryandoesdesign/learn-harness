import Foundation
import LHCore

/// LHCore's ChatStore port (graph derivations read titles/records through it).
extension ChatRepository: ChatStore {
	public func getChat(_ id: String) -> ChatRecord? { (try? get(id)) ?? nil }
	public func listChats() -> [ChatSummary] { (try? summaries()) ?? [] }
}
