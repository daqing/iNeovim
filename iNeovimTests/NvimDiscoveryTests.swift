import XCTest
@testable import iNeovim

@MainActor
final class NvimDiscoveryTests: XCTestCase {
    private func makeBrewFixtureDirectory(executable: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brew = dir.appendingPathComponent("brew")
        FileManager.default.createFile(atPath: brew.path, contents: nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: brew.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testLocateHomebrewFindsExecutableBrew() throws {
        let dir = try makeBrewFixtureDirectory(executable: true)

        XCTAssertEqual(NvimDiscovery.locateHomebrew(in: [dir.path]), dir.appendingPathComponent("brew"))
    }

    func testLocateHomebrewSkipsNonExecutableBrew() throws {
        let dir = try makeBrewFixtureDirectory(executable: false)

        XCTAssertNil(NvimDiscovery.locateHomebrew(in: [dir.path]))
    }

    func testLocateHomebrewPrefersEarlierDirectories() throws {
        let first = try makeBrewFixtureDirectory(executable: true)
        let second = try makeBrewFixtureDirectory(executable: true)

        XCTAssertEqual(
            NvimDiscovery.locateHomebrew(in: [first.path, second.path]),
            first.appendingPathComponent("brew")
        )
    }
}
