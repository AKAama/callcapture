import XCTest
@testable import CallCapture

@available(macOS 14.2, *)
final class WorkerSearchPathTests: XCTestCase {
    func testSearchPathsIncludeBundledWorkerName() {
        let paths = PythonBridge.searchPaths()
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("/worker/call-capture-worker") },
            "expected a Resources/worker/call-capture-worker path, got \(paths)"
        )
    }

    func testSearchPathsIncludeResourcesLocation() {
        let paths = PythonBridge.searchPaths()
        XCTAssertTrue(
            paths.contains { $0.contains("/worker/call-capture-worker") },
            "search paths should target the bundled worker location"
        )
    }
}
