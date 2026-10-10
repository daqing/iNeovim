import XCTest
@testable import iNeovim

@MainActor
final class FuzzyMatcherTests: XCTestCase {
    func testFallbackFilterKeepsSubsequencesInOrder() {
        // Exercises the in-process scorer directly: fzf (preferred at runtime)
        // is absent on some machines, and both paths are subsequence matchers.
        let results = FuzzyMatcher.fallbackFilter(
            "mdl",
            candidates: ["Sources/App/Model.swift", "Sources/App/Modal.swift", "README.md"]
        )
        XCTAssertTrue(results.contains("Sources/App/Model.swift"))
        XCTAssertTrue(results.contains("Sources/App/Modal.swift"), "m→d→l is a subsequence of modal too")
        XCTAssertFalse(results.contains("README.md"), "no l after d in readme.md")
    }

    func testFallbackFilterPrefersSegmentStartsAndShorterPaths() async {
        let results = await FuzzyMatcher.filter(
            "init",
            candidates: [
                "runtime/lua/vim/init.lua",
                "docs/init-notes-about-init-things.txt",
            ]
        )
        XCTAssertEqual(results.first, "runtime/lua/vim/init.lua")
    }

    func testEmptyQueryReturnsPrefixOfCandidates() async {
        let results = await FuzzyMatcher.filter("", candidates: (0..<500).map(String.init))
        XCTAssertEqual(results.count, FuzzyMatcher.resultCap)
        XCTAssertEqual(results.first, "0")
    }
}
