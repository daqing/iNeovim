import XCTest
@testable import iNeovim

@MainActor
final class FuzzyMatcherTests: XCTestCase {
    func testFallbackFilterKeepsSubsequencesInOrder() async {
        let results = await FuzzyMatcher.filter(
            "mdl",
            candidates: ["Sources/App/Model.swift", "Sources/App/Modal.swift", "README.md"]
        )
        XCTAssertTrue(results.contains("Sources/App/Model.swift"))
        XCTAssertFalse(results.contains("Sources/App/Modal.swift"), "l before d must not match")
        XCTAssertFalse(results.contains("README.md"))
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
