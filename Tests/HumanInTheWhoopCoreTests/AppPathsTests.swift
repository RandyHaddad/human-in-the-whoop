import Foundation
#if canImport(XCTest)
import XCTest
@testable import HumanInTheWhoopCore

final class AppPathsTests: XCTestCase {
    func testOverrideRootKeepsAllStateInsideTestDirectory() {
        let root = URL(fileURLWithPath: "/tmp/hitw-path-test", isDirectory: true)
        let paths = AppPaths(rootOverride: root)

        XCTAssertEqual(paths.root, root)
        XCTAssertEqual(paths.database, root.appendingPathComponent("state.sqlite3"))
        XCTAssertEqual(paths.binDirectory, root.appendingPathComponent("bin", isDirectory: true))
    }
}
#else
import Testing
@testable import HumanInTheWhoopCore

@Suite struct AppPathsTests {
    @Test func overrideRootKeepsAllStateInsideTestDirectory() {
        let root = URL(fileURLWithPath: "/tmp/hitw-path-test", isDirectory: true)
        let paths = AppPaths(rootOverride: root)

        #expect(paths.root == root)
        #expect(paths.database == root.appendingPathComponent("state.sqlite3"))
        #expect(paths.binDirectory == root.appendingPathComponent("bin", isDirectory: true))
    }
}
#endif
