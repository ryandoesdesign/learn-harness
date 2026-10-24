import Foundation
import Testing
@testable import LHCore

// Port of tests/session-find.test.tsx — the pure matcher and stepper. The
// DOM seam cases (ranges, hidden subtrees, highlight registry) have no
// native counterpart; per-block display text is tested in LHMarkdownTests.

private func m(_ s: Int, _ e: Int) -> SessionTextMatch { SessionTextMatch(start: s, end: e) }

@Suite struct FindSessionTextMatchesTests {
	@Test func findsEveryLiteralOccurrenceAnyCase() {
		#expect(findSessionTextMatches("Cat and CAT", "cat") == [m(0, 3), m(8, 11)])
		#expect(findSessionTextMatches("scat", "cat") == [m(1, 4)])
	}
	@Test func regexMetacharactersAreInert() {
		#expect(findSessionTextMatches("a.b axb ?*+ (x) [y]", "a.b") == [m(0, 3)])
		#expect(findSessionTextMatches("cost $5 now", "$5") == [m(5, 7)])
		#expect(findSessionTextMatches("a\\b", "a\\b") == [m(0, 3)])
	}
	@Test func emptyQueryMatchesNothing() {
		#expect(findSessionTextMatches("anything", "") == [])
	}
	@Test func unicodeAwareUTF16Offsets() {
		#expect(findSessionTextMatches("α αα", "αα") == [m(2, 4)])
	}
}

@Suite struct StepSessionMatchTests {
	@Test func stepsAndWraps() {
		#expect(stepSessionMatch(0, 3, 1) == 1)
		#expect(stepSessionMatch(2, 3, 1) == 0)
		#expect(stepSessionMatch(0, 3, -1) == 2)
		#expect(stepSessionMatch(1, 3, -1) == 0)
		#expect(stepSessionMatch(-1, 0, 1) == -1)
	}
}
